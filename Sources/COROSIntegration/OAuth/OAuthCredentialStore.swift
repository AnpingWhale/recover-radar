import Foundation
import Security

/// Stores only this application's credential envelope. The widget never links this module.
/// Synchronous operations let OAuthSession commit rotated tokens without actor reentrancy.
public protocol OAuthCredentialStore: Sendable {
    func read(region: COROSRegion) throws -> Data?
    func save(_ data: Data, region: COROSRegion) throws
    func delete(region: COROSRegion) throws
}

public struct KeychainOAuthCredentialStore: OAuthCredentialStore, Sendable {
    private let service: String
    private let useDataProtectionKeychain: Bool

    /// Production uses the data-protection Keychain and its signing entitlement.
    /// An explicitly marked ad-hoc preview may opt into the login Keychain instead.
    /// There is no automatic fallback on a production entitlement or access error.
    public init(service: String = "com.recoverradar.oauth", useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func read(region: COROSRegion) throws -> Data? {
        var query = baseQuery(region)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw OAuthError.keychain(status) }
        guard let data = result as? Data else { throw OAuthError.invalidStoredCredentials }
        return data
    }

    public func save(_ data: Data, region: COROSRegion) throws {
        let query = baseQuery(region)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw OAuthError.keychain(update) }
        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw OAuthError.keychain(status) }
    }

    public func delete(region: COROSRegion) throws {
        let status = SecItemDelete(baseQuery(region) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OAuthError.keychain(status) }
    }

    private func baseQuery(_ region: COROSRegion) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: region.rawValue, kSecAttrSynchronizable: false,
         kSecUseDataProtectionKeychain: useDataProtectionKeychain]
    }
}

struct StoredOAuthCredentials: Codable, Sendable {
    var schemaVersion = 1
    let region: COROSRegion
    let issuer: URL
    let resource: URL
    let connectionID: UUID
    let clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var requiresAuthorization = false

    func validate(for region: COROSRegion) throws {
        guard schemaVersion == 1, self.region == region, issuer == region.issuerURL,
              resource == region.mcpURL, Self.validSecret(clientID),
              expiresAt.timeIntervalSince1970.isFinite,
              requiresAuthorization || (Self.validSecret(accessToken) && Self.validSecret(refreshToken))
        else { throw OAuthError.invalidStoredCredentials }
    }

    private static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }
}
