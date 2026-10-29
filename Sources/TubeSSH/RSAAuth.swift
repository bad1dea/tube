import CCryptoBoringSSL
import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH

// RSA user authentication with rsa-sha2-512 / rsa-sha2-256 (RFC 8332).
//
// Citadel 0.12 only signs "ssh-rsa" (SHA-1), which OpenSSH 8.8+ refuses.
// swift-nio-ssh takes the auth request's algorithm name from the custom key's
// prefix and also writes that prefix into the key blob, where RFC 8332 wants
// "ssh-rsa". RSASHA2PublicKey.write(to:) rewrites the blob's prefix in place.

protocol RSASHA2Hash {
    static var algorithm: String { get }
    static var nid: Int32 { get }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8]
}

enum RSASHA512: RSASHA2Hash {
    static var algorithm: String { "rsa-sha2-512" }
    static var nid: Int32 { NID_sha512 }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA512.hash(data: data)) }
}

enum RSASHA256: RSASHA2Hash {
    static var algorithm: String { "rsa-sha2-256" }
    static var nid: Int32 { NID_sha256 }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA256.hash(data: data)) }
}

/// n, e, d of an RSA key, as big-endian bytes.
struct RSAKeyMaterial: Sendable {
    let n: [UInt8], e: [UInt8], d: [UInt8]

    /// Citadel parses and decrypts the OpenSSH key but keeps the private
    /// exponent internal; read it by reflection. Citadel is pinned exactly and
    /// testRSAKeyAuthenticates fails if the layout changes.
    init(_ key: Insecure.RSA.PrivateKey) throws {
        func bignum(_ value: Any?, _ label: String) throws -> [UInt8] {
            guard let bn = value as? UnsafeMutablePointer<BIGNUM> else {
                throw SSHConnectError.unsupportedKey("RSA key layout (\(label))")
            }
            var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(bn)))
            _ = CCryptoBoringSSL_BN_bn2bin(bn, &out)
            return out
        }
        func child(_ subject: Any, _ label: String) -> Any? {
            Mirror(reflecting: subject).children.first { $0.label == label }?.value
        }
        guard let pub = child(key, "_publicKey") else {
            throw SSHConnectError.unsupportedKey("RSA key layout (_publicKey)")
        }
        d = try bignum(child(key, "privateExponent"), "privateExponent")
        n = try bignum(child(pub, "modulus"), "modulus")
        e = try bignum(child(pub, "publicExponent"), "publicExponent")
    }

    func sign(digest: [UInt8], nid: Int32) throws -> Data {
        let bn = { (bytes: [UInt8]) in CCryptoBoringSSL_BN_bin2bn(bytes, bytes.count, nil)! }
        let (bn_n, bn_e, bn_d) = (bn(n), bn(e), bn(d))
        defer { CCryptoBoringSSL_BN_free(bn_n); CCryptoBoringSSL_BN_free(bn_e); CCryptoBoringSSL_BN_free(bn_d) }
        guard let rsa = CCryptoBoringSSL_RSA_new_private_key_no_crt(bn_n, bn_e, bn_d) else {
            throw SSHConnectError.unsupportedKey("invalid RSA key")
        }
        defer { CCryptoBoringSSL_RSA_free(rsa) }
        var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_RSA_size(rsa)))
        var length: UInt32 = 0
        guard CCryptoBoringSSL_RSA_sign(nid, digest, digest.count, &out, &length, rsa) == 1 else {
            throw SSHConnectError.unsupportedKey("RSA signing failed")
        }
        return Data(out.prefix(Int(length)))
    }
}

struct RSASHA2Signature<H: RSASHA2Hash>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { H.algorithm }
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw SSHConnectError.unsupportedKey("\(H.algorithm) signatures are client-only")
    }
}

final class RSASHA2PublicKey<H: RSASHA2Hash>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { H.algorithm }
    let material: RSAKeyMaterial

    init(_ material: RSAKeyMaterial) { self.material = material }

    var rawRepresentation: Data {
        var buffer = ByteBuffer()
        writeBody(&buffer)
        return Data(buffer.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }

    /// NIOSSH has just written the algorithm name as the blob's type string;
    /// replace it with "ssh-rsa". The returned count is relative to what NIOSSH
    /// believes it wrote, so its length prefix comes out right.
    func write(to buffer: inout ByteBuffer) -> Int {
        let tag = Array(H.algorithm.utf8)
        let start = buffer.writerIndex - 4 - tag.count
        guard start >= 0,
              buffer.getInteger(at: start, as: UInt32.self) == UInt32(tag.count),
              buffer.getBytes(at: start + 4, length: tag.count) == tag
        else { return writeBody(&buffer) }
        buffer.moveWriterIndex(to: start)
        let written = buffer.writeSSHString(Array("ssh-rsa".utf8)) + writeBody(&buffer)
        return written - 4 - tag.count
    }

    @discardableResult
    private func writeBody(_ buffer: inout ByteBuffer) -> Int {
        buffer.writeMPInt(material.e) + buffer.writeMPInt(material.n)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw SSHConnectError.unsupportedKey("\(H.algorithm) keys are client-only")
    }
}

final class RSASHA2PrivateKey<H: RSASHA2Hash>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { H.algorithm }
    let material: RSAKeyMaterial
    let publicKey: NIOSSHPublicKeyProtocol

    init(_ material: RSAKeyMaterial) {
        self.material = material
        self.publicKey = RSASHA2PublicKey<H>(material)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASHA2Signature<H>(rawRepresentation: try material.sign(digest: H.digest(data), nid: H.nid))
    }
}

/// Offers the key as rsa-sha2-512, then rsa-sha2-256, then ssh-rsa for servers
/// older than OpenSSH 7.2.
final class RSAAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var keys: [NIOSSHPrivateKey]

    init(username: String, key: Insecure.RSA.PrivateKey) throws {
        let material = try RSAKeyMaterial(key)
        self.username = username
        self.keys = [
            NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA512>(material)),
            NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA256>(material)),
            NIOSSHPrivateKey(custom: key),
        ]
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), !keys.isEmpty else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        let key = keys.removeFirst()
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

private extension ByteBuffer {
    /// SSH mpint for a non-negative big-endian integer.
    mutating func writeMPInt(_ bytes: [UInt8]) -> Int {
        let trimmed = bytes.drop { $0 == 0 }
        let pad = (trimmed.first ?? 0) & 0x80 != 0
        return writeInteger(UInt32(trimmed.count + (pad ? 1 : 0)))
            + (pad ? writeInteger(UInt8(0)) : 0)
            + writeBytes(trimmed)
    }

    mutating func writeSSHString<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 {
        writeInteger(UInt32(bytes.count)) + writeBytes(bytes)
    }
}
