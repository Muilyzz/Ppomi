// The one secret: the OpenAI-compatible API key, kept in the login keychain as a generic password so the shell can read
// the same item:   security find-generic-password -a "$USER" -s ppomi-openai -w
// Nothing here logs or prints the key.
import Foundation
import Security

enum Keychain {
    static let service = "ppomi-openai"
    static var account: String { NSUserName() }

    struct Error: Swift.Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "키체인 오류 \(status)" + ((SecCopyErrorMessageString(status, nil) as String?).map { ": \($0)" } ?? "")
        }
    }

    /// The attributes that identify our item. Every call below starts from this.
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// nil when there is no item (or it is unreadable); never throws so the UI can just ask "is there a key?".
    static func apiKey() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Update in place when the item exists, add it otherwise.
    static func setAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw Error(status: added) }
        } else if updated != errSecSuccess {
            throw Error(status: updated)
        }
    }

    /// Deleting a key that is not there is not an error.
    static func deleteAPIKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error(status: status) }
    }
}
