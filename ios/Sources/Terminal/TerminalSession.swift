import UIKit
import SwiftTerm
import TubeCore
import TubeSSH

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case disconnected(String?)
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
        view.onFontSizeChange = { [weak self] size in self?.setFontSize(size) }
    }

    /// For SFTP on the same connection while the shell is open.
    var sshConnection: SSHConnection? { connection }

    var statusSymbol: String {
        switch state {
        case .connecting: return "ellipsis"
        case .connected: return "terminal"
        case .disconnected: return "bolt.horizontal.circle"
        }
    }

    func connect() {
        guard let store, let host = store.host(hostID) else {
            state = .disconnected("Host was deleted")
            return
        }
        teardown()
        state = .connecting
        view.feed(text: "\r\nConnecting to \(host.destination)...\r\n")
        let chain: [SSHHop]
        do {
            chain = try store.chain(for: host)
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
            } catch {
                self.fail(error)
            }
        }
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
        Task { try? await shell.resize(cols: t.cols, rows: t.rows) }
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
    }

    func sendPassword() {
        guard let store, let host = store.host(hostID),
              let pw = Keychain.string(for: .hostPassword(host.id)) else { return }
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
        Task { @MainActor in
            try? await self.shell?.resize(cols: newCols, rows: newRows)
        }
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
