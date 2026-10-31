import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum HTTPTransportError: Error, Equatable, Sendable {
    case insecureURL
    case invalidResponse
    case responseTooLarge
    case redirectRefused
}

/// Bounded, cookie-free transport. POSTs are never automatically replayed here:
/// OAuth code exchange, registration and rotating refresh tokens are not idempotent.
public struct URLSessionHTTPTransport: HTTPTransport {
    public let timeout: TimeInterval
    public let maximumResponseBytes: Int
    public let maximumRetries: Int

    public init(timeout: TimeInterval = 30, maximumResponseBytes: Int = 4 * 1_024 * 1_024,
                maximumRetries: Int = 2) {
        self.timeout = timeout.isFinite ? min(max(timeout, 1), 120) : 30
        self.maximumResponseBytes = min(max(maximumResponseBytes, 1), 16 * 1_024 * 1_024)
        self.maximumRetries = min(max(maximumRetries, 0), 2)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw HTTPTransportError.insecureURL }
        let method = (request.httpMethod ?? "GET").uppercased()
        let canRetry = method == "GET" || method == "HEAD"
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let response = try await sendOnce(request)
            guard canRetry, attempt < maximumRetries,
                  let delay = HTTPRetryPolicy.delay(for: response, attempt: attempt) else { return response }
            try await Task.sleep(for: .seconds(delay))
            attempt += 1
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        // Unlike an idle timeout, this also bounds an SSE stream sending endless keep-alives.
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: RefuseRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var boundedRequest = request
        boundedRequest.timeoutInterval = timeout
        let (bytes, rawResponse) = try await session.bytes(for: boundedRequest)
        guard let response = rawResponse as? HTTPURLResponse else { throw HTTPTransportError.invalidResponse }
        if (300...399).contains(response.statusCode) { throw HTTPTransportError.redirectRefused }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw HTTPTransportError.responseTooLarge
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String { result[key] = String(describing: item.value) }
        }
        let isSSE = response.mimeType?.lowercased() == "text/event-stream"
        let expectedID = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?["id"]
        var parser = SSEEventParser()
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
            guard data.count < maximumResponseBytes else { throw HTTPTransportError.responseTooLarge }
            data.append(byte)
            if isSSE, let frame = try parser.append(byte), let expectedID,
               let message = try? JSONDecoder().decode(JSONValue.self, from: frame),
               message["id"] == expectedID, message["method"] == nil,
               message["result"] != nil || message["error"] != nil {
                // A valid POST response ends this exchange, even if the server leaves its SSE stream open.
                break
            }
        }
        try Task.checkCancellation()
        return HTTPResponse(statusCode: response.statusCode, headers: headers, data: data)
    }
}

private final class RefuseRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum HTTPRetryPolicy {
    static func delay(for response: HTTPResponse, attempt: Int, now: Date = Date()) -> TimeInterval? {
        guard [429, 500, 502, 503, 504].contains(response.statusCode) else { return nil }
        if let value = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces) {
            let seconds: TimeInterval?
            if let numeric = Double(value), numeric.isFinite, numeric >= 0 { seconds = numeric }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                seconds = formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
            }
            // Do not retry sooner than the server asks. Long waits are left to the next user sync.
            guard let seconds, seconds <= 30 else { return nil }
            return seconds
        }
        return min(pow(2, Double(attempt)), 4)
    }
}
