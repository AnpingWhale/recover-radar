import Foundation

public struct MCPTool: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?

    public init(name: String, description: String? = nil, inputSchema: JSONValue, outputSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

/// Non-text content is retained as protocol data, never followed as a URL or executed.
public struct MCPContent: Equatable, Sendable {
    public let type: String
    public let text: String?
    public let rawValue: JSONValue

    public init(type: String, text: String? = nil, rawValue: JSONValue = .null) {
        self.type = type
        self.text = text
        self.rawValue = rawValue
    }
}

public struct MCPToolResult: Equatable, Sendable {
    public let content: [MCPContent]
    public let structuredContent: JSONValue?
    public let isError: Bool
    public var textContent: [String] { content.compactMap { $0.type == "text" ? $0.text : nil } }

    public init(content: [MCPContent], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

/// Errors intentionally omit response bodies and server-supplied error text, which can contain health data.
public enum MCPClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidAccessToken
    case httpStatus(Int)
    case unsupportedContentType
    case malformedResponse
    case mismatchedResponseID
    case missingResponse
    case rpcError(Int)
    case unsupportedProtocolVersion
    case toolsNotSupported
    case invalidToolCatalog
    case paginationLimit
    case toolNotAllowed
    case toolUnavailable
    case unsupportedInputSchema
    case invalidArguments
    case toolFailure
}

extension MCPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "COROS 服务地址不受支持。"
        case .invalidAccessToken: "COROS 凭证无效，请重新连接。"
        case .httpStatus(let status): "COROS 请求失败（HTTP \(status)）。"
        case .unsupportedProtocolVersion: "COROS 返回了当前应用不支持的协议版本。"
        case .toolNotAllowed: "此应用只允许读取五项恢复指标。"
        case .toolUnavailable, .toolsNotSupported: "COROS 当前未提供所需的读取工具。"
        case .unsupportedInputSchema, .invalidArguments: "COROS 工具参数契约不兼容，未发送数据请求。"
        case .toolFailure: "COROS 工具报告查询失败。"
        case .rpcError(let code): "COROS 协议请求失败（\(code)）。"
        default: "COROS 响应格式未通过校验，请稍后重试。"
        }
    }
}
