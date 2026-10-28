import SwiftUI
import UniformTypeIdentifiers
import TubeCore

struct IdentitiesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var generating = false
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(store.data.identities) { ident in
                NavigationLink {
                    IdentityDetailView(identity: ident)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ident.label)
                        Text(ident.algorithm.rawValue + (ident.hasPassphrase ? " · passphrase" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in idx.map { store.data.identities[$0].id }.forEach(store.delete(identity:)) }
            if store.data.identities.isEmpty {
                Text("Generate an Ed25519 key or import an existing OpenSSH private key.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Identities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { generating = true } label: { Label("Generate Ed25519", systemImage: "wand.and.stars") }
                    Button { importing = true } label: { Label("Import private key", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add identity")
            }
        }
        .sheet(isPresented: $generating) { NavigationStack { GenerateKeyView() } }
        .sheet(isPresented: $importing) { NavigationStack { ImportKeyView() } }
    }
}

struct GenerateKeyView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = "tube@\(UIDevice.current.name)"
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Creates an Ed25519 key on this device. The private key is stored in the Keychain and is not synced unless you enable it for this identity.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Generate key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Generate") {
                    do {
                        _ = try store.generateIdentity(label: label)
                        dismiss()
                    } catch {
                        self.error = "\(error)"
                    }
                }
                .disabled(label.isEmpty)
            }
        }
    }
}

struct ImportKeyView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var keyText = ""
    @State private var passphrase = ""
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $label)
            }
            Section {
                TextEditor(text: $keyText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 160)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Paste") { keyText = UIPasteboard.general.string ?? "" }
                    Spacer()
                    Button("Choose file") { picking = true }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("OpenSSH private key")
            } footer: {
                Text("Ed25519 and RSA keys in OpenSSH format (BEGIN OPENSSH PRIVATE KEY). Convert PEM keys with `ssh-keygen -p -f key`.")
            }
            Section {
                SecureField("Passphrase (if any)", text: $passphrase)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .navigationTitle("Import key")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .text]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            keyText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if label.isEmpty { label = url.lastPathComponent }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    do {
                        _ = try store.addIdentity(label: label.isEmpty ? "imported" : label,
                                                  privateKey: keyText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                                                  passphrase: passphrase.isEmpty ? nil : passphrase)
                        dismiss()
                    } catch {
                        self.error = "Could not read key: \(error)"
                    }
                }
                .disabled(keyText.isEmpty)
            }
        }
    }
}

struct IdentityDetailView: View {
    @EnvironmentObject var store: AppStore
    let identity: Identity
    @State private var copied = false
    @State private var exporting = false

    var body: some View {
        Form {
            Section("Public key") {
                Text(identity.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy public key") {
                    UIPasteboard.general.string = identity.publicKey
                    copied = true
                }
                ShareLink(item: identity.publicKey) { Label("Share public key", systemImage: "square.and.arrow.up") }
            }
            Section {
                LabeledContent("Type", value: identity.algorithm.rawValue)
                Toggle("Sync private key", isOn: Binding(
                    get: { store.data.identities.first { $0.id == identity.id }?.syncPrivateKey ?? false },
                    set: { v in
                        if let i = store.data.identities.firstIndex(where: { $0.id == identity.id }) {
                            store.data.identities[i].syncPrivateKey = v
                        }
                    }))
            } footer: {
                Text("When on, the private key is included in end-to-end encrypted sync. The sync server only sees ciphertext.")
            }
            Section {
                Button("Export private key") { exporting = true }
            } footer: {
                Text("Hosts using this key: \(store.data.hosts.filter { $0.identityID == identity.id }.map(\.displayName).joined(separator: ", "))")
            }
        }
        .navigationTitle(identity.label)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Export the private key? Anyone with the file can log in as you.", isPresented: $exporting, titleVisibility: .visible) {
            if let key = Keychain.string(for: .privateKey(identity.id)) {
                ShareLink("Share private key", item: key)
                Button("Copy to clipboard") {
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: key]],
                                                  options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true])
                }
            }
        }
    }
}
