import SwiftUI
import QuickLook
import ConchCore
import ConchSSH

@MainActor
final class FilesModel: ObservableObject {
    @Published var path = ""
    @Published var entries: [RemoteFile] = []
    @Published var loading = false
    @Published var error: String?
    @Published var transfer: (name: String, done: UInt64, total: UInt64?)?
    @Published var preview: URL?

    private var browser: FileBrowser?
    private var ownConnection: SSHConnection?
    let host: Host

    init(host: Host) { self.host = host }

    func start(existing: SSHConnection?, store: AppStore, trust: HostKeyTrust) async {
        loading = true
        defer { loading = false }
        do {
            let conn: SSHConnection
            if let existing, existing.isConnected {
                conn = existing
            } else {
                conn = try await SSHConnection.connect(chain: try store.chain(for: host), trust: trust)
                ownConnection = conn
            }
            let b = try await conn.openFileBrowser()
            browser = b
            path = try await b.home()
            try await reload()
        } catch {
            self.error = "\(error)"
        }
    }

    func stop() async {
        await browser?.close()
        await ownConnection?.close()
    }

    func reload() async throws {
        guard let browser else { return }
        entries = try await browser.list(path)
    }

    func open(_ dir: String) async {
        let old = path
        path = dir
        do { try await reload() } catch {
            path = old
            self.error = "\(error)"
        }
    }

    var parent: String? {
        guard path != "/" else { return nil }
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    func download(_ f: RemoteFile) async {
        guard let browser else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sftp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(f.name)
        transfer = (f.name, 0, f.size)
        do {
            try await browser.download(f.path, to: local) { done, total in
                Task { @MainActor in self.transfer = (f.name, done, total) }
            }
            transfer = nil
            preview = local
        } catch {
            transfer = nil
            self.error = "Download failed: \(error)"
        }
    }

    func upload(_ url: URL) async {
        guard let browser else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = (path as NSString).appendingPathComponent(url.lastPathComponent)
        transfer = (url.lastPathComponent, 0, nil)
        do {
            try await browser.upload(url, to: dest) { done, total in
                Task { @MainActor in self.transfer = (url.lastPathComponent, done, total) }
            }
            transfer = nil
            try await reload()
        } catch {
            transfer = nil
            self.error = "Upload failed: \(error)"
        }
    }

    func mkdir(_ name: String) async {
        guard let browser, !name.isEmpty else { return }
        do {
            try await browser.makeDirectory((path as NSString).appendingPathComponent(name))
            try await reload()
        } catch { self.error = "\(error)" }
    }

    func rename(_ f: RemoteFile, to name: String) async {
        guard let browser, !name.isEmpty else { return }
        do {
            try await browser.rename(f.path, to: (path as NSString).appendingPathComponent(name))
            try await reload()
        } catch { self.error = "\(error)" }
    }

    func delete(_ f: RemoteFile) async {
        guard let browser else { return }
        do {
            try await browser.remove(f)
            try await reload()
        } catch { self.error = "\(error)" }
    }
}

struct FilesView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var trust: HostKeyTrust
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: FilesModel
    let existing: SSHConnection?
    @State private var importing = false
    @State private var newFolder = ""
    @State private var askFolder = false
    @State private var renaming: RemoteFile?
    @State private var renameText = ""

    init(host: Host, existing: SSHConnection?) {
        _model = StateObject(wrappedValue: FilesModel(host: host))
        self.existing = existing
    }

    var body: some View {
        NavigationStack {
            List {
                if let parent = model.parent {
                    Button { Task { await model.open(parent) } } label: {
                        Label("..", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(model.entries) { f in
                    Button {
                        Task {
                            if f.isDirectory { await model.open(f.path) } else { await model.download(f) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: f.isDirectory ? "folder" : f.isSymlink ? "link" : "doc")
                                .foregroundStyle(f.isDirectory ? Color.accentColor : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(f.modeString)
                                    if !f.isDirectory, let s = f.size {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
                                    }
                                    if let m = f.modified { Text(m, format: .dateTime.year().month().day().hour().minute()) }
                                }
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await model.delete(f) } }
                        Button("Rename") { renaming = f; renameText = f.name }.tint(.gray)
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = f.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
                        if !f.isDirectory {
                            Button { Task { await model.download(f) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { try? await model.reload() }
            .overlay {
                if model.loading { ProgressView() }
            }
            .safeAreaInset(edge: .bottom) {
                if let t = model.transfer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.name).font(.caption).lineLimit(1)
                        if let total = t.total, total > 0 {
                            ProgressView(value: Double(t.done), total: Double(total))
                        } else {
                            ProgressView()
                        }
                    }
                    .padding(10)
                    .background(.regularMaterial)
                }
            }
            .navigationTitle(model.path.isEmpty ? model.host.displayName : model.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { askFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("New folder")
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Upload")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                Task { for u in urls { await model.upload(u) } }
            }
            .alert("New folder", isPresented: $askFolder) {
                TextField("Name", text: $newFolder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Create") { Task { await model.mkdir(newFolder); newFolder = "" } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Rename") { if let f = renaming { Task { await model.rename(f, to: renameText) } } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.error ?? "")
            }
            .quickLookPreview($model.preview)
        }
        .task { await model.start(existing: existing, store: store, trust: trust) }
        .onDisappear { Task { await model.stop() } }
    }
}
