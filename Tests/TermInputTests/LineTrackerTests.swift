import XCTest
@testable import TermInput

final class LineTrackerTests: XCTestCase {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testTypingAndReturn() {
        var t = LineTracker()
        XCTAssertNil(t.feed(bytes("git sta")))
        XCTAssertEqual(t.text, "git sta")
        XCTAssertEqual(t.feed(bytes("tus\r")), "git status")
        XCTAssertEqual(t.text, "")
    }

    func testEditing() {
        var t = LineTracker()
        _ = t.feed(bytes("docker pz"))
        _ = t.feed([0x7f])
        _ = t.feed(bytes("s"))
        XCTAssertEqual(t.text, "docker ps")
        _ = t.feed([0x17])
        XCTAssertEqual(t.text, "docker ")
        _ = t.feed([0x15])
        XCTAssertEqual(t.text, "")
    }

    func testUnknownAfterArrowsOrTab() {
        var t = LineTracker()
        _ = t.feed(bytes("ls /et"))
        _ = t.feed([0x09])                       // shell completes, we cannot see it
        XCTAssertFalse(t.known)
        XCTAssertNil(t.feed(bytes("c\r")), "must not record a line it could not follow")
        XCTAssertTrue(t.known)
        _ = t.feed(Array("\u{1b}[A".utf8))      // history recall
        XCTAssertFalse(t.known)
        _ = t.feed([0x03])
        XCTAssertTrue(t.known)
    }

    func testUTF8() {
        var t = LineTracker()
        XCTAssertEqual(t.feed(bytes("echo héllo\r")), "echo héllo")
    }
}

final class CommandSuggesterTests: XCTestCase {
    func testHistoryBeatsCommonAndRanks() {
        var s = CommandSuggester()
        let now = Date()
        s.record("git status", at: now)
        s.record("git push origin main", at: now)
        s.record("git push origin main", at: now)
        XCTAssertEqual(s.suggestions(for: "git p", now: now).first, "git push origin main")
        XCTAssertTrue(s.suggestions(for: "git", now: now).contains("git log --oneline -n 20"))
        XCTAssertEqual(s.suggestions(for: "", now: now), [])
        XCTAssertFalse(s.suggestions(for: "git status", now: now).contains("git status"))
    }

    func testRecencyDecay() {
        var s = CommandSuggester()
        let now = Date()
        for _ in 0..<3 { s.record("ssh old-box", at: now.addingTimeInterval(-90 * 86_400)) }
        s.record("ssh new-box", at: now)
        XCTAssertEqual(s.suggestions(for: "ssh ", now: now).first, "ssh new-box")
    }
}
