import XCTest
import Foundation
import ConchCore
@testable import ConchSync

/// Middle step of test/interop.sh: records written by the web client must
/// decode into ConchCore types the way the iOS app decodes them, and records
/// written here must be readable by the web client.
@MainActor
final class InteropTests: XCTestCase {
    struct Info: Decodable {
        let vaultID: String
        let recoveryKey: String
        let hostID: String
        let jumpID: String
    }

    func testWebRecordsDecodeAsConchCoreTypes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["CONCH_INTEROP_FILE"], let server = env["CONCH_SYNC_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("run via test/interop.sh")
        }
        let info = try JSONDecoder().decode(Info.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let creds = try await VaultClient.recover(server: server, vaultID: info.vaultID,
                                                  recoveryKey: try RecoveryKey(displayString: info.recoveryKey), deviceName: "swift")
        let store = MemoryStore()
        try await VaultClient.sync(creds, store: store)

        // Same decoder settings as ios/Sources/Store/VaultSync.swift.
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .millisecondsSince1970

        var host = try dec.decode(Host.self, from: XCTUnwrap(store.records[info.hostID]?.body))
        XCTAssertEqual(host.hostname, "100.64.0.10")
        XCTAssertEqual(host.port, 2022)
        XCTAssertEqual(host.jumpHostIDs, [UUID(uuidString: info.jumpID)!])
        XCTAssertEqual(host.tags, ["lab", "tailnet"])
        XCTAssertEqual(host.terminal?.themeName, "Nord")
        XCTAssertTrue(host.favorite)
        XCTAssertEqual(host.id.uuidString, info.hostID, "web ids must be upper-case to match Swift record ids")
        let jump = try dec.decode(Host.self, from: XCTUnwrap(store.records[info.jumpID]?.body))
        XCTAssertEqual(jump.destination, "jump@ctrl.khuo.ng:2222")

        struct SecretBody: Decodable { let value: String }
        let pw = try dec.decode(SecretBody.self, from: XCTUnwrap(store.records["pw-" + info.hostID]?.body))
        XCTAssertEqual(pw.value, "from-web")

        struct KnownHostBody: Decodable { let key: KnownHostKey }
        let kh = store.records.values.first { $0.kind == "known_host" }
        XCTAssertEqual(try dec.decode(KnownHostBody.self, from: XCTUnwrap(kh?.body)).key.endpoint, "100.64.0.10:2022")

        // Write back the way iOS does.
        host.notes = "edited on iOS"
        host.updatedAt = Date()
        store.edit(info.hostID, kind: "host", String(decoding: try enc.encode(host), as: UTF8.self), at: host.updatedAt)
        let snippet = Snippet(name: "from-swift", command: "df -h {{path}}")
        store.edit(snippet.id.uuidString, kind: "snippet", String(decoding: try enc.encode(snippet), as: UTF8.self))
        try await VaultClient.sync(creds, store: store)
    }
}
