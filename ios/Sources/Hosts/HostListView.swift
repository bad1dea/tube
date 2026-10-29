import SwiftUI
import TubeCore

struct HostListView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var sync: SyncController
    @State private var search = ""
    @State private var quick = ""
    @State private var editing: Host?
    @State private var connectAfterSave = false
    @State private var sheet: Sheet?
    @State private var filesHost: Host?

    enum Sheet: String, Identifiable {
        case identities, snippets, knownHosts, settings, importConfig, sync, tunnels
        var id: String { rawValue }
    }

    private var filtered: [Host] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let hosts = store.data.hosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !q.isEmpty else { return hosts }
        return hosts.filter {
            $0.displayName.lowercased().contains(q) || $0.hostname.lowercased().contains(q)
                || $0.username.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private var recent: [Host] {
        store.data.hosts.filter { $0.lastConnected != nil }
            .sorted { $0.lastConnected! > $1.lastConnected! }
            .prefix(3).map { $0 }
    }

    var body: some View {
        List {
            Section {
                QuickConnectField(text: $quick, connect: quickConnect)
            }

            if !sessions.sessions.isEmpty && search.isEmpty {
                Section("Open") {
                    ForEach(sessions.sessions) { s in
                        Button {
                            sessions.select(s.id)
                            sessions.terminalPresented = true
                        } label: {
                            SessionRow(session: s, host: store.host(s.hostID))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            if search.isEmpty && recent.count > 1 {
                Section("Recent") {
                    ForEach(recent) { row($0) }
                }
            }

            let favorites = filtered.filter(\.favorite)
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { row($0) }
                }
            }
            ForEach(groupedSections, id: \.title) { section in
                Section {
                    ForEach(section.hosts) { row($0) }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text("\(section.hosts.count)").monospacedDigit()
                    }
                }
            }
            if store.data.hosts.isEmpty {
                Section {
                    Button { newHost() } label: { Label("Add host", systemImage: "plus") }
                    Button { sheet = .importConfig } label: { Label("Import ~/.ssh/config", systemImage: "square.and.arrow.down") }
                    Button { sheet = .sync } label: { Label("Restore from sync", systemImage: "arrow.triangle.2.circlepath") }
                } header: {
                    Text("Hosts")
                } footer: {
                    Text("Or type user@host above and press Connect.")
                }
            }

            if search.isEmpty {
                Section("Library") {
                    libraryRow("Keys", "key.fill", .orange, count: store.data.identities.count) { sheet = .identities }
                    libraryRow("Snippets", "curlybraces", .purple, count: store.data.snippets.count) { sheet = .snippets }
                    libraryRow("Tunnels", "point.3.connected.trianglepath.dotted", .teal, count: store.data.forwards.count) { sheet = .tunnels }
                    libraryRow("Known hosts", "checkmark.shield.fill", .green, count: store.data.knownHosts.keys.count) { sheet = .knownHosts }
                    libraryRow("Sync", "arrow.triangle.2.circlepath", .blue, detail: sync.enabled ? "On" : "Off") { sheet = .sync }
                    libraryRow("Settings", "gearshape.fill", .gray) { sheet = .settings }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search hosts, users, tags")
        .navigationTitle("Tube")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newHost() } label: { Label("New host", systemImage: "server.rack") }
                    Button { sheet = .importConfig } label: { Label("Import / export ssh_config", systemImage: "doc.text") }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    newHost()
                }
                .accessibilityLabel("Add host")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $filesHost) { host in
            FilesView(host: host, existing: nil)
        }
        .sheet(item: $editing) { host in
            NavigationStack {
                HostEditView(host: host, saveTitle: connectAfterSave ? "Connect" : "Save") { saved in
                    if connectAfterSave { sessions.open(saved) }
                    connectAfterSave = false
                }
            }
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .identities: IdentitiesView()
                case .snippets: SnippetsView()
                case .knownHosts: KnownHostsView()
                case .settings: SettingsView()
                case .importConfig: SSHConfigView()
                case .sync: SyncView()
                case .tunnels: TunnelsView()
                }
            }
        }
    }

    private func newHost() {
        connectAfterSave = false
        editing = Host(hostname: "", username: "")
    }

    /// Saved host with the same address: connect. Otherwise open the editor
    /// prefilled, so a password or key can be added, and connect on save.
    private func quickConnect() {
        guard let p = QuickConnect.parse(quick) else { return }
        let port = p.port ?? 22
        if let h = store.data.hosts.first(where: {
            $0.hostname.caseInsensitiveCompare(p.host) == .orderedSame && $0.port == port && (p.user == nil || $0.username == p.user)
        }), (h.hasPassword || h.identityID != nil) {
            sessions.open(h)
        } else {
            connectAfterSave = true
            editing = Host(hostname: p.host, port: port, username: p.user ?? "")
        }
        quick = ""
    }

    private struct GroupSection {
        let title: String
        let hosts: [Host]
    }

    private var groupedSections: [GroupSection] {
        let byGroup = Dictionary(grouping: filtered, by: \.groupID)
        var out: [GroupSection] = store.data.groups
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { g in byGroup[g.id].map { GroupSection(title: g.name, hosts: $0) } }
        let known = Set(store.data.groups.map(\.id))
        let ungrouped = filtered.filter { $0.groupID == nil || !known.contains($0.groupID!) }
        if !ungrouped.isEmpty { out.append(GroupSection(title: out.isEmpty ? "Hosts" : "Other", hosts: ungrouped)) }
        return out
    }

    private func libraryRow(_ title: String, _ symbol: String, _ color: Color, count: Int? = nil, detail: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ host: Host) -> some View {
        Button { sessions.open(host) } label: {
            HostRow(host: host, jumpNames: host.jumpHostIDs.compactMap { store.host($0)?.displayName },
                    open: sessions.isOpen(host.id), failure: sessions.failures[host.id])
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.delete(host: host.id) } label: { Label("Delete", systemImage: "trash") }
            Button { connectAfterSave = false; editing = host } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
        }
        .swipeActions(edge: .leading) {
            Button {
                var h = host
                h.favorite.toggle()
                store.upsert(h, password: nil)
            } label: {
                Label(host.favorite ? "Unfavorite" : "Favorite", systemImage: host.favorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button { sessions.open(host) } label: { Label("Connect", systemImage: "terminal") }
            Button { filesHost = host } label: { Label("Files", systemImage: "folder") }
            Button { connectAfterSave = false; editing = host } label: { Label("Edit", systemImage: "pencil") }
            Button {
                var copy = host
                copy.id = UUID()
                copy.label = host.displayName + " copy"
                copy.lastConnected = nil
                store.upsert(copy, password: nil)
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { UIPasteboard.general.string = "ssh -p \(host.port) \(host.username)@\(host.hostname)" } label: {
                Label("Copy ssh command", systemImage: "doc.on.doc")
            }
            if let f = sessions.failures[host.id] {
                Button { UIPasteboard.general.string = f } label: { Label("Copy last error", systemImage: "exclamationmark.circle") }
            }
            Button(role: .destructive) { store.delete(host: host.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct QuickConnectField: View {
    @Binding var text: String
    let connect: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            TextField("ssh user@host -p 22", text: $text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(connect)
                .accessibilityIdentifier("quickConnect")
            Button("Connect", action: connect)
                .font(.subheadline.weight(.semibold))
                .disabled(QuickConnect.parse(text) == nil)
        }
    }
}

struct HostRow: View {
    let host: Host
    let jumpNames: [String]
    var open = false
    var failure: String? = nil

    private var subtitle: String {
        var parts = [host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)"]
        if host.port != 22 { parts[0] += ":\(host.port)" }
        if !jumpNames.isEmpty { parts.append("via " + jumpNames.joined(separator: " → ")) }
        return parts.joined(separator: "  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            OSTile(osID: host.osID)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(host.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if host.favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if !host.tags.isEmpty {
                    Text(host.tags.map { "#" + $0 }.joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if failure != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    .accessibilityLabel("Last connection failed")
            } else if open {
                Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("Connected")
            } else if let last = host.lastConnected {
                Text(last, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects")
    }
}

struct SessionRow: View {
    @ObservedObject var session: TerminalSession
    let host: Host?

    var body: some View {
        HStack(spacing: 12) {
            OSTile(osID: host?.osID)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(session.state == .connected ? .green : session.state == .connecting ? .yellow : .red)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.body.weight(.medium)).lineLimit(1)
                Text(host?.destination ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}

/// Compact list for opening another session from the terminal.
struct HostPicker: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    let pick: (Host) -> Void

    var body: some View {
        NavigationStack {
            List(store.data.hosts.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.hostname.localizedCaseInsensitiveContains(search) }) { h in
                Button { pick(h); dismiss() } label: {
                    HostRow(host: h, jumpNames: h.jumpHostIDs.compactMap { store.host($0)?.displayName })
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $search)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
