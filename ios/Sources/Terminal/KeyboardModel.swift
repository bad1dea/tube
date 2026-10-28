import UIKit
import TermInput

enum PanelTab: String, CaseIterable {
    case keys, snippets, history, themes

    var symbol: String {
        switch self {
        case .keys: return "square.grid.2x2"
        case .snippets: return "curlybraces"
        case .history: return "clock"
        case .themes: return "paintpalette"
        }
    }

    var title: String {
        switch self {
        case .keys: return "Keys"
        case .snippets: return "Snippets"
        case .history: return "History"
        case .themes: return "Theme"
        }
    }
}

/// Keyboard state shared by the accessory bar, the key panel and the terminal
/// view. One per app: latches follow the user across tabs.
@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var bar = ModifierBar()
    @Published var panelVisible = false
    @Published var panelTab: PanelTab = .keys

    weak var terminal: ConchTerminalView?
    var onToggleInputMode: (() -> Void)?
    var clicks = true

    func encodeLatched(text: String, modes: TerminalModes) -> [UInt8] {
        bar.send(text: text, modes: modes)
    }

    func encodeLatched(key: TerminalKey, modes: TerminalModes) -> [UInt8] {
        bar.send(key, modes: modes)
    }

    func tapLatch(_ kind: LatchKind) {
        let now = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .ctrl: bar.ctrl.tap(at: now)
        case .alt: bar.alt.tap(at: now)
        }
    }

    func lockLatch(_ kind: LatchKind) {
        switch kind {
        case .ctrl: bar.ctrl.longPress()
        case .alt: bar.alt.longPress()
        }
    }

    func state(of kind: LatchKind) -> ModifierLatch.State {
        kind == .ctrl ? bar.ctrl.state : bar.alt.state
    }

    func perform(_ action: KeyAction) {
        guard let terminal else { return }
        if clicks { UIDevice.current.playInputClick() }
        switch action {
        case .key(let key, let mods):
            terminal.send(bar.send(key, extra: mods, modes: terminal.modes))
        case .text(let s):
            terminal.send(bar.send(text: s, modes: terminal.modes))
        case .latch(let kind):
            tapLatch(kind)
        case .paste:
            if let s = UIPasteboard.general.string {
                // Bracketed paste lets shells and editors tell pasted text from typing.
                if terminal.getTerminal().bracketedPasteMode {
                    terminal.send(Array("\u{1b}[200~".utf8) + Array(s.utf8) + Array("\u{1b}[201~".utf8))
                } else {
                    terminal.send(Array(s.utf8))
                }
            }
        case .togglePanel:
            onToggleInputMode?()
        case .dismissKeyboard:
            _ = terminal.resignFirstResponder()
        }
    }
}
