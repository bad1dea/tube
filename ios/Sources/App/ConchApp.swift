import SwiftUI
import LocalAuthentication

@main
struct ConchApp: App {
    @StateObject private var store: AppStore
    @StateObject private var trust: HostKeyTrust
    @StateObject private var sessions: SessionManager
    @StateObject private var sync: SyncController
    @StateObject private var tunnels = TunnelManager()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = AppStore()
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
                .overlay {
                    if lock.locked { LockScreen(lock: lock) }
                }
                .onAppear { lock.lockIfEnabled(store.data.settings.lockWithBiometrics) }
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
                        Task { await sync.syncNow() }
                        tunnels.markDropped()
                    }
                    if phase == .background {
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
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Conch") { ok, _ in
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
                    }
            }
        }
        .sheet(item: $trust.question) { q in
            HostKeyPrompt(question: q) { trust.respond($0) }
                .interactiveDismissDisabled()
        }
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
                    LabeledContent("Key type", value: question.algorithm)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint").font(.caption).foregroundStyle(.secondary)
                        Text(question.fingerprint).font(.callout.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Text("First connection to this host. Compare the fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the server before trusting it.")
                }
            }
            .navigationTitle("Unknown host key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { answer(false) } }
                ToolbarItem(placement: .confirmationAction) { Button("Trust") { answer(true) } }
            }
        }
    }
}
