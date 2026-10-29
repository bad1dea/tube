import UIKit
import TermInput

/// Floating direction pad shown by a long press on the terminal. Dragging
/// away from the centre sends arrow keys (or scrolls) with a repeat rate that
/// grows with distance; the row below has copy and paste.
final class TerminalPad: UIView {
    enum Mode: Int { case cursor, scroll }

    weak var terminal: TubeTerminalView?
    var onClose: (() -> Void)?

    private(set) var mode: Mode = .cursor
    private let ring = UIView()
    private let knob = UIView()
    // Icons: the pad is too narrow for "Cursor" / "Scroll" next to four buttons.
    private let modeControl: UISegmentedControl = {
        let cursor = UIImage(systemName: "character.cursor.ibeam")!
        cursor.accessibilityLabel = "Cursor keys"
        let scroll = UIImage(systemName: "scroll")!
        scroll.accessibilityLabel = "Scroll"
        return UISegmentedControl(items: [cursor, scroll])
    }()
    private var copyButton: UIButton!
    private var timer: Timer?
    private var direction: TerminalKey?
    private var distance: CGFloat = 0
    private var idleTimer: Timer?

    static let ringSize: CGFloat = 156
    static let size = CGSize(width: 236, height: ringSize + 60)
    private let deadZone: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        isAccessibilityElement = false

        ring.frame = CGRect(x: (Self.size.width - Self.ringSize) / 2, y: 8, width: Self.ringSize, height: Self.ringSize)
        ring.layer.cornerRadius = Self.ringSize / 2
        ring.backgroundColor = UIColor.tertiarySystemFill
        ring.accessibilityIdentifier = "terminalPad"
        addSubview(ring)
        for (symbol, angle) in [("chevron.up", 0.0), ("chevron.right", 0.5), ("chevron.down", 1.0), ("chevron.left", 1.5)] {
            let iv = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
            iv.tintColor = .secondaryLabel
            let r = Self.ringSize / 2 - 18
            let a = angle * .pi - .pi / 2
            iv.center = CGPoint(x: Self.ringSize / 2 + r * cos(a), y: Self.ringSize / 2 + r * sin(a))
            ring.addSubview(iv)
        }
        knob.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
        knob.layer.cornerRadius = 26
        knob.backgroundColor = .tintColor
        knob.center = CGPoint(x: Self.ringSize / 2, y: Self.ringSize / 2)
        knob.isUserInteractionEnabled = false
        ring.addSubview(knob)
        ring.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))

        modeControl.selectedSegmentIndex = 0
        modeControl.addAction(UIAction { [weak self] _ in
            self?.mode = Mode(rawValue: self?.modeControl.selectedSegmentIndex ?? 0) ?? .cursor
            self?.touched()
        }, for: .valueChanged)

        copyButton = button("doc.on.doc", "Copy") { [weak self] in
            self?.terminal?.copy(nil)
            self?.close()
        }
        let paste = button("doc.on.clipboard", "Paste") { [weak self] in
            self?.terminal?.keyboard?.perform(.paste)
            self?.close()
        }
        let all = button("selection.pin.in.out", "Select all") { [weak self] in
            self?.terminal?.selectAll(nil)
            self?.refresh()
        }
        let close = button("xmark", "Close pad") { [weak self] in self?.close() }

        let row = UIStackView(arrangedSubviews: [modeControl, copyButton, paste, all, close])
        row.spacing = 4
        row.alignment = .center
        row.frame = CGRect(x: 8, y: Self.ringSize + 16, width: Self.size.width - 16, height: 36)
        addSubview(row)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
        c.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        return b
    }

    func refresh() {
        copyButton.isEnabled = terminal?.hasActiveSelection ?? false
        touched()
    }

    private func touched() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.close() }
    }

    func close() {
        stop()
        idleTimer?.invalidate()
        onClose?()
    }

    // MARK: Joystick

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: ring)
        switch g.state {
        case .began, .changed: drive(CGVector(dx: t.x, dy: t.y))
        default: release()
        }
    }

    /// Offset of the finger from the pad centre, from the pad's own pan or
    /// from the long press that opened it.
    func drive(_ v: CGVector) {
        touched()
        let len = hypot(v.dx, v.dy)
        let maxR = Self.ringSize / 2 - 26
        let scale = len > maxR ? maxR / len : 1
        knob.center = CGPoint(x: Self.ringSize / 2 + v.dx * scale, y: Self.ringSize / 2 + v.dy * scale)
        distance = len
        guard len > deadZone else {
            stop()
            return
        }
        let d: TerminalKey = abs(v.dx) > abs(v.dy) ? (v.dx > 0 ? .right : .left) : (v.dy > 0 ? .down : .up)
        if d != direction {
            direction = d
            fire()
            schedule()
        }
    }

    func release() {
        stop()
        UIView.animate(withDuration: 0.12) { self.knob.center = CGPoint(x: Self.ringSize / 2, y: Self.ringSize / 2) }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        direction = nil
    }

    private func schedule() {
        timer?.invalidate()
        // 4 per second near the centre, ~30 at the rim.
        let interval = max(0.033, 0.25 - Double(distance - deadZone) / 260)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fire()
            self?.schedule()
        }
    }

    private func fire() {
        guard let terminal, let direction else { return }
        switch mode {
        case .cursor:
            terminal.send(KeyEncoder.encode(direction, modes: terminal.modes))
        case .scroll:
            let t = terminal.getTerminal()
            if t.isCurrentBufferAlternate {
                // Full-screen apps (less, vim, htop) have no scrollback; they
                // expect arrows, which is what a wheel turns into there.
                if direction == .up || direction == .down {
                    terminal.send(KeyEncoder.encode(direction, modes: terminal.modes))
                }
            } else if direction == .up {
                terminal.scrollUp(lines: 1)
            } else if direction == .down {
                terminal.scrollDown(lines: 1)
            }
        }
        if mode == .cursor { UISelectionFeedbackGenerator().selectionChanged() }
    }
}
