import Foundation
import SwiftUI
import TubeCore
import TermInput
import TubeSSH

/// Everything the app persists except secrets. Saved as one JSON file with
/// complete file protection; secrets are in the Keychain.
struct LocalData: Codable {
    var hosts: [Host] = []
    var groups: [HostGroup] = []
    var identities: [Identity] = []
    var snippets: [Snippet] = []
    var forwards: [PortForward] = []
    var knownHosts = KnownHosts()
    var settings = AppSettings()
    /// Commands sent from snippets or history; never typed input.
    var history: [String] = []
    var sync = SyncState()
    /// Commands typed in sessions, for suggestions. Device only, not synced.
    var commandHistory: [CommandSuggester.Entry] = []

    init() {}

    // Missing keys fall back to defaults so adding a field never makes an
    // older tube.json unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decodeIfPresent([Host].self, forKey: .hosts) ?? []
        groups = try c.decodeIfPresent([HostGroup].self, forKey: .groups) ?? []
        identities = try c.decodeIfPresent([Identity].self, forKey: .identities) ?? []
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
        knownHosts = try c.decodeIfPresent(KnownHosts.self, forKey: .knownHosts) ?? KnownHosts()
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        history = try c.decodeIfPresent([String].self, forKey: .history) ?? []
        sync = try c.decodeIfPresent(SyncState.self, forKey: .sync) ?? SyncState()
        commandHistory = try c.decodeIfPresent([CommandSuggester.Entry].self, forKey: .commandHistory) ?? []
    }
}

/// Sync bookkeeping. Records are diffed against `meta` hashes on each sync
/// instead of hooking every edit.
struct SyncState: Codable {
    struct Meta: Codable {
        var kind: String
        var serverVersion: Int
        var hash: String
        var updatedAt: Date
    }
    var cursor = 0
    var meta: [String: Meta] = [:]
    var lastSync: Date?
    var serverURL: String = ""
}

struct AppSettings: Codable, Equatable {
    var terminal = TerminalSettings()
    var lockWithBiometrics = false
    var showKeyPanelByDefault = false
    var keyClicks = true
    var keepAliveInBackground = false
    var reconnectOnReturn = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try c.decodeIfPresent(TerminalSettings.self, forKey: .terminal) ?? TerminalSettings()
        lockWithBiometrics = try c.decodeIfPresent(Bool.self, forKey: .lockWithBiometrics) ?? false
        showKeyPanelByDefault = try c.decodeIfPresent(Bool.self, forKey: .showKeyPanelByDefault) ?? false
        keyClicks = try c.decodeIfPresent(Bool.self, forKey: .keyClicks) ?? true
        keepAliveInBackground = try c.decodeIfPresent(Bool.self, forKey: .keepAliveInBackground) ?? false
        reconnectOnReturn = try c.decodeIfPresent(Bool.self, forKey: .reconnectOnReturn) ?? true
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var data: LocalData {
        didSet { scheduleSave() }
    }

    private let url: URL
    private var saveTask: Task<Void, Never>?

    init(url: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("tube.json")
        if let raw = try? Data(contentsOf: self.url) {
            if let decoded = try? JSONDecoder.tube.decode(LocalData.self, from: raw) {
                data = decoded
            } else {
                // Keep the unreadable file instead of overwriting it on the next save.
                let aside = self.url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: self.url, to: aside)
                data = LocalData()
            }
        } else {
            data = LocalData()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let raw = try? JSONEncoder.tube.encode(data) else { return }
        try? raw.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Hosts

    func host(_ id: UUID?) -> Host? {
        guard let id else { return nil }
        return data.hosts.first { $0.id == id }
    }

    func upsert(_ host: Host, password: String?) {
        var h = host
        h.updatedAt = Date()
        if let password {
            if password.isEmpty {
                Keychain.remove(.hostPassword(h.id))
                h.hasPassword = false
            } else {
                try? Keychain.set(password, for: .hostPassword(h.id))
                h.hasPassword = true
            }
        }
        if let i = data.hosts.firstIndex(where: { $0.id == h.id }) {
            data.hosts[i] = h
        } else {
            data.hosts.append(h)
        }
    }

    func delete(host id: UUID) {
        Keychain.remove(.hostPassword(id))
        data.hosts.removeAll { $0.id == id }
        for i in data.hosts.indices {
            data.hosts[i].jumpHostIDs.removeAll { $0 == id }
        }
        data.forwards.removeAll { $0.hostID == id }
    }

    func markConnected(_ id: UUID) {
        guard let i = data.hosts.firstIndex(where: { $0.id == id }) else { return }
        data.hosts[i].lastConnected = Date()
    }

    /// Jump hosts first, target last. Fails on a missing or cyclic hop.
    /// Hosts in connection order: jump hosts first, target last.
    func chainHosts(for host: Host) throws -> [Host] {
        var out: [Host] = []
        var seen: Set<UUID> = [host.id]
        for id in host.jumpHostIDs {
            guard let j = self.host(id) else { throw ChainError.missingJumpHost }
            guard seen.insert(id).inserted else { throw ChainError.cycle }
            out.append(j)
        }
        return out + [host]
    }

    /// `passwords` are typed for this attempt and win over saved ones.
    func chain(for host: Host, passwords: [UUID: String] = [:]) throws -> [SSHHop] {
        try chainHosts(for: host).map { h in
            SSHHop(host: h.hostname, port: h.port, username: h.username,
                   credential: try passwords[h.id].map { .password($0) } ?? credential(for: h))
        }
    }

    func credential(for host: Host) throws -> SSHCredential {
        if let iid = host.identityID {
            guard let key = Keychain.string(for: .privateKey(iid)) else { throw ChainError.missingKey(host.displayName) }
            return .privateKey(key, passphrase: Keychain.string(for: .keyPassphrase(iid)))
        }
        if let pw = Keychain.string(for: .hostPassword(host.id)) {
            return .password(pw)
        }
        throw ChainError.noCredential(host.id, host.displayName)
    }

    // MARK: Identities

    func addIdentity(label: String, privateKey: String, passphrase: String?) throws -> Identity {
        let (alg, pub) = try SSHKeys.publicKeyLine(privateKey: privateKey, passphrase: passphrase, comment: label)
        let ident = Identity(label: label, algorithm: alg, publicKey: pub, hasPassphrase: !(passphrase ?? "").isEmpty)
        try Keychain.set(privateKey, for: .privateKey(ident.id))
        if let passphrase, !passphrase.isEmpty {
            try Keychain.set(passphrase, for: .keyPassphrase(ident.id))
        }
        data.identities.append(ident)
        return ident
    }

    func generateIdentity(label: String) throws -> Identity {
        let gen = SSHKeys.generateEd25519(comment: label)
        let ident = Identity(label: label, algorithm: .ed25519, publicKey: gen.publicKeyLine)
        try Keychain.set(gen.privateKeyOpenSSH, for: .privateKey(ident.id))
        data.identities.append(ident)
        return ident
    }

    func delete(identity id: UUID) {
        Keychain.remove(.privateKey(id))
        Keychain.remove(.keyPassphrase(id))
        data.identities.removeAll { $0.id == id }
        for i in data.hosts.indices where data.hosts[i].identityID == id {
            data.hosts[i].identityID = nil
        }
    }

    // MARK: History

    func recordHistory(_ command: String) {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        data.history.removeAll { $0 == c }
        data.history.insert(c, at: 0)
        if data.history.count > 200 { data.history.removeLast(data.history.count - 200) }
    }
}

enum ChainError: Error, CustomStringConvertible {
    case missingJumpHost
    case cycle
    case missingKey(String)
    case noCredential(UUID, String)

    var description: String {
        switch self {
        case .missingJumpHost: return "A jump host for this connection was deleted"
        case .cycle: return "Jump hosts form a loop"
        case .missingKey(let h): return "Private key for \(h) is missing from the Keychain"
        case .noCredential(_, let h): return "No password or identity set for \(h)"
        }
    }
}

extension JSONEncoder {
    static let tube: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let tube: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
