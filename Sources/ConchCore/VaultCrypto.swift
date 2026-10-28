import Foundation
import Crypto

// Vault encryption, shared byte-for-byte with web/src/vault/crypto.ts and
// server/sync (which only stores the outputs). Spec: docs/vault-crypto.md.
//
//   vault key VK      32 random bytes, never leaves a device unwrapped
//   recovery key RK   20 random bytes, shown once as base32 groups
//   KEK               HKDF-SHA256(RK, salt: vaultID, info: "conch-kek-v1")
//   recovery auth     HKDF-SHA256(RK, salt: vaultID, info: "conch-recovery-auth-v1")
//   record key        HKDF-SHA256(VK, salt: vaultID, info: "conch-record-v1")
//   sealed            nonce(12) || ciphertext || tag(16), AES-256-GCM
//
// RK is random rather than a user password, so a fast KDF is enough and the
// server copy of the wrapped vault key cannot be brute-forced offline.

public enum VaultCryptoError: Error, Equatable {
    case badRecoveryKey
    case badCiphertext
}

public struct VaultKey: Sendable, Equatable {
    public let bytes: Data

    public init(bytes: Data) { self.bytes = bytes }

    public static func generate() -> VaultKey {
        VaultKey(bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    var symmetric: SymmetricKey { SymmetricKey(data: bytes) }
}

public struct RecoveryKey: Sendable, Equatable {
    public let bytes: Data

    public init(bytes: Data) { self.bytes = bytes }

    public static func generate() -> RecoveryKey {
        var b = Data(count: 20)
        for i in 0..<20 { b[i] = UInt8.random(in: 0...255) }
        return RecoveryKey(bytes: b)
    }

    /// 32 base32 characters in groups of four, e.g. "ABCD-EFGH-...".
    public var displayString: String {
        let s = Base32.encode(bytes)
        return stride(from: 0, to: s.count, by: 4).map { i -> String in
            let start = s.index(s.startIndex, offsetBy: i)
            return String(s[start..<s.index(start, offsetBy: min(4, s.count - i))])
        }.joined(separator: "-")
    }

    public init(displayString: String) throws {
        let cleaned = displayString.uppercased().filter { !"- \n\t".contains($0) }
        guard let b = Base32.decode(cleaned), b.count == 20 else { throw VaultCryptoError.badRecoveryKey }
        bytes = b
    }
}

public enum VaultCrypto {
    static func hkdf(_ ikm: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                               salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
    }

    public static func kek(recovery: RecoveryKey, vaultID: String) -> SymmetricKey {
        hkdf(recovery.bytes, salt: vaultID, info: "conch-kek-v1")
    }

    /// Sent to the server to prove possession of RK during recovery enrolment.
    /// The server stores only SHA-256 of this value.
    public static func recoveryAuth(recovery: RecoveryKey, vaultID: String) -> Data {
        hkdf(recovery.bytes, salt: vaultID, info: "conch-recovery-auth-v1").withUnsafeBytes { Data($0) }
    }

    public static func recordKey(_ vk: VaultKey, vaultID: String) -> SymmetricKey {
        hkdf(vk.bytes, salt: vaultID, info: "conch-record-v1")
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        return box.combined!
    }

    public static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultCryptoError.badCiphertext
        }
    }

    public static func wrap(_ vk: VaultKey, recovery: RecoveryKey, vaultID: String) throws -> Data {
        try seal(vk.bytes, key: kek(recovery: recovery, vaultID: vaultID), aad: Data("conch-vk-v1|\(vaultID)".utf8))
    }

    public static func unwrap(_ wrapped: Data, recovery: RecoveryKey, vaultID: String) throws -> VaultKey {
        do {
            return VaultKey(bytes: try open(wrapped, key: kek(recovery: recovery, vaultID: vaultID),
                                            aad: Data("conch-vk-v1|\(vaultID)".utf8)))
        } catch {
            throw VaultCryptoError.badRecoveryKey
        }
    }

    /// AAD binds a ciphertext to its record id and kind so the server cannot swap
    /// records between ids or present a host record as an identity.
    public static func recordAAD(vaultID: String, recordID: String, kind: String) -> Data {
        Data("conch-record-v1|\(vaultID)|\(recordID)|\(kind)".utf8)
    }

    /// Pairing transfers VK to a new device through the server, encrypted under a
    /// one-time secret that travels out of band (QR code or typed).
    public static func pairingKey(secret: Data, inviteID: String) -> SymmetricKey {
        hkdf(secret, salt: inviteID, info: "conch-pair-v1")
    }
}

public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    public static func decode(_ s: String) -> Data? {
        var out = Data()
        var buffer = 0, bits = 0
        for c in s {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = ((buffer << 5) | v) & 0xFFFF
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}
