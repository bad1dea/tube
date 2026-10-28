import SwiftUI
import ConchCore

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

    init(host: Host) {
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
                TextField("Host or IP", text: $host.hostname)
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
                Picker("Identity", selection: $host.identityID) {
                    Text("None (password)").tag(UUID?.none)
                    ForEach(store.data.identities) { i in
                        Text(i.label).tag(Optional(i.id))
                    }
                }
                SecureField(host.hasPassword && !passwordChanged ? "Saved password (unchanged)" : "Password", text: $password)
                    .textContentType(.password)
                    .onChange(of: password) { passwordChanged = true }
                if host.hasPassword {
                    Button("Remove saved password", role: .destructive) {
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
                            Text("Deleted host").foregroundStyle(.red)
                        }
                    }
                }
                .onDelete { host.jumpHostIDs.remove(atOffsets: $0) }
                .onMove { host.jumpHostIDs.move(fromOffsets: $0, toOffset: $1) }
                Button { addingJump = true } label: { Label("Add jump host", systemImage: "plus") }
            } header: {
                Text("Jump hosts")
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
                    TextField("New group", text: $newGroup)
                    Button("Add") {
                        let g = HostGroup(name: newGroup.trimmingCharacters(in: .whitespaces))
                        store.data.groups.append(g)
                        host.groupID = g.id
                        newGroup = ""
                    }
                    .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Tags (space separated)", text: $tagText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Terminal") {
                Toggle("Custom settings for this host", isOn: $overrideTerminal)
                if overrideTerminal {
                    Picker("Theme", selection: terminalBinding.themeName) {
                        ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) }
                    }
                    Picker("Font", selection: terminalBinding.fontName) {
                        ForEach(TerminalFonts.names, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Size \(Int(terminalBinding.wrappedValue.fontSize))", value: terminalBinding.fontSize, in: 8...32)
                    Toggle("Backspace sends ^H", isOn: terminalBinding.backspaceSendsControlH)
                }
            }

            Section("Notes") {
                TextField("Notes", text: $host.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle(isNew ? "New host" : host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!valid)
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
                        ContentUnavailableView("No other hosts", systemImage: "server.rack",
                                               description: Text("Save the bastion as a host first, then pick it here."))
                    }
                }
                .navigationTitle("Jump host")
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
        store.upsert(host, password: passwordChanged ? password : nil)
        dismiss()
    }
}
