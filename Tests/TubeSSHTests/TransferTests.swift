import XCTest
import Foundation
import NIOCore
import NIOPosix
import TubeCore
@testable import TubeSSH

/// SFTP and port forwarding against test/sshd. TUBE_SSH_TESTS=1.
final class TransferTests: XCTestCase {
    let keys = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../test/sshd/keys").standardized

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TUBE_SSH_TESTS"] == "1")
    }

    func connect() async throws -> SSHConnection {
        let key = try String(contentsOf: keys.appendingPathComponent("client_ed25519"), encoding: .utf8)
        return try await SSHConnection.connect(
            chain: [SSHHop(host: "127.0.0.1", port: 2022, username: "tester", credential: .privateKey(key, passphrase: nil))],
            trust: MemoryTrust(accept: true))
    }

    func testSFTPRoundTrip() async throws {
        let conn = try await connect()
        let fb = try await conn.openFileBrowser()
        let home = try await fb.home()
        XCTAssertEqual(home, "/home/tester")

        let dir = home + "/sftp-test-\(UUID().uuidString.prefix(8))"
        try await fb.makeDirectory(dir)

        // 300 KB of non-repeating bytes crosses many 32 KB chunks.
        var payload = Data(count: 300_000)
        for i in 0..<payload.count { payload[i] = UInt8((i * 7 + i / 251) & 0xff) }
        let tmp = FileManager.default.temporaryDirectory
        let up = tmp.appendingPathComponent("tube-up-\(UUID())")
        try payload.write(to: up)
        let ticks = Counter()
        try await fb.upload(up, to: dir + "/blob.bin") { done, total in
            ticks.add()
            XCTAssertEqual(total, 300_000)
            XCTAssertLessThanOrEqual(done, 300_000)
        }
        XCTAssertGreaterThan(ticks.value, 5)

        let remoteSize = try await conn.run("stat -c %s \(dir)/blob.bin")
        XCTAssertEqual(remoteSize, "300000\n")

        let list = try await fb.list(dir)
        XCTAssertEqual(list.map(\.name), ["blob.bin"])
        XCTAssertEqual(list[0].size, 300_000)
        XCTAssertFalse(list[0].isDirectory)

        let down = tmp.appendingPathComponent("tube-down-\(UUID())")
        try await fb.download(dir + "/blob.bin", to: down)
        XCTAssertEqual(try Data(contentsOf: down), payload)

        try await fb.rename(dir + "/blob.bin", to: dir + "/renamed.bin")
        let renamed = try await fb.list(dir)
        XCTAssertEqual(renamed.map(\.name), ["renamed.bin"])
        try await fb.remove(try await fb.list(dir)[0])
        let parent = try await fb.list(home)
        let entry = try XCTUnwrap(parent.first { dir.hasSuffix($0.name) })
        XCTAssertTrue(entry.isDirectory)
        try await fb.remove(entry)
        let after = try await fb.list(home)
        XCTAssertFalse(after.contains { dir.hasSuffix($0.name) })

        await fb.close()
        await conn.close()
    }

    /// -L: local port -> sshd on the target itself, read its banner.
    func testLocalForward() async throws {
        let conn = try await connect()
        let fwd = try await conn.forwardLocal(bindPort: 0, targetHost: "127.0.0.1", targetPort: 22)
        XCTAssertGreaterThan(fwd.boundPort, 0)
        let banner = try await readBanner(port: fwd.boundPort)
        XCTAssertTrue(banner.hasPrefix("SSH-2.0-OpenSSH"), banner)
        // Two connections at once share the forward.
        async let a = readBanner(port: fwd.boundPort)
        async let b = readBanner(port: fwd.boundPort)
        let (ra, rb) = try await (a, b)
        XCTAssertTrue(ra.hasPrefix("SSH-2.0") && rb.hasPrefix("SSH-2.0"))
        await fwd.stop()
        await conn.close()
    }

    /// -D: SOCKS5 CONNECT by domain name, resolved on the server side.
    func testDynamicForward() async throws {
        let conn = try await connect()
        let fwd = try await conn.forwardDynamic(bindPort: 0)
        let host = Array("localhost".utf8)
        let request: [UInt8] = [5, 1, 0] + [5, 1, 0, 3, UInt8(host.count)] + host + [0, 22]
        let reply = try await exchange(port: fwd.boundPort, send: request, until: { $0.count >= 2 + 10 + 7 })
        XCTAssertEqual(Array(reply.prefix(2)), [5, 0])
        XCTAssertEqual(reply[3], 0, "CONNECT should succeed")
        XCTAssertEqual(String(decoding: reply.dropFirst(12).prefix(7), as: UTF8.self), "SSH-2.0")
        await fwd.stop()
        await conn.close()
    }

    /// -R: remote port on the server -> a local echo server here.
    func testRemoteForward() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let echo = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(EchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let conn = try await connect()
        let fwd = try await conn.forwardRemote(remotePort: 19022, localHost: "127.0.0.1", localPort: echo.localAddress!.port!)
        XCTAssertEqual(fwd.boundPort, 19022)
        let out = try await conn.run(#"python3 -c "import socket;s=socket.create_connection(('127.0.0.1',19022));s.sendall(b'ping-through-R');print(s.recv(64).decode())""#)
        XCTAssertEqual(out, "ping-through-R\n")
        await fwd.stop()
        try await echo.close()
        await conn.close()
    }

    func readBanner(port: Int) async throws -> String {
        String(decoding: try await exchange(port: port, send: [], until: { $0.contains(0x0a) }), as: UTF8.self)
    }

    func exchange(port: Int, send: [UInt8], until done: @escaping ([UInt8]) -> Bool) async throws -> [UInt8] {
        let collected = Collector(done: done)
        let ch = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(collected) }
            .connect(host: "127.0.0.1", port: port).get()
        if !send.isEmpty { try await ch.writeAndFlush(ByteBuffer(bytes: send)) }
        // Close after 8 s so a stalled forward fails the test instead of hanging it.
        ch.eventLoop.scheduleTask(in: .seconds(8)) { ch.close(promise: nil) }
        let result = try await collected.result.futureResult.get()
        try? await ch.close()
        return result
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

final class Collector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var bytes: [UInt8] = []
    private var completed = false
    private let done: ([UInt8]) -> Bool
    // EventLoopPromise completion is thread-safe; the handler runs on the
    // channel's loop, so `completed` is only touched there.
    let result: EventLoopPromise<[UInt8]>

    init(done: @escaping ([UInt8]) -> Bool) {
        self.done = done
        result = MultiThreadedEventLoopGroup.singleton.next().makePromise()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes += unwrapInboundIn(data).readableBytesView
        if !completed && done(bytes) {
            completed = true
            result.succeed(bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            result.succeed(bytes)
        }
    }
}
