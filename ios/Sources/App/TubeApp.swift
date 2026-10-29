import SwiftUI
import LocalAuthentication
import TubeCore

/// Launch environment TUBE_UITEST=1 (set by UITests/TubeUITests.swift) starts
/// from a throwaway data file with sample hosts, one of them real.
enum UITestSeed {
    @MainActor
    static func store() -> AppStore? {
        let env = ProcessInfo.processInfo.environment
        guard env["TUBE_UITEST"] == "1" else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString).json")
        let s = AppStore(url: url)
        let home = HostGroup(name: "Home")
        let lab = HostGroup(name: "Lab")
        s.data.groups = [home, lab]
        let hour: TimeInterval = 3600
        var hosts = [
            Host(label: "leela", hostname: "10.10.20.20", username: "khuong", groupID: home.id, favorite: true,
                 lastConnected: Date().addingTimeInterval(-2 * hour), osID: "fedora"),
            Host(label: "amy", hostname: "10.10.30.10", username: "khuong", groupID: home.id,
                 lastConnected: Date().addingTimeInterval(-26 * hour), osID: "fedora"),
            Host(label: "nas", hostname: "10.10.30.30", username: "admin", groupID: home.id, tags: ["storage"], osID: "debian"),
            Host(label: "pi", hostname: "pi.lan", username: "pi", groupID: lab.id, osID: "raspbian"),
        ]
        let bastion = Host(label: "bastion", hostname: "ctrl.khuo.ng", port: 2222, username: "jump", groupID: lab.id, osID: "ubuntu")
        hosts.append(bastion)
        hosts.append(Host(label: "lab", hostname: "100.64.0.10", port: 2022, username: "khuong", jumpHostIDs: [bastion.id],
                          groupID: lab.id, osID: "alpine"))
        var real = Host(label: env["TUBE_UITEST_LABEL"] ?? "runner", hostname: env["TUBE_UITEST_HOST"] ?? "127.0.0.1",
                        port: Int(env["TUBE_UITEST_PORT"] ?? "") ?? 22, username: env["TUBE_UITEST_USER"] ?? "runner",
                        favorite: true, lastConnected: Date().addingTimeInterval(-300))
        real.osID = nil
        hosts.append(real)
        // Same server, no saved password: exercises the in-session prompt.
        hosts.append(Host(label: "runner-nopw", hostname: real.hostname, port: real.port, username: real.username))
        s.data.hosts = hosts
        if let pw = env["TUBE_UITEST_PASSWORD"] { s.upsert(real, password: pw) }
        s.data.snippets = [
            Snippet(name: "Disk usage", command: "df -h"),
            Snippet(name: "Follow a unit", command: "journalctl -fu {{unit}}"),
        ]
        return s
    }
}

@main
struct TubeApp: App {
    @StateObject private var store: AppStore
    @StateObject private var trust: HostKeyTrust
    @StateObject private var sessions: SessionManager
    @StateObject private var sync: SyncController
    @StateObject private var tunnels = TunnelManager()
    @StateObject private var keeper = BackgroundKeeper()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = UITestSeed.store() ?? AppStore()
        if ProcessInfo.processInfo.environment["TUBE_UITEST"] == "1" { UIView.setAnimationsEnabled(false) }
        let trust = HostKeyTrust(store: store)
        _store = StateObject(wrappedValue: store)
        _trust = StateObject(wrappedValue: trust)
        _sessions = StateObject(wrappedValue: SessionManager(store: store, trust: trust))
        _sync = StateObject(wrappedValue: SyncController(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(trust)
                .environmentObject(sessions)
                .environmentObject(sync)
                .environmentObject(tunnels)
                .environmentObject(keeper)
                .overlay {
                    if lock.locked { LockScreen(lock: lock) }
                }
                .onAppear { lock.lockIfEnabled(store.data.settings.lockWithBiometrics) }
                .onOpenURL { url in
                    // tube://sessions from the Live Activity.
                    if url.host == "sessions", !sessions.sessions.isEmpty { sessions.terminalPresented = true }
                }
                .onChange(of: store.data.hosts) { sync.scheduleSync() }
                .onChange(of: store.data.snippets) { sync.scheduleSync() }
                .onChange(of: store.data.identities) { sync.scheduleSync() }
                .onChange(of: store.data.groups) { sync.scheduleSync() }
                .onChange(of: store.data.knownHosts) {
                    trust.reload()
                    sync.scheduleSync()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        keeper.becameActive()
                        Task { await sync.syncNow() }
                        tunnels.markDropped()
                        if store.data.settings.reconnectOnReturn { sessions.reconnectDropped() }
                    }
                    if phase == .background {
                        keeper.enteredBackground(hasSessions: !sessions.sessions.isEmpty,
                                                 keepAlive: store.data.settings.keepAliveInBackground)
                        store.saveNow()
                        lock.lockIfEnabled(store.data.settings.lockWithBiometrics)
                    }
                }
                .preferredColorScheme(.dark)
        }
    }
}

/// Optional Face ID / passcode gate in front of the whole app. It hides host
/// details; Keychain items themselves are protected by the device passcode.
@MainActor
final class AppLock: ObservableObject {
    @Published var locked = false

    func lockIfEnabled(_ enabled: Bool) {
        if enabled { locked = true }
    }

    func unlock() {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Tube") { ok, _ in
            Task { @MainActor in if ok { self.locked = false } }
        }
    }
}

struct LockScreen: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock").font(.largeTitle)
                Button("Unlock") { lock.unlock() }.buttonStyle(.borderedProminent)
            }
        }
        .onAppear { lock.unlock() }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var trust: HostKeyTrust
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var sync: SyncController
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    HostListView()
                } detail: {
                    if sessions.sessions.isEmpty {
                        ContentUnavailableView("No sessions", systemImage: "terminal",
                                               description: Text("Pick a host to connect."))
                    } else {
                        TerminalScreen()
                    }
                }
            } else {
                NavigationStack { HostListView() }
                    .fullScreenCover(isPresented: $sessions.terminalPresented) {
                        TerminalScreen()
                            .environmentObject(store)
                            .environmentObject(sessions)
                            .environmentObject(trust)
                            .environmentObject(sync)
                            .sheet(item: hostKeyQuestion(shownHere: true)) { q in hostKeySheet(q) }
                    }
            }
        }
        // A sheet cannot present from under the terminal's full-screen cover,
        // so while the cover is up (iPhone) the cover presents the question.
        .sheet(item: hostKeyQuestion(shownHere: sizeClass == .regular || !sessions.terminalPresented)) { q in
            hostKeySheet(q)
        }
    }

    private func hostKeyQuestion(shownHere: Bool) -> Binding<HostKeyQuestion?> {
        Binding(get: { shownHere ? trust.question : nil },
                set: { if shownHere, $0 == nil { trust.respond(false) } })
    }

    private func hostKeySheet(_ q: HostKeyQuestion) -> some View {
        HostKeyPrompt(question: q) { trust.respond($0) }
            .interactiveDismissDisabled()
    }
}

struct HostKeyPrompt: View {
    let question: HostKeyQuestion
    let answer: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Host", value: "\(question.host):\(question.port)")
                    LabeledContent("Key Type", value: question.algorithm)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint").font(.caption).foregroundStyle(.secondary)
                        Text(question.fingerprint).font(.callout.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Text("You haven’t connected to this server before. If you can, check that the fingerprint matches the one the server shows for `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, then tap Trust.")
                }
            }
            .navigationTitle("Trust This Server?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { answer(false) } }
                ToolbarItem(placement: .confirmationAction) { Button("Trust") { answer(true) } }
            }
        }
    }
}
