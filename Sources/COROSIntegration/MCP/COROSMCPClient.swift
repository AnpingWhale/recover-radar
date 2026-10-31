import Foundation

/// A deliberately small COROS-specific client, not a general-purpose agent or MCP execution runtime.
public actor COROSMCPClient {
    public static let protocolVersion = "2025-06-18"
    public static let allowedToolNames: Set<String> = [
        "querySleepOverview", "querySleepHrv", "queryRestingHeartRate",
        "queryStressLevel", "queryTrainingLoadAssessment"
    ]

    private let endpoint: URL
    private let tokenProvider: any COROSAccessTokenProvider
    private let transport: any HTTPTransport
    private var initialized = false
    private var initialization: Task<Void, any Error>?
    private var catalog: [String: MCPTool]?

    public init(endpoint: URL, tokenProvider: any COROSAccessTokenProvider,
                transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    /// Discovers all pages without invoking a health tool. The caller may inspect raw schemas.
    @discardableResult
    public func discoverTools() async throws -> [MCPTool] {
        try await ensureInitialized()
        var tools = [MCPTool]()
        var names = Set<String>()
        var seenCursors = Set<String>()
        var cursor: String?
        for _ in 0..<20 {
            try Task.checkCancellation()
            let parameters = cursor.map { ["cursor": JSONValue.string($0)] } ?? [:]
            let response = try await rpc(method: "tools/list", parameters: parameters)
            guard let entries = response["tools"]?.arrayValue else { throw MCPClientError.invalidToolCatalog }
            for entry in entries {
                guard let name = entry["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 128,
                      let input = entry["inputSchema"], input.objectValue != nil,
                      names.insert(name).inserted else { throw MCPClientError.invalidToolCatalog }
                let description = entry["description"]?.stringValue
                let output = entry["outputSchema"] == .null ? nil : entry["outputSchema"]
                guard output == nil || output?.objectValue != nil else { throw MCPClientError.invalidToolCatalog }
                tools.append(MCPTool(name: name, description: description, inputSchema: input, outputSchema: output))
                guard tools.count <= 2_000 else { throw MCPClientError.paginationLimit }
            }
            if let next = response["nextCursor"] {
                guard let value = next.stringValue, !value.isEmpty, value.utf8.count <= 4_096,
                      seenCursors.insert(value).inserted else { throw MCPClientError.invalidToolCatalog }
                cursor = value
            } else {
                catalog = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
                return tools
            }
        }
        throw MCPClientError.paginationLimit
    }

    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard Self.allowedToolNames.contains(name) else { throw MCPClientError.toolNotAllowed }
        if catalog == nil { try await discoverTools() }
        guard let tool = catalog?[name] else { throw MCPClientError.toolUnavailable }
        try InputSchemaValidator.validate(arguments: arguments, schema: tool.inputSchema)
        let response = try await rpc(method: "tools/call", parameters: ["name": .string(name), "arguments": .object(arguments)])
        guard let entries = response["content"]?.arrayValue else { throw MCPClientError.malformedResponse }
        if let error = response["isError"], error.boolValue == nil { throw MCPClientError.malformedResponse }
        if response["isError"]?.boolValue == true { throw MCPClientError.toolFailure }
        let content = try entries.map { entry in
            guard let type = entry["type"]?.stringValue, !type.isEmpty else { throw MCPClientError.malformedResponse }
            if type == "text", entry["text"]?.stringValue == nil { throw MCPClientError.malformedResponse }
            return MCPContent(type: type, text: entry["text"]?.stringValue, rawValue: entry)
        }
        let structured = response["structuredContent"] == .null ? nil : response["structuredContent"]
        guard structured == nil || structured?.objectValue != nil else { throw MCPClientError.malformedResponse }
        return MCPToolResult(content: content, structuredContent: structured, isError: false)
    }

    private func ensureInitialized() async throws {
        if initialized { return }
        if let initialization { try await initialization.value; return }
        let task = Task { try await self.performInitialization() }
        initialization = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            initialized = true
            initialization = nil
        } catch {
            initialization = nil
            throw error
        }
    }

    private func performInitialization() async throws {
        let result = try await rpc(method: "initialize", parameters: [
            "protocolVersion": .string(Self.protocolVersion), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("RecoverRadar"), "version": .string("0.1.0")])
        ])
        guard result["protocolVersion"]?.stringValue == Self.protocolVersion else {
            throw MCPClientError.unsupportedProtocolVersion
        }
        guard result["capabilities"]?["tools"]?.objectValue != nil else { throw MCPClientError.toolsNotSupported }
        // COROS documents a stateless lifecycle and explicitly omits notifications/initialized.
        // Do not infer a session, follow server instructions, or enable further capabilities.
    }

    private func rpc(method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        let hosts = ["mcp.coros.com", "mcpcn.coros.com", "mcpeu.coros.com", "mcpus.coros.com"]
        guard endpoint.scheme?.lowercased() == "https", hosts.contains(endpoint.host?.lowercased() ?? ""),
              endpoint.path == "/mcp", endpoint.port == nil || endpoint.port == 443,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw MCPClientError.invalidEndpoint
        }
        let requestID = JSONValue.string(UUID().uuidString)
        let body = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": requestID, "method": .string(method), "params": .object(parameters)
        ]))
        var refreshed = false
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            let token = try await tokenProvider.accessToken()
            guard !token.isEmpty, token.utf8.count <= 32_768,
                  token.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else {
                throw MCPClientError.invalidAccessToken
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if method != "initialize" { request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            let response = try await transport.send(request)
            if response.statusCode == 401, !refreshed {
                refreshed = true
                try await tokenProvider.invalidateAccessToken()
                continue
            }
            if retryCount < 2, let delay = HTTPRetryPolicy.delay(for: response, attempt: retryCount) {
                retryCount += 1
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200...299).contains(response.statusCode) else { throw MCPClientError.httpStatus(response.statusCode) }
            guard response.data.count <= 4 * 1_024 * 1_024 else { throw HTTPTransportError.responseTooLarge }
            return try Self.decode(response: response, expectedID: requestID)
        }
    }

    static func decode(response: HTTPResponse, expectedID: JSONValue) throws -> JSONValue {
        let mediaType = response.header("Content-Type")?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        if mediaType == "application/json" {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: response.data) else {
                throw MCPClientError.malformedResponse
            }
            return try result(from: message, expectedID: expectedID)
        }
        guard mediaType == "text/event-stream" else { throw MCPClientError.unsupportedContentType }
        var parser = SSEEventParser()
        for byte in response.data {
            guard let frame = try parser.append(byte) else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: frame), message.objectValue != nil,
                  message["jsonrpc"]?.stringValue == "2.0" else { throw MCPClientError.malformedResponse }
            // Notifications are protocol data. No server method or request is executed by this client.
            if message["method"] != nil { continue }
            return try result(from: message, expectedID: expectedID)
        }
        throw MCPClientError.missingResponse
    }

    private static func result(from message: JSONValue, expectedID: JSONValue) throws -> JSONValue {
        guard message.objectValue != nil, message["jsonrpc"]?.stringValue == "2.0", message["method"] == nil else {
            throw MCPClientError.malformedResponse
        }
        guard message["id"] == expectedID else { throw MCPClientError.mismatchedResponseID }
        guard (message["error"] == nil) != (message["result"] == nil) else { throw MCPClientError.malformedResponse }
        if let error = message["error"] {
            guard let number = error["code"]?.numberValue, number.isFinite, number.rounded() == number,
                  number >= Double(Int32.min), number <= Double(Int32.max) else { throw MCPClientError.malformedResponse }
            throw MCPClientError.rpcError(Int(number))
        }
        guard let result = message["result"], result.objectValue != nil else { throw MCPClientError.malformedResponse }
        return result
    }
}
