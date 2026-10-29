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
                Text("Make a new key, or import one you already use.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SSH Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { generating = true } label: { Label("Generate New Key", systemImage: "wand.and.stars") }
                    Button { importing = true } label: { Label("Import a Key", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add Key")
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
                Text("Makes a new key on this device. The private part stays in the Keychain and only syncs if you turn that on for this key.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("New Key")
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
                    Button("Choose File") { picking = true }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Private Key")
            } footer: {
                Text("Paste a key that starts with “BEGIN OPENSSH PRIVATE KEY”. Older keys can be converted on a computer with `ssh-keygen -p -f <key>`.")
            }
            Section {
                SecureField("Passphrase (Optional)", text: $passphrase)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .navigationTitle("Import Key")
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
            Section("Public Key") {
                Text(identity.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Public Key") {
                    UIPasteboard.general.string = identity.publicKey
                    copied = true
                }
                ShareLink(item: identity.publicKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
            }
            Section {
                LabeledContent("Type", value: identity.algorithm.rawValue)
                Toggle("Sync Private Key", isOn: Binding(
                    get: { store.data.identities.first { $0.id == identity.id }?.syncPrivateKey ?? false },
                    set: { v in
                        if let i = store.data.identities.firstIndex(where: { $0.id == identity.id }) {
                            store.data.identities[i].syncPrivateKey = v
                        }
                    }))
            } footer: {
                Text("Sends this key to your other devices, encrypted. Leave it off to keep the key on this device only.")
            }
            Section {
                Button("Export Private Key") { exporting = true }
            } footer: {
                Text("Hosts using this key: \(store.data.hosts.filter { $0.identityID == identity.id }.map(\.displayName).joined(separator: ", "))")
            }
        }
        .navigationTitle(identity.label)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Export this private key? Anyone who has it can log in as you.", isPresented: $exporting, titleVisibility: .visible) {
            if let key = Keychain.string(for: .privateKey(identity.id)) {
                ShareLink("Share Private Key", item: key)
                Button("Copy to Clipboard") {
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: key]],
                                                  options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true])
                }
            }
        }
    }
}
