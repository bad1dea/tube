import UIKit
import SwiftTerm
import TubeCore
import TermInput
import TubeSSH

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case disconnected(String?)
        /// No saved password, or the saved one was rejected: ask, then retry.
        case needsPassword(hostID: UUID, destination: String, rejected: Bool)
    }

    let id = UUID()
    let hostID: UUID
    @Published var title: String
    @Published private(set) var state: State = .connecting
    let view: TubeTerminalView

    private var connection: SSHConnection?
    private var shell: ShellSession?
    private var pump: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var outbound: AsyncStream<[UInt8]>.Continuation?
    private weak var store: AppStore?
    private let trust: HostKeyTrust

    init(host: Host, store: AppStore, trust: HostKeyTrust, keyboard: KeyboardModel) {
        hostID = host.id
        title = host.displayName
        self.store = store
        self.trust = trust
        let settings = host.terminal ?? store.data.settings.terminal
        view = TubeTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600),
                                 font: TerminalFonts.font(name: settings.fontName, size: settings.fontSize))
        view.keyboard = keyboard
        view.backspaceSendsControlH = settings.backspaceSendsControlH
        view.optionAsMetaKey = true
        TerminalTheme.named(settings.themeName).apply(to: view)
        view.terminalDelegate = self
        if ProcessInfo.processInfo.environment["TUBE_UITEST"] == "1" {
            // A blinking caret keeps the app from ever being idle, and XCUITest
            // waits for idle before each step.
            view.getTerminal().setCursorStyle(.steadyBlock)
        }
        view.onFontSizeChange = { [weak self] size in self?.setFontSize(size) }
    }

    /// For SFTP on the same connection while the shell is open.
    var sshConnection: SSHConnection? { connection }

    var statusSymbol: String {
        switch state {
        case .connecting: return "ellipsis"
        case .connected: return "terminal"
        case .disconnected: return "bolt.horizontal.circle"
        case .needsPassword: return "key"
        }
    }

    /// Last window size sent to the server (see sendSize).
    private var lastSentSize = (cols: 0, rows: 0)

    /// Passwords typed into the prompt for this session, by host id.
    private var typedPasswords: [UUID: String] = [:]

    func connect(password: String? = nil, for passwordHost: UUID? = nil) {
        if let password, let passwordHost { typedPasswords[passwordHost] = password }
        guard let store, let host = store.host(hostID) else {
            state = .disconnected("Host was deleted")
            return
        }
        teardown()
        state = .connecting
        view.feed(text: "\r\nConnecting to \(host.destination)...\r\n")
        let chain: [SSHHop]
        let hosts: [Host]
        do {
            hosts = try store.chainHosts(for: host)
            chain = try store.chain(for: host, passwords: typedPasswords)
        } catch ChainError.noCredential(let id, _) {
            askPassword(for: id, rejected: false)
            return
        } catch {
            fail(error)
            return
        }
        let terminal = view.getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        let trust = self.trust

        Task {
            do {
                let conn = try await SSHConnection.connect(chain: chain, trust: trust)
                let shell = ShellSession()
                try await shell.start(on: conn, cols: cols, rows: rows)
                self.attach(conn, shell)
                store.markConnected(host.id)
            } catch SSHConnectError.authenticationFailed(let h, let p, let u) {
                // Ask again only for a host that logs in with a password.
                if let rejected = hosts.first(where: { $0.hostname == h && $0.port == p && $0.username == u }),
                   rejected.identityID == nil {
                    self.typedPasswords[rejected.id] = nil
                    self.askPassword(for: rejected.id, rejected: true)
                } else {
                    self.fail(SSHConnectError.authenticationFailed(host: h, port: p, user: u))
                }
            } catch {
                self.fail(error)
            }
        }
    }

    private func askPassword(for id: UUID, rejected: Bool) {
        teardown()
        let dest = store?.host(id)?.destination ?? "host"
        state = .needsPassword(hostID: id, destination: dest, rejected: rejected)
    }

    private func attach(_ conn: SSHConnection, _ shell: ShellSession) {
        connection = conn
        self.shell = shell
        state = .connected

        let (stream, cont) = AsyncStream<[UInt8]>.makeStream()
        outbound = cont
        // One writer task keeps keystrokes in order; separate Tasks per key
        // could reorder an ESC and the byte that follows it.
        writer = Task {
            for await bytes in stream {
                try? await shell.send(bytes)
            }
        }
        pump = Task { [weak self] in
            for await chunk in shell.output {
                guard let self else { break }
                self.view.feed(byteArray: chunk[...])
            }
            self?.remoteClosed()
        }
        let t = view.getTerminal()
        lastSentSize = (0, 0)
        sendSize(cols: t.cols, rows: t.rows)
        detectOS(conn)
    }

    /// Fills Host.osID for the host list icon. One exec channel, ignored on failure.
    private func detectOS(_ conn: SSHConnection) {
        Task { [weak self] in
            guard let out = try? await conn.run("uname -s; (. /etc/os-release 2>/dev/null && echo \"$ID\"); true") else { return }
            let lines = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            guard let kernel = lines.first, !kernel.isEmpty else { return }
            let id = (lines.count > 1 && !lines[1].isEmpty ? lines[1] : kernel).lowercased()
            guard let self, let store = self.store,
                  let i = store.data.hosts.firstIndex(where: { $0.id == self.hostID }),
                  store.data.hosts[i].osID != id else { return }
            store.data.hosts[i].osID = id
        }
    }

    private func remoteClosed() {
        guard state == .connected else { return }
        let reason = shell?.exitError.map { "\($0)" }
        teardown()
        state = .disconnected(reason)
        view.feed(text: "\r\n[connection closed]\r\n")
    }

    private func fail(_ error: Error) {
        teardown()
        let message = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        state = .disconnected(message)
        view.feed(text: "\r\n\u{1b}[31m\(message)\u{1b}[0m\r\n")
    }

    func send(_ bytes: [UInt8]) {
        outbound?.yield(bytes)
        trackLine(bytes)
    }

    // MARK: Typed line (for suggestions)

    private var tracker = LineTracker()
    /// What the user has typed on the current shell line, if it could be followed.
    @Published private(set) var typedLine: String?
    var onCommand: ((String) -> Void)?

    /// Prompt text in front of the cursor when the current line started.
    private var linePrompt = ""

    private func trackLine(_ bytes: [UInt8]) {
        if tracker.known && tracker.text.isEmpty {
            linePrompt = cursorLine
        }
        if let line = tracker.feed(bytes) {
            // Recorded only when typed at a shell prompt, judged from the prompt
            // before the first key; a password prompt never qualifies. (Waiting
            // for the echo was unreliable: fast input sends Return first.)
            if !view.getTerminal().isCurrentBufferAlternate && ShellPrompt.isCommandPrompt(linePrompt) {
                onCommand?(line)
            }
        }
        typedLine = tracker.known && !view.getTerminal().isCurrentBufferAlternate ? tracker.text : nil
    }

    var hasSavedPassword: Bool {
        Keychain.data(for: .hostPassword(hostID)) != nil
    }

    var destination: String { store?.host(hostID)?.destination ?? title }

    /// Text of the line the cursor is on, e.g. "[sudo] password for khuong: ".
    var cursorLine: String {
        let t = view.getTerminal()
        return t.getLine(row: t.getCursorLocation().y)?.translateToString(trimRight: true) ?? ""
    }

    /// Heuristic only: sudo, ssh, su and most tools end the prompt line with
    /// one of these words. Echo state is not visible to the client.
    var looksLikePasswordPrompt: Bool {
        let l = cursorLine.lowercased()
        return ["password", "passphrase", "passcode"].contains { l.contains($0) }
    }

    /// Types the saved password and Return. Callers authenticate first.
    func typeSavedPassword() {
        guard let pw = Keychain.string(for: .hostPassword(hostID)) else { return }
        send(Array(pw.utf8) + [0x0d])
    }

    func close() {
        teardown()
    }

    private func teardown() {
        outbound?.finish()
        outbound = nil
        writer?.cancel()
        pump?.cancel()
        shell?.close()
        shell = nil
        if let c = connection {
            Task { await c.close() }
        }
        connection = nil
    }

    func setFontSize(_ size: CGFloat) {
        view.font = TerminalFonts.font(name: store?.data.settings.terminal.fontName ?? "", size: size)
        store?.data.settings.terminal.fontSize = Double(size)
    }

    func applySettings(_ settings: TerminalSettings) {
        view.font = TerminalFonts.font(name: settings.fontName, size: settings.fontSize)
        view.backspaceSendsControlH = settings.backspaceSendsControlH
        TerminalTheme.named(settings.themeName).apply(to: view)
    }
}

extension TerminalSession: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in self.sendSize(cols: newCols, rows: newRows) }
    }

    /// A terminal view that is off screen (another session selected) or mid
    /// layout can measure as a few cells or zero. Sending that as a window
    /// change makes full-screen programs redraw for nothing, and tmux has
    /// crashed on degenerate sizes, so only real sizes go to the server.
    func sendSize(cols: Int, rows: Int) {
        guard cols >= 20, rows >= 5, view.window != nil else { return }
        guard cols != lastSentSize.cols || rows != lastSentSize.rows else { return }
        lastSentSize = (cols, rows)
        Task { try? await self.shell?.resize(cols: cols, rows: rows) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor in
            if !title.isEmpty { self.title = title }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // SwiftTerm calls this on the main thread; staying synchronous keeps
        // keystroke order intact.
        let bytes = Array(data)
        MainActor.assumeIsolated { self.send(bytes) }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in UIApplication.shared.open(url) }
    }

    nonisolated func bell(source: TerminalView) {
        Task { @MainActor in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52 from the remote host; allowed to write, never to read.
        if let s = String(data: content, encoding: .utf8) {
            Task { @MainActor in UIPasteboard.general.string = s }
        }
    }

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
