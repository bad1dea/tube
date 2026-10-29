import UIKit
import SwiftTerm
import TermInput

/// SwiftTerm's view with the key bar's CTRL/ALT latches applied to soft
/// keyboard input. Hardware keys with real modifiers go straight to SwiftTerm,
/// which already encodes them (and speaks the kitty keyboard protocol).
final class TubeTerminalView: TerminalView {
    weak var keyboard: KeyboardModel?
    var onFontSizeChange: ((CGFloat) -> Void)?

    private var pinchStartSize: CGFloat = 13

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
        accessibilityIdentifier = "terminal"
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        spellCheckingType = .no
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var modes: TerminalModes {
        TerminalModes(applicationCursor: getTerminal().applicationCursor,
                      backspaceSendsControlH: backspaceSendsControlH)
    }

    override func insertText(_ text: String) {
        guard let keyboard, !keyboard.bar.active.isEmpty else {
            super.insertText(text)
            return
        }
        send(keyboard.encodeLatched(text: text, modes: modes))
    }

    override func deleteBackward() {
        guard let keyboard, !keyboard.bar.active.isEmpty else {
            super.deleteBackward()
            return
        }
        send(keyboard.encodeLatched(key: .backspace, modes: modes))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A latch on the bar combined with an unmodified hardware letter, e.g.
        // tap CTRL on screen then press C on a keyboard without a Ctrl key.
        if let keyboard, !keyboard.bar.active.isEmpty, presses.count == 1,
           let key = presses.first?.key,
           key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty,
           key.charactersIgnoringModifiers.count == 1 {
            send(keyboard.encodeLatched(text: key.characters, modes: modes))
            return
        }
        super.pressesBegan(presses, with: event)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartSize = font.pointSize
        case .changed, .ended:
            let size = min(max(pinchStartSize * g.scale, 8), 32).rounded()
            if size != font.pointSize {
                onFontSizeChange?(size)
            }
        default:
            break
        }
    }
}
