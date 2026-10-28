import Foundation
import Citadel
import NIOCore
import NIOPosix
import NIOSSH

/// Joins two channels so bytes read on one are written to the other, with
/// backpressure: a side stops reading while its partner is not writable.
/// Same approach as swift-nio's GlueHandler example (Apache-2.0).
final class RelayHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: RelayHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// Reads that arrived before the partner was in its pipeline. The far side
    /// often speaks first (SSH banner) while the other channel is still opening.
    private var early: [NIOAny] = []
    private var closedEarly = false

    static func pair() -> (RelayHandler, RelayHandler) {
        let a = RelayHandler(), b = RelayHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        partner?.deliverEarly(to: context)
        // The partner held back reads while this side was missing.
        context.eventLoop.execute { [weak self] in self?.partner?.partnerBecameWritable() }
    }

    private func deliverEarly(to ctx: ChannelHandlerContext) {
        // Both channels share one event loop in all current uses; hop if not.
        ctx.eventLoop.execute { [self] in
            for d in early { ctx.write(d, promise: nil) }
            if !early.isEmpty { ctx.flush() }
            early.removeAll()
            if closedEarly { ctx.close(promise: nil) }
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if let p = partner?.context {
            p.write(data, promise: nil)
        } else {
            early.append(data)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let p = partner?.context {
            p.close(promise: nil)
        } else {
            closedEarly = true
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e {
            partner?.context?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let p = partner?.context, p.channel.isWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// Forwarded-tcpip channels carry SSHChannelData; the relay works on ByteBuffer.
final class SSHDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .channel = d.type, case .byteBuffer(let b) = d.data else { return }
        context.fireChannelRead(wrapInboundOut(b))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

public enum ForwardError: Error, CustomStringConvertible {
    case socks(String)
    public var description: String {
        switch self {
        case .socks(let m): return "SOCKS: \(m)"
        }
    }
}

/// A listening forward. `stop()` closes the listener; open connections end
/// when either side closes them.
public final class PortForwardHandle: @unchecked Sendable {
    public let boundPort: Int
    let listener: Channel?
    let task: Task<Void, Error>?
    weak var connection: SSHConnection?

    init(boundPort: Int, listener: Channel?, task: Task<Void, Error>? = nil, connection: SSHConnection? = nil) {
        self.boundPort = boundPort
        self.listener = listener
        self.task = task
        self.connection = connection
    }

    public func stop() async {
        try? await listener?.close()
        task?.cancel()
    }

    public var isAlive: Bool {
        if let listener { return listener.isActive && connection?.isConnected != false }
        return task.map { !$0.isCancelled } ?? false && connection?.isConnected != false
    }
}

extension SSHConnection {
    private func openDirect(to host: String, port: Int, from origin: SocketAddress?, glue: RelayHandler) -> EventLoopFuture<Channel> {
        let client = self.client
        let originator = (try? origin ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)) ?? origin!
        let promise = client.eventLoop.makePromise(of: Channel.self)
        promise.completeWithTask {
            try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: originator)
            ) { channel in
                channel.pipeline.addHandler(glue)
            }
        }
        return promise.futureResult
    }

    /// `ssh -L bindHost:bindPort:targetHost:targetPort`. Pass bindPort 0 to pick a free port.
    public func forwardLocal(bindHost: String = "127.0.0.1", bindPort: Int, targetHost: String, targetPort: Int) async throws -> PortForwardHandle {
        let listener = try await ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { [self] child in
                let (local, remote) = RelayHandler.pair()
                return child.pipeline.addHandler(local).flatMap {
                    self.openDirect(to: targetHost, port: targetPort, from: child.remoteAddress, glue: remote)
                }.map { _ in
                    child.read()
                }.flatMapErrorThrowing { error in
                    child.close(promise: nil)
                    throw error
                }
            }
            .bind(host: bindHost, port: bindPort).get()
        return PortForwardHandle(boundPort: listener.localAddress?.port ?? bindPort, listener: listener, connection: self)
    }

    /// `ssh -D bindHost:bindPort`: SOCKS5 (no auth, CONNECT only).
    public func forwardDynamic(bindHost: String = "127.0.0.1", bindPort: Int) async throws -> PortForwardHandle {
        let listener = try await ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] child in
                child.pipeline.addHandler(SOCKS5Handler(connection: self))
            }
            .bind(host: bindHost, port: bindPort).get()
        return PortForwardHandle(boundPort: listener.localAddress?.port ?? bindPort, listener: listener, connection: self)
    }

    /// `ssh -R remoteHost:remotePort:localHost:localPort`. The server must allow
    /// it (AllowTcpForwarding, and GatewayPorts for non-loopback binds).
    public func forwardRemote(remoteHost: String = "127.0.0.1", remotePort: Int, localHost: String, localPort: Int) async throws -> PortForwardHandle {
        let client = self.client
        let opened = AsyncThrowingStream<Int, Error>.makeStream()
        let task = Task {
            do {
                try await client.withRemotePortForward(
                    host: remoteHost, port: remotePort,
                    onOpen: { forward in
                        opened.continuation.yield(forward.boundPort)
                        // Keep the forward open until the task is cancelled.
                        while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    },
                    handleChannel: { channel, _ in
                        let (sshSide, localSide) = RelayHandler.pair()
                        return channel.pipeline.addHandlers([SSHDataCodec(), sshSide]).flatMap {
                            ClientBootstrap(group: channel.eventLoop)
                                .channelInitializer { $0.pipeline.addHandler(localSide) }
                                .connect(host: localHost, port: localPort)
                                .map { _ in }
                        }.flatMapError { error in
                            channel.close(promise: nil)
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    })
            } catch {
                opened.continuation.finish(throwing: error)
                throw error
            }
        }
        for try await port in opened.stream {
            return PortForwardHandle(boundPort: port, listener: nil, task: task, connection: self)
        }
        throw SSHClientError.channelCreationFailed
    }
}

/// Minimal SOCKS5 server side: method negotiation (no auth), CONNECT to
/// IPv4/IPv6/domain. Replaces itself with a relay once the tunnel is open.
final class SOCKS5Handler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let connection: SSHConnection
    private var buffer = ByteBuffer()
    private var greeted = false
    private var connecting = false

    init(connection: SSHConnection) { self.connection = connection }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        do { try process(context: context) } catch {
            context.close(promise: nil)
        }
    }

    private func reply(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: bytes)), promise: nil)
    }

    private func process(context: ChannelHandlerContext) throws {
        if !greeted {
            guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: min(buffer.readableBytes, 2)), bytes.count == 2 else { return }
            guard bytes[0] == 5 else { throw ForwardError.socks("not SOCKS5") }
            let n = Int(bytes[1])
            guard let methods = buffer.readBytes(length: 2 + n)?.dropFirst(2) else { return }
            guard methods.contains(0) else {
                reply(context, [5, 0xff])
                throw ForwardError.socks("client requires authentication")
            }
            greeted = true
            reply(context, [5, 0])
        }
        guard !connecting else { return }
        let start = buffer.readerIndex
        guard let head = buffer.getBytes(at: start, length: min(buffer.readableBytes, 5)), head.count >= 5 else { return }
        guard head[0] == 5, head[1] == 1 else {
            reply(context, [5, 7, 0, 1, 0, 0, 0, 0, 0, 0])
            throw ForwardError.socks("only CONNECT is supported")
        }
        let host: String
        let addrLen: Int
        switch head[3] {
        case 1: addrLen = 4
        case 4: addrLen = 16
        case 3: addrLen = 1 + Int(head[4])
        default: throw ForwardError.socks("bad address type")
        }
        guard buffer.readableBytes >= 4 + addrLen + 2 else { return }
        buffer.moveReaderIndex(forwardBy: 4)
        let addr = buffer.readBytes(length: addrLen)!
        let port = Int(buffer.readInteger(as: UInt16.self)!)
        switch head[3] {
        case 1: host = addr.map(String.init).joined(separator: ".")
        case 4: host = stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(addr[$0]) << 8 | Int(addr[$0 + 1])) }.joined(separator: ":")
        default: host = String(decoding: addr.dropFirst(), as: UTF8.self)
        }
        connecting = true

        let (local, remote) = RelayHandler.pair()
        let leftover = buffer.readSlice(length: buffer.readableBytes)
        let channel = context.channel
        let client = connection.client
        let origin = channel.remoteAddress ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        promise.completeWithTask {
            try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
            ) { $0.pipeline.addHandler(remote) }
        }
        promise.futureResult.hop(to: channel.eventLoop).whenComplete { [self] result in
            switch result {
            case .success(let sshChannel):
                reply(context, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
                // Adding `local` releases anything the target already sent,
                // after the reply above.
                _ = channel.pipeline.addHandler(local).flatMap { channel.pipeline.removeHandler(self) }.map {
                    if let leftover, leftover.readableBytes > 0 {
                        sshChannel.writeAndFlush(leftover, promise: nil)
                    }
                }
            case .failure:
                reply(context, [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
                context.close(promise: nil)
            }
        }
    }
}
