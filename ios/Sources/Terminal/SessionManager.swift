import UIKit
import SwiftUI
import LocalAuthentication
import Combine
import TubeCore

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeID: UUID?
    /// iPhone: whether the terminal screen covers the host list.
    @Published var terminalPresented = false
    @Published var hostPickerPresented = false
    /// Snippet waiting for variable values; asked in a sheet because a text
    /// field inside the key panel would take first responder from the terminal.
    @Published var pendingSnippet: Snippet?
    @Published var filesPresented = false
    @Published var passwordRequest: PasswordRequest?
    /// Last connection error per host, for the badge in the host list.
    @Published private(set) var failures: [UUID: String] = [:]
    private var stateWatchers: [UUID: AnyCancellable] = [:]

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
    }

    var active: TerminalSession? { sessions.first { $0.id == activeID } }

    func open(_ host: Host) {
        let s = TerminalSession(host: host, store: store, trust: trust, keyboard: keyboard)
        sessions.append(s)
        activeID = s.id
        terminalPresented = true
        hostPickerPresented = false
        s.connect()
        observe(s)
    }

    private func observe(_ s: TerminalSession) {
        let hostID = s.hostID
        stateWatchers[s.id] = s.$state.receive(on: RunLoop.main).sink { [weak self] state in
            switch state {
            case .connected: self?.failures[hostID] = nil
            case .disconnected(let reason?): self?.failures[hostID] = reason
            default: break
            }
        }
        // Forward per-session changes (title, state) so the tab strip redraws.
        Task { [weak self, weak s] in
            guard let s else { return }
            for await _ in s.objectWillChange.values {
                self?.objectWillChange.send()
            }
        }
    }

    func select(_ id: UUID) {
        activeID = id
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].close()
        stateWatchers[id] = nil
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
