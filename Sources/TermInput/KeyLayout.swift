// Key definitions shared by the accessory bar (above the system keyboard) and the
// full key panel (replaces the system keyboard). Views only render these.

public enum LatchKind: Hashable, Sendable { case ctrl, alt }

public enum KeyAction: Hashable, Sendable {
    case key(TerminalKey, KeyModifiers = [])
    case latch(LatchKind)
    case text(String)
    case paste
    case togglePanel
    case dismissKeyboard
}

public struct KeyCap: Hashable, Sendable, Identifiable {
    public var label: String
    public var action: KeyAction
    /// Auto-repeat while held (arrows, backspace).
    public var repeats: Bool
    public var accessibilityLabel: String

    public var id: String { label + "\(action)" }

    public init(_ label: String, _ action: KeyAction, repeats: Bool = false, accessibilityLabel: String? = nil) {
        self.label = label
        self.action = action
        self.repeats = repeats
        self.accessibilityLabel = accessibilityLabel ?? label
    }

    static func ch(_ s: Character) -> KeyCap { KeyCap(String(s), .key(.character(s))) }
    static func ctrl(_ s: Character) -> KeyCap {
        KeyCap("^" + String(s).uppercased(), .key(.character(s), .ctrl), accessibilityLabel: "Control \(String(s).uppercased())")
    }
}

public struct KeyGroup: Hashable, Sendable, Identifiable {
    public var id: String
    public var keys: [KeyCap]
}

public enum KeyLayout {
    public static let modifiers = KeyGroup(id: "mod", keys: [
        KeyCap("esc", .key(.escape), accessibilityLabel: "Escape"),
        KeyCap("tab", .key(.tab), accessibilityLabel: "Tab"),
        KeyCap("ctrl", .latch(.ctrl), accessibilityLabel: "Control"),
        KeyCap("alt", .latch(.alt), accessibilityLabel: "Alt"),
    ])

    public static let arrows = KeyGroup(id: "arrows", keys: [
        KeyCap("←", .key(.left), repeats: true, accessibilityLabel: "Left"),
        KeyCap("↓", .key(.down), repeats: true, accessibilityLabel: "Down"),
        KeyCap("↑", .key(.up), repeats: true, accessibilityLabel: "Up"),
        KeyCap("→", .key(.right), repeats: true, accessibilityLabel: "Right"),
    ])

    public static let navigation = KeyGroup(id: "nav", keys: [
        KeyCap("home", .key(.home), accessibilityLabel: "Home"),
        KeyCap("end", .key(.end), accessibilityLabel: "End"),
        KeyCap("pgup", .key(.pageUp), repeats: true, accessibilityLabel: "Page up"),
        KeyCap("pgdn", .key(.pageDown), repeats: true, accessibilityLabel: "Page down"),
        KeyCap("del", .key(.delete), repeats: true, accessibilityLabel: "Forward delete"),
    ])

    public static let shell = KeyGroup(id: "shell", keys: "cdzlraewukbf".map { KeyCap.ctrl($0) })

    public static let symbols = KeyGroup(id: "sym", keys: Array("/|-~_\\:;=+$#@!&*?<>`'\"{}[]()%^").map { KeyCap.ch($0) })

    public static let function = KeyGroup(id: "fn", keys: (1...12).map {
        KeyCap("F\($0)", .key(.function($0)))
    })

    /// Accessory bar order: most used first so the first screen width covers
    /// esc/tab/ctrl/alt, arrows and the common path characters.
    public static let accessoryBar: [KeyGroup] = [
        modifiers,
        KeyGroup(id: "path", keys: Array("/|~-").map { KeyCap.ch($0) }),
        KeyGroup(id: "sig", keys: [KeyCap.ctrl("c"), KeyCap.ctrl("d"), KeyCap.ctrl("l")]),
        arrows,
        shell,
        navigation,
        symbols,
        function,
    ]

    /// Full panel shown instead of the system keyboard: 8 equal columns, left and
    /// right halves of 4 so related keys stay in one block. Scrolls vertically
    /// when the panel is shorter than the rows (landscape iPhone).
    public static let panelRows: [[KeyCap]] = [
        modifiers.keys + Array("/|~-").map { KeyCap.ch($0) },
        [KeyCap.ctrl("c"), KeyCap.ctrl("d"), KeyCap.ctrl("l"), KeyCap.ctrl("z"),
         KeyCap("home", .key(.home)), KeyCap("pgUp", .key(.pageUp), repeats: true, accessibilityLabel: "Page up"),
         KeyCap("pgDn", .key(.pageDown), repeats: true, accessibilityLabel: "Page down"), KeyCap("end", .key(.end))],
        Array("=:;!*$%^").map { KeyCap.ch($0) },
        Array("<>(){}[]").map { KeyCap.ch($0) },
        [KeyCap("paste", .paste), KeyCap("del", .key(.delete), repeats: true, accessibilityLabel: "Forward delete"),
         KeyCap("ins", .key(.insert), accessibilityLabel: "Insert"), KeyCap.ch("@")]
            + (1...4).map { KeyCap("F\($0)", .key(.function($0))) },
        [KeyCap("⇧tab", .key(.tab, .shift), accessibilityLabel: "Shift tab"),
         KeyCap.ctrl("r"), KeyCap.ctrl("a"), KeyCap.ctrl("e")]
            + (5...8).map { KeyCap("F\($0)", .key(.function($0))) },
        [KeyCap.ctrl("w"), KeyCap.ctrl("u"), KeyCap.ctrl("k"), KeyCap.ctrl("b")]
            + (9...12).map { KeyCap("F\($0)", .key(.function($0))) },
        Array("#&?_").map { KeyCap.ch($0) } + Array("`'\"\\").map { KeyCap.ch($0) },
        [KeyCap("⌫", .key(.backspace), repeats: true, accessibilityLabel: "Backspace"),
         KeyCap("space", .key(.character(" ")), repeats: true, accessibilityLabel: "Space"),
         KeyCap("⏎", .key(.enter), accessibilityLabel: "Return"),
         KeyCap("abc", .togglePanel, accessibilityLabel: "System keyboard"),
         KeyCap("←", .key(.left), repeats: true, accessibilityLabel: "Left"),
         KeyCap("↑", .key(.up), repeats: true, accessibilityLabel: "Up"),
         KeyCap("↓", .key(.down), repeats: true, accessibilityLabel: "Down"),
         KeyCap("→", .key(.right), repeats: true, accessibilityLabel: "Right")],
    ]
}
