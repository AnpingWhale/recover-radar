import Foundation

public protocol COROSAccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    func invalidateAccessToken() async throws
}

public enum OAuthConnectionState: String, Sendable {
    case disconnected, connecting, connected, requiresAuthorization
}

/// Safe for UI and cache isolation; it deliberately contains no user identity or credential.
public struct OAuthConnectionStatus: Sendable {
    public let state: OAuthConnectionState
    public let region: COROSRegion
    public let connectionID: UUID?
    public let expiresAt: Date?
    public var isConnected: Bool { state == .connected }
}

public struct OAuthDisconnectResult: Sendable {
    public let localCredentialsRemoved: Bool
    public let revocationConfirmed: Bool
    public let hadCredentials: Bool
}

/// Owns this app's OAuth state, including refresh-token rotation and cancellation barriers.
/// All networking is injectable and default transport refuses redirects and token POST retries.
public actor OAuthSession: COROSAccessTokenProvider {
    public nonisolated let region: COROSRegion
    private let transport: any HTTPTransport
    private let credentialStore: any OAuthCredentialStore
    private let now: @Sendable () -> Date
    private var credentials: StoredOAuthCredentials?
    private var hasLoadedCredentials = false
    private var metadata: OAuthServerMetadata?
    private var generation = 0
    private var loginID: UUID?
    private var activeBrowser: (any OAuthWebAuthenticating)?
    private var refreshOperation: (id: UUID, task: Task<String, any Error>)?

    public init(region: COROSRegion,
                transport: any HTTPTransport = URLSessionHTTPTransport(),
                credentialStore: any OAuthCredentialStore = KeychainOAuthCredentialStore(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.region = region
        self.transport = transport
        self.credentialStore = credentialStore
        self.now = now
    }

    public func status() throws -> OAuthConnectionStatus {
        try restoreIfNeeded()
        return connectionStatus()
    }

    /// Invoked only after the user starts connection in the app. Discovery alone never registers.
    @discardableResult
    public func connect(using browser: any OAuthWebAuthenticating) async throws -> OAuthConnectionStatus {
        try restoreIfNeeded()
        guard loginID == nil else { throw OAuthError.authorizationInProgress }
        guard credentials == nil || credentials?.requiresAuthorization == true else { throw OAuthError.alreadyConnected }
        generation += 1
        let expectedGeneration = generation
        let id = UUID()
        loginID = id
        activeBrowser = browser
        do {
            let redirectURI = try await browser.prepareCallback()
            try OAuthProtocol.validateRedirectURI(redirectURI)
            try checkGeneration(expectedGeneration)
            let server = try await discover()
            try checkGeneration(expectedGeneration)
            let clientID = try await registerClient(at: server.registrationEndpoint, redirectURI: redirectURI)
            try checkGeneration(expectedGeneration)
            let verifier = try OAuthProtocol.randomURLSafeString()
            let state = try OAuthProtocol.randomURLSafeString()
            let authorizationURL = try OAuthProtocol.authorizationURL(metadata: server, region: region,
                                                                       clientID: clientID, state: state, verifier: verifier,
                                                                       redirectURI: redirectURI)
            let callback = try await browser.authenticate(url: authorizationURL, callbackURLScheme: "http")
            try checkGeneration(expectedGeneration)
            let code = try OAuthProtocol.authorizationCode(from: callback, expectedState: state, issuer: server.issuer,
                                                           redirectURI: redirectURI)
            let tokens = try await requestTokens(endpoint: server.tokenEndpoint, form: [
                "grant_type": "authorization_code", "client_id": clientID,
                "code": code, "redirect_uri": redirectURI.absoluteString, "code_verifier": verifier
            ])
            try checkTokenCommit(tokens, clientID: clientID, server: server, expectedGeneration: expectedGeneration)
            let stored = StoredOAuthCredentials(region: region, issuer: region.issuerURL, resource: region.mcpURL,
                                                 connectionID: UUID(), clientID: clientID,
                                                 accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                                 expiresAt: now().addingTimeInterval(tokens.expiresIn))
            try persist(stored)
            await finishLogin(id: id, browser: browser)
            return connectionStatus()
        } catch {
            await finishLogin(id: id, browser: browser)
            throw error
        }
    }

    private func finishLogin(id: UUID, browser: any OAuthWebAuthenticating) async {
        guard loginID == id else { return }
        await browser.cancel()
        if loginID == id { loginID = nil; activeBrowser = nil }
    }

    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        try restoreIfNeeded()
        guard let stored = credentials else { throw OAuthError.notConnected }
        guard !stored.requiresAuthorization else { throw OAuthError.requiresAuthorization }
        if let operation = refreshOperation {
            let result = try await operation.task.value
            try Task.checkCancellation()
            return result
        }
        if stored.expiresAt.timeIntervalSince(now()) > 60 { return stored.accessToken }

        let id = UUID()
        let expectedGeneration = generation
        let task = Task { try await self.refresh(expectedGeneration: expectedGeneration) }
        refreshOperation = (id, task)
        defer { if refreshOperation?.id == id { refreshOperation = nil } }
        // One caller's cancellation must not cancel a refresh that other callers are awaiting.
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    public func invalidateAccessToken() throws {
        try restoreIfNeeded()
        guard var stored = credentials else { throw OAuthError.notConnected }
        guard !stored.requiresAuthorization else { throw OAuthError.requiresAuthorization }
        // A concurrent refresh already owns replacement of this access token.
        guard refreshOperation == nil else { return }
        stored.expiresAt = .distantPast
        try persist(stored)
    }

    /// Removes local state before networking. A network failure cannot retain local credentials.
    /// The caller separately removes private history and the App Group snapshot.
    @discardableResult
    public func disconnect() async throws -> OAuthDisconnectResult {
        // Even a malformed credential envelope must remain removable.
        try? restoreIfNeeded()
        let previous = credentials
        let knownMetadata = metadata
        let browser = activeBrowser
        // An in-flight code exchange or rotating refresh can succeed remotely after cancellation.
        let hadInFlightAuthorization = loginID != nil || refreshOperation != nil
        generation += 1
        refreshOperation?.task.cancel()
        refreshOperation = nil
        loginID = nil
        activeBrowser = nil
        credentials = nil
        hasLoadedCredentials = true
        metadata = nil
        var localError: (any Error)?
        do { try credentialStore.delete(region: region) } catch {
            // Do not report a disconnected session when Keychain removal actually failed.
            credentials = previous
            hasLoadedCredentials = previous != nil
            localError = error
        }
        await browser?.cancel()
        if let localError { throw localError }

        guard let previous, !previous.refreshToken.isEmpty else {
            return OAuthDisconnectResult(localCredentialsRemoved: true, revocationConfirmed: false, hadCredentials: previous != nil)
        }
        // Use fresh validated discovery if the session was restored after relaunch.
        let server: OAuthServerMetadata?
        if let knownMetadata { server = knownMetadata }
        else { server = try? await fetchMetadata() }
        var revoked = false
        if let endpoint = server?.revocationEndpoint {
            // Revoke the refresh grant as well as the access token. Never retry these POSTs.
            let refreshRevoked = await revoke(previous.refreshToken, hint: "refresh_token", clientID: previous.clientID, endpoint: endpoint)
            let accessRevoked = await revoke(previous.accessToken, hint: "access_token", clientID: previous.clientID, endpoint: endpoint)
            revoked = refreshRevoked && accessRevoked && !hadInFlightAuthorization
        }
        return OAuthDisconnectResult(localCredentialsRemoved: true, revocationConfirmed: revoked, hadCredentials: true)
    }

    private func refresh(expectedGeneration: Int) async throws -> String {
        guard var stored = credentials, !stored.requiresAuthorization else { throw OAuthError.requiresAuthorization }
        let server = try await discover()
        try checkGeneration(expectedGeneration)
        do {
            let tokens = try await requestTokens(endpoint: server.tokenEndpoint, form: [
                "grant_type": "refresh_token", "client_id": stored.clientID, "refresh_token": stored.refreshToken
            ])
            try checkTokenCommit(tokens, clientID: stored.clientID, server: server, expectedGeneration: expectedGeneration)
            stored.accessToken = tokens.accessToken
            stored.refreshToken = tokens.refreshToken
            stored.expiresAt = now().addingTimeInterval(tokens.expiresIn)
            // Commit both rotated tokens as one Keychain value before returning the access token.
            try persist(stored)
            return stored.accessToken
        } catch OAuthError.requiresAuthorization {
            try checkGeneration(expectedGeneration)
            stored.accessToken = ""
            stored.refreshToken = ""
            stored.requiresAuthorization = true
            try persist(stored)
            throw OAuthError.requiresAuthorization
        }
    }

    private func restoreIfNeeded() throws {
        guard !hasLoadedCredentials else { return }
        if let data = try credentialStore.read(region: region) {
            guard data.count <= 131_072,
                  let stored = try? JSONDecoder().decode(StoredOAuthCredentials.self, from: data)
            else { throw OAuthError.invalidStoredCredentials }
            try stored.validate(for: region)
            credentials = stored
        }
        hasLoadedCredentials = true
    }

    private func persist(_ stored: StoredOAuthCredentials) throws {
        try stored.validate(for: region)
        try credentialStore.save(JSONEncoder().encode(stored), region: region)
        credentials = stored
        hasLoadedCredentials = true
    }

    private func connectionStatus() -> OAuthConnectionStatus {
        let state: OAuthConnectionState
        if loginID != nil { state = .connecting }
        else if let credentials { state = credentials.requiresAuthorization ? .requiresAuthorization : .connected }
        else { state = .disconnected }
        return OAuthConnectionStatus(state: state, region: region, connectionID: credentials?.connectionID, expiresAt: credentials?.expiresAt)
    }

    private func checkGeneration(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw OAuthError.cancelled }
    }

    private func checkTokenCommit(_ tokens: TokenResponse, clientID: String,
                                  server: OAuthServerMetadata, expectedGeneration: Int) throws {
        if Task.isCancelled || generation != expectedGeneration {
            if let endpoint = server.revocationEndpoint {
                // This unstructured cleanup does not inherit the cancelled caller's task state.
                // It never restores credentials and does not hold up local disconnection.
                Task {
                    _ = await revoke(tokens.refreshToken, hint: "refresh_token", clientID: clientID, endpoint: endpoint)
                    _ = await revoke(tokens.accessToken, hint: "access_token", clientID: clientID, endpoint: endpoint)
                }
            }
        }
        try checkGeneration(expectedGeneration)
    }

    private func discover() async throws -> OAuthServerMetadata {
        if let metadata { return metadata }
        let result = try await fetchMetadata()
        metadata = result
        return result
    }

    private func fetchMetadata() async throws -> OAuthServerMetadata {
        var request = URLRequest(url: region.metadataURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await send(request)
        guard response.statusCode == 200 else { throw OAuthError.requestRejected(response.statusCode) }
        guard let result = try? JSONDecoder().decode(OAuthServerMetadata.self, from: response.data)
        else { throw OAuthError.invalidMetadata }
        return try result.validated(for: region)
    }

    private func registerClient(at endpoint: URL, redirectURI: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ClientRegistrationRequest(redirectURI: redirectURI))
        let response = try await send(request)
        guard response.statusCode == 200 || response.statusCode == 201
        else { throw OAuthError.registrationRejected(response.statusCode) }
        guard let registered = try? JSONDecoder().decode(ClientRegistrationResponse.self, from: response.data),
              !registered.clientID.isEmpty,
              registered.tokenEndpointAuthMethod == nil || registered.tokenEndpointAuthMethod == "none",
              registered.clientSecret == nil || registered.clientSecret?.isEmpty == true,
              registered.redirectURIs.map({ $0 == [redirectURI.absoluteString] }) ?? true
        else { throw OAuthError.unsupportedAuthorization }
        return registered.clientID
    }

    private func requestTokens(endpoint: URL, form: [String: String]) async throws -> TokenResponse {
        let response = try await send(formRequest(endpoint, values: form))
        guard response.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(OAuthServerFailure.self, from: response.data)
            if failure?.error == "invalid_grant" || failure?.error == "invalid_client" || response.statusCode == 401 {
                throw OAuthError.requiresAuthorization
            }
            throw OAuthError.requestRejected(response.statusCode)
        }
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: response.data),
              result.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              Self.validToken(result.accessToken), Self.validToken(result.refreshToken),
              result.expiresIn.isFinite, result.expiresIn > 0, result.expiresIn <= 315_360_000
        else { throw OAuthError.invalidTokenResponse }
        return result
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    private func revoke(_ token: String, hint: String, clientID: String, endpoint: URL) async -> Bool {
        guard !token.isEmpty else { return true }
        let request = formRequest(endpoint, values: ["token": token, "token_type_hint": hint, "client_id": clientID])
        guard let response = try? await send(request) else { return false }
        return response.statusCode == 200
    }

    private func formRequest(_ endpoint: URL, values: [String: String]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthProtocol.formBody(values)
        return request
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url else { throw OAuthError.untrustedEndpoint }
        try region.validateEndpoint(url)
        var request = request
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let response = try await transport.send(request)
            guard response.data.count <= 131_072 else { throw OAuthError.invalidMetadata }
            return response
        } catch is CancellationError { throw CancellationError() }
        catch let error as OAuthError { throw error }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw OAuthError.networkFailure
        }
    }
}

private struct ClientRegistrationRequest: Encodable {
    let client_name = "Recover Radar for macOS"
    let application_type = "native"
    let redirect_uris: [String]
    init(redirectURI: URL) { redirect_uris = [redirectURI.absoluteString] }
    let grant_types = ["authorization_code", "refresh_token"]
    let response_types = ["code"]
    let scope = OAuthProtocol.scopes
    let token_endpoint_auth_method = "none"
}

private struct ClientRegistrationResponse: Decodable {
    let clientID: String
    let tokenEndpointAuthMethod: String?
    let clientSecret: String?
    let redirectURIs: [String]?
    enum CodingKeys: String, CodingKey {
        case clientID = "client_id", tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case clientSecret = "client_secret", redirectURIs = "redirect_uris"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Double
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case tokenType = "token_type", expiresIn = "expires_in"
    }
}

private struct OAuthServerFailure: Decodable { let error: String }
