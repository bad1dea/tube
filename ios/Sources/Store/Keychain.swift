import Foundation
import Security

/// Secrets that never go into the JSON data file: host passwords, private keys
/// and their passphrases. Items are device-only (no iCloud Keychain) and
/// readable after first unlock so reconnect works while the screen is locked.
enum Keychain {
    static let service = "pro.imnot.tube"

    enum Item {
        case hostPassword(UUID)
        case privateKey(UUID)
        case keyPassphrase(UUID)
        case vaultKey
        case syncCredentials

        var account: String {
            switch self {
            case .hostPassword(let id): return "pw.\(id.uuidString)"
            case .privateKey(let id): return "key.\(id.uuidString)"
            case .keyPassphrase(let id): return "keypass.\(id.uuidString)"
            case .vaultKey: return "vault.key"
            case .syncCredentials: return "sync.credentials"
            }
        }
    }

    static func set(_ value: String, for item: Item) throws {
        try set(Data(value.utf8), for: item)
    }

    static func set(_ data: Data, for item: Item) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func data(for item: Item) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func string(for item: Item) -> String? {
        data(for: item).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func remove(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
