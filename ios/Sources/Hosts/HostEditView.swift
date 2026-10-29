import SwiftUI
import TubeCore

struct HostEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var password = ""
    @State private var passwordChanged = false
    @State private var tagText = ""
    @State private var addingJump = false
    @State private var newGroup = ""
    @State private var overrideTerminal = false
    let saveTitle: String
    let onSave: ((Host) -> Void)?

    init(host: Host, saveTitle: String = "Save", onSave: ((Host) -> Void)? = nil) {
        self.saveTitle = saveTitle
        self.onSave = onSave
        _host = State(initialValue: host)
        _tagText = State(initialValue: host.tags.joined(separator: " "))
        _overrideTerminal = State(initialValue: host.terminal != nil)
    }

    private var isNew: Bool { store.host(host.id) == nil }
    private var valid: Bool {
        !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty && !host.username.isEmpty && (1...65535).contains(host.port)
    }

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $host.label)
                TextField("Host Name or IP", text: $host.hostname)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("Username", text: $host.username)
                    .textContentType(.username)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Section("Authentication") {
                Picker("Key", selection: $host.identityID) {
                    Text("None (Use Password)").tag(UUID?.none)
                    ForEach(store.data.identities) { i in
                        Text(i.label).tag(Optional(i.id))
                    }
                }
                SecureField(host.hasPassword && !passwordChanged ? "Saved password (unchanged)" : "Password", text: $password)
                    .textContentType(.password)
                    .onChange(of: password) { passwordChanged = true }
                if host.hasPassword {
                    Button("Remove Saved Password", role: .destructive) {
                        password = ""
                        passwordChanged = true
                        host.hasPassword = false
                    }
                }
            }

            Section {
                ForEach(Array(host.jumpHostIDs.enumerated()), id: \.offset) { index, id in
                    HStack {
                        Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let j = store.host(id) {
                            VStack(alignment: .leading) {
                                Text(j.displayName)
                                Text(j.destination).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Host deleted").foregroundStyle(.red)
                        }
                    }
                }
                .onDelete { host.jumpHostIDs.remove(atOffsets: $0) }
                .onMove { host.jumpHostIDs.move(fromOffsets: $0, toOffset: $1) }
                Button { addingJump = true } label: { Label("Add Jump Host", systemImage: "plus") }
            } header: {
                Text("Jump Hosts")
            } footer: {
                Text(chainDescription).font(.caption.monospaced())
            }

            Section("Organize") {
                Toggle("Favorite", isOn: $host.favorite)
                Picker("Group", selection: $host.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.data.groups) { g in Text(g.name).tag(Optional(g.id)) }
                }
                HStack {
                    TextField("New Group", text: $newGroup)
                    Button("Add") {
                        let g = HostGroup(name: newGroup.trimmingCharacters(in: .whitespaces))
                        store.data.groups.append(g)
                        host.groupID = g.id
                        newGroup = ""
                    }
                    .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Tags, separated by spaces", text: $tagText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Terminal") {
                Toggle("Custom Settings for This Host", isOn: $overrideTerminal)
                if overrideTerminal {
                    Picker("Theme", selection: terminalBinding.themeName) {
                        ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) }
                    }
                    Picker("Font", selection: terminalBinding.fontName) {
                        ForEach(TerminalFonts.names, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Font Size \(Int(terminalBinding.wrappedValue.fontSize))", value: terminalBinding.fontSize, in: 8...32)
                    Toggle("Backspace Sends ^H", isOn: terminalBinding.backspaceSendsControlH)
                }
            }

            Section("Notes") {
                TextField("Notes", text: $host.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle(isNew ? "New Host" : host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) { save() }.disabled(!valid)
            }
        }
        .sheet(isPresented: $addingJump) {
            NavigationStack {
                List(store.data.hosts.filter { $0.id != host.id && !host.jumpHostIDs.contains($0.id) }) { h in
                    Button {
                        host.jumpHostIDs.append(h.id)
                        addingJump = false
                    } label: {
                        HostRow(host: h, jumpNames: [])
                    }
                    .foregroundStyle(.primary)
                }
                .overlay {
                    if store.data.hosts.count < 2 {
                        ContentUnavailableView("No Other Hosts", systemImage: "server.rack",
                                               description: Text("Add the jump host as a normal host first, then pick it here."))
                    }
                }
                .navigationTitle("Jump Host")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addingJump = false } } }
            }
        }
    }

    private var terminalBinding: Binding<TerminalSettings> {
        Binding(get: { host.terminal ?? store.data.settings.terminal }, set: { host.terminal = $0 })
    }

    /// Shows the equivalent OpenSSH command so the chain is easy to check.
    private var chainDescription: String {
        let jumps = host.jumpHostIDs.compactMap { store.host($0)?.destination }
        var cmd = "ssh"
        if !jumps.isEmpty { cmd += " -J " + jumps.joined(separator: ",") }
        if host.port != 22 { cmd += " -p \(host.port)" }
        cmd += " \(host.username.isEmpty ? "user" : host.username)@\(host.hostname.isEmpty ? "host" : host.hostname)"
        return cmd
    }

    private func save() {
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.tags = tagText.split(separator: " ").map(String.init)
        if !overrideTerminal { host.terminal = nil }
        // Typing in the field and clearing it again keeps the saved password;
        // only Remove Saved Password deletes it.
        let keepSaved = password.isEmpty && host.hasPassword
        store.upsert(host, password: passwordChanged && !keepSaved ? password : nil)
        let saved = store.host(host.id) ?? host
        dismiss()
        onSave?(saved)
    }
}
