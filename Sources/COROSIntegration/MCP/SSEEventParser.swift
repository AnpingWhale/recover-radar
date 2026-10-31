import Foundation

/// Incremental UTF-8 SSE framing; line and code point boundaries may span arbitrary network chunks.
/// Only a blank line dispatches an event. An unterminated final event is deliberately not accepted.
struct SSEEventParser {
    private var line = Data()
    private var fields = [String]()
    private var lastWasCR = false
    private var firstLine = true

    mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 10, lastWasCR { lastWasCR = false; return nil }
        if byte == 10 || byte == 13 {
            lastWasCR = byte == 13
            guard var text = String(data: line, encoding: .utf8) else { throw MCPClientError.malformedResponse }
            line.removeAll(keepingCapacity: true)
            if firstLine { text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text; firstLine = false }
            if text.isEmpty {
                guard !fields.isEmpty else { return nil }
                let payload = fields.joined(separator: "\n")
                fields.removeAll(keepingCapacity: true)
                return Data(payload.utf8)
            }
            guard !text.hasPrefix(":") else { return nil }
            let components = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if components[0] == "data" {
                let value = components.count == 2 ? String(components[1]) : ""
                fields.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
            }
            return nil
        }
        lastWasCR = false
        line.append(byte)
        return nil
    }
}
