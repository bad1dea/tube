import Foundation
import Citadel
import NIOCore

public struct RemoteFile: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var size: UInt64?
    public var permissions: UInt32?
    public var modified: Date?

    public var id: String { path }
    // st_mode file type bits, as in sys/stat.h.
    public var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
    public var isSymlink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }

    /// rwxr-xr-x form of the permission bits.
    public var modeString: String {
        guard let p = permissions else { return "?????????" }
        let chars = Array("rwxrwxrwx")
        return String((0..<9).map { p & (1 << (8 - $0)) != 0 ? chars[$0] : "-" })
    }
}

public enum FileBrowserError: Error, CustomStringConvertible {
    case folderNotEmpty
    public var description: String {
        switch self {
        case .folderNotEmpty: return "Folder isn’t empty."
        }
    }
}

/// SFTP session over an existing connection.
public final class FileBrowser: @unchecked Sendable {
    let sftp: SFTPClient
    public static let chunk = 32 * 1024

    init(sftp: SFTPClient) { self.sftp = sftp }

    public func home() async throws -> String {
        try await sftp.getRealPath(atPath: ".")
    }

    public func list(_ path: String) async throws -> [RemoteFile] {
        let names = try await sftp.listDirectory(atPath: path)
        let base = path.hasSuffix("/") ? path : path + "/"
        return names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { c in
                RemoteFile(name: c.filename, path: base + c.filename, size: c.attributes.size,
                           permissions: c.attributes.permissions,
                           modified: c.attributes.accessModificationTime?.modificationTime)
            }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Streams the remote file to `local`. `progress` gets bytes done and total.
    public func download(_ path: String, to local: URL, progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil) async throws {
        let file = try await sftp.openFile(filePath: path, flags: .read)
        let total = try? await file.readAttributes().size
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        var offset: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                let buf = try await file.read(from: offset, length: UInt32(Self.chunk))
                if buf.readableBytes == 0 { break }
                try out.write(contentsOf: Data(buf.readableBytesView))
                offset += UInt64(buf.readableBytes)
                progress?(offset, total)
            }
        } catch {
            try? out.close()
            try? await file.close()
            throw error
        }
        try out.close()
        try await file.close()
    }

    public func upload(_ local: URL, to path: String, progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil) async throws {
        let input = try FileHandle(forReadingFrom: local)
        let total = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        var offset: UInt64 = 0
        do {
            while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                progress?(offset, total)
            }
        } catch {
            try? input.close()
            try? await file.close()
            throw error
        }
        try input.close()
        try await file.close()
    }

    /// Writes `data` to `path`, created readable by the owner only (0600).
    public func writePrivate(_ data: Data, to path: String) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o600
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate], attributes: attributes)
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + Self.chunk, data.count)
                try await file.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                offset = end
            }
        } catch {
            try? await file.close()
            throw error
        }
        try await file.close()
    }

    /// Creates each missing directory along `path` (absolute), owner-only (0700).
    public func makeDirectories(_ path: String) async throws {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            if await isDirectory(current) { continue }
            var attributes = SFTPFileAttributes()
            attributes.permissions = 0o700
            try await sftp.createDirectory(atPath: current, attributes: attributes)
        }
    }

    /// `list` reports symlinks as themselves (lstat); this follows them.
    public func isDirectory(_ path: String) async -> Bool {
        guard let mode = try? await sftp.getAttributes(at: path).permissions else { return false }
        return mode & 0o170000 == 0o040000
    }

    public func exists(_ path: String) async throws -> Bool {
        do {
            _ = try await sftp.getAttributes(at: path)
            return true
        } catch let e as SFTPMessage.Status where e.errorCode == .noSuchFile {
            return false
        }
    }

    public func makeDirectory(_ path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    public func remove(_ file: RemoteFile) async throws {
        if file.isDirectory {
            do {
                try await sftp.rmdir(at: file.path)
            } catch let e as SFTPMessage.Status where e.errorCode == .failure {
                // OpenSSH sends a bare SSH_FX_FAILURE for ENOTEMPTY.
                if let entries = try? await list(file.path), !entries.isEmpty { throw FileBrowserError.folderNotEmpty }
                throw e
            }
        } else {
            try await sftp.remove(at: file.path)
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try await sftp.rename(at: path, to: newPath)
    }

    public func close() async {
        try? await sftp.close()
    }
}

extension SSHConnection {
    public func openFileBrowser() async throws -> FileBrowser {
        FileBrowser(sftp: try await client.openSFTP())
    }
}
