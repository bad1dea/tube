import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SyncError: Error, Equatable, CustomStringConvertible {
    public let status: Int
    public let message: String
    public var description: String { "Sync server returned \(status): \(message)" }
}

/// Wire types and HTTP calls for server/sync. Field names match the Rust
/// structs (snake_case).
public struct SyncAPI: Sendable {
    public let baseURL: URL
    public var token: String?
    let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public struct DeviceToken: Codable, Equatable, Sendable {
        public var vault_id: String
        public var device_id: String
        public var token: String
    }

    public struct VaultInfo: Codable, Sendable {
        public var vault_id: String
        public var key_epoch: Int
        public var wrapped_key: String
        public var device_id: String
    }

    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var version: Int
        public var epoch: Int
        public var deleted: Bool
        public var ciphertext: String?
        public var seq: Int
        public var updated_by: String
        public var updated_at: Int
    }

    public struct PushRecord: Codable, Sendable {
        public var id: String
        public var kind: String
        public var base_version: Int
        public var epoch: Int
        public var deleted: Bool
        public var ciphertext: String?
    }

    public struct Applied: Codable, Sendable {
        public var id: String
        public var version: Int
        public var seq: Int
    }

    public struct PushResponse: Codable, Sendable {
        public var applied: [Applied]
        public var conflicts: [Record]
    }

    public struct PullResponse: Codable, Sendable {
        public var records: [Record]
        public var cursor: Int
        public var more: Bool
    }

    public struct DeviceInfo: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var created_at: Int
        public var last_seen: Int
        public var revoked: Bool
        public var current: Bool
    }

    public struct Claimed: Codable, Sendable {
        public var device: DeviceToken
        public var payload: String
        public var key_epoch: Int
    }

    public struct Recovered: Codable, Sendable {
        public var device: DeviceToken
        public var wrapped_key: String
        public var key_epoch: Int
    }

    struct Empty: Codable {}

    func request<Body: Encodable, Out: Decodable>(_ method: String, _ path: String, body: Body?,
                                                    headers: [String: String] = [:]) async throws -> Out {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        if path.contains("?"), let full = URL(string: path, relativeTo: baseURL) {
            req = URLRequest(url: full)
        }
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try JSONEncoder().encode(body) }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? String(decoding: data, as: UTF8.self)
            throw SyncError(status: status, message: msg)
        }
        if Out.self == Empty.self { return Empty() as! Out }
        return try JSONDecoder().decode(Out.self, from: data)
    }

    public func createVault(vaultID: String, wrappedKey: Data, recoveryAuth: Data, deviceName: String,
                            registrationToken: String?) async throws -> DeviceToken {
        struct Body: Encodable { let vault_id, wrapped_key, recovery_auth, device_name: String }
        return try await request("POST", "v1/vaults",
                                 body: Body(vault_id: vaultID, wrapped_key: wrappedKey.base64EncodedString(),
                                            recovery_auth: recoveryAuth.base64EncodedString(), device_name: deviceName),
                                 headers: registrationToken.map { ["x-conch-registration": $0] } ?? [:])
    }

    public func vault() async throws -> VaultInfo {
        try await request("GET", "v1/vault", body: Optional<Empty>.none)
    }

    public func rotateKey(wrappedKey: Data, epoch: Int) async throws {
        struct Body: Encodable { let wrapped_key: String; let key_epoch: Int }
        let _: Empty = try await request("PUT", "v1/vault/key", body: Body(wrapped_key: wrappedKey.base64EncodedString(), key_epoch: epoch))
    }

    public func pull(since: Int) async throws -> PullResponse {
        try await request("GET", "v1/records?since=\(since)", body: Optional<Empty>.none)
    }

    public func push(_ records: [PushRecord]) async throws -> PushResponse {
        struct Body: Encodable { let records: [PushRecord] }
        return try await request("POST", "v1/records", body: Body(records: records))
    }

    public func devices() async throws -> [DeviceInfo] {
        try await request("GET", "v1/devices", body: Optional<Empty>.none)
    }

    public func revoke(deviceID: String) async throws {
        let _: Empty = try await request("DELETE", "v1/devices/\(deviceID)", body: Optional<Empty>.none)
    }

    public func createInvite(inviteID: String, payload: Data) async throws {
        struct Body: Encodable { let invite_id, payload: String }
        struct Out: Decodable { let invite_id: String }
        let _: Out = try await request("POST", "v1/pairing", body: Body(invite_id: inviteID, payload: payload.base64EncodedString()))
    }

    public func claim(inviteID: String, deviceName: String) async throws -> Claimed {
        struct Body: Encodable { let device_name: String }
        return try await request("POST", "v1/pairing/\(inviteID)/claim", body: Body(device_name: deviceName))
    }

    public func recover(vaultID: String, recoveryAuth: Data, deviceName: String) async throws -> Recovered {
        struct Body: Encodable { let vault_id, recovery_auth, device_name: String }
        return try await request("POST", "v1/recover",
                                 body: Body(vault_id: vaultID, recovery_auth: recoveryAuth.base64EncodedString(), device_name: deviceName))
    }
}
