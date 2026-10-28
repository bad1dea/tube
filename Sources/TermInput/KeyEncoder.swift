// xterm-compatible byte encoding for keys sent from the on-screen key bar and the
// soft keyboard while a CTRL/ALT latch is active. Hardware keyboards go through
// SwiftTerm's own pressesBegan handling, which also speaks the kitty protocol.

public enum TerminalKey: Hashable, Sendable {
    case character(Character)
    case escape, tab, backspace, enter
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, delete
    case function(Int)
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1)
    public static let alt = KeyModifiers(rawValue: 2)
    public static let ctrl = KeyModifiers(rawValue: 4)

    // xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4)
    var xtermParameter: Int { 1 + Int(rawValue & 0x7) }
}

public struct TerminalModes: Hashable, Sendable {
    /// DECCKM, set by vim/less/htop with ESC [ ? 1 h.
    public var applicationCursor: Bool
    public var backspaceSendsControlH: Bool

    public init(applicationCursor: Bool = false, backspaceSendsControlH: Bool = false) {
        self.applicationCursor = applicationCursor
        self.backspaceSendsControlH = backspaceSendsControlH
    }
}

public enum KeyEncoder {
    static let esc: UInt8 = 0x1b

    public static func encode(_ key: TerminalKey, modifiers: KeyModifiers = [], modes: TerminalModes = .init()) -> [UInt8] {
        switch key {
        case .character(let c):
            return encodeCharacter(c, modifiers: modifiers)
        case .escape:
            return modifiers.contains(.alt) ? [esc, esc] : [esc]
        case .tab:
            if modifiers.contains(.shift) { return csi("Z") }
            return altPrefixed([0x09], modifiers)
        case .backspace:
            // Ctrl+Backspace flips the configured erase character, like xterm.
            var h = modes.backspaceSendsControlH
            if modifiers.contains(.ctrl) { h.toggle() }
            return altPrefixed([h ? 0x08 : 0x7f], modifiers)
        case .enter:
            return altPrefixed([0x0d], modifiers)
        case .up: return cursorKey("A", modifiers, modes)
        case .down: return cursorKey("B", modifiers, modes)
        case .right: return cursorKey("C", modifiers, modes)
        case .left: return cursorKey("D", modifiers, modes)
        case .home: return cursorKey("H", modifiers, modes)
        case .end: return cursorKey("F", modifiers, modes)
        case .insert: return tildeKey(2, modifiers)
        case .delete: return tildeKey(3, modifiers)
        case .pageUp: return tildeKey(5, modifiers)
        case .pageDown: return tildeKey(6, modifiers)
        case .function(let n):
            return functionKey(n, modifiers)
        }
    }

    public static func encode(text: String, modifiers: KeyModifiers, modes: TerminalModes = .init()) -> [UInt8] {
        if modifiers.isEmpty { return Array(text.utf8) }
        // Modifiers apply to the first character only; this is what a latch means
        // when the soft keyboard delivers a multi-character insert (autocomplete).
        guard let first = text.first else { return [] }
        let firstKey: TerminalKey
        switch first {
        case "\n", "\r": firstKey = .enter
        case "\t": firstKey = .tab
        default: firstKey = .character(first)
        }
        return encode(firstKey, modifiers: modifiers, modes: modes) + Array(text.dropFirst().utf8)
    }

    /// The control byte for Ctrl+c, or nil when the character has no C0 mapping.
    public static func controlByte(for c: Character) -> UInt8? {
        guard let ascii = c.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7a: return ascii - 0x60          // a-z
        case 0x40...0x5f: return ascii - 0x40          // @ A-Z [ \ ] ^ _
        case 0x20: return 0x00                         // space
        case 0x32: return 0x00                         // 2
        case 0x33: return 0x1b                         // 3
        case 0x34: return 0x1c                         // 4
        case 0x35: return 0x1d                         // 5
        case 0x36, 0x7e: return 0x1e                   // 6 ~
        case 0x37, 0x2f: return 0x1f                   // 7 /
        case 0x38, 0x3f: return 0x7f                   // 8 ?
        default: return nil
        }
    }

    static func encodeCharacter(_ c: Character, modifiers: KeyModifiers) -> [UInt8] {
        var bytes: [UInt8]
        if modifiers.contains(.ctrl), let b = controlByte(for: c) {
            bytes = [b]
        } else {
            bytes = Array(String(c).utf8)
        }
        if modifiers.contains(.alt) { bytes.insert(esc, at: 0) }
        return bytes
    }

    static func altPrefixed(_ bytes: [UInt8], _ m: KeyModifiers) -> [UInt8] {
        m.contains(.alt) ? [esc] + bytes : bytes
    }

    static func csi(_ s: String) -> [UInt8] { [esc, 0x5b] + Array(s.utf8) }
    static func ss3(_ s: String) -> [UInt8] { [esc, 0x4f] + Array(s.utf8) }

    static func cursorKey(_ final: String, _ m: KeyModifiers, _ modes: TerminalModes) -> [UInt8] {
        let mods = m.intersection([.shift, .alt, .ctrl])
        if !mods.isEmpty { return csi("1;\(mods.xtermParameter)\(final)") }
        return modes.applicationCursor ? ss3(final) : csi(final)
    }

    static func tildeKey(_ code: Int, _ m: KeyModifiers) -> [UInt8] {
        let mods = m.intersection([.shift, .alt, .ctrl])
        if !mods.isEmpty { return csi("\(code);\(mods.xtermParameter)~") }
        return csi("\(code)~")
    }

    static func functionKey(_ n: Int, _ m: KeyModifiers) -> [UInt8] {
        let mods = m.intersection([.shift, .alt, .ctrl])
        switch n {
        case 1...4:
            let final = ["P", "Q", "R", "S"][n - 1]
            return mods.isEmpty ? ss3(final) : csi("1;\(mods.xtermParameter)\(final)")
        case 5...12:
            let codes = [15, 17, 18, 19, 20, 21, 23, 24]
            return tildeKey(codes[n - 5], mods)
        default:
            return []
        }
    }
}
