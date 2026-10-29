import XCTest
import Crypto
@testable import TubeCore

final class SSHConfigTests: XCTestCase {
    let sample = """
    # comment
    Host *
        User fallback
        ServerAliveInterval 30

    Host jump
        HostName ctrl.khuo.ng
        User jump
        Port 2222

    Host lab lab2
        HostName 100.64.0.10
        Port=2022
        User khuong
        ProxyJump jump
        IdentityFile ~/.ssh/id_ed25519

    Host deep
        HostName 10.0.0.5
        ProxyJump admin@bastion.example.com:2200,jump

    Host *.internal !skip.internal
        User ops
    """

    func testParse() {
        let e = SSHConfig.parse(sample)
        XCTAssertEqual(e.map(\.alias), ["jump", "lab", "lab2", "deep"])
        let jump = e[0]
        XCTAssertEqual(jump.hostname, "ctrl.khuo.ng")
        XCTAssertEqual(jump.user, "fallback")   // first match wins: Host * appears first
        XCTAssertEqual(jump.port, 2222)
        let lab = e[1]
        XCTAssertEqual(lab.hostname, "100.64.0.10")
        XCTAssertEqual(lab.port, 2022)
        XCTAssertEqual(lab.proxyJump, ["jump"])
        XCTAssertEqual(lab.identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(e[3].proxyJump, ["admin@bastion.example.com:2200", "jump"])
    }

    func testJumpSpec() {
        let a = JumpSpec("jump@ctrl.khuo.ng:2222")!
        XCTAssertEqual(a.user, "jump"); XCTAssertEqual(a.host, "ctrl.khuo.ng"); XCTAssertEqual(a.port, 2222)
        let b = JumpSpec("[fd00::1]:22")!
        XCTAssertEqual(b.host, "fd00::1"); XCTAssertEqual(b.port, 22)
        let c = JumpSpec("fd00::1")!
        XCTAssertEqual(c.host, "fd00::1"); XCTAssertNil(c.port)
        XCTAssertNil(JumpSpec("none"))
    }

    func testImportLinksJumpHosts() {
        let hosts = SSHConfig.importHosts(SSHConfig.parse(sample), defaultUser: "me")
        let jump = hosts.first { $0.label == "jump" }!
        let lab = hosts.first { $0.label == "lab" }!
        XCTAssertEqual(lab.jumpHostIDs, [jump.id])
        let deep = hosts.first { $0.label == "deep" }!
        XCTAssertEqual(deep.jumpHostIDs.count, 2)
        let bastion = hosts.first { $0.id == deep.jumpHostIDs[0] }!
        XCTAssertEqual(bastion.destination, "admin@bastion.example.com:2200")
        XCTAssertEqual(deep.jumpHostIDs[1], jump.id)
    }

    func testExportRoundTrip() {
        let jump = Host(label: "jump", hostname: "ctrl.khuo.ng", port: 2222, username: "jump")
        let lab = Host(label: "lab", hostname: "100.64.0.10", port: 2022, username: "khuong", jumpHostIDs: [jump.id])
        let text = SSHConfig.export([jump, lab])
        XCTAssertTrue(text.contains("ProxyJump jump"))
        let back = SSHConfig.parse(text)
        XCTAssertEqual(back[1].hostname, "100.64.0.10")
        XCTAssertEqual(back[1].port, 2022)
        XCTAssertEqual(back[1].proxyJump, ["jump"])
    }
}

final class KnownHostsTests: XCTestCase {
    let keyA = Data(repeating: 1, count: 51).base64EncodedString()
    let keyB = Data(repeating: 2, count: 51).base64EncodedString()

    func testFlow() {
        var kh = KnownHosts()
        guard case .unknown = kh.check(host: "Example.com", port: 22, algorithm: "ssh-ed25519", keyBase64: keyA) else {
            return XCTFail()
        }
        kh.trust(host: "example.com", port: 22, algorithm: "ssh-ed25519", keyBase64: keyA)
        XCTAssertEqual(kh.check(host: "EXAMPLE.com", port: 22, algorithm: "ssh-ed25519", keyBase64: keyA), .trusted)
        // Same name on another port is a different endpoint.
        if case .trusted = kh.check(host: "example.com", port: 2222, algorithm: "ssh-ed25519", keyBase64: keyA) { XCTFail() }
    }

    func testChangedKeyIsNeverTrustedByTrustCall() {
        var kh = KnownHosts()
        kh.trust(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: keyA)
        guard case .changed = kh.check(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: keyB) else { return XCTFail() }
        kh.trust(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: keyB)
        guard case .changed = kh.check(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: keyB) else { return XCTFail() }
        kh.remove(host: "h", port: 22)
        kh.trust(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: keyB)
        XCTAssertEqual(kh.check(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: keyB), .trusted)
    }

    func testFingerprintMatchesOpenSSH() {
        // ssh-keygen -lf on this public key prints SHA256:ZnGzdSMAMR9ri5bKd5+0brd1cPNStp4ORPq5gWS5Xl0
        // (value computed independently with: echo <blob> | base64 -d | sha256sum | xxd -r -p | base64)
        let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        let digest = Data(SHA256.hash(data: Data(base64Encoded: blob)!)).base64EncodedString()
        XCTAssertEqual(KnownHosts.fingerprint(blobBase64: blob), "SHA256:" + digest.replacingOccurrences(of: "=", with: ""))
        XCTAssertFalse(KnownHosts.fingerprint(blobBase64: blob).hasSuffix("="))
    }
}

final class SnippetTests: XCTestCase {
    func testVariables() {
        let s = Snippet(name: "logs", command: "journalctl -u {{unit}} -n {{ lines }} | grep {{unit}}")
        XCTAssertEqual(s.variables, ["unit", "lines"])
        XCTAssertEqual(s.render(["unit": "nginx", "lines": "50"]), "journalctl -u nginx -n 50 | grep nginx")
        XCTAssertEqual(s.render(["unit": "nginx"]), "journalctl -u nginx -n {{ lines }} | grep nginx")
    }
}

final class VaultCryptoTests: XCTestCase {
    func testWrapUnwrap() throws {
        let vk = VaultKey.generate()
        let rk = RecoveryKey.generate()
        let wrapped = try VaultCrypto.wrap(vk, recovery: rk, vaultID: "v1")
        XCTAssertEqual(try VaultCrypto.unwrap(wrapped, recovery: rk, vaultID: "v1"), vk)
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, recovery: RecoveryKey.generate(), vaultID: "v1"))
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, recovery: rk, vaultID: "v2"))
    }

    func testRecoveryKeyDisplayRoundTrip() throws {
        let rk = RecoveryKey.generate()
        XCTAssertEqual(rk.displayString.count, 32 + 7)
        XCTAssertEqual(try RecoveryKey(displayString: rk.displayString.lowercased()), rk)
        XCTAssertThrowsError(try RecoveryKey(displayString: "ABCD"))
    }

    func testRecordAADBindsIdentity() throws {
        let vk = VaultKey.generate()
        let k = VaultCrypto.recordKey(vk, vaultID: "v")
        let sealed = try VaultCrypto.seal(Data("{}".utf8), key: k, aad: VaultCrypto.recordAAD(vaultID: "v", recordID: "a", kind: "host"))
        XCTAssertNoThrow(try VaultCrypto.open(sealed, key: k, aad: VaultCrypto.recordAAD(vaultID: "v", recordID: "a", kind: "host")))
        XCTAssertThrowsError(try VaultCrypto.open(sealed, key: k, aad: VaultCrypto.recordAAD(vaultID: "v", recordID: "b", kind: "host")))
        XCTAssertThrowsError(try VaultCrypto.open(sealed, key: k, aad: VaultCrypto.recordAAD(vaultID: "v", recordID: "a", kind: "identity")))
    }

    /// Fixed vector; web and server tests assert the same output.
    func testCrossPlatformVector() throws {
        let rk = RecoveryKey(bytes: Data(0..<20))
        let vk = VaultKey(bytes: Data(100..<132))
        XCTAssertEqual(rk.displayString, "AAAQ-EAYE-AUDA-OCAJ-BIFQ-YDIO-B4IB-CEQT")
        let auth = VaultCrypto.recoveryAuth(recovery: rk, vaultID: "vault-test")
        let rec = VaultCrypto.recordKey(vk, vaultID: "vault-test").withUnsafeBytes { Data($0) }
        XCTAssertEqual(auth.base64EncodedString(), "PI0075RFvxEL4uVbeFlTSsKnTd+UL6onZdftX9G8Mpo=")
        XCTAssertEqual(rec.base64EncodedString(), "w7dOgz2l/n1IJS5godqscl1jgBK8TV66jJdU+SQfus4=")
    }
}

final class QuickConnectTests: XCTestCase {
    func testForms() {
        XCTAssertEqual(QuickConnect.parse("ssh khuong@100.64.0.10 -p 2022")?.port, 2022)
        XCTAssertEqual(QuickConnect.parse("ssh khuong@100.64.0.10 -p 2022")?.user, "khuong")
        XCTAssertEqual(QuickConnect.parse("ssh -p 2222 -l jump ctrl.khuo.ng")?.user, "jump")
        XCTAssertEqual(QuickConnect.parse("root@[fd00::1]:22")?.host, "fd00::1")
        XCTAssertEqual(QuickConnect.parse("amy")?.host, "amy")
        XCTAssertNil(QuickConnect.parse("ssh"))
    }
}
