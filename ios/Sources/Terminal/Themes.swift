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
        TerminalTheme(name: "Tube Dark", background: 0x14171c, foreground: 0xd6dae0, cursor: 0x7fd1ae,
                      ansi: [0x1d2128, 0xe06c75, 0x8cc68f, 0xe5c07b, 0x6fa8dc, 0xc49bd6, 0x63c5c9, 0xc8ccd2,
                             0x5c6370, 0xff7b85, 0xa5dca8, 0xf2d08e, 0x8bbcf0, 0xd8b3e8, 0x7fd8db, 0xf2f4f7],
                      isDark: true),
        TerminalTheme(name: "Tube Light", background: 0xfafafa, foreground: 0x2b2f36, cursor: 0x2a7f62,
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
        // Palettes below from iTerm2-Color-Schemes (MIT).
        TerminalTheme(name: "Catppuccin Mocha", background: 0x1e1e2e, foreground: 0xcdd6f4, cursor: 0xf5e0dc,
                      ansi: [0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
                             0x585b70, 0xf7aec2, 0xc2ecbf, 0xfcd682, 0xaeccfc, 0xf398da, 0xb1eae1, 0xa6adc8],
                      isDark: true),
        TerminalTheme(name: "Catppuccin Macchiato", background: 0x24273a, foreground: 0xcad3f5, cursor: 0xf4dbd6,
                      ansi: [0x494d64, 0xed8796, 0xa6da95, 0xeed49f, 0x8aadf4, 0xf5bde6, 0x8bd5ca, 0xb8c0e0,
                             0x5b6078, 0xf2a7b2, 0xbde3b0, 0xf4e3c1, 0xadc5f7, 0xf493da, 0xa5ded6, 0xa5adcb],
                      isDark: true),
        TerminalTheme(name: "Catppuccin Frappé", background: 0x303446, foreground: 0xc6d0f5, cursor: 0xf2d5cf,
                      ansi: [0x51576d, 0xe78284, 0xa6d189, 0xe5c890, 0x8caaee, 0xf4b8e4, 0x81c8be, 0xb5bfe2,
                             0x626880, 0xeda0a2, 0xb9dba2, 0xecd7ae, 0xadc2f3, 0xf38ed8, 0x98d2ca, 0xa5adce],
                      isDark: true),
        TerminalTheme(name: "Catppuccin Latte", background: 0xeff1f5, foreground: 0x4c4f69, cursor: 0xdc8a78,
                      ansi: [0xbcc0cc, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0x5c5f77,
                             0xacb0be, 0xe7103f, 0x46b02f, 0xe49931, 0x3878f6, 0xef95d7, 0x19a1a8, 0x6c6f85],
                      isDark: false),
        TerminalTheme(name: "Dracula", background: 0x282a36, foreground: 0xf8f8f2, cursor: 0xf8f8f2,
                      ansi: [0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
                             0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Darcula", background: 0x202020, foreground: 0xadadad, cursor: 0xffffff,
                      ansi: [0x000000, 0xfa5355, 0x126e00, 0xc2c300, 0x4581eb, 0xfa54ff, 0x33c2c1, 0xadadad,
                             0x555555, 0xfb7172, 0x67ff4f, 0xffff00, 0x6d9df1, 0xfb82ff, 0x60d3d1, 0xeeeeee],
                      isDark: true),
        TerminalTheme(name: "One Dark", background: 0x21252b, foreground: 0xabb2bf, cursor: 0xabb2bf,
                      ansi: [0x21252b, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
                             0x767676, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf],
                      isDark: true),
        TerminalTheme(name: "One Light", background: 0xf9f9f9, foreground: 0x2a2c33, cursor: 0xbbbbbb,
                      ansi: [0x000000, 0xde3e35, 0x3f953a, 0xd2b67c, 0x2f5af3, 0x950095, 0x3f953a, 0xbbbbbb,
                             0x000000, 0xde3e35, 0x3f953a, 0xd2b67c, 0x2f5af3, 0xa00095, 0x3f953a, 0xffffff],
                      isDark: false),
        TerminalTheme(name: "Tokyo Night", background: 0x1a1b26, foreground: 0xc0caf5, cursor: 0xc0caf5,
                      ansi: [0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
                             0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5],
                      isDark: true),
        TerminalTheme(name: "Tokyo Night Storm", background: 0x24283b, foreground: 0xc0caf5, cursor: 0xc0caf5,
                      ansi: [0x1d202f, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
                             0x4e5575, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5],
                      isDark: true),
        TerminalTheme(name: "Tokyo Night Day", background: 0xe1e2e7, foreground: 0x3760bf, cursor: 0x3760bf,
                      ansi: [0xe9e9ed, 0xf52a65, 0x587539, 0x8c6c3e, 0x2e7de9, 0x9854f1, 0x007197, 0x6172b0,
                             0xa1a6c5, 0xf52a65, 0x587539, 0x8c6c3e, 0x2e7de9, 0x9854f1, 0x007197, 0x3760bf],
                      isDark: false),
        TerminalTheme(name: "Monokai", background: 0x272822, foreground: 0xfdfff1, cursor: 0xc0c1b5,
                      ansi: [0x272822, 0xf92672, 0xa6e22e, 0xe6db74, 0xfd971f, 0xae81ff, 0x66d9ef, 0xfdfff1,
                             0x6e7066, 0xf92672, 0xa6e22e, 0xe6db74, 0xfd971f, 0xae81ff, 0x66d9ef, 0xfdfff1],
                      isDark: true),
        TerminalTheme(name: "Monokai Pro", background: 0x2d2a2e, foreground: 0xfcfcfa, cursor: 0xc1c0c0,
                      ansi: [0x2d2a2e, 0xff6188, 0xa9dc76, 0xffd866, 0xfc9867, 0xab9df2, 0x78dce8, 0xfcfcfa,
                             0x727072, 0xff6188, 0xa9dc76, 0xffd866, 0xfc9867, 0xab9df2, 0x78dce8, 0xfcfcfa],
                      isDark: true),
        TerminalTheme(name: "Solarized Light", background: 0xfdf6e3, foreground: 0x657b83, cursor: 0x657b83,
                      ansi: [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xbbb5a2,
                             0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3],
                      isDark: false),
        TerminalTheme(name: "Gruvbox Light", background: 0xfbf1c7, foreground: 0x3c3836, cursor: 0x3c3836,
                      ansi: [0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
                             0x928374, 0x9d0006, 0x79740e, 0xb57614, 0x076678, 0x8f3f71, 0x427b58, 0x3c3836],
                      isDark: false),
        TerminalTheme(name: "Everforest Dark", background: 0x232a2e, foreground: 0xd3c6aa, cursor: 0xe69875,
                      ansi: [0x7a8478, 0xe67e80, 0xa7c080, 0xdbbc7f, 0x7fbbb3, 0xd699b6, 0x83c092, 0xf2efdf,
                             0xa6b0a0, 0xf85552, 0x8da101, 0xdfa000, 0x3a94c5, 0xdf69ba, 0x35a77c, 0xfffbef],
                      isDark: true),
        TerminalTheme(name: "Everforest Light", background: 0xefebd4, foreground: 0x5c6a72, cursor: 0xf57d26,
                      ansi: [0x7a8478, 0xe67e80, 0x9ab373, 0xc1a266, 0x7fbbb3, 0xd699b6, 0x83c092, 0xb2af9f,
                             0xa6b0a0, 0xf85552, 0x8da101, 0xdfa000, 0x3a94c5, 0xdf69ba, 0x35a77c, 0xfffbef],
                      isDark: false),
        TerminalTheme(name: "Rosé Pine", background: 0x191724, foreground: 0xe0def4, cursor: 0xe0def4,
                      ansi: [0x26233a, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
                             0x6e6a86, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4],
                      isDark: true),
        TerminalTheme(name: "Rosé Pine Moon", background: 0x232136, foreground: 0xe0def4, cursor: 0xe0def4,
                      ansi: [0x393552, 0xeb6f92, 0x3e8fb0, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xea9a97, 0xe0def4,
                             0x6e6a86, 0xeb6f92, 0x3e8fb0, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xea9a97, 0xe0def4],
                      isDark: true),
        TerminalTheme(name: "Rosé Pine Dawn", background: 0xfaf4ed, foreground: 0x575279, cursor: 0x575279,
                      ansi: [0xf2e9e1, 0xb4637a, 0x286983, 0xea9d34, 0x56949f, 0x907aa9, 0xd7827e, 0x575279,
                             0x9893a5, 0xb4637a, 0x286983, 0xea9d34, 0x56949f, 0x907aa9, 0xd7827e, 0x575279],
                      isDark: false),
        TerminalTheme(name: "Kanagawa", background: 0x1f1f28, foreground: 0xdcd7ba, cursor: 0xdcd7ba,
                      ansi: [0x090618, 0xc34043, 0x76946a, 0xc0a36e, 0x7e9cd8, 0x957fb8, 0x6a9589, 0xc8c093,
                             0x727169, 0xe82424, 0x98bb6c, 0xe6c384, 0x7fb4ca, 0x938aa9, 0x7aa89f, 0xdcd7ba],
                      isDark: true),
        TerminalTheme(name: "Kanagawa Dragon", background: 0x181616, foreground: 0xc5c9c5, cursor: 0xc8c093,
                      ansi: [0x0d0c0c, 0xc4746e, 0x8a9a7b, 0xc4b28a, 0x8ba4b0, 0xa292a3, 0x8ea4a2, 0xc8c093,
                             0xa6a69c, 0xe46876, 0x87a987, 0xe6c384, 0x7fb4ca, 0x938aa9, 0x7aa89f, 0xc5c9c5],
                      isDark: true),
        TerminalTheme(name: "Ayu Dark", background: 0x0b0e14, foreground: 0xbfbdb6, cursor: 0xe6b450,
                      ansi: [0x11151c, 0xea6c73, 0x7fd962, 0xf9af4f, 0x53bdfa, 0xcda1fa, 0x90e1c6, 0xc7c7c7,
                             0x686868, 0xf07178, 0xaad94c, 0xffb454, 0x59c2ff, 0xd2a6ff, 0x95e6cb, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Ayu Mirage", background: 0x1f2430, foreground: 0xcccac2, cursor: 0xffcc66,
                      ansi: [0x171b24, 0xed8274, 0x87d96c, 0xfacc6e, 0x6dcbfa, 0xdabafa, 0x90e1c6, 0xc7c7c7,
                             0x686868, 0xf28779, 0xd5ff80, 0xffd173, 0x73d0ff, 0xdfbfff, 0x95e6cb, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Ayu Light", background: 0xf8f9fa, foreground: 0x5c6166, cursor: 0xffaa33,
                      ansi: [0x000000, 0xea6c6d, 0x6cbf43, 0xeca944, 0x3199e1, 0x9e75c7, 0x46ba94, 0xbababa,
                             0x686868, 0xf07171, 0x86b300, 0xf2ae49, 0x399ee6, 0xa37acc, 0x4cbf99, 0xd1d1d1],
                      isDark: false),
        TerminalTheme(name: "Material Darker", background: 0x212121, foreground: 0xeeffff, cursor: 0xffffff,
                      ansi: [0x000000, 0xff5370, 0xc3e88d, 0xffcb6b, 0x82aaff, 0xc792ea, 0x89ddff, 0xffffff,
                             0x545454, 0xff5370, 0xc3e88d, 0xffcb6b, 0x82aaff, 0xc792ea, 0x89ddff, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "GitHub Dark", background: 0x0d1117, foreground: 0xe6edf3, cursor: 0x2f81f7,
                      ansi: [0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
                             0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "GitHub Light", background: 0xffffff, foreground: 0x1f2328, cursor: 0x0969da,
                      ansi: [0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
                             0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f],
                      isDark: false),
        TerminalTheme(name: "Nord Light", background: 0xe5e9f0, foreground: 0x414858, cursor: 0x7bb3c3,
                      ansi: [0x3b4252, 0xbf616a, 0x96b17f, 0xc5a565, 0x81a1c1, 0xb48ead, 0x7bb3c3, 0xa5abb6,
                             0x4c566a, 0xbf616a, 0x96b17f, 0xc5a565, 0x81a1c1, 0xb48ead, 0x82afae, 0xeceff4],
                      isDark: false),
        TerminalTheme(name: "Nightfox", background: 0x192330, foreground: 0xcdcecf, cursor: 0xcdcecf,
                      ansi: [0x393b44, 0xc94f6d, 0x81b29a, 0xdbc074, 0x719cd6, 0x9d79d6, 0x63cdcf, 0xdfdfe0,
                             0x575860, 0xd16983, 0x8ebaa4, 0xe0c989, 0x86abdc, 0xbaa1e2, 0x7ad5d6, 0xe4e4e5],
                      isDark: true),
        TerminalTheme(name: "Oceanic Next", background: 0x162c35, foreground: 0xc0c5ce, cursor: 0xc0c5ce,
                      ansi: [0x162c35, 0xec5f67, 0x99c794, 0xfac863, 0x6699cc, 0xc594c5, 0x5fb3b3, 0xffffff,
                             0x65737e, 0xec5f67, 0x99c794, 0xfac863, 0x6699cc, 0xc594c5, 0x5fb3b3, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Snazzy", background: 0x1e1f29, foreground: 0xebece6, cursor: 0xe4e4e4,
                      ansi: [0x000000, 0xfc4346, 0x50fb7c, 0xf0fb8c, 0x49baff, 0xfc4cb4, 0x8be9fe, 0xededec,
                             0x555555, 0xfc4346, 0x50fb7c, 0xf0fb8c, 0x49baff, 0xfc4cb4, 0x8be9fe, 0xededec],
                      isDark: true),
        TerminalTheme(name: "Cobalt2", background: 0x132738, foreground: 0xffffff, cursor: 0xf0cc09,
                      ansi: [0x000000, 0xff0000, 0x38de21, 0xffe50a, 0x1460d2, 0xff005d, 0x00bbbb, 0xbbbbbb,
                             0x555555, 0xf40e17, 0x3bd01d, 0xedc809, 0x5555ff, 0xff55ff, 0x6ae3fa, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Horizon", background: 0x1c1e26, foreground: 0xd5d8da, cursor: 0x6c6f93,
                      ansi: [0x000000, 0xe95678, 0x29d398, 0xfab795, 0x26bbd9, 0xee64ac, 0x59e1e3, 0xe5e5e5,
                             0x666666, 0xec6a88, 0x3fdaa4, 0xfbc3a7, 0x3fc4de, 0xf075b5, 0x6be4e6, 0xe5e5e5],
                      isDark: true),
        TerminalTheme(name: "Night Owl", background: 0x011627, foreground: 0xd6deeb, cursor: 0x7e57c2,
                      ansi: [0x011627, 0xef5350, 0x22da6e, 0xaddb67, 0x82aaff, 0xc792ea, 0x21c7a8, 0xffffff,
                             0x575656, 0xef5350, 0x22da6e, 0xffeb95, 0x82aaff, 0xc792ea, 0x7fdbca, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Tomorrow Night", background: 0x1d1f21, foreground: 0xc5c8c6, cursor: 0xc5c8c6,
                      ansi: [0x000000, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xffffff,
                             0x4c4c4c, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Tomorrow", background: 0xffffff, foreground: 0x4d4d4c, cursor: 0x4d4d4c,
                      ansi: [0x000000, 0xc82829, 0x718c00, 0xeab700, 0x4271ae, 0x8959a8, 0x3e999f, 0xbfbfbf,
                             0x000000, 0xc82829, 0x718c00, 0xeab700, 0x4271ae, 0x8959a8, 0x3e999f, 0xffffff],
                      isDark: false),
        TerminalTheme(name: "Zenburn", background: 0x3f3f3f, foreground: 0xdcdccc, cursor: 0x73635a,
                      ansi: [0x4d4d4d, 0x7d5d5d, 0x60b48a, 0xf0dfaf, 0x5d6d7d, 0xdc8cc3, 0x8cd0d3, 0xdcdccc,
                             0x709080, 0xdca3a3, 0xc3bf9f, 0xe0cf9f, 0x94bff3, 0xec93d3, 0x93e0e3, 0xffffff],
                      isDark: true),
        TerminalTheme(name: "Ubuntu", background: 0x300a24, foreground: 0xeeeeec, cursor: 0xbbbbbb,
                      ansi: [0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
                             0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec],
                      isDark: true),
        TerminalTheme(name: "Tango Dark", background: 0x000000, foreground: 0xffffff, cursor: 0xffffff,
                      ansi: [0x000000, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
                             0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec],
                      isDark: true),
        TerminalTheme(name: "Tango Light", background: 0xffffff, foreground: 0x000000, cursor: 0x000000,
                      ansi: [0x000000, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xb9bdb5,
                             0x555753, 0xef2929, 0x7dd527, 0xd6c329, 0x729fcf, 0xad7fa8, 0x27d5d5, 0xeeeeec],
                      isDark: false),
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
