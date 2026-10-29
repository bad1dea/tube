import SwiftUI
import TubeCore
import TubeSSH

/// Running forwards, one SSH connection per host. iOS suspends the app soon
/// after it leaves the foreground, which stops every forward; there is no way
/// around that for a non-VPN app.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var running: [UUID: Int] = [:]   // forward id -> bound port
    @Published var errors: [UUID: String] = [:]
    private var handles: [UUID: PortForwardHandle] = [:]
    private var connections: [UUID: SSHConnection] = [:]      // host id -> connection
    private var hostOf: [UUID: UUID] = [:]                    // forward id -> host id
    private(set) var pendingPasswordHost: UUID?
    private var passwords: [UUID: String] = [:]

    /// Retry the waiting forward with one more typed password (a jump host may ask next).
    func supplyPassword(_ password: String, store: AppStore, trust: HostKeyTrust) async {
        guard let f = needsPassword, let id = pendingPasswordHost else { return }
        needsPassword = nil
        var all = passwords
        all[id] = password
        await start(f, store: store, trust: trust, passwords: all)
    }

    /// After editing a running forward: stop it and start it with the new settings.
    func restartIfRunning(_ f: PortForward, store: AppStore, trust: HostKeyTrust) async {
        guard running[f.id] != nil else { return }
        await stop(f.id)
        await start(f, store: store, trust: trust)
    }

    /// A forward waiting for a password (host has none saved); the view asks.
    @Published var needsPassword: PortForward?

    func start(_ f: PortForward, store: AppStore, trust: HostKeyTrust, passwords: [UUID: String] = [:]) async {
        guard let host = store.host(f.hostID) else { return }
        errors[f.id] = nil
        do {
            let conn: SSHConnection
            if let c = connections[host.id], c.isConnected {
                conn = c
            } else {
                conn = try await SSHConnection.connect(chain: try store.chain(for: host, passwords: passwords), trust: trust)
                connections[host.id] = conn
            }
            let h: PortForwardHandle
            switch f.kind {
            case .local:
                h = try await conn.forwardLocal(bindHost: f.bindAddress, bindPort: f.bindPort, targetHost: f.targetHost, targetPort: f.targetPort)
            case .remote:
                h = try await conn.forwardRemote(remoteHost: f.bindAddress, remotePort: f.bindPort, localHost: f.targetHost, localPort: f.targetPort)
            case .dynamic:
                h = try await conn.forwardDynamic(bindHost: f.bindAddress, bindPort: f.bindPort)
            }
            handles[f.id] = h
            hostOf[f.id] = host.id
            running[f.id] = h.boundPort
        } catch ChainError.noCredential(let id, _) {
            pendingPasswordHost = id
            needsPassword = f
            self.passwords = passwords
        } catch {
            errors[f.id] = SSHErrorText.describe(error, target: host.destination)
        }
    }

    /// After returning from the background: forwards whose connection iOS
    /// closed are shown as stopped instead of pretending to run.
    func markDropped() {
        for id in running.keys where handles[id]?.isAlive != true {
            if let h = handles.removeValue(forKey: id) { Task { await h.stop() } }
            hostOf[id] = nil
            running[id] = nil
            errors[id] = "Stopped while Tube was in the background."
        }
        for (hostID, c) in connections where !c.isConnected {
            connections[hostID] = nil
        }
    }

    func stop(_ id: UUID) async {
        await handles.removeValue(forKey: id)?.stop()
        hostOf[id] = nil
        running[id] = nil
    }

    /// Stops every forward on the host and closes its connection, e.g. when the host is deleted.
    func stop(hostID: UUID) async {
        for id in hostOf.filter({ $0.value == hostID }).map(\.key) { await stop(id) }
        await connections.removeValue(forKey: hostID)?.close()
    }

    func stopAll() async {
        for id in handles.keys { await stop(id) }
        for c in connections.values { await c.close() }
        connections.removeAll()
    }
}

struct TunnelsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var trust: HostKeyTrust
    @EnvironmentObject var tunnels: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PortForward?
    @State private var password = ""

    var body: some View {
        List {
            ForEach(store.data.forwards) { f in
                HStack {
                    Button { editing = f } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.label.isEmpty ? summary(f) : f.label)
                                Text(summary(f)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let e = tunnels.errors[f.id] { Text(e).font(.caption).foregroundStyle(.red) }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the tunnel settings.")
                    Toggle("", isOn: Binding(
                        get: { tunnels.running[f.id] != nil },
                        set: { on in Task { if on { await tunnels.start(f, store: store, trust: trust) } else { await tunnels.stop(f.id) } } }))
                    .labelsHidden()
                    .accessibilityLabel("Run \(summary(f))")
                }
            }
            .onDelete { idx in
                let ids = idx.map { store.data.forwards[$0].id }
                Task { for id in ids { await tunnels.stop(id) } }
                store.data.forwards.remove(atOffsets: idx)
            }
            Section {
                EmptyView()
            } footer: {
                Text("Tunnels stay open while Tube is on screen. iOS pauses apps soon after you switch away, which closes them.")
            }
        }
        .navigationTitle("Tunnels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let h = store.data.hosts.first {
                        editing = PortForward(hostID: h.id, kind: .local, bindPort: 8080, targetHost: "127.0.0.1", targetPort: 80)
                    }
                } label: { Image(systemName: "plus") }
                .disabled(store.data.hosts.isEmpty)
                .accessibilityLabel("Add Tunnel")
            }
        }
        .sheet(item: $editing) { f in NavigationStack { TunnelEditView(forward: f) } }
        .alert("Password Needed", isPresented: Binding(get: { tunnels.needsPassword != nil },
                                                      set: { if !$0 { tunnels.needsPassword = nil } })) {
            SecureField("Password", text: $password)
            Button("Connect") {
                let pw = password
                password = ""
                Task { await tunnels.supplyPassword(pw, store: store, trust: trust) }
            }
            Button("Cancel", role: .cancel) { password = "" }
        } message: {
            Text("No password is saved for \(tunnels.pendingPasswordHost.flatMap { store.host($0)?.destination } ?? "this host"). It’s used for this tunnel only and isn’t saved.")
        }
    }

    private func summary(_ f: PortForward) -> String {
        let host = store.host(f.hostID)?.displayName ?? "?"
        switch f.kind {
        case .local: return "-L \(f.bindAddress):\(f.bindPort) → \(f.targetHost):\(f.targetPort) via \(host)"
        case .remote: return "-R \(f.bindAddress):\(f.bindPort) on \(host) → \(f.targetHost):\(f.targetPort)"
        case .dynamic: return "-D \(f.bindAddress):\(f.bindPort) SOCKS via \(host)"
        }
    }
}

struct TunnelEditView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var trust: HostKeyTrust
    @EnvironmentObject var tunnels: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State var forward: PortForward

    var body: some View {
        Form {
            TextField("Label", text: $forward.label)
            Picker("Host", selection: $forward.hostID) {
                ForEach(store.data.hosts) { Text($0.displayName).tag($0.id) }
            }
            Picker("Type", selection: $forward.kind) {
                Text("Local (-L)").tag(PortForward.Kind.local)
                Text("Remote (-R)").tag(PortForward.Kind.remote)
                Text("Dynamic SOCKS (-D)").tag(PortForward.Kind.dynamic)
            }
            Section(forward.kind == .remote ? "Listen on Server" : "Listen on This Device") {
                TextField("Address", text: $forward.bindAddress)
                TextField("Port", value: $forward.bindPort, format: .number.grouping(.never)).keyboardType(.numberPad)
            }
            if forward.kind != .dynamic {
                Section(forward.kind == .remote ? "Connect from This Device to" : "Connect from Server to") {
                    TextField("Host", text: $forward.targetHost)
                    TextField("Port", value: $forward.targetPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Tunnel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    forward.updatedAt = Date()
                    if let i = store.data.forwards.firstIndex(where: { $0.id == forward.id }) {
                        store.data.forwards[i] = forward
                        let f = forward
                        Task { await tunnels.restartIfRunning(f, store: store, trust: trust) }
                    } else {
                        store.data.forwards.append(forward)
                    }
                    dismiss()
                }
                .disabled(!(1...65535).contains(forward.bindPort))
            }
        }
    }
}
