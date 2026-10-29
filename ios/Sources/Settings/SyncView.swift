import SwiftUI
import CoreImage.CIFilterBuiltins
import TubeCore
import TubeSync

struct SyncView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sync: SyncController
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode?
    @State private var confirmLeave = false

    enum Mode: String, Identifiable {
        case create, join, recover
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            if let c = sync.credentials {
                Section {
                    LabeledContent("Server", value: c.serverURL.absoluteString)
                    LabeledContent("Vault ID") {
                        Text(c.vaultID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Key Version", value: "\(c.epoch)")
                    if let last = store.data.sync.lastSync {
                        LabeledContent("Last Sync") { Text(last, style: .relative) }
                    }
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            if sync.syncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(sync.syncing)
                }
                Section("Add a Device") {
                    PairingCodeView()
                }
                Section {
                    ForEach(sync.devices, id: \.id) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name + (d.current ? " (this device)" : ""))
                                Text(d.revoked ? "Revoked" : "Last seen \(Date(timeIntervalSince1970: TimeInterval(d.last_seen)).formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if !d.current && !d.revoked {
                                Button("Revoke", role: .destructive) { Task { await sync.revoke(d.id) } }
                            }
                        }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("Removing a device also changes the vault key, so it can’t read anything new.")
                }
                Section {
                    Button("Stop Syncing on This Device", role: .destructive) { confirmLeave = true }
                        .confirmationDialog("Stop syncing on this device?", isPresented: $confirmLeave, titleVisibility: .visible) {
                            Button("Stop Syncing", role: .destructive) { sync.leave() }
                        } message: {
                            Text("Hosts and keys stay here, but changes will no longer sync. To sync again you’ll need a pairing code or the recovery key.")
                        }
                } footer: {
                    Text("Local hosts and keys stay on this device.")
                }
            } else {
                Section {
                    Text("Sync is off. Your hosts, keys and snippets are only on this device.")
                    Button("Create a Vault") { mode = .create }
                    Button("Join with a Pairing Code") { mode = .join }
                    Button("Recover with Recovery Key") { mode = .recover }
                } footer: {
                    Text("Sync uses a Tube server you run yourself. Everything is encrypted on this device before it’s sent, so the server can’t read it.")
                }
            }
            if let err = sync.lastError {
                Section { Text(err).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await sync.refreshDevices() }
        .sheet(item: $mode) { m in
            NavigationStack { SyncSetupView(mode: m) }
        }
    }
}

struct PairingCodeView: View {
    @EnvironmentObject var sync: SyncController
    @State private var code: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        if let code {
            VStack(alignment: .leading, spacing: 8) {
                if let img = qr(code) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Pairing QR code")
                }
                Text(code).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(4)
                HStack {
                    Button("Copy") { UIPasteboard.general.string = code }
                    Spacer()
                    Text("Works once, for 10 minutes").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button(working ? "Creating…" : "Show Pairing Code") {
                working = true
                Task {
                    do { code = try await sync.invite() } catch { self.error = syncErrorText(error) }
                    working = false
                }
            }
            .disabled(working)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }

    private func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct SyncSetupView: View {
    let mode: SyncView.Mode
    @EnvironmentObject var sync: SyncController
    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://"
    @State private var registration = ""
    @State private var code = ""
    @State private var vaultID = ""
    @State private var recoveryKey = ""
    @State private var working = false
    @State private var error: String?
    @State private var created: (RecoveryKey, String)?
    @State private var savedKey = false

    init(mode: SyncView.Mode, code: String = "") {
        self.mode = mode
        _code = State(initialValue: code)
    }

    var body: some View {
        Form {
            if let (rk, vault) = created {
                Section {
                    Text(rk.displayString).font(.title3.monospaced()).textSelection(.enabled)
                    LabeledContent("Vault ID") { Text(vault).font(.caption.monospaced()).textSelection(.enabled) }
                    Button("Copy Both") { UIPasteboard.general.string = "Tube vault \(vault)\nRecovery key \(rk.displayString)" }
                    Toggle("I’ve Saved My Recovery Key", isOn: $savedKey)
                } header: {
                    Text("Recovery Key")
                } footer: {
                    Text("This is shown only once. With it and the vault ID you can restore everything on a new device. If you lose both this key and all your devices, synced data can’t be recovered.")
                }
            } else {
                switch mode {
                case .create:
                    Section {
                        TextField("Server Address", text: $server).keyboardType(.URL)
                        SecureField("Registration Token (If Required)", text: $registration)
                    }
                case .join:
                    Section {
                        TextField("tube://pair?...", text: $code, axis: .vertical).font(.caption.monospaced())
                        Button("Paste") { code = UIPasteboard.general.string ?? "" }
                    } footer: {
                        Text("On a device that already syncs, open Sync and tap Show Pairing Code.")
                    }
                case .recover:
                    Section {
                        TextField("Server Address", text: $server).keyboardType(.URL)
                        TextField("Vault ID", text: $vaultID).font(.body.monospaced())
                        TextField("Recovery Key", text: $recoveryKey).font(.body.monospaced())
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout) } }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(mode == .create ? "New Vault" : mode == .join ? "Join" : "Recover")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(created != nil && !savedKey)
        .toolbar {
            if created != nil {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(!savedKey) }
            } else {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Working…" : "Continue") { run() }.disabled(working)
                }
            }
        }
    }

    private func run() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                switch mode {
                case .create:
                    guard let url = URL(string: server), url.scheme == "https" || url.host == "localhost" else {
                        error = "The server address needs to start with https://"
                        return
                    }
                    let rk = try await sync.create(server: url, registrationToken: registration)
                    created = (rk, sync.credentials?.vaultID ?? "")
                case .join:
                    try await sync.join(code: code)
                    dismiss()
                case .recover:
                    guard let url = URL(string: server) else { error = "That server address doesn’t look right."; return }
                    try await sync.recover(server: url, vaultID: vaultID.trimmingCharacters(in: .whitespaces), recoveryKey: recoveryKey)
                    dismiss()
                }
            } catch {
                self.error = syncErrorText(error)
            }
        }
    }
}

/// URLSession errors are long NSError dumps; say what failed instead.
func syncErrorText(_ error: Error) -> String {
    if let e = error as? SyncError {
        switch e.status {
        case 401, 403: return "The server turned this down: \(e.message). Check the registration token or pairing code."
        case 0: return e.message
        default: return "The sync server answered \(e.status): \(e.message)"
        }
    }
    guard let u = error as? URLError else { return error.localizedDescription }
    let host = u.failingURL?.host() ?? "the server"
    switch u.code {
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
         .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
        return "Couldn’t make a secure connection to \(host). Check the address, and that the server has a valid HTTPS certificate."
    case .cannotFindHost, .dnsLookupFailed:
        return "Couldn’t find \(host). Check the address."
    case .cannotConnectToHost, .timedOut, .networkConnectionLost:
        return "Couldn’t reach \(host). Check the address and that the server is running."
    case .notConnectedToInternet:
        return "You’re offline."
    default:
        return "Couldn’t talk to \(host): \(u.localizedDescription)"
    }
}
