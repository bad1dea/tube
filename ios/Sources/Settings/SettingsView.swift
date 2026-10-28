import SwiftUI
import UniformTypeIdentifiers
import TubeCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
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
                Stepper("Font size \(Int(store.data.settings.terminal.fontSize))",
                        value: $store.data.settings.terminal.fontSize, in: 8...32)
                Toggle("Backspace sends ^H", isOn: $store.data.settings.terminal.backspaceSendsControlH)
            }
            Section("Keyboard") {
                Toggle("Open with key panel", isOn: $store.data.settings.showKeyPanelByDefault)
                Toggle("Key clicks", isOn: $store.data.settings.keyClicks)
            }
            Section {
                Toggle("Require Face ID / passcode", isOn: $store.data.settings.lockWithBiometrics)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Locks the app when it goes to the background. Private keys and passwords are in the device Keychain and never leave the device unless you turn on key sync for an identity.")
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
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
                Text("Host keys are recorded the first time you trust a server.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Known hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: store.data.knownHosts.exportOpenSSH()) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export known_hosts")
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
                    Button("Choose file") { picking = true }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Import ssh_config")
            } footer: {
                Text("Reads Host, HostName, User, Port and ProxyJump. IdentityFile paths are listed but keys must be imported under Identities.")
            }
            if !parsed.isEmpty {
                Section("\(parsed.count) hosts") {
                    ForEach(parsed, id: \.alias) { e in
                        VStack(alignment: .leading) {
                            Text(e.alias)
                            Text("\(e.user ?? "?")@\(e.hostname):\(e.port ?? 22)" + (e.proxyJump.isEmpty ? "" : "  via \(e.proxyJump.joined(separator: ","))"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Button("Import \(parsed.count) hosts") {
                        let hosts = SSHConfig.importHosts(parsed, defaultUser: "root")
                        for h in hosts { store.upsert(h, password: nil) }
                        result = "Imported \(hosts.count) hosts"
                        text = ""
                    }
                }
            }
            if let result { Text(result) }
            Section("Export") {
                ShareLink(item: SSHConfig.export(store.data.hosts)) {
                    Label("Export hosts as ssh_config", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("ssh_config")
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
