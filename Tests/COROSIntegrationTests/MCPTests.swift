import Foundation
import Testing
@testable import COROSIntegration

private let daySchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object(["days": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(31)])]),
    "required": .array([.string("days")]), "additionalProperties": .bool(false)
])

private func initializedResult(version: String = COROSMCPClient.protocolVersion) -> JSONValue {
    .object(["protocolVersion": .string(version), "capabilities": .object(["tools": .object([:])])])
}

private func catalogResult(cursor: String? = nil, name: String = "querySleepOverview") -> JSONValue {
    var result: [String: JSONValue] = ["tools": .array([.object([
        "name": .string(name), "inputSchema": daySchema, "description": .string("Synthetic tool contract")
    ])])]
    if let cursor { result["nextCursor"] = .string(cursor) }
    return .object(result)
}

private func reply(_ request: URLRequest, result: JSONValue) throws -> HTTPResponse {
    let requestJSON = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    let body: JSONValue = .object(["jsonrpc": .string("2.0"), "id": try #require(requestJSON["id"]), "result": result])
    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], data: try JSONEncoder().encode(body))
}

private actor ScriptedMCPTransport: HTTPTransport {
    private var requests = [URLRequest]()
    let handler: @Sendable (URLRequest, Int) throws -> HTTPResponse
    init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> HTTPResponse) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        return try handler(request, requests.count)
    }
    func recorded() -> [URLRequest] { requests }
}

private actor SyntheticTokenProvider: COROSAccessTokenProvider {
    private var invalidations = 0
    func accessToken() async throws -> String { invalidations == 0 ? "synthetic-original" : "synthetic-refreshed" }
    func invalidateAccessToken() async throws { invalidations += 1 }
    func count() -> Int { invalidations }
}

private actor BlockingMCPTransport: HTTPTransport {
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        started = true
        observer?.resume()
        observer = nil
        try await Task.sleep(for: .seconds(20))
        return HTTPResponse(statusCode: 500, headers: [:], data: Data())
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
}

private func client(transport: any HTTPTransport, tokens: SyntheticTokenProvider = SyntheticTokenProvider()) -> COROSMCPClient {
    COROSMCPClient(endpoint: URL(string: "https://mcpcn.coros.com/mcp")!, tokenProvider: tokens, transport: transport)
}

@Test func jsonRoundTripKeepsTypesAndUnicode() throws {
    let value: JSONValue = .object(["boolean": .bool(true), "number": .number(1), "null": .null,
                                    "list": .array([.string("睡眠"), .number(2.5)])])
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == value)
    #expect(value["boolean"]?.numberValue == nil)
    #expect(value["number"]?.boolValue == nil)
}

@Test func discoveryPaginatesAndDoesNotSendInitializedNotification() async throws {
    let transport = ScriptedMCPTransport { request, count in
        switch count {
        case 1: try reply(request, result: initializedResult())
        case 2: try reply(request, result: catalogResult(cursor: "next-page"))
        default: try reply(request, result: catalogResult(name: "querySleepHrv"))
        }
    }
    let tools = try await client(transport: transport).discoverTools()
    #expect(tools.map(\.name) == ["querySleepOverview", "querySleepHrv"])
    let requests = await transport.recorded()
    #expect(requests.count == 3)
    let messages = try requests.map { try JSONDecoder().decode(JSONValue.self, from: #require($0.httpBody)) }
    #expect(messages.map { $0["method"]?.stringValue } == ["initialize", "tools/list", "tools/list"])
    #expect(messages[2]["params"]?["cursor"] == .string("next-page"))
    #expect(requests[0].value(forHTTPHeaderField: "MCP-Protocol-Version") == nil)
    #expect(requests[1].value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
}

@Test func writeToolRejectedBeforeAnyNetworkOrTokenRequest() async {
    let transport = ScriptedMCPTransport { _, _ in throw MCPClientError.malformedResponse }
    await #expect(throws: MCPClientError.toolNotAllowed) {
        try await client(transport: transport).callTool(name: "createSingleWorkout", arguments: [:])
    }
    #expect(await transport.recorded().isEmpty)
}

@Test func toolCallRequiresDiscoveredAndValidatedArguments() async throws {
    let transport = ScriptedMCPTransport { request, count in
        try reply(request, result: count == 1 ? initializedResult() : catalogResult())
    }
    let service = client(transport: transport)
    await #expect(throws: MCPClientError.invalidArguments) {
        try await service.callTool(name: "querySleepOverview", arguments: ["days": .number(32)])
    }
    await #expect(throws: MCPClientError.invalidArguments) {
        try await service.callTool(name: "querySleepOverview", arguments: ["days": .number(7), "execute": .string("anything")])
    }
    await #expect(throws: MCPClientError.toolUnavailable) {
        try await service.callTool(name: "queryStressLevel", arguments: ["days": .number(7)])
    }
    #expect(await transport.recorded().count == 2)
}

@Test func ordinaryTextIsPreservedWithoutInventingJSON() async throws {
    let transport = ScriptedMCPTransport { request, count in
        let result: JSONValue
        if count == 1 { result = initializedResult() }
        else if count == 2 { result = catalogResult() }
        else { result = .object(["content": .array([.object(["type": .string("text"), "text": .string("Synthetic sleep summary — no numeric contract")])]), "structuredContent": .null]) }
        return try reply(request, result: result)
    }
    let result = try await client(transport: transport).callTool(name: "querySleepOverview", arguments: ["days": .number(7)])
    #expect(result.textContent == ["Synthetic sleep summary — no numeric contract"])
    #expect(result.structuredContent == nil)
}

@Test func unauthorizedRefreshIsBoundedToOneRetry() async {
    let tokens = SyntheticTokenProvider()
    let transport = ScriptedMCPTransport { _, _ in HTTPResponse(statusCode: 401, headers: [:], data: Data()) }
    await #expect(throws: MCPClientError.httpStatus(401)) { try await client(transport: transport, tokens: tokens).discoverTools() }
    #expect(await tokens.count() == 1)
    let requests = await transport.recorded()
    #expect(requests.count == 2)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-original")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-refreshed")
}

@Test func rateLimitRetriesAreBoundedAndHonorLongRetryAfter() async {
    let transport = ScriptedMCPTransport { _, _ in
        HTTPResponse(statusCode: 429, headers: ["Retry-After": "0"], data: Data())
    }
    await #expect(throws: MCPClientError.httpStatus(429)) { try await client(transport: transport).discoverTools() }
    #expect(await transport.recorded().count == 3)
    let longWait = HTTPResponse(statusCode: 429, headers: ["rEtRy-AfTeR": "3600"], data: Data())
    #expect(HTTPRetryPolicy.delay(for: longWait, attempt: 0) == nil)
    let now = Date(timeIntervalSince1970: 1_445_412_470)
    let dated = HTTPResponse(statusCode: 429, headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"], data: Data())
    #expect(HTTPRetryPolicy.delay(for: dated, attempt: 0, now: now) == 10)
}

@Test func differentProtocolAndRepeatedPaginationFailClosed() async {
    let wrongProtocol = ScriptedMCPTransport { request, _ in try reply(request, result: initializedResult(version: "2099-01-01")) }
    await #expect(throws: MCPClientError.unsupportedProtocolVersion) { try await client(transport: wrongProtocol).discoverTools() }
    let repeated = ScriptedMCPTransport { request, count in
        try reply(request, result: count == 1 ? initializedResult() : catalogResult(cursor: "same", name: "tool\(count)"))
    }
    await #expect(throws: MCPClientError.invalidToolCatalog) { try await client(transport: repeated).discoverTools() }
}

@Test func sseHandlesByteBoundariesCRLFCommentsAndMultipleDataLines() throws {
    let source = "\u{FEFF}: keep-alive\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\n"
        + "data: {\"jsonrpc\":\"2.0\",\"id\":\"synthetic-id\",\r\ndata: \"result\":{\"text\":\"睡眠\"}}\r\n\r\n"
    let response = HTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream; charset=utf-8"], data: Data(source.utf8))
    #expect(try COROSMCPClient.decode(response: response, expectedID: .string("synthetic-id"))["text"] == .string("睡眠"))
}

@Test func sseDoesNotAcceptAnUnterminatedEventOrWrongResponseID() throws {
    let unterminated = HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"],
                                    data: Data("data: {\"jsonrpc\":\"2.0\",\"id\":\"id\",\"result\":{}}\n".utf8))
    #expect(throws: MCPClientError.missingResponse) { try COROSMCPClient.decode(response: unterminated, expectedID: .string("id")) }
    let wrongID = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                              data: Data("{\"jsonrpc\":\"2.0\",\"id\":\"wrong\",\"result\":{}}".utf8))
    #expect(throws: MCPClientError.mismatchedResponseID) { try COROSMCPClient.decode(response: wrongID, expectedID: .string("id")) }
}

@Test func rpcAndToolErrorsRemainDistinct() async throws {
    let error = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"],
                            data: Data("{\"jsonrpc\":\"2.0\",\"id\":\"id\",\"error\":{\"code\":-32602,\"message\":\"Synthetic failure\"}}".utf8))
    #expect(throws: MCPClientError.rpcError(-32602)) { try COROSMCPClient.decode(response: error, expectedID: .string("id")) }
    let transport = ScriptedMCPTransport { request, count in
        try reply(request, result: count == 1 ? initializedResult() : count == 2 ? catalogResult() : .object([
            "content": .array([.object(["type": .string("text"), "text": .string("Synthetic tool error")])]), "isError": .bool(true)
        ]))
    }
    await #expect(throws: MCPClientError.toolFailure) { try await client(transport: transport).callTool(name: "querySleepOverview", arguments: ["days": .number(7)]) }
}

@Test func schemaRejectsUnknownConstraintsAndMissingRequiredValues() throws {
    #expect(throws: MCPClientError.invalidArguments) { try InputSchemaValidator.validate(arguments: [:], schema: daySchema) }
    #expect(throws: MCPClientError.invalidArguments) { try InputSchemaValidator.validate(arguments: ["days": .number(1.2)], schema: daySchema) }
    #expect(throws: MCPClientError.unsupportedInputSchema) {
        try InputSchemaValidator.validate(arguments: [:], schema: .object(["type": .string("object"), "$ref": .string("external")]))
    }
}

@Test func cancellationPropagatesIntoInitializationRequest() async {
    let transport = BlockingMCPTransport()
    let task = Task { try await client(transport: transport).discoverTools() }
    await transport.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func nullableSchemaAndLocalReferencesValidateBeforeCalling() throws {
    let schema: JSONValue = .object([
        "type": .string("object"), "properties": .object([
            "days": .object(["anyOf": .array([
                .object(["$ref": .string("#/$defs/positiveDays")]), .object(["type": .string("null")])
            ])])
        ]), "$defs": .object([
            "positiveDays": .object(["type": .string("integer"), "format": .string("int32"), "minimum": .number(1)])
        ])
    ])
    try InputSchemaValidator.validate(arguments: ["days": .number(31)], schema: schema)
    try InputSchemaValidator.validate(arguments: ["days": .null], schema: schema)
    #expect(throws: MCPClientError.invalidArguments) { try InputSchemaValidator.validate(arguments: ["days": .number(0)], schema: schema) }
    #expect(throws: MCPClientError.invalidArguments) { try InputSchemaValidator.validate(arguments: ["days": .number(2_147_483_648)], schema: schema) }
    let recursive: JSONValue = .object([
        "$ref": .string("#/$defs/cycle"), "$defs": .object(["cycle": .object(["$ref": .string("#/$defs/cycle")])])
    ])
    #expect(throws: MCPClientError.unsupportedInputSchema) { try InputSchemaValidator.validate(arguments: [:], schema: recursive) }
}

@Test func oneOfRejectsAmbiguityAndAllOfCombinesBounds() throws {
    let schema: JSONValue = .object(["type": .string("object"), "properties": .object([
        "days": .object(["oneOf": .array([
            .object(["type": .string("integer")]), .object(["type": .string("number")])
        ])])
    ])])
    #expect(throws: MCPClientError.invalidArguments) { try InputSchemaValidator.validate(arguments: ["days": .number(7)], schema: schema) }
    try InputSchemaValidator.validate(arguments: ["days": .number(7.5)], schema: schema)
    let bounded: JSONValue = .object(["type": .string("object"), "properties": .object([
        "days": .object(["allOf": .array([.object(["minimum": .number(1)]), .object(["maximum": .number(31)])])])
    ])])
    #expect(throws: MCPClientError.invalidArguments) { try InputSchemaValidator.validate(arguments: ["days": .number(32)], schema: bounded) }
}

@Test func schemaFormatsValidateCalendarDatesAndNumericBoundaries() throws {
    func formatted(_ format: String, type: String) -> JSONValue {
        .object(["type": .string("object"), "properties": .object([
            "value": .object(["type": .string(type), "format": .string(format)])
        ])])
    }
    try InputSchemaValidator.validate(arguments: ["value": .string("2024-02-29")], schema: formatted("date", type: "string"))
    #expect(throws: MCPClientError.invalidArguments) {
        try InputSchemaValidator.validate(arguments: ["value": .string("2025-02-29")], schema: formatted("date", type: "string"))
    }
    try InputSchemaValidator.validate(arguments: ["value": .string("2026-10-30T12:30:00.123+08:00")], schema: formatted("date-time", type: "string"))
    #expect(throws: MCPClientError.invalidArguments) {
        try InputSchemaValidator.validate(arguments: ["value": .string("2026-10-30T12:30:00")], schema: formatted("date-time", type: "string"))
    }
    try InputSchemaValidator.validate(arguments: ["value": .number(-9_223_372_036_854_775_808)], schema: formatted("int64", type: "integer"))
    #expect(throws: MCPClientError.invalidArguments) {
        try InputSchemaValidator.validate(arguments: ["value": .number(9_223_372_036_854_775_808)], schema: formatted("int64", type: "integer"))
    }
}
