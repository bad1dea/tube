import XCTest
import Foundation
import ConchCore
import TermInput
@testable import ConchSSH

// Runs against test/sshd (start with test/sshd/up.sh). Skipped unless
// CONCH_SSH_TESTS=1 so `swift test` works without containers.

final class MemoryTrust: HostKeyTrustStore, @unchecked Sendable {
    var known = KnownHosts()
    var accept: Bool
    var prompted: [String] = []

    init(accept: Bool) { self.accept = accept }

    func check(host: String, port: Int, algorithm: String, keyBase64: String) -> HostKeyCheck {
        known.check(host: host, port: port, algorithm: algorithm, keyBase64: keyBase64)
    }

    func confirmUnknown(host: String, port: Int, algorithm: String, keyBase64: String, fingerprint: String) async -> Bool {
        prompted.append(fingerprint)
        if accept { known.trust(host: host, port: port, algorithm: algorithm, keyBase64: keyBase64) }
        return accept
    }
}

final class SSHIntegrationTests: XCTestCase {
    let keys = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../test/sshd/keys").standardized

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONCH_SSH_TESTS"] == "1", "set CONCH_SSH_TESTS=1 with test/sshd running")
    }

    func key(_ name: String) throws -> String {
        try String(contentsOf: keys.appendingPathComponent(name), encoding: .utf8)
    }

    var hostFingerprint: String {
        get throws {
            let line = try key("host/host_ed25519.pub").split(separator: " ")
            return KnownHosts.fingerprint(blobBase64: String(line[1]))
        }
    }

    func target(_ cred: SSHCredential) -> SSHHop {
        SSHHop(host: "127.0.0.1", port: 2022, username: "tester", credential: cred)
    }

    func testPasswordAuthAndUnknownHostPrompt() async throws {
        let trust = MemoryTrust(accept: true)
        let conn = try await SSHConnection.connect(chain: [target(.password("tester-pass"))], trust: trust)
        defer { Task { await conn.close() } }
        XCTAssertEqual(trust.prompted, [try hostFingerprint])
        let out = try await conn.run("echo hello")
        XCTAssertEqual(out, "hello\n")

        // Second connection: key is known, no prompt.
        let conn2 = try await SSHConnection.connect(chain: [target(.password("tester-pass"))], trust: trust)
        XCTAssertEqual(trust.prompted.count, 1)
        await conn2.close()
    }

    func testWrongPasswordFails() async throws {
        let trust = MemoryTrust(accept: true)
        do {
            let c = try await SSHConnection.connect(chain: [target(.password("nope"))], trust: trust)
            await c.close()
            XCTFail("connected with wrong password")
        } catch {}
    }

    func testRejectedHostKeyDoesNotConnect() async throws {
        let trust = MemoryTrust(accept: false)
        do {
            _ = try await SSHConnection.connect(chain: [target(.password("tester-pass"))], trust: trust)
            XCTFail("connected despite rejected host key")
        } catch let e as SSHConnectError {
            XCTAssertEqual(e, .hostKeyRejected(host: "127.0.0.1", port: 2022))
        }
    }

    func testChangedHostKeyIsRefused() async throws {
        let trust = MemoryTrust(accept: true)
        // Pretend we previously stored a different key for this endpoint.
        trust.known.trust(host: "127.0.0.1", port: 2022, algorithm: "ssh-ed25519",
                          keyBase64: Data(repeating: 7, count: 51).base64EncodedString())
        do {
            _ = try await SSHConnection.connect(chain: [target(.password("tester-pass"))], trust: trust)
            XCTFail("connected despite changed host key")
        } catch let e as SSHConnectError {
            guard case .hostKeyChanged(_, _, _, let presented) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(presented, try hostFingerprint)
        }
        XCTAssertTrue(trust.prompted.isEmpty, "changed key must not reach the unknown-key prompt")
    }

    func testEd25519Key() async throws {
        let trust = MemoryTrust(accept: true)
        let conn = try await SSHConnection.connect(chain: [target(.privateKey(try key("client_ed25519"), passphrase: nil))], trust: trust)
        let who = try await conn.run("whoami")
        XCTAssertEqual(who, "tester\n")
        await conn.close()
    }

    func testEncryptedEd25519Key() async throws {
        let trust = MemoryTrust(accept: true)
        let conn = try await SSHConnection.connect(chain: [target(.privateKey(try key("client_ed25519_pw"), passphrase: "hunter2"))], trust: trust)
        let who = try await conn.run("whoami")
        XCTAssertEqual(who, "tester\n")
        await conn.close()

        do {
            _ = try await SSHConnection.connect(chain: [target(.privateKey(try key("client_ed25519_pw"), passphrase: "wrong"))], trust: trust)
            XCTFail("wrong passphrase accepted")
        } catch {}
    }

    /// Citadel 0.12 signs RSA auth with SHA-1 ("ssh-rsa"), which OpenSSH 8.8+
    /// refuses by default. Keep this test so a fix (rsa-sha2-256) shows up.
    func testRSAKeyAgainstModernOpenSSH() async throws {
        let trust = MemoryTrust(accept: true)
        do {
            let conn = try await SSHConnection.connect(chain: [target(.privateKey(try key("client_rsa"), passphrase: nil))], trust: trust)
            await conn.close()
            print("RSA: accepted")
        } catch {
            print("RSA: refused (\(error))")
        }
    }

    func testImportedPublicKeyMatchesSSHKeygen() throws {
        let (alg, line) = try SSHKeys.publicKeyLine(privateKey: try key("client_ed25519"), passphrase: nil)
        XCTAssertEqual(alg, .ed25519)
        let expected = try key("client_ed25519.pub").split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(line, expected)
    }

    func testGeneratedKeyAuthenticates() async throws {
        let gen = SSHKeys.generateEd25519(comment: "gen-test")
        XCTAssertTrue(gen.privateKeyOpenSSH.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        let trust = MemoryTrust(accept: true)
        let setup = try await SSHConnection.connect(chain: [target(.password("tester-pass"))], trust: trust)
        _ = try await setup.run("echo '\(gen.publicKeyLine)' >> ~/.ssh/authorized_keys")
        await setup.close()
        let conn = try await SSHConnection.connect(chain: [target(.privateKey(gen.privateKeyOpenSSH, passphrase: nil))], trust: trust)
        let ok = try await conn.run("echo ok")
        XCTAssertEqual(ok, "ok\n")
        _ = try await conn.run("grep -v gen-test ~/.ssh/authorized_keys > /tmp/ak; cat /tmp/ak > ~/.ssh/authorized_keys")
        await conn.close()
    }

    func testJumpHostToInternalOnlyServer() async throws {
        let trust = MemoryTrust(accept: true)
        let k = try key("client_ed25519")
        let chain = [
            SSHHop(host: "127.0.0.1", port: 2222, username: "tester", credential: .privateKey(k, passphrase: nil)),
            SSHHop(host: "inner", port: 22, username: "tester", credential: .password("tester-pass")),
        ]
        let conn = try await SSHConnection.connect(chain: chain, trust: trust)
        let name = try await conn.run("cat /etc/hostname")
        XCTAssertFalse(name.isEmpty)
        // Both hops were verified, each under its own endpoint name.
        XCTAssertEqual(trust.prompted.count, 2)
        XCTAssertEqual(trust.known.keys.map(\.endpoint).sorted(), ["127.0.0.1:2222", "inner:22"])
        await conn.close()
    }

    // MARK: PTY / keyboard bytes

    func openShell(cols: Int = 80, rows: Int = 24) async throws -> (SSHConnection, ShellSession, OutputCollector) {
        let trust = MemoryTrust(accept: true)
        let conn = try await SSHConnection.connect(chain: [target(.privateKey(try key("client_ed25519"), passphrase: nil))], trust: trust)
        let shell = ShellSession()
        try await shell.start(on: conn, cols: cols, rows: rows)
        let collector = OutputCollector(shell.output)
        try await shell.send(Array("export PS1='$ '; stty -echoctl\r".utf8))
        try await collector.waitFor("$ ")
        return (conn, shell, collector)
    }

    func testPTYTermAndResize() async throws {
        let (conn, shell, out) = try await openShell(cols: 100, rows: 30)
        try await shell.send(Array("echo T=$TERM; stty size\r".utf8))
        try await out.waitFor("T=xterm-256color")
        try await out.waitFor("30 100")
        try await shell.resize(cols: 132, rows: 40)
        try await shell.send(Array("stty size\r".utf8))
        try await out.waitFor("40 132")
        shell.close()
        await conn.close()
    }

    /// The remote side reads raw bytes and prints them as hex, so this checks
    /// exactly what the key bar transmits.
    func testKeyBytesArriveVerbatim() async throws {
        let (conn, shell, out) = try await openShell()
        let reader = #"python3 -c 'import os,sys,tty,time; tty.setraw(0); time.sleep(0.4); print("HEX=" + os.read(0, 64).hex(), end="\r\n")'"#

        var bar = ModifierBar()
        var cases: [(String, [UInt8])] = []
        bar.ctrl.tap(at: 0); cases.append(("ctrl-c", bar.send(text: "c", modes: .init())))
        bar.ctrl.tap(at: 0); cases.append(("ctrl-d", bar.send(text: "d", modes: .init())))
        bar.ctrl.tap(at: 0); cases.append(("ctrl-z", bar.send(text: "z", modes: .init())))
        bar.alt.tap(at: 0); cases.append(("alt-b", bar.send(text: "b", modes: .init())))
        cases.append(("up-app", bar.send(.up, modes: TerminalModes(applicationCursor: true))))
        cases.append(("f5", bar.send(.function(5), modes: .init())))
        cases.append(("ctrl-right", KeyEncoder.encode(.right, modifiers: .ctrl)))
        cases.append(("shift-tab", KeyEncoder.encode(.tab, modifiers: .shift)))

        for (name, bytes) in cases {
            out.reset()
            try await shell.send(Array((reader + "\r").utf8))
            try await Task.sleep(nanoseconds: 200_000_000)
            try await shell.send(bytes)
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            try await out.waitFor("HEX=" + hex, label: name)
            try await out.waitFor("$ ")
        }
        shell.close()
        await conn.close()
    }

    func testCtrlCInterruptsForegroundJob() async throws {
        let (conn, shell, out) = try await openShell()
        try await shell.send(Array("sleep 30; echo FINISHED\r".utf8))
        try await Task.sleep(nanoseconds: 500_000_000)
        out.reset()
        var bar = ModifierBar()
        bar.ctrl.tap(at: 0)
        try await shell.send(bar.send(text: "c", modes: .init()))
        try await out.waitFor("$ ", timeout: 3)
        try await shell.send(Array("echo rc=$?\r".utf8))
        try await out.waitFor("rc=130")
        XCTAssertFalse(out.text.contains("FINISHED"))
        shell.close()
        await conn.close()
    }

    func testVimSwitchesToApplicationCursorMode() async throws {
        let (conn, shell, out) = try await openShell()
        out.reset()
        try await shell.send(Array("vim -u NONE -N -c 'set t_ks=\\e[?1h\\e=' /tmp/x\r".utf8))
        // vim enables DECCKM (ESC [ ? 1 h) on start; the app tracks it through
        // SwiftTerm, here we only check the remote really asks for it.
        try await out.waitFor("\u{1b}[?1h")
        try await shell.send(Array("ihello".utf8))
        try await shell.send(KeyEncoder.encode(.escape))
        try await shell.send(Array(":wq\r".utf8))
        try await out.waitFor("$ ")
        try await shell.send(Array("cat /tmp/x\r".utf8))
        try await out.waitFor("hello")
        shell.close()
        await conn.close()
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<[UInt8]>) {
        task = Task { [weak self] in
            for await chunk in stream {
                self?.lock.withLock { self?.buffer += chunk }
            }
        }
    }

    var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }

    func reset() { lock.withLock { buffer.removeAll() } }

    func waitFor(_ needle: String, timeout: TimeInterval = 8, label: String = "") async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.contains(needle) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(needle.debugDescription) \(label); got \(text.suffix(300).debugDescription)")
        throw CancellationError()
    }
}
