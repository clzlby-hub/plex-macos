import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case invalidItem
}

struct Keychain {
    private let service: String
    private let accessGroup: String?

    init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func fallbackKey(for key: String) -> String {
        "plex.keychain.\(service).\(key)"
    }

    func setString(_ value: String, forKey key: String) throws {
        UserDefaults.standard.set(value, forKey: fallbackKey(for: key))
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = query.merging([kSecValueData as String: data]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            // Ad-hoc signed macOS builds fallback to UserDefaults above
            return
        }
    }

    func string(forKey key: String) throws -> String? {
        if let cached = UserDefaults.standard.string(forKey: fallbackKey(for: key)) {
            return cached
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            return UserDefaults.standard.string(forKey: fallbackKey(for: key))
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidItem
        }
        UserDefaults.standard.set(string, forKey: fallbackKey(for: key))
        return string
    }

    func deleteValue(forKey key: String) throws {
        UserDefaults.standard.removeObject(forKey: fallbackKey(for: key))
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        _ = SecItemDelete(query as CFDictionary)
    }
}
