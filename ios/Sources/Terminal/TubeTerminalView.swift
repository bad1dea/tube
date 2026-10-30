import UIKit
import UniformTypeIdentifiers
import SwiftTerm
import TermInput

/// SwiftTerm's view with the key bar's CTRL/ALT latches applied to soft
/// keyboard input. Hardware keys with real modifiers go straight to SwiftTerm,
/// which already encodes them (and speaks the kitty keyboard protocol).
final class TubeTerminalView: TerminalView {
    weak var keyboard: KeyboardModel?
    var onFontSizeChange: ((CGFloat) -> Void)?
    /// An image on the clipboard (screenshot, copied photo): data and file extension.
    var onPasteImage: ((Data, String) -> Void)?

    private var pinchStartSize: CGFloat = 13

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
        accessibilityIdentifier = "terminal"
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        swipe.addTarget(self, action: #selector(swiped(_:)))
        addGestureRecognizer(swipe)
        // The native scroll only runs when the swipe declines the touch.
        panGestureRecognizer.require(toFail: swipe)
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

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if !pb.hasStrings, let onPasteImage, let (data, ext) = Self.clipboardImage(pb) {
            onPasteImage(data, ext)
            return
        }
        super.paste(sender)
    }

    /// Sends `text` the way a paste would, bracketed when the remote asked for it.
    func pasteText(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode
        send((bracketed ? Array("\u{1b}[200~".utf8) : []) + Array(text.utf8) + (bracketed ? Array("\u{1b}[201~".utf8) : []))
    }

    private static func clipboardImage(_ pb: UIPasteboard) -> (Data, String)? {
        guard pb.hasImages else { return nil }
        if let png = pb.data(forPasteboardType: UTType.png.identifier) { return (png, "png") }
        if let jpeg = pb.data(forPasteboardType: UTType.jpeg.identifier) { return (jpeg, "jpg") }
        return pb.image?.pngData().map { ($0, "png") }
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

    // MARK: Swipes

    /// One-finger drags that the scroll view cannot use:
    ///   left/right anywhere        → ← / → (move along the command line)
    ///   up/down in full-screen apps → wheel events if the app enabled mouse
    ///                                reporting (tmux `mouse on`, vim
    ///                                `mouse=a`), otherwise ↑ / ↓
    /// Up/down at a normal prompt stays a native scroll through scrollback.
    let swipe = UIPanGestureRecognizer()
    private var swipeSent = CGPoint.zero

    private var cellSize: CGSize {
        let w = ("W" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(w, 4), height: max(font.lineHeight, 8))
    }

    private var verticalGoesToApp: Bool {
        let t = getTerminal()
        return t.isCurrentBufferAlternate || t.mouseMode != .off
    }

    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            swipeSent = .zero
        case .changed:
            let t = g.translation(in: self)
            let cell = cellSize
            let horizontal = abs(t.x) > abs(t.y)
            if horizontal {
                let steps = Int((t.x / cell.width).rounded(.towardZero)) - Int(swipeSent.x)
                for _ in 0..<abs(steps) { send(KeyEncoder.encode(steps > 0 ? .right : .left, modes: modes)) }
                swipeSent.x += CGFloat(steps)
            } else {
                // Finger down = earlier content = wheel/arrow up.
                let steps = Int((t.y / cell.height).rounded(.towardZero)) - Int(swipeSent.y)
                for _ in 0..<abs(steps) { sendVertical(up: steps > 0, at: g.location(in: self)) }
                swipeSent.y += CGFloat(steps)
            }
            if (t.x != 0 || t.y != 0) { keyboard?.dismissPadHint() }
        default:
            break
        }
    }

    // SwiftTerm adds its own mouse-drag pan when an app turns on mouse reporting.
    // Left alone it wins over the swipe and sends a click instead of wheel events.
    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        for g in gestureRecognizers ?? [] where g is UIPanGestureRecognizer && g !== swipe {
            g.require(toFail: swipe)
        }
    }

    // UIView asks this for every recognizer on the view, including the swipe.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === swipe else { return super.gestureRecognizerShouldBegin(g) }
        let v = swipe.velocity(in: self)
        if abs(v.x) > abs(v.y) { return true }
        return verticalGoesToApp
    }

    private func sendVertical(up: Bool, at point: CGPoint) {
        let t = getTerminal()
        if t.mouseMode != .off {
            let cell = cellSize
            let col = max(0, min(t.cols - 1, Int(point.x / cell.width)))
            let row = max(0, min(t.rows - 1, Int((point.y - contentOffset.y) / cell.height)))
            let flags = t.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            t.sendEvent(buttonFlags: flags, x: col, y: row)
        } else {
            send(KeyEncoder.encode(up ? .up : .down, modes: modes))
        }
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
