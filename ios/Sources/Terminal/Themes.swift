import UIKit
import SwiftTerm

struct TerminalTheme: Identifiable, Equatable {
    var name: String
    var background: UInt32
    var foreground: UInt32
    var cursor: UInt32
    /// black red green yellow blue magenta cyan white, then bright variants.
    var ansi: [UInt32]
    var isDark: Bool

    var id: String { name }

    static let all: [TerminalTheme] = [
        TerminalTheme(name: "Conch Dark", background: 0x14171c, foreground: 0xd6dae0, cursor: 0x7fd1ae,
                      ansi: [0x1d2128, 0xe06c75, 0x8cc68f, 0xe5c07b, 0x6fa8dc, 0xc49bd6, 0x63c5c9, 0xc8ccd2,
                             0x5c6370, 0xff7b85, 0xa5dca8, 0xf2d08e, 0x8bbcf0, 0xd8b3e8, 0x7fd8db, 0xf2f4f7],
                      isDark: true),
        TerminalTheme(name: "Conch Light", background: 0xfafafa, foreground: 0x2b2f36, cursor: 0x2a7f62,
                      ansi: [0x2b2f36, 0xc0392b, 0x2e7d32, 0x9a6a00, 0x1f5fa8, 0x8e3fa3, 0x007c80, 0xd0d3d8,
                             0x6b717c, 0xe0483a, 0x3c9a41, 0xb88400, 0x2f74c8, 0xa857c0, 0x00979c, 0xffffff],
                      isDark: false),
        TerminalTheme(name: "Solarized Dark", background: 0x002b36, foreground: 0x839496, cursor: 0x93a1a1,
                      ansi: [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                             0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3],
                      isDark: true),
        TerminalTheme(name: "Gruvbox", background: 0x282828, foreground: 0xebdbb2, cursor: 0xebdbb2,
                      ansi: [0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
                             0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2],
                      isDark: true),
        TerminalTheme(name: "Nord", background: 0x2e3440, foreground: 0xd8dee9, cursor: 0xd8dee9,
                      ansi: [0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                             0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4],
                      isDark: true),
        TerminalTheme(name: "Phosphor", background: 0x0a0f0a, foreground: 0x9cf09c, cursor: 0x9cf09c,
                      ansi: [0x0a0f0a, 0x5fd75f, 0x87ff87, 0xafffaf, 0x5faf5f, 0x87d787, 0xafd7af, 0x9cf09c,
                             0x3a5a3a, 0x87ff87, 0xafffaf, 0xd7ffd7, 0x87d787, 0xafd7af, 0xd7ffd7, 0xeaffea],
                      isDark: true),
    ]

    static func named(_ name: String) -> TerminalTheme {
        all.first { $0.name == name } ?? all[0]
    }

    func apply(to view: TerminalView) {
        view.installColors(ansi.map(Self.swiftTermColor))
        view.nativeBackgroundColor = Self.uiColor(background)
        view.nativeForegroundColor = Self.uiColor(foreground)
        view.caretColor = Self.uiColor(cursor)
        view.keyboardAppearance = isDark ? .dark : .light
    }

    static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }

    static func swiftTermColor(_ rgb: UInt32) -> SwiftTerm.Color {
        // SwiftTerm colors are 16-bit per channel.
        SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xff) * 257,
                        green: UInt16((rgb >> 8) & 0xff) * 257,
                        blue: UInt16(rgb & 0xff) * 257)
    }
}

enum TerminalFonts {
    static let names = ["System Mono", "Menlo", "Courier New"]

    static func font(name: String, size: CGFloat) -> UIFont {
        if name != "System Mono", let f = UIFont(name: name, size: size) { return f }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
