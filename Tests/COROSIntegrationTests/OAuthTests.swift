import Foundation
import Testing
@testable import COROSIntegration

@Suite("Native COROS OAuth")
struct OAuthTests {
    @Test("PKCE matches the RFC 7636 S256 test vector")
    func pkceVector() throws {
        #expect(OAuthProtocol.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try OAuthProtocol.randomURLSafeString()
        let second = try OAuthProtocol.randomURLSafeString()
        #expect(first.count == 43)
        #expect(first != second)
        #expect(first.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
        })
    }

    @Test("Callback checks exact destination, state, issuer and duplicate parameters")
    func callbackValidation() throws {
        let issuer = COROSRegion.china.issuerURL
        #expect(try OAuthProtocol.authorizationCode(from: URL(string: "http://127.0.0.1:43123/callback?code=synthetic-code&state=expected")!,
                                                    expectedState: "expected", issuer: issuer) == "synthetic-code")
        for callback in [
            "http://attacker.invalid:43123/callback?code=x&state=expected",
            "http://127.0.0.1:43123/wrong?code=x&state=expected",
            "http://127.0.0.1:43123/callback?code=x&state=expected&state=expected",
            "http://127.0.0.1:43123/callback?code=x&state=expected&iss=https://mcpus.coros.com",
            "http://127.0.0.1:43123/callback?code=x&state=expected#fragment"
        ] {
            #expect(throws: OAuthError.invalidCallback) {
                try OAuthProtocol.authorizationCode(from: URL(string: callback)!, expectedState: "expected", issuer: issuer)
            }
        }
        #expect(throws: OAuthError.stateMismatch) {
            try OAuthProtocol.authorizationCode(from: URL(string: "http://127.0.0.1:43123/callback?code=x&state=wrong")!,
                                                expectedState: "expected", issuer: issuer)
        }
        #expect(throws: OAuthError.authorizationDenied) {
            try OAuthProtocol.authorizationCode(from: URL(string: "http://127.0.0.1:43123/callback?error=access_denied&state=expected")!,
                                                expectedState: "expected", issuer: issuer)
        }
    }

    @Test("OAuth endpoint validation prevents region changes and credential-bearing URLs")
    func endpointValidation() throws {
        try COROSRegion.china.validateEndpoint(URL(string: "https://mcpcn.coros.com/oauth2/token")!)
        for unsafe in [
            "http://mcpcn.coros.com/oauth2/token", "https://mcpus.coros.com/oauth2/token",
            "https://mcpcn.coros.com.attacker.invalid/oauth2/token", "https://user@mcpcn.coros.com/oauth2/token",
            "https://mcpcn.coros.com:444/oauth2/token", "https://mcpcn.coros.com/oauth2/token#fragment",
            "https://mcpcn.coros.com/oauth2/token?next=https://attacker.invalid"
        ] {
            #expect(throws: OAuthError.untrustedEndpoint) { try COROSRegion.china.validateEndpoint(URL(string: unsafe)!) }
        }
        let mixed = oauthMetadata.replacingOccurrences(of: "https://mcpcn.coros.com/oauth2/token", with: "https://mcpus.coros.com/oauth2/token")
        let decoded = try JSONDecoder().decode(OAuthServerMetadata.self, from: Data(mixed.utf8))
        #expect(throws: OAuthError.untrustedEndpoint) { try decoded.validated(for: .china) }
    }

    @Test("Native redirect is restricted to an exact IPv4 loopback endpoint")
    func loopbackRedirectValidation() throws {
        try OAuthProtocol.validateRedirectURI(URL(string: "http://127.0.0.1:53124/callback")!)
        for url in ["http://0.0.0.0:53124/callback", "http://localhost:53124/callback",
                    "http://127.0.0.1/callback", "http://127.0.0.1:53124/callback?extra=1",
                    "recoverradar://oauth/callback", "https://attacker.invalid/callback"] {
            #expect(throws: OAuthError.invalidCallback) { try OAuthProtocol.validateRedirectURI(URL(string: url)!) }
        }
        #expect(throws: OAuthError.invalidCallback) {
            try OAuthProtocol.authorizationCode(from: URL(string: "http://127.0.0.1:53125/callback?state=expected&code=x")!,
                                                expectedState: "expected", issuer: COROSRegion.china.issuerURL,
                                                redirectURI: URL(string: "http://127.0.0.1:53124/callback")!)
        }
    }

    @Test("Loopback HTTP parser rejects foreign hosts, paths, methods, states and oversized requests")
    func loopbackHTTPRequestValidation() {
        let redirect = OAuthProtocol.redirectURI
        let valid = "GET /callback?state=expected&code=synthetic HTTP/1.1\r\nHost: 127.0.0.1:43123\r\n\r\n"
        #expect(LoopbackHTTPRequest.callback(from: Data(valid.utf8), redirectURI: redirect, expectedState: "expected") != nil)
        for malformed in [
            valid.replacingOccurrences(of: "GET ", with: "POST "),
            valid.replacingOccurrences(of: "/callback?", with: "/wrong?"),
            valid.replacingOccurrences(of: "Host: 127.0.0.1:43123", with: "Host: attacker.invalid"),
            valid.replacingOccurrences(of: "state=expected", with: "state=wrong"),
            valid.replacingOccurrences(of: "state=expected", with: "state=expected&state=expected"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: 127.0.0.1:43123\r\n\r\n"),
            valid + "unexpected body",
            valid.replacingOccurrences(of: "code=synthetic", with: "code=" + String(repeating: "a", count: 8_200))
        ] {
            #expect(LoopbackHTTPRequest.callback(from: Data(malformed.utf8), redirectURI: redirect, expectedState: "expected") == nil)
        }
    }

    @Test("Real local socket rejects an unrelated callback, then accepts the correct state")
    @MainActor
    func loopbackSocketRoundTrip() async throws {
        let server = LoopbackCallbackServer(timeout: 5)
        let redirect = try await server.start()
        #expect(redirect.host == "127.0.0.1")
        #expect(redirect.port != nil)
        var requests: Task<[Int], any Error>?
        let received = try await server.waitForCallback(expectedState: "synthetic-state") {
            requests = Task {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 2
                let client = URLSession(configuration: configuration)
                defer { client.invalidateAndCancel() }
                let bad = URL(string: redirect.absoluteString + "?state=wrong&code=synthetic")!
                let (_, first) = try await client.data(from: bad)
                let good = URL(string: redirect.absoluteString + "?state=synthetic-state&code=synthetic")!
                let (_, second) = try await client.data(from: good)
                return [(first as? HTTPURLResponse)?.statusCode ?? 0, (second as? HTTPURLResponse)?.statusCode ?? 0]
            }
            return true
        }
        #expect(received.port == redirect.port)
        #expect(try await requests?.value == [400, 200])
        // A completed listener releases its endpoint and can start another independent attempt.
        _ = try await server.start()
        server.cancel()
    }

    @Test("Loopback timeout and explicit cancellation both close the listener")
    @MainActor
    func loopbackTimeoutAndCancellation() async throws {
        let timeoutServer = LoopbackCallbackServer(timeout: 0.1)
        await #expect(throws: OAuthError.authorizationTimedOut) {
            _ = try await timeoutServer.start()
            return try await timeoutServer.waitForCallback(expectedState: "synthetic") { true }
        }
        let cancelledServer = LoopbackCallbackServer(timeout: 5)
        _ = try await cancelledServer.start()
        await #expect(throws: OAuthError.cancelled) {
            try await cancelledServer.waitForCallback(expectedState: "synthetic") {
                cancelledServer.cancel()
                return true
            }
        }
        _ = try await cancelledServer.start()
        cancelledServer.cancel()
    }

    @Test("Native authorization sends PKCE and stores only validated tokens")
    @MainActor
    func nativeConnect() async throws {
        let store = MemoryOAuthStore()
        let transport = OAuthQueueTransport(responses: [metadataResponse(), registrationResponse(), tokenResponse()])
        let browser = SyntheticOAuthBrowser()
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        let status = try await session.connect(using: browser)
        #expect(status.isConnected)
        #expect(status.connectionID != nil)
        let authorization = try #require(browser.authorizationURL)
        let query = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(query.first(where: { $0.name == "resource" })?.value == COROSRegion.china.mcpURL.absoluteString)
        let requests = await transport.requests
        #expect(requests.count == 3)
        let registrationBody = try #require(requests[1].httpBody)
        let registrationObject = try JSONSerialization.jsonObject(with: registrationBody)
        let registration = try #require(registrationObject as? [String: Any])
        #expect(registration["token_endpoint_auth_method"] as? String == "none")
        #expect(registration["redirect_uris"] as? [String] == ["http://127.0.0.1:43123/callback"])
        #expect(registration["client_secret"] == nil)
        let form = try #require(requests[2].httpBody).flatMapBytesToString()
        #expect(form.contains("grant_type=authorization_code"))
        #expect(form.contains("code_verifier="))
        #expect(!form.contains("client_secret"))
        let restored = try store.storedCredentials()
        #expect(restored?.connectionID == status.connectionID)
        #expect(restored?.refreshToken == "synthetic-rotated-refresh")
    }

    @Test("Mismatched state never reaches the token endpoint")
    @MainActor
    func mismatchedStateStopsExchange() async throws {
        let store = MemoryOAuthStore()
        let transport = OAuthQueueTransport(responses: [metadataResponse(), registrationResponse()])
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        await #expect(throws: OAuthError.stateMismatch) {
            try await session.connect(using: SyntheticOAuthBrowser(wrongState: true))
        }
        #expect(await transport.requests.count == 2)
        #expect(try store.read(region: .china) == nil)
        #expect(try await session.status().state == .disconnected)
    }

    @Test("Disconnect cancels a pending browser authorization without exchanging a code")
    @MainActor
    func cancelPendingAuthorization() async throws {
        let store = MemoryOAuthStore()
        let transport = OAuthQueueTransport(responses: [metadataResponse(), registrationResponse()])
        let browser = PendingOAuthBrowser()
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        let pending = Task { try await session.connect(using: browser) }
        await browser.waitUntilPresented()
        #expect(try await session.status().state == .connecting)
        _ = try await session.disconnect()
        await #expect(throws: OAuthError.cancelled) { try await pending.value }
        #expect(await transport.requests.count == 2)
        #expect(try store.read(region: .china) == nil)
        #expect(try await session.status().state == .disconnected)
    }

    @Test("Concurrent callers share refresh and persist rotated tokens with the same connection ID")
    func refreshSingleFlight() async throws {
        let original = expiredCredentials()
        let store = try MemoryOAuthStore(credentials: original)
        let transport = GatedRefreshTransport()
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        let first = Task { try await session.accessToken() }
        await transport.waitForTokenRequest()
        let second = Task { try await session.accessToken() }
        await transport.releaseTokenResponse()
        let values = try await [first.value, second.value]
        #expect(values == ["synthetic-access", "synthetic-access"])
        #expect(await transport.tokenRequestCount == 1)
        #expect(try store.storedCredentials()?.refreshToken == "synthetic-rotated-refresh")
        #expect(try await session.status().connectionID == original.connectionID)
        #expect(try await session.accessToken() == "synthetic-access")
        #expect(await transport.tokenRequestCount == 1)
    }

    @Test("Disconnect is a barrier against an in-flight refresh restoring credentials")
    func disconnectDuringRefresh() async throws {
        let store = try MemoryOAuthStore(credentials: expiredCredentials())
        let transport = GatedRefreshTransport()
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        let pending = Task { try await session.accessToken() }
        await transport.waitForTokenRequest()
        let result = try await session.disconnect()
        #expect(result.localCredentialsRemoved)
        #expect(!result.revocationConfirmed)
        #expect(try store.read(region: .china) == nil)
        await transport.releaseTokenResponse()
        do {
            _ = try await pending.value
            Issue.record("A disconnected refresh must not return an access token")
        } catch { }
        #expect(try store.read(region: .china) == nil)
        #expect(try await session.status().state == .disconnected)
    }

    @Test("Revocation failure does not prevent local removal")
    func failedRevocationStillRemovesCredentials() async throws {
        let store = try MemoryOAuthStore(credentials: expiredCredentials())
        let transport = OAuthQueueTransport(responses: [metadataResponse(), response(status: 503, json: "{}"), response(status: 503, json: "{}")])
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        let result = try await session.disconnect()
        #expect(result.localCredentialsRemoved)
        #expect(!result.revocationConfirmed)
        #expect(try store.read(region: .china) == nil)
    }

    @Test("Invalid grant requires authorization without changing the history isolation key")
    func invalidRefreshGrant() async throws {
        let original = expiredCredentials()
        let store = try MemoryOAuthStore(credentials: original)
        let transport = OAuthQueueTransport(responses: [metadataResponse(), response(status: 400, json: #"{"error":"invalid_grant"}"#)])
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        await #expect(throws: OAuthError.requiresAuthorization) { try await session.accessToken() }
        let status = try await session.status()
        #expect(status.state == .requiresAuthorization)
        #expect(status.connectionID == original.connectionID)
        #expect(try store.storedCredentials()?.accessToken == "")
        await #expect(throws: OAuthError.requiresAuthorization) { try await session.accessToken() }
        #expect(await transport.requests.count == 2)
    }

    @Test("Temporary token service failure retains credentials for later retry")
    func temporaryFailure() async throws {
        let original = expiredCredentials()
        let store = try MemoryOAuthStore(credentials: original)
        let transport = OAuthQueueTransport(responses: [metadataResponse(), response(status: 503, json: "{}"), tokenResponse()])
        let session = OAuthSession(region: .china, transport: transport, credentialStore: store)
        await #expect(throws: OAuthError.requestRejected(503)) { try await session.accessToken() }
        #expect(try store.storedCredentials()?.refreshToken == original.refreshToken)
        #expect(try await session.accessToken() == "synthetic-access")
    }

    @Test("Corrupted credentials can still be deleted")
    func corruptedCredentialRemoval() async throws {
        let store = MemoryOAuthStore()
        try store.save(Data("not-json".utf8), region: .china)
        let session = OAuthSession(region: .china, transport: OAuthQueueTransport(responses: []), credentialStore: store)
        await #expect(throws: OAuthError.invalidStoredCredentials) { try await session.status() }
        _ = try await session.disconnect()
        #expect(try store.read(region: .china) == nil)
    }
}

// Every value in these tests is synthetic. No Keychain or remote endpoints are accessed.
private let oauthMetadata = #"{"issuer":"https://mcpcn.coros.com","authorization_endpoint":"https://mcpcn.coros.com/oauth2/authorize","token_endpoint":"https://mcpcn.coros.com/oauth2/token","registration_endpoint":"https://mcpcn.coros.com/connect/register","revocation_endpoint":"https://mcpcn.coros.com/oauth2/revoke","token_endpoint_auth_methods_supported":["none"],"code_challenge_methods_supported":["S256"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"scopes_supported":["openid","offline_access","mcp.tools"]}"#

private func response(status: Int = 200, json: String) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], data: Data(json.utf8))
}
private func metadataResponse() -> HTTPResponse { response(json: oauthMetadata) }
private func registrationResponse() -> HTTPResponse {
    response(status: 201, json: #"{"client_id":"synthetic-client","token_endpoint_auth_method":"none","redirect_uris":["http://127.0.0.1:43123/callback"]}"#)
}
private func tokenResponse() -> HTTPResponse {
    response(json: #"{"access_token":"synthetic-access","refresh_token":"synthetic-rotated-refresh","token_type":"Bearer","expires_in":3600}"#)
}
private func expiredCredentials() -> StoredOAuthCredentials {
    StoredOAuthCredentials(region: .china, issuer: COROSRegion.china.issuerURL, resource: COROSRegion.china.mcpURL,
                           connectionID: UUID(), clientID: "synthetic-client", accessToken: "synthetic-expired-access",
                           refreshToken: "synthetic-old-refresh", expiresAt: .distantPast)
}

private final class MemoryOAuthStore: OAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init() { }
    init(credentials: StoredOAuthCredentials) throws { data = try JSONEncoder().encode(credentials) }
    func read(region: COROSRegion) throws -> Data? { lock.withLock { data } }
    func save(_ data: Data, region: COROSRegion) throws { lock.withLock { self.data = data } }
    func delete(region: COROSRegion) throws { lock.withLock { data = nil } }
    func storedCredentials() throws -> StoredOAuthCredentials? {
        try lock.withLock { try data.map { try JSONDecoder().decode(StoredOAuthCredentials.self, from: $0) } }
    }
}

private actor OAuthQueueTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private actor GatedRefreshTransport: HTTPTransport {
    private var tokenGate: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var tokenRequestCount = 0

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path == "/.well-known/oauth-authorization-server" { return metadataResponse() }
        if request.url?.path == "/oauth2/revoke" { return response(json: "{}") }
        guard request.url?.path == "/oauth2/token" else { throw URLError(.badURL) }
        tokenRequestCount += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if !isReleased { await withCheckedContinuation { tokenGate = $0 } }
        // Intentionally ignore task cancellation to test the session's own commit barrier.
        return tokenResponse()
    }

    func waitForTokenRequest() async {
        if tokenRequestCount > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func releaseTokenResponse() {
        isReleased = true
        tokenGate?.resume()
        tokenGate = nil
    }
}

@MainActor
private final class SyntheticOAuthBrowser: OAuthWebAuthenticating {
    private let wrongState: Bool
    private(set) var authorizationURL: URL?
    init(wrongState: Bool = false) { self.wrongState = wrongState }
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        authorizationURL = url
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return URL(string: "http://127.0.0.1:43123/callback?code=synthetic-code&state=\(wrongState ? "wrong" : state)")!
    }
    func cancel() { }
}

@MainActor
private final class PendingOAuthBrowser: OAuthWebAuthenticating {
    private var pending: CheckedContinuation<URL, any Error>?
    private var presentationWaiters: [CheckedContinuation<Void, Never>] = []
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            presentationWaiters.forEach { $0.resume() }
            presentationWaiters.removeAll()
        }
    }
    func waitUntilPresented() async {
        if pending != nil { return }
        await withCheckedContinuation { presentationWaiters.append($0) }
    }
    func cancel() {
        let current = pending
        pending = nil
        current?.resume(throwing: OAuthError.cancelled)
    }
}

private extension Data {
    func flatMapBytesToString() -> String { String(decoding: self, as: UTF8.self) }
}
