import Foundation

/// Region is explicit: a token is never sent to another region or the auto-routing host.
public enum COROSRegion: String, CaseIterable, Codable, Sendable, Identifiable {
    case china = "cn"
    case europe = "eu"
    case unitedStates = "us"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .china: "中国大陆"
        case .europe: "欧洲"
        case .unitedStates: "美国及其他地区"
        }
    }

    public var issuerURL: URL { URL(string: "https://\(host)")! }
    public var mcpURL: URL { issuerURL.appending(path: "mcp") }
    public var metadataURL: URL { issuerURL.appending(path: ".well-known/oauth-authorization-server") }

    var host: String {
        switch self {
        case .china: "mcpcn.coros.com"
        case .europe: "mcpeu.coros.com"
        case .unitedStates: "mcpus.coros.com"
        }
    }

    /// Apply before sending any authorization code, verifier, or refresh token.
    func validateEndpoint(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == host,
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.query == nil else { throw OAuthError.untrustedEndpoint }
    }
}

public enum OAuthError: Error, Equatable, LocalizedError, Sendable {
    case untrustedEndpoint
    case invalidMetadata
    case unsupportedAuthorization
    case invalidCallback
    case stateMismatch
    case authorizationDenied
    case registrationRejected(Int)
    case requestRejected(Int)
    case invalidTokenResponse
    case notConnected
    case requiresAuthorization
    case authorizationInProgress
    case alreadyConnected
    case presentationUnavailable
    case browserUnavailable
    case loopbackUnavailable
    case authorizationTimedOut
    case cancelled
    case randomGenerationFailed
    case invalidStoredCredentials
    case keychain(Int32)
    case networkFailure

    public var errorDescription: String? {
        switch self {
        case .untrustedEndpoint: "COROS 授权端点不属于所选区域，已停止连接。"
        case .invalidMetadata: "COROS 授权服务信息不完整或格式已变化。"
        case .unsupportedAuthorization: "COROS 服务未声明支持本应用所需的公共客户端和 PKCE 授权。"
        case .invalidCallback: "授权回调地址或参数不符合预期，请重新连接。"
        case .stateMismatch: "授权回调校验失败，请重新连接。"
        case .authorizationDenied: "COROS 授权未获批准。"
        case .registrationRejected(let status): "COROS 客户端注册未成功（HTTP \(status)）；原生回调兼容性尚待验证。"
        case .requestRejected(let status): "COROS 授权请求未成功（HTTP \(status)）。"
        case .invalidTokenResponse: "COROS 令牌响应不完整或格式已变化。"
        case .notConnected: "请先连接 COROS。"
        case .requiresAuthorization: "COROS 授权已失效，请重新连接。"
        case .authorizationInProgress: "COROS 授权正在进行。"
        case .alreadyConnected: "请先断开当前 COROS 连接，再切换账号。"
        case .presentationUnavailable: "请在应用窗口中发起 COROS 连接。"
        case .browserUnavailable: "无法打开系统授权窗口。"
        case .loopbackUnavailable: "无法建立本机授权回调，请检查应用的网络权限。"
        case .authorizationTimedOut: "COROS 授权已超时，请重新连接。"
        case .cancelled: "已取消 COROS 授权。"
        case .randomGenerationFailed: "无法创建安全授权参数。"
        case .invalidStoredCredentials: "本应用保存的 COROS 凭证无效，请断开后重新连接。"
        case .keychain: "无法访问本应用的钥匙串凭证，请解锁钥匙串后重试。"
        case .networkFailure: "无法连接 COROS 授权服务，请检查网络后重试。"
        }
    }
}

struct OAuthServerMetadata: Decodable, Sendable {
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL
    let revocationEndpoint: URL?
    let tokenEndpointAuthMethodsSupported: [String]
    let codeChallengeMethodsSupported: [String]
    let responseTypesSupported: [String]
    let grantTypesSupported: [String]
    let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case scopesSupported = "scopes_supported"
    }

    func validated(for region: COROSRegion) throws -> Self {
        try region.validateEndpoint(issuer)
        guard issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == region.issuerURL.absoluteString else { throw OAuthError.untrustedEndpoint }
        for endpoint in [authorizationEndpoint, tokenEndpoint, registrationEndpoint] {
            try region.validateEndpoint(endpoint)
        }
        if let revocationEndpoint { try region.validateEndpoint(revocationEndpoint) }
        guard tokenEndpointAuthMethodsSupported.contains("none"),
              codeChallengeMethodsSupported.contains("S256"),
              responseTypesSupported.contains("code"),
              grantTypesSupported.contains("authorization_code"),
              grantTypesSupported.contains("refresh_token"),
              scopesSupported.map({ Set(OAuthProtocol.scopes.split(separator: " ").map(String.init)).isSubset(of: Set($0)) }) ?? true
        else { throw OAuthError.unsupportedAuthorization }
        return self
    }
}
