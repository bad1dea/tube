import SwiftUI
import CoreImage.CIFilterBuiltins
import ConchCore
import ConchSync

struct SyncView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sync: SyncController
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode?

    enum Mode: String, Identifiable {
        case create, join, recover
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            if let c = sync.credentials {
                Section {
                    LabeledContent("Server", value: c.serverURL.absoluteString)
                    LabeledContent("Vault") {
                        Text(c.vaultID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Key epoch", value: "\(c.epoch)")
                    if let last = store.data.sync.lastSync {
                        LabeledContent("Last sync") { Text(last, style: .relative) }
                    }
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync now")
                            if sync.syncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(sync.syncing)
                }
                Section("Add a device") {
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
                    Text("Revoking a device also rotates the vault key, so it cannot read anything written afterwards.")
                }
                Section {
                    Button("Stop syncing on this device", role: .destructive) { sync.leave() }
                } footer: {
                    Text("Local hosts and keys stay on this device.")
                }
            } else {
                Section {
                    Text("Local only. Hosts, keys and snippets stay on this device.")
                    Button("Create a vault on my server") { mode = .create }
                    Button("Join with a pairing code") { mode = .join }
                    Button("Recover with recovery key") { mode = .recover }
                } footer: {
                    Text("Sync needs a Conch sync server you run yourself (docker compose up -d). Everything is encrypted on this device before upload; the server cannot read it.")
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
                    Text("Valid for 10 minutes, one device").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button(working ? "Creating…" : "Show pairing code") {
                working = true
                Task {
                    do { code = try await sync.invite() } catch { self.error = "\(error)" }
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

    var body: some View {
        Form {
            if let (rk, vault) = created {
                Section {
                    Text(rk.displayString).font(.title3.monospaced()).textSelection(.enabled)
                    LabeledContent("Vault") { Text(vault).font(.caption.monospaced()).textSelection(.enabled) }
                    Button("Copy both") { UIPasteboard.general.string = "Conch vault \(vault)\nRecovery key \(rk.displayString)" }
                    Toggle("I saved the recovery key somewhere safe", isOn: $savedKey)
                } header: {
                    Text("Recovery key")
                } footer: {
                    Text("Shown once. With it and the vault id you can restore on a new device if all your devices are lost. Without it, losing every device loses the vault.")
                }
            } else {
                switch mode {
                case .create:
                    Section {
                        TextField("Server URL", text: $server).keyboardType(.URL)
                        SecureField("Registration token (if the server requires one)", text: $registration)
                    }
                case .join:
                    Section {
                        TextField("conch://pair?...", text: $code, axis: .vertical).font(.caption.monospaced())
                        Button("Paste") { code = UIPasteboard.general.string ?? "" }
                    } footer: {
                        Text("On a device that already syncs, open Sync and tap Show pairing code.")
                    }
                case .recover:
                    Section {
                        TextField("Server URL", text: $server).keyboardType(.URL)
                        TextField("Vault id", text: $vaultID).font(.body.monospaced())
                        TextField("Recovery key", text: $recoveryKey).font(.body.monospaced())
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout) } }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(mode == .create ? "New vault" : mode == .join ? "Join" : "Recover")
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
                        error = "Use an https:// URL"
                        return
                    }
                    let rk = try await sync.create(server: url, registrationToken: registration)
                    created = (rk, sync.credentials?.vaultID ?? "")
                case .join:
                    try await sync.join(code: code)
                    dismiss()
                case .recover:
                    guard let url = URL(string: server) else { error = "Invalid server URL"; return }
                    try await sync.recover(server: url, vaultID: vaultID.trimmingCharacters(in: .whitespaces), recoveryKey: recoveryKey)
                    dismiss()
                }
            } catch {
                self.error = "\(error)"
            }
        }
    }
}
