import Foundation
import SwiftUI
import Crypto
import TubeCore
import TubeSync

/// Maps AppStore contents to sync records:
///
///   host / group / identity / snippet / forward   id = entity UUID
///   known_host                                    id = "kh-" + sha256(endpoint) prefix
///   secret                                        id = "pw-<host>" or "key-<identity>"
///   settings                                      id = "settings"
///
/// Private keys are only included for identities with syncPrivateKey on.
@MainActor
final class AppSyncStore: SyncStore {
    let store: AppStore

    init(store: AppStore) { self.store = store }

    var cursor: Int {
        get { store.data.sync.cursor }
        set { store.data.sync.cursor = newValue }
    }

    private struct Item {
        let kind: String
        let body: Data
        let updatedAt: Date
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    private struct SecretBody: Codable {
        var value: String
        var passphrase: String?
    }

    private struct KnownHostBody: Codable {
        var key: KnownHostKey
    }

    private func snapshot() -> [String: Item] {
        let d = store.data
        var out: [String: Item] = [:]
        func put<T: Encodable>(_ id: String, _ kind: String, _ value: T, _ date: Date) {
            if let body = try? Self.encoder.encode(value) {
                out[id] = Item(kind: kind, body: body, updatedAt: date)
            }
        }
        for h in d.hosts {
            // lastConnected is per device and would cause endless re-pushes.
            var copy = h
            copy.lastConnected = nil
            put(h.id.uuidString, "host", copy, h.updatedAt)
            if h.hasPassword, let pw = Keychain.string(for: .hostPassword(h.id)) {
                put("pw-" + h.id.uuidString, "secret", SecretBody(value: pw), h.updatedAt)
            }
        }
        for g in d.groups { put(g.id.uuidString, "group", g, g.updatedAt) }
        for i in d.identities {
            put(i.id.uuidString, "identity", i, i.updatedAt)
            if i.syncPrivateKey, let key = Keychain.string(for: .privateKey(i.id)) {
                put("key-" + i.id.uuidString, "secret",
                    SecretBody(value: key, passphrase: Keychain.string(for: .keyPassphrase(i.id))), i.updatedAt)
            }
        }
        for s in d.snippets { put(s.id.uuidString, "snippet", s, s.updatedAt) }
        for f in d.forwards { put(f.id.uuidString, "forward", f, f.updatedAt) }
        for k in d.knownHosts.keys { put(Self.knownHostID(k.endpoint), "known_host", KnownHostBody(key: k), k.addedAt) }
        return out
    }

    static func knownHostID(_ endpoint: String) -> String {
        "kh-" + SHA256.hash(data: Data(endpoint.utf8)).prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    func record(_ id: String) -> LocalRecord? {
        let snap = snapshot()
        let meta = store.data.sync.meta[id]
        if let item = snap[id] {
            let dirty = meta.map { $0.hash != Self.hash(item.body) } ?? true
            return LocalRecord(id: id, kind: item.kind, body: item.body,
                               updatedAt: dirty ? max(item.updatedAt, meta?.updatedAt ?? .distantPast) : (meta?.updatedAt ?? item.updatedAt),
                               serverVersion: meta?.serverVersion ?? 0, dirty: dirty)
        }
        guard let meta else { return nil }
        // Known locally but gone: deleted here (dirty) unless already a tombstone.
        return LocalRecord(id: id, kind: meta.kind, body: nil, updatedAt: meta.updatedAt,
                           serverVersion: meta.serverVersion, dirty: meta.hash != "deleted")
    }

    func dirtyRecords() -> [LocalRecord] {
        let ids = Set(snapshot().keys).union(store.data.sync.meta.keys)
        return ids.compactMap { record($0) }.filter(\.dirty)
    }

    func allRecords() -> [LocalRecord] {
        let ids = Set(snapshot().keys).union(store.data.sync.meta.keys)
        return ids.compactMap { record($0) }
    }

    func markSynced(id: String, version: Int) {
        let snap = snapshot()
        if let item = snap[id] {
            store.data.sync.meta[id] = .init(kind: item.kind, serverVersion: version, hash: Self.hash(item.body), updatedAt: item.updatedAt)
        } else if let meta = store.data.sync.meta[id] {
            store.data.sync.meta[id] = .init(kind: meta.kind, serverVersion: version, hash: "deleted", updatedAt: meta.updatedAt)
        }
    }

    func applyRemote(_ r: LocalRecord) {
        if r.dirty {
            // Rebase of a local edit (conflict won locally, or key rotation):
            // keep local data, remember the server version.
            var meta = store.data.sync.meta[r.id] ?? .init(kind: r.kind, serverVersion: 0, hash: "", updatedAt: r.updatedAt)
            meta.serverVersion = r.serverVersion
            meta.hash = "rebase"
            store.data.sync.meta[r.id] = meta
            return
        }
        guard let body = r.body else {
            delete(id: r.id, kind: r.kind)
            store.data.sync.meta[r.id] = .init(kind: r.kind, serverVersion: r.serverVersion, hash: "deleted", updatedAt: r.updatedAt)
            return
        }
        upsert(id: r.id, kind: r.kind, body: body)
        // Hash what the snapshot now produces, so a no-op round trip is not dirty.
        let h = snapshot()[r.id].map { Self.hash($0.body) } ?? Self.hash(body)
        store.data.sync.meta[r.id] = .init(kind: r.kind, serverVersion: r.serverVersion, hash: h, updatedAt: r.updatedAt)
    }

    private func upsert(id: String, kind: String, body: Data) {
        let dec = Self.decoder
        switch kind {
        case "host":
            guard var h = try? dec.decode(Host.self, from: body) else { return }
            if let i = store.data.hosts.firstIndex(where: { $0.id == h.id }) {
                h.lastConnected = store.data.hosts[i].lastConnected
                // hasPassword follows the secret record, not the remote device.
                h.hasPassword = store.data.hosts[i].hasPassword
                store.data.hosts[i] = h
            } else {
                h.hasPassword = Keychain.string(for: .hostPassword(h.id)) != nil
                store.data.hosts.append(h)
            }
        case "group":
            guard let g = try? dec.decode(HostGroup.self, from: body) else { return }
            replace(&store.data.groups, g)
        case "identity":
            guard var i = try? dec.decode(Identity.self, from: body) else { return }
            if let local = store.data.identities.first(where: { $0.id == i.id }) { i.hasPassphrase = local.hasPassphrase }
            replace(&store.data.identities, i)
        case "snippet":
            guard let s = try? dec.decode(Snippet.self, from: body) else { return }
            replace(&store.data.snippets, s)
        case "forward":
            guard let f = try? dec.decode(PortForward.self, from: body) else { return }
            replace(&store.data.forwards, f)
        case "known_host":
            guard let k = try? dec.decode(KnownHostBody.self, from: body).key else { return }
            let parts = k.endpoint.split(separator: ":")
            guard let port = parts.last.flatMap({ Int($0) }) else { return }
            let host = parts.dropLast().joined(separator: ":")
            // A synced key never replaces a different local one; that would be a
            // silent host key change.
            if case .changed = store.data.knownHosts.check(host: host, port: port, algorithm: k.algorithm, keyBase64: k.keyBase64) { return }
            store.data.knownHosts.trust(host: host, port: port, algorithm: k.algorithm, keyBase64: k.keyBase64)
        case "secret":
            guard let s = try? dec.decode(SecretBody.self, from: body) else { return }
            if id.hasPrefix("pw-"), let hid = UUID(uuidString: String(id.dropFirst(3))) {
                try? Keychain.set(s.value, for: .hostPassword(hid))
                if let i = store.data.hosts.firstIndex(where: { $0.id == hid }) { store.data.hosts[i].hasPassword = true }
            } else if id.hasPrefix("key-"), let iid = UUID(uuidString: String(id.dropFirst(4))) {
                try? Keychain.set(s.value, for: .privateKey(iid))
                if let p = s.passphrase { try? Keychain.set(p, for: .keyPassphrase(iid)) }
            }
        default:
            break
        }
    }

    private func delete(id: String, kind: String) {
        let uuid = UUID(uuidString: id)
        switch kind {
        case "host": if let uuid { store.delete(host: uuid) }
        case "group": store.data.groups.removeAll { $0.id == uuid }
        case "identity": if let uuid { store.delete(identity: uuid) }
        case "snippet": store.data.snippets.removeAll { $0.id == uuid }
        case "forward": store.data.forwards.removeAll { $0.id == uuid }
        case "known_host":
            // Forgetting a key on another device does not remove it here; a
            // removal should stay a deliberate local action.
            break
        case "secret":
            if id.hasPrefix("pw-"), let hid = UUID(uuidString: String(id.dropFirst(3))) {
                Keychain.remove(.hostPassword(hid))
                if let i = store.data.hosts.firstIndex(where: { $0.id == hid }) { store.data.hosts[i].hasPassword = false }
            }
            // Private keys are not deleted remotely: turning sync off on one
            // device must not wipe the key from the others.
        default:
            break
        }
    }

    private func replace<T: Identifiable>(_ list: inout [T], _ item: T) {
        if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
    }
}

@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var credentials: VaultCredentials?
    @Published private(set) var syncing = false
    @Published var lastError: String?
    @Published var devices: [SyncAPI.DeviceInfo] = []

    private let store: AppStore
    private lazy var adapter = AppSyncStore(store: store)
    private var pending: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
        if let raw = Keychain.data(for: .syncCredentials) {
            credentials = try? JSONDecoder().decode(VaultCredentials.self, from: raw)
        }
    }

    var enabled: Bool { credentials != nil }

    private func save(_ c: VaultCredentials?) throws {
        credentials = c
        if let c {
            try Keychain.set(try JSONEncoder().encode(c), for: .syncCredentials)
        } else {
            Keychain.remove(.syncCredentials)
        }
    }

    private var deviceName: String { UIDevice.current.name }

    func create(server: URL, registrationToken: String?) async throws -> RecoveryKey {
        let (c, rk) = try await VaultClient.create(server: server, deviceName: deviceName,
                                                   registrationToken: registrationToken?.isEmpty == true ? nil : registrationToken)
        resetLocalSyncState(server: server)
        try save(c)
        await syncNow()
        return rk
    }

    func join(code: String) async throws {
        let c = try await VaultClient.claim(code, deviceName: deviceName)
        resetLocalSyncState(server: c.serverURL)
        try save(c)
        await syncNow()
    }

    func recover(server: URL, vaultID: String, recoveryKey: String) async throws {
        let rk = try RecoveryKey(displayString: recoveryKey)
        let c = try await VaultClient.recover(server: server, vaultID: vaultID, recoveryKey: rk, deviceName: deviceName)
        resetLocalSyncState(server: server)
        try save(c)
        await syncNow()
    }

    func invite() async throws -> String {
        guard let c = credentials else { throw SyncError(status: 0, message: "Sync is off") }
        return try await VaultClient.invite(c)
    }

    func refreshDevices() async {
        guard let c = credentials else { return }
        do {
            devices = try await SyncAPI(baseURL: c.serverURL, token: c.token).devices()
        } catch {
            lastError = syncErrorText(error)
        }
    }

    func revoke(_ deviceID: String) async {
        guard let c = credentials else { return }
        do {
            try save(try await VaultClient.revokeAndRotate(c, deviceID: deviceID, store: adapter))
            await refreshDevices()
        } catch {
            lastError = syncErrorText(error)
        }
    }

    /// Stops syncing on this device. Local data stays.
    func leave() {
        try? save(nil)
        store.data.sync = SyncState()
    }

    private func resetLocalSyncState(server: URL) {
        // Everything local is pushed as new records into the joined vault.
        store.data.sync = SyncState()
        store.data.sync.serverURL = server.absoluteString
    }

    func syncNow() async {
        guard let c = credentials, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await VaultClient.sync(c, store: adapter)
            store.data.sync.lastSync = Date()
            lastError = nil
        } catch let e as SyncError where e.status == 401 {
            lastError = "This device was revoked or the vault was removed. Sync is off."
            try? save(nil)
        } catch {
            lastError = syncErrorText(error)
        }
    }

    /// Debounced sync after local edits.
    func scheduleSync() {
        guard enabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }
}
