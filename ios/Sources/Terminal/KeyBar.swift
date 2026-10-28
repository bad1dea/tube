import UIKit
import SwiftUI
import Combine
import TermInput

enum KeyStyle {
    static let keyBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 1, alpha: 0.9) }
    static let keyPressed = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.28) : UIColor(white: 0.8, alpha: 1) }
    static let armed = UIColor.tintColor.withAlphaComponent(0.35)
    static let locked = UIColor.tintColor
    static let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let smallFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}

/// One key. Fires on touch-up so keys inside a scroll view do not trigger when
/// the user starts a scroll on them. Repeating keys fire after a hold and keep
/// firing until release; latch keys lock on a long hold.
final class KeyButton: UIControl {
    let cap: KeyCap
    var onFire: ((KeyCap) -> Void)?
    var onLongPress: ((KeyCap) -> Void)?

    private let label = UILabel()
    private var holdTimer: Timer?
    private var repeatTimer: Timer?
    private var heldAction = false

    init(cap: KeyCap, compact: Bool = false) {
        self.cap = cap
        super.init(frame: .zero)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        backgroundColor = KeyStyle.keyBackground
        label.text = cap.label
        label.font = cap.label.count > 3 ? KeyStyle.smallFont : KeyStyle.font
        label.textColor = .label
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if compact {
            widthAnchor.constraint(greaterThanOrEqualToConstant: cap.label.count > 2 ? 46 : 36).isActive = true
        }
        isAccessibilityElement = true
        accessibilityLabel = cap.accessibilityLabel
        accessibilityTraits = .keyboardKey
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        addTarget(self, action: #selector(cancel), for: [.touchUpOutside, .touchCancel])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setLatch(_ state: ModifierLatch.State) {
        switch state {
        case .off:
            backgroundColor = KeyStyle.keyBackground
            label.textColor = .label
            accessibilityValue = nil
        case .armed:
            backgroundColor = KeyStyle.armed
            label.textColor = .label
            accessibilityValue = "on for next key"
        case .locked:
            backgroundColor = KeyStyle.locked
            label.textColor = .white
            accessibilityValue = "locked"
        }
        label.font = state == .locked ? UIFont.monospacedSystemFont(ofSize: label.font.pointSize, weight: .bold) : label.font
    }

    private var isLatch: Bool {
        if case .latch = cap.action { return true }
        return false
    }

    @objc private func down() {
        heldAction = false
        if !isLatch { backgroundColor = KeyStyle.keyPressed }
        if cap.repeats {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.heldAction = true
                self.onFire?(self.cap)
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.onFire?(self.cap)
                }
            }
        } else if isLatch {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.heldAction = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.onLongPress?(self.cap)
            }
        }
    }

    @objc private func up() {
        stopTimers()
        if !heldAction { onFire?(cap) }
        if !isLatch { backgroundColor = KeyStyle.keyBackground }
    }

    @objc private func cancel() {
        stopTimers()
        if !isLatch { backgroundColor = KeyStyle.keyBackground }
    }

    private func stopTimers() {
        holdTimer?.invalidate()
        repeatTimer?.invalidate()
        holdTimer = nil
        repeatTimer = nil
    }
}

/// Sits above the system keyboard (or above the key panel): session tabs on
/// top, a scrollable row of grouped keys below when the system keyboard is up.
final class AccessoryBar: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    private let keyboard: KeyboardModel
    private let sessions: SessionManager
    private let stripScroll = UIScrollView()
    private let stripStack = UIStackView()
    private let keyScroll = UIScrollView()
    private var latchButtons: [LatchKind: KeyButton] = [:]
    private var toggleButton = UIButton(type: .system)
    private var cancellables: Set<AnyCancellable> = []
    private let rowHeight: CGFloat = 44

    init(keyboard: KeyboardModel, sessions: SessionManager) {
        self.keyboard = keyboard
        self.sessions = sessions
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 88), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        keyboard.$bar.receive(on: RunLoop.main).sink { [weak self] bar in self?.updateLatches(bar) }.store(in: &cancellables)
        keyboard.$panelVisible.receive(on: RunLoop.main).sink { [weak self] visible in self?.updatePanelState(visible) }.store(in: &cancellables)
        sessions.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            DispatchQueue.main.async { self?.rebuildStrip() }
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: keyboard.panelVisible ? rowHeight : rowHeight * 2)
    }

    private func build() {
        let vstack = UIStackView()
        vstack.axis = .vertical
        vstack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            vstack.topAnchor.constraint(equalTo: topAnchor),
            vstack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Session strip
        let strip = UIStackView()
        strip.axis = .horizontal
        strip.spacing = 6
        strip.isLayoutMarginsRelativeArrangement = true
        strip.directionalLayoutMargins = .init(top: 5, leading: 6, bottom: 5, trailing: 6)
        strip.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let back = iconButton("chevron.left", label: "Hosts") { [weak self] in self?.sessions.showHosts() }
        stripScroll.showsHorizontalScrollIndicator = false
        stripStack.axis = .horizontal
        stripStack.spacing = 6
        stripStack.translatesAutoresizingMaskIntoConstraints = false
        stripScroll.addSubview(stripStack)
        NSLayoutConstraint.activate([
            stripStack.leadingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.leadingAnchor),
            stripStack.trailingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.trailingAnchor),
            stripStack.topAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.topAnchor),
            stripStack.bottomAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.bottomAnchor),
            stripStack.heightAnchor.constraint(equalTo: stripScroll.frameLayoutGuide.heightAnchor),
        ])
        let add = iconButton("plus", label: "New session") { [weak self] in self?.sessions.requestNewSession() }
        let password = iconButton("key", label: "Send saved password") { [weak self] in self?.sessions.sendPassword() }
        toggleButton = iconButton("square.grid.2x2", label: "Key panel") { [weak self] in self?.keyboard.perform(.togglePanel) }
        let hide = iconButton("keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in self?.keyboard.perform(.dismissKeyboard) }
        [back, stripScroll, add, password, toggleButton, hide].forEach(strip.addArrangedSubview)
        vstack.addArrangedSubview(strip)

        // Key row
        keyScroll.showsHorizontalScrollIndicator = false
        keyScroll.delaysContentTouches = false
        keyScroll.canCancelContentTouches = true
        keyScroll.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        let keys = UIStackView()
        keys.axis = .horizontal
        keys.spacing = 5
        keys.isLayoutMarginsRelativeArrangement = true
        keys.directionalLayoutMargins = .init(top: 4, leading: 6, bottom: 6, trailing: 6)
        keys.translatesAutoresizingMaskIntoConstraints = false
        keyScroll.addSubview(keys)
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: keyScroll.contentLayoutGuide.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: keyScroll.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: keyScroll.contentLayoutGuide.topAnchor),
            keys.bottomAnchor.constraint(equalTo: keyScroll.contentLayoutGuide.bottomAnchor),
            keys.heightAnchor.constraint(equalTo: keyScroll.frameLayoutGuide.heightAnchor),
        ])
        for (i, group) in KeyLayout.accessoryBar.enumerated() {
            if i > 0 {
                let sep = UIView()
                sep.backgroundColor = .separator
                sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
                keys.addArrangedSubview(sep)
            }
            for cap in group.keys {
                keys.addArrangedSubview(makeKey(cap, compact: true))
            }
        }
        vstack.addArrangedSubview(keyScroll)
        rebuildStrip()
    }

    func makeKey(_ cap: KeyCap, compact: Bool) -> KeyButton {
        let b = KeyButton(cap: cap, compact: compact)
        b.onFire = { [weak self] cap in self?.keyboard.perform(cap.action) }
        b.onLongPress = { [weak self] cap in
            if case .latch(let kind) = cap.action { self?.keyboard.lockLatch(kind) }
        }
        if case .latch(let kind) = cap.action { latchButtons[kind] = b }
        return b
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        config.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 8)
        let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    private func rebuildStrip() {
        stripStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in sessions.sessions {
            let active = s.id == sessions.activeID
            var config = active ? UIButton.Configuration.tinted() : UIButton.Configuration.gray()
            config.title = s.title
            config.titleLineBreakMode = .byTruncatingTail
            config.cornerStyle = .medium
            config.buttonSize = .small
            config.image = UIImage(systemName: s.statusSymbol)
            config.imagePadding = 5
            config.imagePlacement = .leading
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.sessions.select(s.id) })
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
            b.accessibilityLabel = "Session \(s.title)"
            b.accessibilityTraits = active ? [.button, .selected] : .button
            b.menu = UIMenu(children: [
                UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.sessions.reconnect(s.id) },
                UIAction(title: "Close", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in self?.sessions.close(s.id) },
            ])
            stripStack.addArrangedSubview(b)
        }
    }

    private func updateLatches(_ bar: ModifierBar) {
        latchButtons[.ctrl]?.setLatch(bar.ctrl.state)
        latchButtons[.alt]?.setLatch(bar.alt.state)
    }

    private func updatePanelState(_ visible: Bool) {
        keyScroll.isHidden = visible
        var config = toggleButton.configuration
        config?.image = UIImage(systemName: visible ? "keyboard" : "square.grid.2x2",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        toggleButton.configuration = config
        toggleButton.accessibilityLabel = visible ? "System keyboard" : "Key panel"
        invalidateIntrinsicContentSize()
    }
}

/// Replaces the system keyboard. Keys tab is a UIKit grid for reliable touch
/// handling; the other tabs are SwiftUI lists.
final class KeyPanel: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    private let keyboard: KeyboardModel
    private let content = UIView()
    private let keysView = UIScrollView()
    private var hosted: UIHostingController<AnyView>?
    private var tabButtons: [PanelTab: UIButton] = [:]
    private var latchButtons: [LatchKind: KeyButton] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let makeTab: (PanelTab) -> AnyView

    init(keyboard: KeyboardModel, makeTab: @escaping (PanelTab) -> AnyView) {
        self.keyboard = keyboard
        self.makeTab = makeTab
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 300), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        keyboard.$bar.receive(on: RunLoop.main).sink { [weak self] bar in
            self?.latchButtons[.ctrl]?.setLatch(bar.ctrl.state)
            self?.latchButtons[.alt]?.setLatch(bar.alt.state)
        }.store(in: &cancellables)
        keyboard.$panelTab.receive(on: RunLoop.main).sink { [weak self] tab in self?.show(tab) }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize {
        let compactHeight = traitCollection.verticalSizeClass == .compact
        return CGSize(width: UIView.noIntrinsicMetric, height: compactHeight ? 200 : 320)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        invalidateIntrinsicContentSize()
    }

    private func build() {
        let tabs = UIStackView()
        tabs.axis = .horizontal
        tabs.distribution = .fillEqually
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(tabs)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: tabs.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 40),
        ])
        for tab in PanelTab.allCases {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: tab.symbol)
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.keyboard.panelTab = tab })
            b.accessibilityLabel = tab.title
            tabButtons[tab] = b
            tabs.addArrangedSubview(b)
        }
        var kb = UIButton.Configuration.plain()
        kb.image = UIImage(systemName: "keyboard")
        let sys = UIButton(configuration: kb, primaryAction: UIAction { [weak self] _ in self?.keyboard.perform(.togglePanel) })
        sys.accessibilityLabel = "System keyboard"
        tabs.addArrangedSubview(sys)

        buildKeys()
    }

    private func buildKeys() {
        keysView.delaysContentTouches = false
        keysView.canCancelContentTouches = true
        keysView.alwaysBounceVertical = false
        keysView.translatesAutoresizingMaskIntoConstraints = false
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 6
        rows.isLayoutMarginsRelativeArrangement = true
        rows.directionalLayoutMargins = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        rows.translatesAutoresizingMaskIntoConstraints = false
        keysView.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: keysView.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: keysView.contentLayoutGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: keysView.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: keysView.contentLayoutGuide.bottomAnchor),
            rows.widthAnchor.constraint(equalTo: keysView.frameLayoutGuide.widthAnchor),
        ])
        for rowCaps in KeyLayout.panelRows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 5
            row.distribution = .fillEqually
            row.heightAnchor.constraint(equalToConstant: 38).isActive = true
            for (i, cap) in rowCaps.enumerated() {
                let key = KeyButton(cap: cap)
                key.onFire = { [weak self] cap in self?.keyboard.perform(cap.action) }
                key.onLongPress = { [weak self] cap in
                    if case .latch(let kind) = cap.action { self?.keyboard.lockLatch(kind) }
                }
                if case .latch(let kind) = cap.action { latchButtons[kind] = key }
                row.addArrangedSubview(key)
                if i == 3 { row.setCustomSpacing(14, after: key) }
            }
            rows.addArrangedSubview(row)
        }
    }

    private func show(_ tab: PanelTab) {
        for (t, b) in tabButtons {
            b.tintColor = t == tab ? .tintColor : .secondaryLabel
            b.accessibilityTraits = t == tab ? [.button, .selected] : .button
        }
        content.subviews.forEach { $0.removeFromSuperview() }
        hosted = nil
        let view: UIView
        if tab == .keys {
            view = keysView
        } else {
            let host = UIHostingController(rootView: makeTab(tab))
            host.view.backgroundColor = .clear
            hosted = host
            view = host.view
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}
