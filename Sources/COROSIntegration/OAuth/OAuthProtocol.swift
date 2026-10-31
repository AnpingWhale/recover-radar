import CryptoKit
import Foundation
import Security

enum OAuthProtocol {
    // Fixed only for injected test authenticators. The real listener supplies its bound ephemeral port.
    static let redirectURI = URL(string: "http://127.0.0.1:43123/callback")!
    static let scopes = "openid offline_access mcp.tools"

    static func randomURLSafeString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw OAuthError.randomGenerationFailed }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(metadata: OAuthServerMetadata, region: COROSRegion,
                                 clientID: String, state: String, verifier: String,
                                 redirectURI: URL = OAuthProtocol.redirectURI) throws -> URL {
        try validateRedirectURI(redirectURI)
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        else { throw OAuthError.invalidMetadata }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // COROS's official helper binds resource to the full regional /mcp URL.
            URLQueryItem(name: "resource", value: region.mcpURL.absoluteString),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else { throw OAuthError.invalidMetadata }
        return url
    }

    static func authorizationCode(from callback: URL, expectedState: String, issuer: URL,
                                  redirectURI: URL = OAuthProtocol.redirectURI) throws -> String {
        try validateRedirectURI(redirectURI)
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == redirectURI.scheme, components.host == redirectURI.host,
              components.percentEncodedPath == redirectURI.path, components.port == redirectURI.port,
              components.user == nil, components.password == nil, components.fragment == nil
        else { throw OAuthError.invalidCallback }
        let items = components.queryItems ?? []
        // Duplicated security parameters are ambiguous and must not be accepted.
        for key in ["state", "code", "error", "iss"] {
            guard items.filter({ $0.name == key }).count <= 1 else { throw OAuthError.invalidCallback }
        }
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              constantTimeEqual(returnedState, expectedState) else { throw OAuthError.stateMismatch }
        if let returnedIssuer = items.first(where: { $0.name == "iss" })?.value,
           returnedIssuer != issuer.absoluteString { throw OAuthError.invalidCallback }
        guard !items.contains(where: { $0.name == "error" }) else { throw OAuthError.authorizationDenied }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw OAuthError.invalidCallback }
        return code
    }

    static func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    static func validateRedirectURI(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1",
              let port = components.port, (1...65_535).contains(port),
              components.percentEncodedPath == "/callback", components.query == nil,
              components.fragment == nil, components.user == nil, components.password == nil
        else { throw OAuthError.invalidCallback }
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
