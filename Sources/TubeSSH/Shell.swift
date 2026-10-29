import Foundation
import Citadel
import NIOCore
import NIOSSH

/// Interactive PTY shell. Output arrives on `output`; input is written with
/// `send`. The channel stays open until the remote shell exits or `close` is
/// called.
public final class ShellSession: @unchecked Sendable {
    public let output: AsyncStream<[UInt8]>
    private let outputContinuation: AsyncStream<[UInt8]>.Continuation
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    public private(set) var exitError: Error?
    /// Set when the remote shell ended on its own (`exit`, logout), whatever its status.
    public private(set) var exited = false

    public init() {
        (output, outputContinuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts the shell and returns once the PTY is open.
    public func start(on connection: SSHConnection, term: String = "xterm-256color", cols: Int, rows: Int) async throws {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term,
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )
        let client = connection.client
        let cont = outputContinuation
        let started = AsyncThrowingStream<Void, Error>.makeStream()
        task = Task { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    self?.lock.withLock { self?.writer = outbound }
                    started.continuation.yield(())
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let b), .stderr(let b):
                            cont.yield(Array(b.readableBytesView))
                        }
                    }
                    self?.exited = true
                }
            } catch {
                // Citadel ends the stream with CommandFailed when the shell exits
                // non-zero (e.g. `exit` after a ^C), and closing a channel the
                // server already closed throws too. Both are a normal logout.
                // withPTY's cleanup close() replaces the CommandFailed with alreadyClosed.
                if error is SSHClient.CommandFailed || (error as? ChannelError) == .alreadyClosed {
                    self?.exited = true
                } else if self?.exited != true {
                    self?.exitError = error
                }
                started.continuation.finish(throwing: error)
            }
            started.continuation.finish()
            cont.finish()
        }
        for try await _ in started.stream { return }
        if let e = exitError { throw e }
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let w = lock.withLock({ writer }) else { return }
        try await w.write(ByteBuffer(bytes: bytes))
    }

    public func resize(cols: Int, rows: Int) async throws {
        guard let w = lock.withLock({ writer }) else { return }
        try await w.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    public func close() {
        task?.cancel()
        outputContinuation.finish()
    }
}

extension SSHConnection {
    /// Runs a command without a PTY and returns stdout. Throws on non-zero exit.
    public func run(_ command: String) async throws -> String {
        let buf = try await client.executeCommand(command)
        return String(buffer: buf)
    }

    /// Appends `publicKeyLine` to ~/.ssh/authorized_keys unless it is already there.
    /// Only POSIX sh, so it also works when the login shell is fish or similar
    /// (the command goes through `sh -c`).
    public func installPublicKey(_ publicKeyLine: String) async throws {
        let line = publicKeyLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = "'" + line.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "(grep -qxF \(quoted) ~/.ssh/authorized_keys || echo \(quoted) >> ~/.ssh/authorized_keys)"
        let shQuoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        _ = try await run("sh -c " + shQuoted)
    }
}
