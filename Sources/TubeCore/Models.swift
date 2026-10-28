import Foundation

public struct Host: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var identityID: UUID?
    /// Password lives in the vault under `VaultSecret.hostPassword(id)`; this only
    /// records that one exists.
    public var hasPassword: Bool
    /// Hops in connection order, like `ssh -J a,b target`.
    public var jumpHostIDs: [UUID]
    public var groupID: UUID?
    public var tags: [String]
    public var favorite: Bool
    public var notes: String
    public var terminal: TerminalSettings?
    public var lastConnected: Date?
    public var updatedAt: Date

    public init(id: UUID = UUID(), label: String = "", hostname: String, port: Int = 22, username: String,
                identityID: UUID? = nil, hasPassword: Bool = false, jumpHostIDs: [UUID] = [],
                groupID: UUID? = nil, tags: [String] = [], favorite: Bool = false, notes: String = "",
                terminal: TerminalSettings? = nil, lastConnected: Date? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityID = identityID
        self.hasPassword = hasPassword
        self.jumpHostIDs = jumpHostIDs
        self.groupID = groupID
        self.tags = tags
        self.favorite = favorite
        self.notes = notes
        self.terminal = terminal
        self.lastConnected = lastConnected
        self.updatedAt = updatedAt
    }

    public var displayName: String { label.isEmpty ? hostname : label }

    /// user@host or user@host:port, the form ProxyJump and the UI use.
    public var destination: String {
        let h = hostname.contains(":") ? "[\(hostname)]" : hostname
        return port == 22 ? "\(username)@\(h)" : "\(username)@\(h):\(port)"
    }
}

public struct HostGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.updatedAt = updatedAt
    }
}

public enum KeyAlgorithm: String, Codable, Sendable {
    case ed25519 = "ssh-ed25519"
    case rsa = "ssh-rsa"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
}

/// Public half of an SSH identity. The private key is a vault secret.
public struct Identity: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var algorithm: KeyAlgorithm
    /// OpenSSH authorized_keys line.
    public var publicKey: String
    public var hasPassphrase: Bool
    /// Off by default: private keys stay on the device that created them.
    public var syncPrivateKey: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), label: String, algorithm: KeyAlgorithm, publicKey: String,
                hasPassphrase: Bool = false, syncPrivateKey: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.hasPassphrase = hasPassphrase
        self.syncPrivateKey = syncPrivateKey
        self.updatedAt = updatedAt
    }
}

public struct TerminalSettings: Codable, Hashable, Sendable {
    public var themeName: String
    public var fontName: String
    public var fontSize: Double
    public var backspaceSendsControlH: Bool

    public init(themeName: String = "Tube Dark", fontName: String = "Menlo", fontSize: Double = 13,
                backspaceSendsControlH: Bool = false) {
        self.themeName = themeName
        self.fontName = fontName
        self.fontSize = fontSize
        self.backspaceSendsControlH = backspaceSendsControlH
    }
}

public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var folder: String
    /// Append a carriage return when run.
    public var runImmediately: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, command: String, folder: String = "",
                runImmediately: Bool = true, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.command = command
        self.folder = folder
        self.runImmediately = runImmediately
        self.updatedAt = updatedAt
    }

    /// Names of `{{var}}` placeholders in first-appearance order.
    public var variables: [String] { SnippetTemplate.variables(in: command) }

    public func render(_ values: [String: String]) -> String {
        SnippetTemplate.render(command, values: values)
    }
}

public enum SnippetTemplate {
    static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#)

    public static func variables(in s: String) -> [String] {
        var seen: [String] = []
        let ns = s as NSString
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    /// Unknown variables are left in place so a missing value is visible rather
    /// than silently producing a different command.
    public static func render(_ s: String, values: [String: String]) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += values[name] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

public struct PortForward: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, remote, dynamic }

    public var id: UUID
    public var label: String
    public var hostID: UUID
    public var kind: Kind
    public var bindAddress: String
    public var bindPort: Int
    /// Unused for dynamic (SOCKS) forwards.
    public var targetHost: String
    public var targetPort: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(), label: String = "", hostID: UUID, kind: Kind, bindAddress: String = "127.0.0.1",
                bindPort: Int, targetHost: String = "", targetPort: Int = 0, updatedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.hostID = hostID
        self.kind = kind
        self.bindAddress = bindAddress
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.updatedAt = updatedAt
    }
}
