import Foundation
import Crypto
import ConchCore

/// What a device keeps to talk to its vault. Stored in the Keychain on iOS.
public struct VaultCredentials: Codable, Equatable, Sendable {
    public var serverURL: URL
    public var vaultID: String
    public var deviceID: String
    public var token: String
    public var epoch: Int
    /// Vault key per epoch; old epochs stay until every record is re-encrypted.
    public var keys: [Int: Data]
    /// KEK from the recovery key, kept so this device can re-wrap a rotated
    /// vault key without asking for the recovery key again.
    public var kek: Data

    var api: SyncAPI { SyncAPI(baseURL: serverURL, token: token) }
    func vaultKey(_ epoch: Int) -> VaultKey? { keys[epoch].map(VaultKey.init(bytes:)) }
}

/// A record as the app sees it: plaintext plus sync bookkeeping.
public struct LocalRecord: Equatable, Sendable {
    public var id: String
    public var kind: String
    /// nil for a local delete.
    public var body: Data?
    public var updatedAt: Date
    /// Last server version this device has seen; 0 if never synced.
    public var serverVersion: Int
    public var dirty: Bool

    public init(id: String, kind: String, body: Data?, updatedAt: Date, serverVersion: Int = 0, dirty: Bool = true) {
        self.id = id
        self.kind = kind
        self.body = body
        self.updatedAt = updatedAt
        self.serverVersion = serverVersion
        self.dirty = dirty
    }
}

/// The app's side of sync. Implementations persist records and the cursor.
public protocol SyncStore: AnyObject {
    var cursor: Int { get set }
    func record(_ id: String) -> LocalRecord?
    func dirtyRecords() -> [LocalRecord]
    func allRecords() -> [LocalRecord]
    /// Replace local state with a server copy. `body == nil` means deleted.
    func applyRemote(_ record: LocalRecord)
    func markSynced(id: String, version: Int)
}

/// Encrypted form: JSON envelope with the edit time so conflicts can be
/// resolved without trusting server timestamps.
struct Envelope: Codable {
    var updatedAt: Date
    var body: Data
}

public enum VaultClient {
    // MARK: Vault lifecycle

    public static func create(server: URL, deviceName: String, registrationToken: String? = nil) async throws -> (VaultCredentials, RecoveryKey) {
        let vaultID = UUID().uuidString.lowercased()
        let vk = VaultKey.generate()
        let rk = RecoveryKey.generate()
        let kek = VaultCrypto.kek(recovery: rk, vaultID: vaultID)
        let wrapped = try VaultCrypto.wrap(vk, recovery: rk, vaultID: vaultID)
        let dev = try await SyncAPI(baseURL: server).createVault(
            vaultID: vaultID, wrappedKey: wrapped,
            recoveryAuth: VaultCrypto.recoveryAuth(recovery: rk, vaultID: vaultID),
            deviceName: deviceName, registrationToken: registrationToken)
        let creds = VaultCredentials(serverURL: server, vaultID: vaultID, deviceID: dev.device_id, token: dev.token,
                                     epoch: 1, keys: [1: vk.bytes], kek: kek.withUnsafeBytes { Data($0) })
        return (creds, rk)
    }

    public static func recover(server: URL, vaultID: String, recoveryKey: RecoveryKey, deviceName: String) async throws -> VaultCredentials {
        let r = try await SyncAPI(baseURL: server).recover(
            vaultID: vaultID, recoveryAuth: VaultCrypto.recoveryAuth(recovery: recoveryKey, vaultID: vaultID), deviceName: deviceName)
        guard let wrapped = Data(base64Encoded: r.wrapped_key) else { throw VaultCryptoError.badCiphertext }
        let vk = try VaultCrypto.unwrap(wrapped, recovery: recoveryKey, vaultID: vaultID)
        let kek = VaultCrypto.kek(recovery: recoveryKey, vaultID: vaultID)
        return VaultCredentials(serverURL: server, vaultID: vaultID, deviceID: r.device.device_id, token: r.device.token,
                                epoch: r.key_epoch, keys: [r.key_epoch: vk.bytes], kek: kek.withUnsafeBytes { Data($0) })
    }

    /// Returns a `conch://pair` URL to show as QR/text on the existing device.
    public static func invite(_ creds: VaultCredentials) async throws -> String {
        let inviteID = Base32.encode(randomBytes(16))
        let secret = randomBytes(32)
        guard let vk = creds.keys[creds.epoch] else { throw VaultCryptoError.badCiphertext }
        let key = VaultCrypto.pairingKey(secret: secret, inviteID: inviteID)
        let payload = try VaultCrypto.seal(vk + creds.kek, key: key, aad: Data("conch-pair-v1|\(inviteID)".utf8))
        try await creds.api.createInvite(inviteID: inviteID, payload: payload)
        var c = URLComponents()
        c.scheme = "conch"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "server", value: creds.serverURL.absoluteString),
            URLQueryItem(name: "invite", value: inviteID),
            URLQueryItem(name: "secret", value: secret.base64URLEncoded),
        ]
        return c.string!
    }

    public static func claim(_ code: String, deviceName: String) async throws -> VaultCredentials {
        guard let c = URLComponents(string: code.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "conch", c.host == "pair",
              let server = c.queryItems?.first(where: { $0.name == "server" })?.value.flatMap(URL.init(string:)),
              let inviteID = c.queryItems?.first(where: { $0.name == "invite" })?.value,
              let secret = c.queryItems?.first(where: { $0.name == "secret" })?.value.flatMap(Data.init(base64URLEncoded:))
        else { throw SyncError(status: 0, message: "Not a Conch pairing code") }
        let claimed = try await SyncAPI(baseURL: server).claim(inviteID: inviteID, deviceName: deviceName)
        guard let payload = Data(base64Encoded: claimed.payload) else { throw VaultCryptoError.badCiphertext }
        let opened = try VaultCrypto.open(payload, key: VaultCrypto.pairingKey(secret: secret, inviteID: inviteID),
                                          aad: Data("conch-pair-v1|\(inviteID)".utf8))
        guard opened.count == 64 else { throw VaultCryptoError.badCiphertext }
        return VaultCredentials(serverURL: server, vaultID: claimed.device.vault_id, deviceID: claimed.device.device_id,
                                token: claimed.device.token, epoch: claimed.key_epoch,
                                keys: [claimed.key_epoch: Data(opened.prefix(32))], kek: Data(opened.suffix(32)))
    }

    /// Revokes a device and rotates the vault key so it cannot read anything
    /// written afterwards. All records are re-encrypted under the new key.
    public static func revokeAndRotate(_ creds: VaultCredentials, deviceID: String, store: SyncStore) async throws -> VaultCredentials {
        try await creds.api.revoke(deviceID: deviceID)
        return try await rotate(creds, store: store)
    }

    public static func rotate(_ creds: VaultCredentials, store: SyncStore) async throws -> VaultCredentials {
        // Bring local state up to date first so nothing is re-encrypted from stale data.
        try await sync(creds, store: store)
        let newKey = VaultKey.generate()
        let newEpoch = creds.epoch + 1
        let wrapped = try VaultCrypto.seal(newKey.bytes, key: SymmetricKey(data: creds.kek),
                                           aad: Data("conch-vk-v1|\(creds.vaultID)".utf8))
        try await creds.api.rotateKey(wrappedKey: wrapped, epoch: newEpoch)
        var next = creds
        next.epoch = newEpoch
        next.keys[newEpoch] = newKey.bytes
        for var r in store.allRecords() where r.serverVersion > 0 {
            r.dirty = true
            store.applyRemote(r)
        }
        try await sync(next, store: store)
        return next
    }

    // MARK: Sync

    /// Pull, merge, push. Newer `updatedAt` wins a conflict.
    @discardableResult
    public static func sync(_ creds: VaultCredentials, store: SyncStore) async throws -> (pulled: Int, pushed: Int) {
        let api = creds.api
        var pulled = 0
        while true {
            let page = try await api.pull(since: store.cursor)
            for remote in page.records {
                try merge(remote, creds: creds, store: store)
                pulled += 1
            }
            store.cursor = page.cursor
            if !page.more { break }
        }

        var pushed = 0
        for _ in 0..<3 {
            let dirty = store.dirtyRecords()
            if dirty.isEmpty { break }
            guard let key = creds.vaultKey(creds.epoch) else { throw VaultCryptoError.badCiphertext }
            let recordKey = VaultCrypto.recordKey(key, vaultID: creds.vaultID)
            var batch: [SyncAPI.PushRecord] = []
            for r in dirty {
                var ct: String?
                if let body = r.body {
                    let env = try JSONEncoder.sync.encode(Envelope(updatedAt: r.updatedAt, body: body))
                    ct = try VaultCrypto.seal(env, key: recordKey,
                                              aad: VaultCrypto.recordAAD(vaultID: creds.vaultID, recordID: r.id, kind: r.kind)).base64EncodedString()
                }
                batch.append(.init(id: r.id, kind: r.kind, base_version: r.serverVersion, epoch: creds.epoch,
                                   deleted: r.body == nil, ciphertext: ct))
            }
            for chunk in stride(from: 0, to: batch.count, by: 200).map({ Array(batch[$0..<min($0 + 200, batch.count)]) }) {
                let resp = try await api.push(chunk)
                for a in resp.applied {
                    store.markSynced(id: a.id, version: a.version)
                    pushed += 1
                }
                for c in resp.conflicts {
                    try merge(c, creds: creds, store: store)
                }
            }
        }
        return (pulled, pushed)
    }

    static func merge(_ remote: SyncAPI.Record, creds: VaultCredentials, store: SyncStore) throws {
        let local = store.record(remote.id)
        if let local, local.serverVersion >= remote.version { return }
        let decoded = try decrypt(remote, creds: creds)
        if let local, local.dirty {
            // Both sides changed. Keep whichever edit is newer; if ours wins,
            // rebase it on the server version so the next push applies.
            if local.updatedAt > (decoded?.updatedAt ?? .distantPast) {
                var rebased = local
                rebased.serverVersion = remote.version
                store.applyRemote(rebased)
                return
            }
        }
        store.applyRemote(LocalRecord(id: remote.id, kind: remote.kind, body: decoded?.body,
                                      updatedAt: decoded?.updatedAt ?? Date(), serverVersion: remote.version, dirty: false))
    }

    static func decrypt(_ r: SyncAPI.Record, creds: VaultCredentials) throws -> Envelope? {
        guard !r.deleted, let ctB64 = r.ciphertext, let ct = Data(base64Encoded: ctB64) else { return nil }
        guard let key = creds.vaultKey(r.epoch) else { throw VaultCryptoError.badCiphertext }
        let plain = try VaultCrypto.open(ct, key: VaultCrypto.recordKey(key, vaultID: creds.vaultID),
                                         aad: VaultCrypto.recordAAD(vaultID: creds.vaultID, recordID: r.id, kind: r.kind))
        return try JSONDecoder.sync.decode(Envelope.self, from: plain)
    }

    static func randomBytes(_ n: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: n * 8)).withUnsafeBytes { Data($0) }
    }
}

extension JSONEncoder {
    static let sync: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
}

extension JSONDecoder {
    static let sync: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
