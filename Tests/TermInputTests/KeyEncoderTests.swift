import XCTest
@testable import TermInput

final class KeyEncoderTests: XCTestCase {
    func enc(_ k: TerminalKey, _ m: KeyModifiers = [], appCursor: Bool = false) -> [UInt8] {
        KeyEncoder.encode(k, modifiers: m, modes: TerminalModes(applicationCursor: appCursor))
    }

    func testControlLetters() {
        XCTAssertEqual(enc(.character("c"), .ctrl), [0x03])   // SIGINT
        XCTAssertEqual(enc(.character("d"), .ctrl), [0x04])   // EOF
        XCTAssertEqual(enc(.character("z"), .ctrl), [0x1a])   // SUSP
        XCTAssertEqual(enc(.character("l"), .ctrl), [0x0c])
        XCTAssertEqual(enc(.character("a"), .ctrl), [0x01])
        XCTAssertEqual(enc(.character("e"), .ctrl), [0x05])
        XCTAssertEqual(enc(.character("r"), .ctrl), [0x12])
        XCTAssertEqual(enc(.character("w"), .ctrl), [0x17])
        XCTAssertEqual(enc(.character("u"), .ctrl), [0x15])
        XCTAssertEqual(enc(.character("k"), .ctrl), [0x0b])
        XCTAssertEqual(enc(.character("b"), .ctrl), [0x02])   // tmux prefix
        XCTAssertEqual(enc(.character("f"), .ctrl), [0x06])
        XCTAssertEqual(enc(.character("C"), .ctrl), [0x03])
    }

    func testControlPunctuation() {
        XCTAssertEqual(enc(.character(" "), .ctrl), [0x00])
        XCTAssertEqual(enc(.character("@"), .ctrl), [0x00])
        XCTAssertEqual(enc(.character("["), .ctrl), [0x1b])
        XCTAssertEqual(enc(.character("\\"), .ctrl), [0x1c])  // SIGQUIT
        XCTAssertEqual(enc(.character("]"), .ctrl), [0x1d])   // telnet/ssh escape style
        XCTAssertEqual(enc(.character("^"), .ctrl), [0x1e])
        XCTAssertEqual(enc(.character("_"), .ctrl), [0x1f])   // undo in readline/nano
        XCTAssertEqual(enc(.character("/"), .ctrl), [0x1f])
        XCTAssertEqual(enc(.character("?"), .ctrl), [0x7f])
        XCTAssertEqual(enc(.character("é"), .ctrl), Array("é".utf8))
    }

    func testAltIsEscPrefix() {
        XCTAssertEqual(enc(.character("b"), .alt), [0x1b, 0x62])
        XCTAssertEqual(enc(.character("f"), .alt), [0x1b, 0x66])
        XCTAssertEqual(enc(.character("."), .alt), [0x1b, 0x2e])
        XCTAssertEqual(enc(.character("x"), [.alt, .ctrl]), [0x1b, 0x18])
        XCTAssertEqual(enc(.backspace, .alt), [0x1b, 0x7f])
    }

    func testPlainKeys() {
        XCTAssertEqual(enc(.escape), [0x1b])
        XCTAssertEqual(enc(.tab), [0x09])
        XCTAssertEqual(enc(.tab, .shift), Array("\u{1b}[Z".utf8))
        XCTAssertEqual(enc(.enter), [0x0d])
        XCTAssertEqual(enc(.backspace), [0x7f])
        XCTAssertEqual(enc(.backspace, .ctrl), [0x08])
        XCTAssertEqual(KeyEncoder.encode(.backspace, modes: TerminalModes(backspaceSendsControlH: true)), [0x08])
    }

    func testArrowsFollowCursorMode() {
        XCTAssertEqual(enc(.up), Array("\u{1b}[A".utf8))
        XCTAssertEqual(enc(.left), Array("\u{1b}[D".utf8))
        XCTAssertEqual(enc(.up, appCursor: true), Array("\u{1b}OA".utf8))
        XCTAssertEqual(enc(.right, appCursor: true), Array("\u{1b}OC".utf8))
        XCTAssertEqual(enc(.home), Array("\u{1b}[H".utf8))
        XCTAssertEqual(enc(.end, appCursor: true), Array("\u{1b}OF".utf8))
    }

    func testModifiedArrowsIgnoreCursorMode() {
        XCTAssertEqual(enc(.right, .ctrl), Array("\u{1b}[1;5C".utf8))
        XCTAssertEqual(enc(.right, .ctrl, appCursor: true), Array("\u{1b}[1;5C".utf8))
        XCTAssertEqual(enc(.left, .alt), Array("\u{1b}[1;3D".utf8))
        XCTAssertEqual(enc(.up, .shift), Array("\u{1b}[1;2A".utf8))
        XCTAssertEqual(enc(.down, [.ctrl, .shift]), Array("\u{1b}[1;6B".utf8))
    }

    func testTildeKeys() {
        XCTAssertEqual(enc(.pageUp), Array("\u{1b}[5~".utf8))
        XCTAssertEqual(enc(.pageDown), Array("\u{1b}[6~".utf8))
        XCTAssertEqual(enc(.insert), Array("\u{1b}[2~".utf8))
        XCTAssertEqual(enc(.delete), Array("\u{1b}[3~".utf8))
        XCTAssertEqual(enc(.pageUp, .ctrl), Array("\u{1b}[5;5~".utf8))
    }

    func testFunctionKeys() {
        let expected = ["\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS",
                        "\u{1b}[15~", "\u{1b}[17~", "\u{1b}[18~", "\u{1b}[19~",
                        "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~"]
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(enc(.function(i + 1)), Array(e.utf8), "F\(i + 1)")
        }
        XCTAssertEqual(enc(.function(1), .shift), Array("\u{1b}[1;2P".utf8))
        XCTAssertEqual(enc(.function(5), .ctrl), Array("\u{1b}[15;5~".utf8))
        XCTAssertEqual(enc(.function(13)), [])
    }

    func testTextWithLatchAppliesToFirstCharacter() {
        XCTAssertEqual(KeyEncoder.encode(text: "c", modifiers: .ctrl), [0x03])
        XCTAssertEqual(KeyEncoder.encode(text: "cd", modifiers: .ctrl), [0x03, 0x64])
        XCTAssertEqual(KeyEncoder.encode(text: "\n", modifiers: .alt), [0x1b, 0x0d])
        XCTAssertEqual(KeyEncoder.encode(text: "ls", modifiers: []), Array("ls".utf8))
    }
}

final class ModifierLatchTests: XCTestCase {
    func testOneShot() {
        var bar = ModifierBar()
        bar.ctrl.tap(at: 0)
        XCTAssertEqual(bar.ctrl.state, .armed)
        XCTAssertEqual(bar.send(text: "c", modes: .init()), [0x03])
        XCTAssertEqual(bar.ctrl.state, .off)
        XCTAssertEqual(bar.send(text: "c", modes: .init()), [0x63])
    }

    func testDoubleTapLocks() {
        var bar = ModifierBar()
        bar.ctrl.tap(at: 10)
        bar.ctrl.tap(at: 10.2)
        XCTAssertEqual(bar.ctrl.state, .locked)
        XCTAssertEqual(bar.send(text: "a", modes: .init()), [0x01])
        XCTAssertEqual(bar.send(text: "e", modes: .init()), [0x05])
        XCTAssertEqual(bar.ctrl.state, .locked)
        bar.ctrl.tap(at: 20)
        XCTAssertEqual(bar.ctrl.state, .off)
    }

    func testSlowSecondTapCancels() {
        var latch = ModifierLatch()
        latch.tap(at: 0)
        latch.tap(at: 2)
        XCTAssertEqual(latch.state, .off)
    }

    func testLongPressLocks() {
        var latch = ModifierLatch()
        latch.longPress()
        XCTAssertEqual(latch.state, .locked)
        latch.consume()
        XCTAssertEqual(latch.state, .locked)
    }

    func testCtrlAltTogether() {
        var bar = ModifierBar()
        bar.ctrl.tap(at: 0)
        bar.alt.tap(at: 0)
        XCTAssertEqual(bar.send(.character("x"), modes: .init()), [0x1b, 0x18])
        XCTAssertEqual(bar.active, [])
    }

    func testLockedAltWithArrowInVim() {
        var bar = ModifierBar()
        bar.alt.longPress()
        let modes = TerminalModes(applicationCursor: true)
        XCTAssertEqual(bar.send(.left, modes: modes), Array("\u{1b}[1;3D".utf8))
        XCTAssertEqual(bar.send(.up, modes: modes), Array("\u{1b}[1;3A".utf8))
    }

    func testPanelRowsAreNotEmptyAndBalanced() {
        for row in KeyLayout.panelRows {
            XCTAssertEqual(row.count, 8)
        }
    }
}
