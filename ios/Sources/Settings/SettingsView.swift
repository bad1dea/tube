import SwiftUI
import UniformTypeIdentifiers
import TubeCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var keeper: BackgroundKeeper
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Theme", selection: $store.data.settings.terminal.themeName) {
                    ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) }
                }
                Picker("Font", selection: $store.data.settings.terminal.fontName) {
                    ForEach(TerminalFonts.names, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Font Size \(Int(store.data.settings.terminal.fontSize))",
                        value: $store.data.settings.terminal.fontSize, in: 8...32)
                Toggle("Backspace Sends ^H", isOn: $store.data.settings.terminal.backspaceSendsControlH)
            }
            Section("Keyboard") {
                Toggle("Start with the Key Panel", isOn: $store.data.settings.showKeyPanelByDefault)
                Toggle("Key Clicks", isOn: $store.data.settings.keyClicks)
            }
            Section {
                Toggle("Keep Sessions Alive in Background", isOn: Binding(
                    get: { store.data.settings.keepAliveInBackground },
                    set: { on in
                        store.data.settings.keepAliveInBackground = on
                        if on && !keeper.locationAllowed { keeper.requestPermission() }
                    }))
                Toggle("Reconnect Automatically", isOn: $store.data.settings.reconnectOnReturn)
            } header: {
                Text("Background")
            } footer: {
                Text(store.data.settings.keepAliveInBackground && keeper.authorization == .denied
                     ? "Location access is off for Tube, so sessions stop about 30 seconds after you leave the app. You can turn it on in the Settings app."
                     : "iOS pauses apps about 30 seconds after you leave them. With this on, Tube keeps a low-accuracy location request running while sessions are open, which keeps them connected. You’ll see the location icon while it runs. Your location isn’t stored or sent anywhere.")
            }
            Section {
                Toggle("Require Face ID or Passcode", isOn: $store.data.settings.lockWithBiometrics)
            } header: {
                Text("Privacy")
            } footer: {
                Text((store.data.settings.lockWithBiometrics ? "Tube asks for Face ID or your passcode when you come back to it. " : "")
                     + "Passwords and keys are kept in this device’s Keychain. With sync on, saved passwords, and keys you choose to sync, go to your other devices encrypted.")
            }
            Section {
                NavigationLink("About Tube") { AboutView() }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onChange(of: store.data.settings) { sessions.applySettings() }
    }
}

struct KnownHostsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var trust: HostKeyTrust
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(store.data.knownHosts.keys, id: \.self) { k in
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.endpoint).font(.body.monospaced())
                    Text("\(k.algorithm)  \(k.fingerprint)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .swipeActions {
                    Button("Forget", role: .destructive) {
                        let parts = k.endpoint.split(separator: ":")
                        if let port = parts.last.flatMap({ Int($0) }) {
                            store.data.knownHosts.remove(host: parts.dropLast().joined(separator: ":"), port: port)
                            trust.reload()
                        }
                    }
                }
            }
            if store.data.knownHosts.keys.isEmpty {
                Text("Servers you trust show up here.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Known Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: store.data.knownHosts.exportOpenSSH()) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export Known Hosts")
            }
        }
    }
}

struct SSHConfigView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var picking = false
    @State private var result: String?

    private var parsed: [SSHConfigEntry] { SSHConfig.parse(text) }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .frame(minHeight: 180)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Paste") { text = UIPasteboard.general.string ?? "" }
                    Spacer()
                    Button("Choose File") { picking = true }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Import SSH Config")
            } footer: {
                Text("Brings in Host, HostName, User, Port and ProxyJump. Keys named by IdentityFile need to be imported in SSH Keys.")
            }
            if !parsed.isEmpty {
                Section(parsed.count == 1 ? "1 Host" : "\(parsed.count) Hosts") {
                    ForEach(parsed, id: \.alias) { e in
                        VStack(alignment: .leading) {
                            Text(e.alias)
                            Text("\(e.user ?? "?")@\(e.hostname):\(e.port ?? 22)" + (e.proxyJump.isEmpty ? "" : "  via \(e.proxyJump.joined(separator: ","))"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Button(parsed.count == 1 ? "Import 1 Host" : "Import \(parsed.count) Hosts") {
                        let hosts = SSHConfig.importHosts(parsed, defaultUser: "root")
                        for h in hosts { store.upsert(h, password: nil) }
                        result = hosts.count == 1 ? "Imported 1 host" : "Imported \(hosts.count) hosts"
                        text = ""
                    }
                }
            }
            if let result { Text(result) }
            Section("Export") {
                ShareLink(item: SSHConfig.export(store.data.hosts)) {
                    Label("Export Hosts as SSH Config", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("SSH Config")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .text]) { r in
            guard case .success(let url) = r else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
