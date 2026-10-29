import UIKit
import SwiftUI
import LocalAuthentication
import Combine
import TubeCore
import TermInput

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeID: UUID? {
        didSet { watchTyping() }
    }
    /// iPhone: whether the terminal screen covers the host list.
    @Published var terminalPresented = false
    @Published var hostPickerPresented = false
    /// Snippet waiting for variable values; asked in a sheet because a text
    /// field inside the key panel would take first responder from the terminal.
    @Published var pendingSnippet: Snippet?
    @Published var filesPresented = false
    @Published var passwordRequest: PasswordRequest?
    @Published private(set) var suggestions: [String] = []
    private var typedWatcher: AnyCancellable?
    private let liveActivity = SessionsLiveActivity()
    private var activityWatcher: AnyCancellable?
    /// Last connection error per host, for the badge in the host list.
    @Published private(set) var failures: [UUID: String] = [:]
    private var stateWatchers: [UUID: AnyCancellable] = [:]
    private var forwarders: [UUID: AnyCancellable] = [:]

    struct PasswordRequest: Identifiable {
        let id = UUID()
        let sessionID: UUID
        let destination: String
        let hasPassword: Bool
        let atPrompt: Bool
    }

    let keyboard = KeyboardModel()
    private let store: AppStore
    let trust: HostKeyTrust

    init(store: AppStore, trust: HostKeyTrust) {
        self.store = store
        self.trust = trust
        keyboard.clicks = store.data.settings.keyClicks
        keyboard.panelVisible = store.data.settings.showKeyPanelByDefault
        // objectWillChange fires before the change lands; read on the next turn.
        activityWatcher = objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.refreshLiveActivity()
        }
    }

    var active: TerminalSession? { sessions.first { $0.id == activeID } }

    func open(_ host: Host) {
        let s = TerminalSession(host: host, store: store, trust: trust, keyboard: keyboard)
        s.onCommand = { [weak self] line in self?.recordCommand(line) }
        sessions.append(s)
        activeID = s.id
        terminalPresented = true
        hostPickerPresented = false
        s.connect()
        observe(s)
    }

    private func observe(_ s: TerminalSession) {
        let hostID = s.hostID
        s.onExit = { [weak self, id = s.id] in self?.close(id) }
        stateWatchers[s.id] = s.$state.receive(on: RunLoop.main).sink { [weak self] state in
            switch state {
            case .connected: self?.failures[hostID] = nil
            case .disconnected(let reason?): self?.failures[hostID] = reason
            default: break
            }
        }
        // Forward per-session changes (title, state) so the tab strip redraws.
        // A sink, not `for await in .values`: AsyncPublisher traps when the
        // session publishes again before the loop asks for the next value,
        // which typing does on every key.
        forwarders[s.id] = s.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func select(_ id: UUID) {
        activeID = id
    }

    private func refreshLiveActivity() {
        liveActivity.update(sessions.map {
            .init(title: label(for: $0), osID: store.host($0.hostID)?.osID, connected: $0.state == .connected)
        })
    }

    private func recordCommand(_ line: String) {
        var s = CommandSuggester(history: store.data.commandHistory)
        s.record(line)
        store.data.commandHistory = s.history
    }

    private func watchTyping() {
        typedWatcher = active?.$typedLine.receive(on: RunLoop.main).sink { [weak self] typed in
            guard let self else { return }
            let next = typed.map { CommandSuggester(history: self.store.data.commandHistory).suggestions(for: $0) } ?? []
            if next != self.suggestions { self.suggestions = next }
        }
    }

    /// Completes the current line with `suggestion` by typing the missing part.
    func accept(_ suggestion: String) {
        guard let s = active, let typed = s.typedLine, suggestion.hasPrefix(typed) else { return }
        s.view.send(Array(suggestion.dropFirst(typed.count).utf8))
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].close()
        stateWatchers[id] = nil
        forwarders[id] = nil
        sessions.remove(at: i)
        if activeID == id {
            activeID = sessions.indices.contains(i) ? sessions[i].id : sessions.last?.id
        }
        if sessions.isEmpty { terminalPresented = false }
    }

    /// After returning from the background: sessions iOS let die reconnect.
    func reconnectDropped() {
        for s in sessions {
            if case .disconnected = s.state { s.connect() }
        }
    }

    func reconnect(_ id: UUID) {
        sessions.first { $0.id == id }?.connect()
    }

    func showHosts() {
        terminalPresented = false
    }

    /// Host name, numbered when several sessions go to the same host; the
    /// terminal's own title (often "user@host:~") cannot tell them apart.
    func label(for s: TerminalSession) -> String {
        let name = store.host(s.hostID)?.displayName ?? s.title
        let same = sessions.filter { $0.hostID == s.hostID }
        guard same.count > 1, let i = same.firstIndex(where: { $0.id == s.id }) else { return name }
        return "\(name) \(i + 1)"
    }

    func isOpen(_ hostID: UUID) -> Bool {
        sessions.contains { $0.hostID == hostID && $0.state == .connected }
    }

    func requestNewSession() {
        hostPickerPresented = true
    }

    func requestFiles() {
        if active != nil { filesPresented = true }
    }

    /// Asks first; the password is only typed after confirmation and device
    /// authentication (confirmTypePassword).
    func sendPassword() {
        guard let s = active else { return }
        passwordRequest = PasswordRequest(sessionID: s.id, destination: s.destination,
                                          hasPassword: s.hasSavedPassword, atPrompt: s.looksLikePasswordPrompt)
    }

    func confirmTypePassword(_ request: PasswordRequest) {
        guard let s = sessions.first(where: { $0.id == request.sessionID }) else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No passcode set on the device: the confirmation was the only gate.
            s.typeSavedPassword()
            _ = s.view.becomeFirstResponder()
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Type the saved password for \(request.destination)") { ok, _ in
            Task { @MainActor in
                if ok { s.typeSavedPassword() }
                _ = s.view.becomeFirstResponder()
            }
        }
    }

    func run(snippet: Snippet, values: [String: String]) {
        guard let s = active else { return }
        let text = snippet.render(values)
        store.recordHistory(text)
        s.send(Array(text.utf8) + (snippet.runImmediately ? [0x0d] : []))
    }

    func run(history command: String) {
        guard let s = active else { return }
        store.recordHistory(command)
        s.send(Array(command.utf8))
    }

    func applySettings() {
        keyboard.clicks = store.data.settings.keyClicks
        for s in sessions {
            let settings = store.host(s.hostID)?.terminal ?? store.data.settings.terminal
            s.applySettings(settings)
        }
    }

    func selectNext(_ delta: Int) {
        guard let id = activeID, let i = sessions.firstIndex(where: { $0.id == id }), !sessions.isEmpty else { return }
        activeID = sessions[(i + delta + sessions.count) % sessions.count].id
    }

    func select(index: Int) {
        if sessions.indices.contains(index) { activeID = sessions[index].id }
    }
}
