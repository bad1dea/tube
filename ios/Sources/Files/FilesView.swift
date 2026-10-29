import SwiftUI
import QuickLook
import TubeCore
import TubeSSH

@MainActor
final class FilesModel: ObservableObject {
    @Published var path = ""
    @Published var entries: [RemoteFile] = []
    @Published var loading = false
    @Published var error: String?
    @Published var transfer: (name: String, done: UInt64, total: UInt64?)?
    @Published var preview: URL?
    @Published var connectError: String?
    /// Set when the chain has a host with nothing saved to log in with.
    @Published var needsPassword: (id: UUID, name: String)?
    @Published var replacing: (urls: [URL], existing: [String])?

    @Published private(set) var browser: FileBrowser?
    private var ownConnection: SSHConnection?
    private var passwords: [UUID: String] = [:]   // used for this connection only, never saved
    let host: Host

    init(host: Host) { self.host = host }

    func start(existing: SSHConnection?, store: AppStore, trust: HostKeyTrust, password: String? = nil) async {
        loading = true
        connectError = nil
        defer { loading = false }
        do {
            let conn: SSHConnection
            if let existing, existing.isConnected {
                conn = existing
            } else {
                await ownConnection?.close()
                ownConnection = nil
                if let id = needsPassword?.id, let password { passwords[id] = password }
                conn = try await SSHConnection.connect(chain: try store.chain(for: host, passwords: passwords), trust: trust)
                ownConnection = conn
            }
            let b = try await conn.openFileBrowser()
            browser = b
            path = try await b.home()
            try await reload()
        } catch ChainError.noCredential(let id, let name) {
            needsPassword = (id, name)
        } catch {
            await browser?.close()
            browser = nil
            connectError = SSHErrorText.describe(error, target: host.destination)
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
            self.error = SSHErrorText.describe(error, target: host.destination)
        }
    }

    func select(_ f: RemoteFile) async {
        if f.isDirectory {
            await open(f.path)
        } else if f.isSymlink, let browser, await browser.isDirectory(f.path) {
            await open(f.path)
        } else {
            await download(f)
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
            self.error = "Download failed: " + SSHErrorText.describe(error, target: host.destination)
        }
    }

    /// Asks before overwriting: uploads straight away only if nothing is in the way.
    func upload(_ urls: [URL]) async {
        guard let browser else { return }
        var existing: [String] = []
        for u in urls {
            let dest = (path as NSString).appendingPathComponent(u.lastPathComponent)
            if (try? await browser.exists(dest)) ?? true { existing.append(u.lastPathComponent) }
        }
        if existing.isEmpty {
            for u in urls { await upload(u) }
        } else {
            replacing = (urls, existing)
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
            self.error = "Upload failed: " + SSHErrorText.describe(error, target: host.destination)
        }
    }

    func mkdir(_ name: String) async {
        guard let browser, !name.isEmpty else { return }
        do {
            try await browser.makeDirectory((path as NSString).appendingPathComponent(name))
            try await reload()
        } catch { self.error = SSHErrorText.describe(error, target: host.destination) }
    }

    func rename(_ f: RemoteFile, to name: String) async {
        guard let browser, !name.isEmpty else { return }
        do {
            try await browser.rename(f.path, to: (path as NSString).appendingPathComponent(name))
            try await reload()
        } catch { self.error = SSHErrorText.describe(error, target: host.destination) }
    }

    func delete(_ f: RemoteFile) async {
        guard let browser else { return }
        do {
            try await browser.remove(f)
            try await reload()
        } catch { self.error = SSHErrorText.describe(error, target: host.destination) }
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
    @State private var deleting: RemoteFile?
    @State private var password = ""

    init(host: Host, existing: SSHConnection?) {
        _model = StateObject(wrappedValue: FilesModel(host: host))
        self.existing = existing
    }

    var body: some View {
        NavigationStack {
            prompts(dialogs(browser))
        }
        .task { await model.start(existing: existing, store: store, trust: trust) }
        .onDisappear { Task { await model.stop() } }
    }

    // Split out of body: as one expression it is too much for the type checker.
    private var browser: some View {
            List {
                if let parent = model.parent {
                    Button { Task { await model.open(parent) } } label: {
                        Label("..", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(model.entries) { f in
                    Button { Task { await model.select(f) } } label: {
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
                        // Not role: .destructive, which removes the row before the dialog answers.
                        Button("Delete") { deleting = f }.tint(.red)
                        Button("Rename") { renaming = f; renameText = f.name }.tint(.gray)
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = f.path } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                        if !f.isDirectory {
                            Button { Task { await model.download(f) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { try? await model.reload() }
            .overlay {
                if model.loading {
                    ProgressView()
                } else if model.browser == nil {
                    connectForm
                }
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
    }

    private func dialogs(_ content: some View) -> some View {
        content
            .navigationTitle(model.path.isEmpty ? model.host.displayName : model.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { askFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("New Folder")
                        .disabled(model.browser == nil)
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Upload")
                        .disabled(model.browser == nil)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                Task { await model.upload(urls) }
            }
    }

    private func prompts(_ content: some View) -> some View {
        content
            .confirmationDialog(replaceQuestion, isPresented: Binding(get: { model.replacing != nil }, set: { if !$0 { model.replacing = nil } }),
                                titleVisibility: .visible, presenting: model.replacing) { r in
                Button("Replace", role: .destructive) { Task { for u in r.urls { await model.upload(u) } } }
                if r.urls.count > r.existing.count {
                    Button("Skip Existing") { Task { for u in r.urls where !r.existing.contains(u.lastPathComponent) { await model.upload(u) } } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { f in
                Button(f.isDirectory ? "Delete Folder" : "Delete File", role: .destructive) { Task { await model.delete(f) } }
            } message: { _ in
                Text("This deletes it from \(model.host.displayName). It can’t be undone.")
            }
            .alert("New Folder", isPresented: $askFolder) {
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

    private var replaceQuestion: String {
        guard let names = model.replacing?.existing else { return "" }
        return names.count == 1 ? "Replace \(names[0])?" : "Replace \(names.count) existing files?"
    }

    @ViewBuilder private var connectForm: some View {
        if let need = model.needsPassword {
            VStack(spacing: 12) {
                Text("No password or key saved for \(need.name). Enter the password to connect. It isn’t saved.")
                    .multilineTextAlignment(.center)
                if let e = model.connectError {
                    Text(e).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connectWithPassword)
                Button("Connect", action: connectWithPassword)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
            .padding()
            .frame(maxWidth: 400)
        } else if let e = model.connectError {
            ContentUnavailableView {
                Label("Couldn’t Connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text(e)
            } actions: {
                Button("Retry") { Task { await model.start(existing: existing, store: store, trust: trust) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func connectWithPassword() {
        guard !password.isEmpty else { return }
        let pw = password
        password = ""
        Task { await model.start(existing: existing, store: store, trust: trust, password: pw) }
    }
}
