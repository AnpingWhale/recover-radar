import Foundation
import Network

/// HTTP is limited to an ephemeral 127.0.0.1 callback, as allowed for native OAuth (RFC 8252).
/// All COROS requests and the browser authorization URL still use HTTPS.
@MainActor
final class LoopbackCallbackServer {
    private let timeout: TimeInterval
    private var listener: NWListener?
    private var operationID: UUID?
    private var callbackURL: URL?
    private var expectedState: String?
    private var preparation: CheckedContinuation<URL, any Error>?
    private var completion: CheckedContinuation<URL, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var connectionTimeouts: [UUID: Task<Void, Never>] = [:]

    init(timeout: TimeInterval = 300) { self.timeout = max(0.05, min(timeout, 300)) }

    func start() async throws -> URL {
        guard listener == nil else { throw OAuthError.authorizationInProgress }
        try Task.checkCancellation()
        let id = UUID()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: .any) }
        catch { throw OAuthError.loopbackUnavailable }
        self.listener = listener
        operationID = id
        listener.newConnectionLimit = 16
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.operationID == id else { return }
                switch state {
                case .ready:
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback")
                    else { self.finish(.failure(OAuthError.loopbackUnavailable)); return }
                    self.callbackURL = url
                    let pending = self.preparation
                    self.preparation = nil
                    pending?.resume(returning: url)
                case .failed: self.finish(.failure(OAuthError.loopbackUnavailable))
                case .cancelled: self.finish(.failure(OAuthError.cancelled))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.operationID == id else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                preparation = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.timeout ?? 300)) } catch { return }
                    guard self?.operationID == id else { return }
                    self?.finish(.failure(OAuthError.authorizationTimedOut))
                }
                listener.start(queue: .main)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.operationID == id else { return }
                self?.cancel()
            }
        }
    }

    func waitForCallback(expectedState: String, openBrowser: @MainActor () -> Bool) async throws -> URL {
        guard let id = operationID, callbackURL != nil, completion == nil,
              !expectedState.isEmpty else { throw OAuthError.loopbackUnavailable }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.expectedState = expectedState
                completion = continuation
                if !openBrowser() { finish(.failure(OAuthError.browserUnavailable)) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.operationID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(OAuthError.cancelled)) }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8, completion != nil else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connectionTimeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.closeConnection(id)
        }
        connection.start(queue: .main)
        receive(connection, id: id, buffered: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_193 - buffered.count) { [weak self] content, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var data = buffered
                if let content { data.append(content) }
                guard data.count <= 8_192 else { self.respond(connection, id: id, status: 431); return }
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard let callbackURL = self.callbackURL, let expectedState = self.expectedState,
                          let callback = LoopbackHTTPRequest.callback(from: data, redirectURI: callbackURL, expectedState: expectedState)
                    else { self.respond(connection, id: id, status: 400); return }
                    self.respond(connection, id: id, status: 200)
                    self.finish(.success(callback))
                } else if complete || error != nil {
                    self.closeConnection(id)
                } else {
                    self.receive(connection, id: id, buffered: data)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, status: Int) {
        let body = status == 200 ? "COROS 授权回调已收到。请返回 Recovery Radar 查看连接结果。" : "Invalid authorization callback."
        let content = Data(body.utf8)
        let reason = status == 200 ? "OK" : (status == 431 ? "Request Header Fields Too Large" : "Bad Request")
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        var response = Data(header.utf8)
        response.append(content)
        connections.removeValue(forKey: id)
        connectionTimeouts.removeValue(forKey: id)?.cancel()
        // Let the final response flush before closing the winning connection.
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func closeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        connectionTimeouts.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<URL, any Error>) {
        operationID = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        callbackURL = nil
        expectedState = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        for id in Array(connections.keys) { closeConnection(id) }
        let preparing = preparation
        let waiting = completion
        preparation = nil
        completion = nil
        preparing?.resume(with: result)
        waiting?.resume(with: result)
    }
}

/// This small parser accepts exactly the browser's GET callback, not a general HTTP server.
enum LoopbackHTTPRequest {
    static func callback(from data: Data, redirectURI: URL, expectedState: String) -> URL? {
        guard data.count <= 8_192, let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n"), headerEnd.upperBound == text.endIndex else { return nil }
        let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              request[1].hasPrefix("/callback?"), !request[1].contains("#") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let name = String(line[..<colon]).lowercased()
            guard name.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "-" }),
                  headers[name] == nil else { return nil }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let port = redirectURI.port, headers["host"] == "127.0.0.1:\(port)",
              headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0",
              let url = URL(string: "http://127.0.0.1:\(port)\(request[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == "/callback", components.fragment == nil else { return nil }
        let query = components.queryItems ?? []
        let states = query.filter { $0.name == "state" }
        guard states.count == 1, let state = states[0].value,
              OAuthProtocol.constantTimeEqual(state, expectedState),
              query.filter({ $0.name == "code" }).count <= 1,
              query.filter({ $0.name == "error" }).count <= 1,
              query.contains(where: { ($0.name == "code" || $0.name == "error") && !($0.value ?? "").isEmpty })
        else { return nil }
        return url
    }
}
