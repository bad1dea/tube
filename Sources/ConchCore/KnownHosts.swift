import Foundation
import Crypto

public struct KnownHostKey: Codable, Hashable, Sendable {
    /// "host:port", lowercased. Port is always included so a bastion on 2222 and
    /// a host on 22 with the same name do not share an entry.
    public var endpoint: String
    public var algorithm: String
    /// Base64 of the SSH wire-format public key blob.
    public var keyBase64: String
    public var addedAt: Date

    public init(endpoint: String, algorithm: String, keyBase64: String, addedAt: Date = Date()) {
        self.endpoint = endpoint
        self.algorithm = algorithm
        self.keyBase64 = keyBase64
        self.addedAt = addedAt
    }

    public var fingerprint: String { KnownHosts.fingerprint(blobBase64: keyBase64) }
}

public enum HostKeyCheck: Equatable, Sendable {
    case trusted
    /// First connection: the user must confirm the fingerprint.
    case unknown(fingerprint: String)
    /// Key differs from the stored one. Never accepted automatically.
    case changed(expected: String, presented: String)
}

public struct KnownHosts: Codable, Equatable, Sendable {
    public private(set) var keys: [KnownHostKey] = []

    public init(keys: [KnownHostKey] = []) { self.keys = keys }

    public static func endpoint(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    public func check(host: String, port: Int, algorithm: String, keyBase64: String) -> HostKeyCheck {
        let ep = Self.endpoint(host: host, port: port)
        let stored = keys.filter { $0.endpoint == ep }
        if stored.isEmpty {
            return .unknown(fingerprint: Self.fingerprint(blobBase64: keyBase64))
        }
        if stored.contains(where: { $0.keyBase64 == keyBase64 }) {
            return .trusted
        }
        return .changed(expected: stored[0].fingerprint, presented: Self.fingerprint(blobBase64: keyBase64))
    }

    /// Only for `.unknown` results the user accepted. Replacing a changed key goes
    /// through `remove` first so it is an explicit, separate action.
    public mutating func trust(host: String, port: Int, algorithm: String, keyBase64: String) {
        let ep = Self.endpoint(host: host, port: port)
        guard !keys.contains(where: { $0.endpoint == ep }) else { return }
        keys.append(KnownHostKey(endpoint: ep, algorithm: algorithm, keyBase64: keyBase64))
    }

    public mutating func remove(host: String, port: Int) {
        let ep = Self.endpoint(host: host, port: port)
        keys.removeAll { $0.endpoint == ep }
    }

    /// OpenSSH SHA256 fingerprint: unpadded base64 of SHA-256 over the key blob.
    public static func fingerprint(blobBase64: String) -> String {
        guard let blob = Data(base64Encoded: blobBase64) else { return "SHA256:?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Lines in OpenSSH known_hosts format, using `[host]:port` for non-22 ports.
    public func exportOpenSSH() -> String {
        keys.map { k in
            let colon = k.endpoint.lastIndex(of: ":")!
            let host = String(k.endpoint[..<colon])
            let port = String(k.endpoint[k.endpoint.index(after: colon)...])
            let name = port == "22" ? host : "[\(host)]:\(port)"
            return "\(name) \(k.algorithm) \(k.keyBase64)"
        }.joined(separator: "\n")
    }
}
