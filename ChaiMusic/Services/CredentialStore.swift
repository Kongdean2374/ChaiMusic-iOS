import Foundation
import Security

struct SourceCredential: Codable { var username: String; var password: String }

enum CredentialStore {
    private static let service = "app.chai.music.sources"
    static func save(_ credential: SourceCredential, id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: id.uuidString]
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SourceFailure.credentials }
        } else if result != errSecSuccess { throw SourceFailure.credentials }
    }
    static func load(id: UUID) throws -> SourceCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: id.uuidString,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SourceFailure.credentials }
        do { return try JSONDecoder().decode(SourceCredential.self, from: data) }
        catch { throw SourceFailure.credentials }
    }
    static func remove(id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}
