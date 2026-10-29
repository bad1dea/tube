import SwiftUI
import UIKit
import Combine
import TubeCore

struct TerminalScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var trust: HostKeyTrust

    var body: some View {
        ZStack {
            Color(TerminalTheme.named(store.data.settings.terminal.themeName).background.uiColor)
                .ignoresSafeArea()
            TerminalHost(store: store, sessions: sessions)
                .ignoresSafeArea(.container, edges: .bottom)
            if let s = sessions.active {
                SessionStatusOverlay(session: s)
            }
        }
        .sheet(item: $sessions.pendingSnippet) { snippet in
            SnippetVariablesSheet(snippet: snippet) { values in
                sessions.run(snippet: snippet, values: values)
            }
        }
        .alert(item: $sessions.passwordRequest) { req in
            if !req.hasPassword {
                return Alert(title: Text("No saved password"),
                             message: Text("Save a password for \(req.destination) in the host settings to use this key."),
                             dismissButton: .default(Text("OK")))
            }
            return Alert(
                title: Text("Type saved password?"),
                message: Text(req.atPrompt
                    ? "Types the password for \(req.destination) and presses Return. Requires Face ID, Touch ID or your passcode."
                    : "The cursor is not at a password prompt. The password will be typed where the cursor is and may appear on screen in plain text."),
                primaryButton: req.atPrompt ? .default(Text("Type password")) { sessions.confirmTypePassword(req) }
                                            : .destructive(Text("Type anyway")) { sessions.confirmTypePassword(req) },
                secondaryButton: .cancel { _ = sessions.active?.view.becomeFirstResponder() })
        }
        .sheet(isPresented: $sessions.filesPresented) {
            if let s = sessions.active, let host = store.host(s.hostID) {
                FilesView(host: host, existing: s.sshConnection)
                    .environmentObject(store)
                    .environmentObject(trust)
            }
        }
        .sheet(isPresented: $sessions.hostPickerPresented) {
            HostPicker { host in sessions.open(host) }
                .environmentObject(store)
        }
    }
}

private extension UInt32 {
    var uiColor: UIColor { TerminalTheme.uiColor(self) }
}

struct SessionStatusOverlay: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        switch session.state {
        case .connected:
            EmptyView()
        case .connecting:
            VStack {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting").font(.callout)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding(.top, 8)
        case .needsPassword(let hostID, let destination, let rejected):
            VStack {
                Spacer()
                PasswordPrompt(session: session, hostID: hostID, destination: destination, rejected: rejected)
                    .id(hostID.uuidString + (rejected ? "r" : ""))
                    .padding()
            }
        case .disconnected(let reason):
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Disconnected").font(.headline)
                    if let reason {
                        Text(reason).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Reconnect") { session.connect() }
                            .buttonStyle(.borderedProminent)
                        Button("Close", role: .destructive) { sessions.close(session.id) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .frame(maxWidth: 480, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }
        }
    }
}

/// Asked when a host has no saved password or the saved one was rejected.
struct PasswordPrompt: View {
    @ObservedObject var session: TerminalSession
    let hostID: UUID
    let destination: String
    let rejected: Bool
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @State private var password = ""
    @State private var save = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rejected ? "Wrong password" : "Password").font(.headline)
            Text(destination).font(.caption.monospaced()).foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(submit)
                .padding(8)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("sessionPassword")
            Toggle("Save to vault", isOn: $save)
                .font(.subheadline)
            HStack {
                Button("Connect", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                Button("Close", role: .destructive) { sessions.close(session.id) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        if save, let h = store.host(hostID) {
            // Saved only once it is typed; a wrong one is replaced on the next prompt.
            store.upsert(h, password: password)
        }
        session.connect(password: password, for: hostID)
        _ = session.view.becomeFirstResponder()
    }
}

struct TerminalHost: UIViewControllerRepresentable {
    let store: AppStore
    let sessions: SessionManager

    func makeUIViewController(context: Context) -> TerminalHostController {
        TerminalHostController(store: store, sessions: sessions)
    }

    func updateUIViewController(_ vc: TerminalHostController, context: Context) {
        vc.show(sessions.active)
    }
}

/// Holds the active session's terminal view, installs the key bar / key panel
/// as its input views, and provides Command shortcuts for hardware keyboards.
final class TerminalHostController: UIViewController {
    private let store: AppStore
    private let sessions: SessionManager
    private var current: TubeTerminalView?
    private lazy var accessory = AccessoryBar(keyboard: sessions.keyboard, sessions: sessions)
    // The panel outlives this controller (it stays installed as the terminal
    // view's inputView), so its tab factory must not capture self.
    private lazy var panel = KeyPanel(keyboard: sessions.keyboard) { [store, sessions] tab in
        AnyView(PanelTabView(tab: tab).environmentObject(store).environmentObject(sessions))
    }

    init(store: AppStore, sessions: SessionManager) {
        self.store = store
        self.sessions = sessions
        super.init(nibName: nil, bundle: nil)
        sessions.keyboard.onToggleInputMode = { [weak self] in self?.toggleInputMode() }
        // Switch views on every selection change, including taps in the
        // keyboard's session strip that do not re-render the SwiftUI screen.
        // $activeID emits before the property changes, so use the value.
        activeWatcher = sessions.$activeID.receive(on: RunLoop.main).sink { [weak self] id in
            guard let self else { return }
            self.show(self.sessions.sessions.first { $0.id == id })
        }
    }

    private var activeWatcher: AnyCancellable?

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = current?.becomeFirstResponder()
    }

    func show(_ session: TerminalSession?) {
        let tv = session?.view
        guard tv !== current else { return }
        let wasFirstResponder = current?.isFirstResponder ?? true
        current?.removeFromSuperview()
        current = tv
        sessions.keyboard.terminal = tv
        guard let tv else { return }
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
            tv.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4),
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // keyboardLayoutGuide follows the keyboard plus accessory, so the
            // prompt line is never hidden behind them.
            tv.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        tv.inputAccessoryView = accessory
        tv.inputView = sessions.keyboard.panelVisible ? panel : nil
        installPadGesture(on: tv)
        if wasFirstResponder && view.window != nil {
            _ = tv.becomeFirstResponder()
        }
    }

    // MARK: Long-press pad

    private final class PadPress: UILongPressGestureRecognizer {}
    private var pad: TerminalPad?
    private var padOrigin: CGPoint = .zero

    private func installPadGesture(on tv: TubeTerminalView) {
        guard !(tv.gestureRecognizers ?? []).contains(where: { $0 is PadPress }) else { return }
        let press = PadPress(target: self, action: #selector(padPressed(_:)))
        press.minimumPressDuration = 0.35
        tv.addGestureRecognizer(press)
        // SwiftTerm's own long press opens an edit menu; the pad carries the
        // same copy/paste, so it takes precedence.
        for g in tv.gestureRecognizers ?? [] where g is UILongPressGestureRecognizer && !(g is PadPress) {
            g.require(toFail: press)
        }
    }

    @objc private func padPressed(_ g: UILongPressGestureRecognizer) {
        guard let tv = current else { return }
        let p = g.location(in: view)
        switch g.state {
        case .began:
            showPad(at: p, for: tv)
        case .changed:
            pad?.drive(CGVector(dx: p.x - padOrigin.x, dy: p.y - padOrigin.y))
        default:
            pad?.release()
        }
    }

    private func showPad(at point: CGPoint, for tv: TubeTerminalView) {
        pad?.removeFromSuperview()
        let size = TerminalPad.size
        let bounds = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 8, dy: 8)
        // Centre the ring under the finger, kept fully on screen.
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - 8 - TerminalPad.ringSize / 2)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), view.keyboardLayoutGuide.layoutFrame.minY - size.height - 8)
        let p = TerminalPad(frame: CGRect(origin: origin, size: size))
        p.terminal = tv
        p.onClose = { [weak self, weak p] in
            UIView.animate(withDuration: 0.15, animations: { p?.alpha = 0 }) { _ in p?.removeFromSuperview() }
            if self?.pad === p { self?.pad = nil }
        }
        p.alpha = 0
        view.addSubview(p)
        UIView.animate(withDuration: 0.12) { p.alpha = 1 }
        pad = p
        padOrigin = CGPoint(x: origin.x + size.width / 2, y: origin.y + 8 + TerminalPad.ringSize / 2)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        p.refresh()
    }

    private func toggleInputMode() {
        guard let tv = current else { return }
        sessions.keyboard.panelVisible.toggle()
        tv.inputView = sessions.keyboard.panelVisible ? panel : nil
        accessory.invalidateIntrinsicContentSize()
        if tv.isFirstResponder {
            tv.reloadInputViews()
        } else {
            _ = tv.becomeFirstResponder()
        }
    }

    // MARK: Hardware keyboard shortcuts (Command only, so Ctrl/Option reach the shell)

    override var keyCommands: [UIKeyCommand]? {
        var cmds = [
            UIKeyCommand(title: "New Session", action: #selector(newSession), input: "t", modifierFlags: .command),
            UIKeyCommand(title: "Close Session", action: #selector(closeSession), input: "w", modifierFlags: .command),
            UIKeyCommand(title: "Next Session", action: #selector(nextSession), input: "]", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Previous Session", action: #selector(previousSession), input: "[", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Bigger Text", action: #selector(fontUp), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Text", action: #selector(fontDown), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Show Hosts", action: #selector(showHosts), input: "h", modifierFlags: [.command, .shift]),
        ]
        for i in 1...9 {
            cmds.append(UIKeyCommand(title: "Session \(i)", action: #selector(selectIndex(_:)), input: "\(i)", modifierFlags: .command))
        }
        for c in cmds { c.wantsPriorityOverSystemBehavior = true }
        return cmds
    }

    @objc private func newSession() { sessions.requestNewSession() }
    @objc private func closeSession() { if let id = sessions.activeID { sessions.close(id) } }
    @objc private func nextSession() { sessions.selectNext(1) }
    @objc private func previousSession() { sessions.selectNext(-1) }
    @objc private func showHosts() { sessions.showHosts() }
    @objc private func fontUp() { sessions.active?.setFontSize((current?.font.pointSize ?? 13) + 1) }
    @objc private func fontDown() { sessions.active?.setFontSize(max(8, (current?.font.pointSize ?? 13) - 1)) }
    @objc private func selectIndex(_ cmd: UIKeyCommand) {
        if let s = cmd.input, let n = Int(s) { sessions.select(index: n - 1) }
    }
}

struct PanelTabView: View {
    let tab: PanelTab
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        switch tab {
        case .keys:
            EmptyView()
        case .snippets:
            List {
                if store.data.snippets.isEmpty {
                    Text("No snippets. Add them from the host list menu.").foregroundStyle(.secondary)
                }
                ForEach(store.data.snippets) { s in
                    Button {
                        if s.variables.isEmpty {
                            sessions.run(snippet: s, values: [:])
                        } else {
                            sessions.pendingSnippet = s
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline)
                            Text(s.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .history:
            List {
                if store.data.history.isEmpty {
                    Text("Commands run from snippets appear here.").foregroundStyle(.secondary)
                }
                ForEach(store.data.history, id: \.self) { cmd in
                    Button { sessions.run(history: cmd) } label: {
                        Text(cmd).font(.caption.monospaced()).lineLimit(2)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .themes:
            ThemePicker()
        }
    }
}

struct ThemePicker: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Font").font(.caption).foregroundStyle(.secondary)
                    Picker("Font", selection: $store.data.settings.terminal.fontName) {
                        ForEach(TerminalFonts.names, id: \.self) { Text($0).tag($0) }
                    }
                    Spacer()
                    Stepper("\(Int(store.data.settings.terminal.fontSize)) pt",
                            value: $store.data.settings.terminal.fontSize, in: 8...32, step: 1)
                        .fixedSize()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(TerminalTheme.all) { theme in
                        Button { store.data.settings.terminal.themeName = theme.name } label: {
                            ThemeSwatch(theme: theme, selected: theme.name == store.data.settings.terminal.themeName)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
        }
        .onChange(of: store.data.settings.terminal) { sessions.applySettings() }
    }
}

struct ThemeSwatch: View {
    let theme: TerminalTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text("$ ls").foregroundStyle(Color(TerminalTheme.uiColor(theme.foreground)))
                HStack(spacing: 3) {
                    ForEach(1..<7) { i in
                        Rectangle().fill(Color(TerminalTheme.uiColor(theme.ansi[i]))).frame(width: 10, height: 4)
                    }
                }
            }
            .font(.caption2.monospaced())
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(TerminalTheme.uiColor(theme.background)), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
            Text(theme.name).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SnippetVariablesSheet: View {
    let snippet: Snippet
    let run: ([String: String]) -> Void
    @State private var values: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(snippet.variables, id: \.self) { name in
                        TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                }
                Section("Command") {
                    Text(snippet.render(values)).font(.caption.monospaced())
                }
            }
            .navigationTitle(snippet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { run(values); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
