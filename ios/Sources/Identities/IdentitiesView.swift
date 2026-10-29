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
    @Environment(\.dismiss) private var dismiss
    let identity: Identity
    @State private var label = ""
    @State private var copied = false
    @State private var exporting = false
    @State private var deleting = false

    private var users: [Host] { store.data.hosts.filter { $0.identityID == identity.id } }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { if !label.isEmpty { store.rename(identity: identity.id, to: label) } }
                LabeledContent("Type", value: identity.algorithm.rawValue)
            }
            Section("Public Key") {
                Text(identity.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("publicKey")
                Button(copied ? "Copied" : "Copy Public Key") {
                    UIPasteboard.general.string = identity.publicKey
                    copied = true
                }
                ShareLink(item: identity.publicKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
            }
            Section {
                NavigationLink("Install on a Server") { InstallKeyView(identity: identity) }
            } footer: {
                Text(users.isEmpty
                     ? "Adds this key to a server’s authorized_keys, so you can log in without a password."
                     : "Used by \(users.map(\.displayName).joined(separator: ", ")).")
            }
            Section {
                Toggle("Sync Private Key", isOn: Binding(
                    get: { store.data.identities.first { $0.id == identity.id }?.syncPrivateKey ?? false },
                    set: { v in
                        if let i = store.data.identities.firstIndex(where: { $0.id == identity.id }) {
                            store.data.identities[i].syncPrivateKey = v
                            store.data.identities[i].updatedAt = Date()
                        }
                    }))
            } footer: {
                Text("Sends this key to your other devices, encrypted. Leave it off to keep the key on this device only.")
            }
            Section {
                Button("Export Private Key") { exporting = true }
                Button("Delete Key", role: .destructive) { deleting = true }
            }
        }
        .navigationTitle(label.isEmpty ? identity.label : label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { label = identity.label }
        .onDisappear { if !label.isEmpty && label != identity.label { store.rename(identity: identity.id, to: label) } }
        .confirmationDialog("Export this private key? Anyone who has it can log in as you.", isPresented: $exporting, titleVisibility: .visible) {
            if let key = Keychain.string(for: .privateKey(identity.id)) {
                ShareLink("Share Private Key", item: key)
                Button("Copy to Clipboard") {
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: key]],
                                                  options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true])
                }
            }
        }
        .confirmationDialog(users.isEmpty
                            ? "Delete this key from this device?"
                            : "Delete this key? \(users.map(\.displayName).joined(separator: ", ")) will ask for a password instead.",
                            isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Key", role: .destructive) {
                store.delete(identity: identity.id)
                dismiss()
            }
        } message: {
            Text("Servers that have the public key keep it. Remove it from their authorized_keys if you no longer need it.")
        }
    }
}

struct InstallKeyView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var trust: HostKeyTrust
    @Environment(\.dismiss) private var dismiss
    let identity: Identity
    @State private var hostID: UUID?
    @State private var password = ""
    @State private var useForHost = true
    @State private var working = false
    @State private var error: String?

    private var host: Host? { store.host(hostID) }
    private var needsPassword: Bool {
        guard let host else { return false }
        return host.identityID == nil && !host.hasPassword
    }

    var body: some View {
        Form {
            Section {
                ForEach(store.data.hosts) { h in
                    Button {
                        hostID = h.id
                        error = nil
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.displayName).foregroundStyle(.primary)
                                Text(h.destination).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if h.id == hostID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .accessibilityIdentifier("install-\(h.displayName)")
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Tube logs in the way it does now and adds the key to ~/.ssh/authorized_keys.")
            }
            if needsPassword {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Used once to install the key. It isn’t saved.")
                }
            }
            Section {
                Toggle("Log In with This Key", isOn: $useForHost)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .navigationTitle("Install Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    ProgressView()
                } else {
                    Button("Install") { install() }
                        .disabled(host == nil || (needsPassword && password.isEmpty))
                }
            }
        }
    }

    private func install() {
        guard let host else { return }
        working = true
        error = nil
        Task {
            do {
                try await store.install(identity: identity, on: host, password: password, useForHost: useForHost, trust: trust)
                working = false
                dismiss()
            } catch {
                working = false
                self.error = "Couldn’t install the key on \(host.displayName): \(error)"
            }
        }
    }
}
