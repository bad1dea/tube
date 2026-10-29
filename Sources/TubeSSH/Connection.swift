import Foundation
import Citadel
import TubeCore
import Crypto
import NIOCore
import NIOSSH

public enum SSHCredential: Sendable {
    case password(String)
    /// OpenSSH-format private key text (`-----BEGIN OPENSSH PRIVATE KEY-----`).
    case privateKey(String, passphrase: String?)
}

/// One hop of a connection chain. The last hop is the target.
public struct SSHHop: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHCredential

    public init(host: String, port: Int = 22, username: String, credential: SSHCredential) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
    }
}

public enum SSHConnectError: Error, Equatable, CustomStringConvertible {
    case hostKeyRejected(host: String, port: Int)
    case hostKeyChanged(host: String, port: Int, expected: String, presented: String)
    case unsupportedKey(String)
    case badPassphrase
    case authenticationFailed(host: String, port: Int, user: String)

    public var description: String {
        switch self {
        case .hostKeyRejected(let h, let p): return "Host key for \(h):\(p) was not accepted"
        case .hostKeyChanged(let h, let p, let e, let pr):
            return "Host key for \(h):\(p) changed. Expected \(e), server presented \(pr)"
        case .unsupportedKey(let t): return "Unsupported private key: \(t)"
        case .badPassphrase: return "Wrong passphrase for private key"
        case .authenticationFailed(let h, let p, let u): return "\(u)@\(h):\(p) rejected the password or key"
        }
    }
}

/// Decides unknown host keys. Changed keys never reach this: they fail the
/// connection before any credentials are sent.
public protocol HostKeyTrustStore: AnyObject, Sendable {
    func check(host: String, port: Int, algorithm: String, keyBase64: String) -> HostKeyCheck
    /// Ask the user about a first-seen key. Return true to trust and remember it.
    func confirmUnknown(host: String, port: Int, algorithm: String, keyBase64: String, fingerprint: String) async -> Bool
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let store: HostKeyTrustStore
    private(set) var failure: SSHConnectError?
    private(set) var unknownKey: (algorithm: String, keyBase64: String, fingerprint: String)?

    init(host: String, port: Int, store: HostKeyTrustStore) {
        self.host = host
        self.port = port
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey).split(separator: " ")
        guard line.count >= 2 else {
            validationCompletePromise.fail(SSHConnectError.hostKeyRejected(host: host, port: port))
            return
        }
        let algorithm = String(line[0]), blob = String(line[1])
        switch store.check(host: host, port: port, algorithm: algorithm, keyBase64: blob) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .changed(let expected, let presented):
            let err = SSHConnectError.hostKeyChanged(host: host, port: port, expected: expected, presented: presented)
            failure = err
            validationCompletePromise.fail(err)
        case .unknown(let fp):
            // Citadel gives the whole handshake a fixed 10 s login timeout, so
            // asking the user here would race it. Abort this attempt and let
            // connect() ask with no clock running, then reconnect.
            unknownKey = (algorithm, blob, fp)
            validationCompletePromise.fail(SSHConnectError.hostKeyRejected(host: host, port: port))
        }
    }
}

public enum SSHKeys {
    public static func authentication(username: String, credential: SSHCredential) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let p):
            return .passwordBased(username: username, password: p)
        case .privateKey(let text, let passphrase):
            let decryption = passphrase.map { Data($0.utf8) }
            let type: SSHKeyType
            do {
                type = try SSHKeyDetection.detectPrivateKeyType(from: text)
            } catch {
                throw SSHConnectError.unsupportedKey("not an OpenSSH private key")
            }
            do {
                switch type {
                case .ed25519:
                    return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryption))
                case .rsa:
                    return .custom(try RSAAuthenticationDelegate(username: username, key: Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryption)))
                default:
                    throw SSHConnectError.unsupportedKey(type.description)
                }
            } catch let e as SSHConnectError {
                throw e
            } catch {
                throw passphrase == nil ? SSHConnectError.unsupportedKey("\(error)") : SSHConnectError.badPassphrase
            }
        }
    }

    public struct Generated: Sendable {
        public var privateKeyOpenSSH: String
        public var publicKeyLine: String
    }

    /// Unencrypted OpenSSH private key; at rest it is protected by the vault.
    public static func generateEd25519(comment: String) -> Generated {
        let key = Curve25519.Signing.PrivateKey()
        let pub = NIOSSHPrivateKey(ed25519Key: key).publicKey
        var line = String(openSSHPublicKey: pub)
        if !comment.isEmpty { line += " " + comment }
        return Generated(privateKeyOpenSSH: key.makeSSHRepresentation(comment: comment), publicKeyLine: line)
    }

    /// Public key line for an imported private key.
    public static func publicKeyLine(privateKey text: String, passphrase: String?, comment: String = "") throws -> (KeyAlgorithm, String) {
        let decryption = passphrase.map { Data($0.utf8) }
        let type = try SSHKeyDetection.detectPrivateKeyType(from: text)
        let pub: NIOSSHPublicKey
        let alg: KeyAlgorithm
        switch type {
        case .ed25519:
            pub = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryption)).publicKey
            alg = .ed25519
        case .rsa:
            let k = try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryption)
            pub = NIOSSHPrivateKey(custom: k).publicKey
            alg = .rsa
        default:
            throw SSHConnectError.unsupportedKey(type.description)
        }
        var line = String(openSSHPublicKey: pub)
        if !comment.isEmpty { line += " " + comment }
        return (alg, line)
    }
}

/// An open connection, possibly tunnelled through jump hosts. Closing it closes
/// every hop.
public final class SSHConnection: @unchecked Sendable {
    public let client: SSHClient
    let hops: [SSHClient]

    init(client: SSHClient, hops: [SSHClient]) {
        self.client = client
        self.hops = hops
    }

    public static func connect(chain: [SSHHop], trust: HostKeyTrustStore, timeout: TimeAmount = .seconds(20)) async throws -> SSHConnection {
        precondition(!chain.isEmpty)
        var clients: [SSHClient] = []
        do {
            for hop in chain {
                let auth = try SSHKeys.authentication(username: hop.username, credential: hop.credential)
                // Second pass only happens after the user trusted a new key.
                for attempt in 0..<2 {
                    let delegate = HostKeyDelegate(host: hop.host, port: hop.port, store: trust)
                    var settings = SSHClientSettings(host: hop.host, port: hop.port,
                                                     authenticationMethod: { auth },
                                                     hostKeyValidator: .custom(delegate))
                    settings.connectTimeout = timeout
                    do {
                        if let previous = clients.last {
                            clients.append(try await previous.jump(to: settings))
                        } else {
                            clients.append(try await SSHClient.connect(to: settings))
                        }
                        break
                    } catch {
                        // NIO wraps the promise failure; surface our own reason.
                        if let f = delegate.failure { throw f }
                        if case SSHClientError.allAuthenticationOptionsFailed = error {
                            throw SSHConnectError.authenticationFailed(host: hop.host, port: hop.port, user: hop.username)
                        }
                        if attempt == 0, let k = delegate.unknownKey {
                            guard await trust.confirmUnknown(host: hop.host, port: hop.port, algorithm: k.algorithm,
                                                             keyBase64: k.keyBase64, fingerprint: k.fingerprint) else {
                                throw SSHConnectError.hostKeyRejected(host: hop.host, port: hop.port)
                            }
                            continue
                        }
                        throw error
                    }
                }
            }
        } catch {
            for c in clients.reversed() { try? await c.close() }
            throw error
        }
        return SSHConnection(client: clients.last!, hops: Array(clients.dropLast()))
    }

    public func close() async {
        try? await client.close()
        for c in hops.reversed() { try? await c.close() }
    }

    public var isConnected: Bool { client.isConnected }
}
