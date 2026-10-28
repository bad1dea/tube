import SwiftUI
import ConchCore

struct HostListView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @State private var search = ""
    @State private var editing: Host?
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
            .prefix(4).map { $0 }
    }

    var body: some View {
        List {
            if !sessions.sessions.isEmpty {
                Section("Open") {
                    ForEach(sessions.sessions) { s in
                        Button {
                            sessions.select(s.id)
                            sessions.terminalPresented = true
                        } label: {
                            Label(s.title, systemImage: s.statusSymbol)
                        }
                    }
                }
            }
            if search.isEmpty && !recent.isEmpty {
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
                Section(section.title) {
                    ForEach(section.hosts) { row($0) }
                }
            }
            if store.data.hosts.isEmpty {
                Section {
                    Button { editing = Host(hostname: "", username: "") } label: {
                        Label("Add host", systemImage: "plus")
                    }
                    Button { sheet = .importConfig } label: {
                        Label("Import ~/.ssh/config", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Hosts, users, tags")
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Host(hostname: "", username: "") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add host")
                    .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { sheet = .identities } label: { Label("Identities", systemImage: "key") }
                    Button { sheet = .snippets } label: { Label("Snippets", systemImage: "curlybraces") }
                    Button { sheet = .tunnels } label: { Label("Tunnels", systemImage: "point.3.connected.trianglepath.dotted") }
                    Button { sheet = .knownHosts } label: { Label("Known hosts", systemImage: "checkmark.shield") }
                    Button { sheet = .importConfig } label: { Label("Import / export ssh config", systemImage: "doc.text") }
                    Button { sheet = .sync } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    Button { sheet = .settings } label: { Label("Settings", systemImage: "gear") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(item: $filesHost) { host in
            FilesView(host: host, existing: nil)
        }
        .sheet(item: $editing) { host in
            NavigationStack { HostEditView(host: host) }
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
        if !ungrouped.isEmpty { out.append(GroupSection(title: out.isEmpty ? "All" : "Other", hosts: ungrouped)) }
        return out
    }

    private func row(_ host: Host) -> some View {
        Button { sessions.open(host) } label: {
            HostRow(host: host, jumpNames: host.jumpHostIDs.compactMap { store.host($0)?.displayName })
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.delete(host: host.id) } label: { Label("Delete", systemImage: "trash") }
            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
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
            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
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
            Button(role: .destructive) { store.delete(host: host.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct HostRow: View {
    let host: Host
    let jumpNames: [String]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(host.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if host.favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                Text(host.destination).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if !jumpNames.isEmpty || !host.tags.isEmpty {
                    HStack(spacing: 6) {
                        if !jumpNames.isEmpty {
                            Label("via " + jumpNames.joined(separator: " → "), systemImage: "arrow.triangle.branch")
                        }
                        if !host.tags.isEmpty {
                            Text(host.tags.map { "#" + $0 }.joined(separator: " "))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects")
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
