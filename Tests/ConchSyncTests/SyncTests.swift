import XCTest
import Foundation
import ConchCore
@testable import ConchSync

// Runs against a live server/sync binary. test/sync.sh starts one on a temp
// database and sets CONCH_SYNC_URL.

@MainActor
final class MemoryStore: SyncStore {
    var cursor = 0
    var records: [String: LocalRecord] = [:]

    func record(_ id: String) -> LocalRecord? { records[id] }
    func dirtyRecords() -> [LocalRecord] { records.values.filter(\.dirty).sorted { $0.id < $1.id } }
    func allRecords() -> [LocalRecord] { Array(records.values) }
    func applyRemote(_ r: LocalRecord) { records[r.id] = r }
    func markSynced(id: String, version: Int) {
        records[id]?.serverVersion = version
        records[id]?.dirty = false
    }

    func edit(_ id: String, kind: String = "host", _ text: String?, at: Date = Date()) {
        var r = records[id] ?? LocalRecord(id: id, kind: kind, body: nil, updatedAt: at)
        r.body = text.map { Data($0.utf8) }
        r.updatedAt = at
        r.dirty = true
        records[id] = r
    }

    func text(_ id: String) -> String? { records[id]?.body.map { String(decoding: $0, as: UTF8.self) } }
}

@MainActor
final class SyncTests: XCTestCase {
    var server: URL {
        get throws {
            let url = ProcessInfo.processInfo.environment["CONCH_SYNC_URL"]
            try XCTSkipIf(url == nil, "set CONCH_SYNC_URL (test/sync.sh)")
            return URL(string: url!)!
        }
    }

    func testTwoDevicesThroughPairing() async throws {
        let (a, rk) = try await VaultClient.create(server: try server, deviceName: "phone")
        XCTAssertEqual(rk.displayString.count, 39)
        let storeA = MemoryStore()
        storeA.edit("h1", "{\"hostname\":\"10.0.0.1\"}")
        storeA.edit("s1", kind: "snippet", "uptime")
        let r = try await VaultClient.sync(a, store: storeA)
        XCTAssertEqual(r.pushed, 2)

        let code = try await VaultClient.invite(a)
        XCTAssertTrue(code.hasPrefix("conch://pair?"))
        let b = try await VaultClient.claim(code, deviceName: "ipad")
        XCTAssertEqual(b.vaultID, a.vaultID)
        XCTAssertEqual(b.keys, a.keys)
        let storeB = MemoryStore()
        try await VaultClient.sync(b, store: storeB)
        XCTAssertEqual(storeB.text("h1"), "{\"hostname\":\"10.0.0.1\"}")
        XCTAssertEqual(storeB.text("s1"), "uptime")

        // Code is single use.
        do {
            _ = try await VaultClient.claim(code, deviceName: "again")
            XCTFail("invite reused")
        } catch let e as SyncError {
            XCTAssertEqual(e.status, 410)
        }

        // Edit on B, delete on B, both reach A.
        storeB.edit("h1", "{\"hostname\":\"10.0.0.2\"}")
        storeB.edit("s1", kind: "snippet", nil)
        try await VaultClient.sync(b, store: storeB)
        try await VaultClient.sync(a, store: storeA)
        XCTAssertEqual(storeA.text("h1"), "{\"hostname\":\"10.0.0.2\"}")
        XCTAssertNil(storeA.records["s1"]?.body)
    }

    func testOfflineEditsConflictNewestWins() async throws {
        let (a, rk) = try await VaultClient.create(server: try server, deviceName: "a")
        let b = try await VaultClient.recover(server: try server, vaultID: a.vaultID, recoveryKey: rk, deviceName: "b")
        let sa = MemoryStore(), sb = MemoryStore()
        sa.edit("h", "v1", at: Date(timeIntervalSince1970: 1000))
        try await VaultClient.sync(a, store: sa)
        try await VaultClient.sync(b, store: sb)

        // Both edit while offline; B's edit is newer.
        sa.edit("h", "from-a", at: Date(timeIntervalSince1970: 2000))
        sb.edit("h", "from-b", at: Date(timeIntervalSince1970: 3000))
        try await VaultClient.sync(a, store: sa)
        try await VaultClient.sync(b, store: sb)   // conflict: B newer, B wins and pushes
        try await VaultClient.sync(a, store: sa)
        XCTAssertEqual(sa.text("h"), "from-b")
        XCTAssertEqual(sb.text("h"), "from-b")

        // Older offline edit loses.
        sa.edit("h", "stale", at: Date(timeIntervalSince1970: 2500))
        sb.edit("h", "fresh", at: Date(timeIntervalSince1970: 4000))
        try await VaultClient.sync(b, store: sb)
        try await VaultClient.sync(a, store: sa)
        XCTAssertEqual(sa.text("h"), "fresh")
        XCTAssertFalse(sa.records["h"]!.dirty)
    }

    func testRecoveryOnFreshInstall() async throws {
        let (a, rk) = try await VaultClient.create(server: try server, deviceName: "old phone")
        let sa = MemoryStore()
        sa.edit("id1", kind: "identity", "ssh-ed25519 AAAA test")
        try await VaultClient.sync(a, store: sa)

        // Device lost. Fresh install knows only vault id + recovery key text.
        let typed = rk.displayString.lowercased().replacingOccurrences(of: "-", with: " ")
        let fresh = try await VaultClient.recover(server: try server, vaultID: a.vaultID,
                                                  recoveryKey: try RecoveryKey(displayString: typed), deviceName: "new phone")
        let sf = MemoryStore()
        try await VaultClient.sync(fresh, store: sf)
        XCTAssertEqual(sf.text("id1"), "ssh-ed25519 AAAA test")

        // Wrong key gets nothing.
        do {
            _ = try await VaultClient.recover(server: try server, vaultID: a.vaultID, recoveryKey: RecoveryKey.generate(), deviceName: "thief")
            XCTFail("recovered with wrong key")
        } catch let e as SyncError {
            XCTAssertEqual(e.status, 401)
        }
    }

    func testRevokedDeviceCannotReadNewData() async throws {
        let (a, rk) = try await VaultClient.create(server: try server, deviceName: "a")
        let lost = try await VaultClient.recover(server: try server, vaultID: a.vaultID, recoveryKey: rk, deviceName: "stolen")
        let sa = MemoryStore()
        sa.edit("h", "before")
        try await VaultClient.sync(a, store: sa)

        let rotated = try await VaultClient.revokeAndRotate(a, deviceID: lost.deviceID, store: sa)
        XCTAssertEqual(rotated.epoch, 2)
        XCTAssertNotEqual(rotated.keys[2], rotated.keys[1])

        // Token is dead.
        do {
            try await VaultClient.sync(lost, store: MemoryStore())
            XCTFail("revoked device synced")
        } catch let e as SyncError {
            XCTAssertEqual(e.status, 401)
        }

        // Records on the server are now under the new key: the old key cannot
        // open them even with a token.
        sa.edit("h", "after")
        try await VaultClient.sync(rotated, store: sa)
        let page = try await rotated.api.pull(since: 0)
        let rec = page.records.first { $0.id == "h" }!
        XCTAssertEqual(rec.epoch, 2)
        var oldOnly = lost
        oldOnly.keys = [2: lost.keys[1]!]
        XCTAssertThrowsError(try VaultClient.decrypt(rec, creds: oldOnly))

        // A device enrolled afterwards with the recovery key gets the new key.
        let later = try await VaultClient.recover(server: try server, vaultID: a.vaultID, recoveryKey: rk, deviceName: "replacement")
        XCTAssertEqual(later.epoch, 2)
        let sl = MemoryStore()
        try await VaultClient.sync(later, store: sl)
        XCTAssertEqual(sl.text("h"), "after")
    }

    func testServerNeverSeesPlaintext() async throws {
        let (a, _) = try await VaultClient.create(server: try server, deviceName: "a")
        let s = MemoryStore()
        s.edit("h", "hostname=very-secret-host.example password=hunter2")
        try await VaultClient.sync(a, store: s)
        let page = try await a.api.pull(since: 0)
        let ct = Data(base64Encoded: page.records[0].ciphertext!)!
        XCTAssertNil(String(data: ct, encoding: .utf8).flatMap { $0.contains("very-secret") ? $0 : nil })
        XCTAssertFalse(ct.range(of: Data("hunter2".utf8)) != nil)
    }
}
