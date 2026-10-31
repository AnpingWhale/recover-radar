import AppKit
import Foundation

@MainActor
public protocol OAuthWebAuthenticating: Sendable {
    /// Reserve the callback before registration so the exact same URI is used throughout OAuth.
    func prepareCallback() async throws -> URL
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL
    func cancel()
}

public extension OAuthWebAuthenticating {
    /// Test doubles can use the official helper's fixed callback without opening a listener.
    func prepareCallback() async throws -> URL { OAuthProtocol.redirectURI }
}

/// Uses the user's system browser with a short-lived IPv4 loopback callback.
/// COROS CN rejected the custom application scheme during the public DCR compatibility check.
@MainActor
public final class BrowserAuthenticator: OAuthWebAuthenticating {
    private let callbackServer: LoopbackCallbackServer
    private var callback: URL?

    public init() { callbackServer = LoopbackCallbackServer() }

    public func prepareCallback() async throws -> URL {
        let url = try await callbackServer.start()
        callback = url
        return url
    }

    public func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callbackURLScheme == "http", let callback,
              query.first(where: { $0.name == "redirect_uri" })?.value == callback.absoluteString,
              let state = query.first(where: { $0.name == "state" })?.value, !state.isEmpty
        else { throw OAuthError.invalidCallback }
        return try await callbackServer.waitForCallback(expectedState: state) {
            NSWorkspace.shared.open(url)
        }
    }

    public func cancel() {
        callback = nil
        callbackServer.cancel()
    }
}
