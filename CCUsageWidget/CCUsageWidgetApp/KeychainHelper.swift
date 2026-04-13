import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.viktorsvirsky.ccusage.shared"
    private static let accessGroup: String = {
        // Detect team ID prefix at runtime by writing a temp item and reading its access group.
        // This works regardless of how the app was signed (App Store, dev, AltStore).
        let tempQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.viktorsvirsky.ccusage.teamid-probe",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data([0]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(tempQuery as CFDictionary)
        SecItemAdd(tempQuery as CFDictionary, nil)

        var readQuery = tempQuery
        readQuery.removeValue(forKey: kSecValueData as String)
        readQuery[kSecReturnAttributes as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        SecItemDelete(tempQuery as CFDictionary)

        if status == errSecSuccess,
           let attrs = result as? [String: Any],
           let group = attrs[kSecAttrAccessGroup as String] as? String {
            // group is like "TEAMID.com.viktorsvirsky.ccusage-widget"
            // Extract prefix: everything before the first '.'
            if let dotIndex = group.firstIndex(of: ".") {
                let prefix = String(group[group.startIndex...dotIndex])
                return prefix + "com.viktorsvirsky.ccusage.shared"
            }
        }
        // Fallback: use entitlement value directly (works in dev signing)
        return "com.viktorsvirsky.ccusage.shared"
    }()

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
