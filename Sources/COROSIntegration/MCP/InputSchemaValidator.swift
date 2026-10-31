import Foundation

/// A conservative JSON Schema subset for the five scalar-parameter COROS read tools.
/// Unknown validation constructs fail closed; this is not advertised as a full JSON Schema engine.
enum InputSchemaValidator {
    static func validate(arguments: [String: JSONValue], schema: JSONValue) throws {
        guard let properties = try declaredProperties(schema, root: schema, depth: 0) else {
            throw MCPClientError.unsupportedInputSchema
        }
        // Even if a server allows additionalProperties, this app only sends explicitly advertised parameters.
        guard Set(arguments.keys).isSubset(of: properties) else { throw MCPClientError.invalidArguments }
        try check(.object(arguments), against: schema, root: schema, depth: 0)
    }

    private static func check(_ value: JSONValue, against schema: JSONValue, root: JSONValue, depth: Int) throws {
        guard depth <= 16, let definition = schema.objectValue else { throw MCPClientError.unsupportedInputSchema }
        let supported: Set<String> = [
            "$schema", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly",
            "type", "properties", "required", "additionalProperties", "enum", "const", "minimum", "maximum",
            "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "pattern",
            "items", "minItems", "maxItems", "uniqueItems", "minProperties", "maxProperties",
            "anyOf", "oneOf", "allOf", "$ref", "$defs", "definitions", "format"
        ]
        guard Set(definition.keys).isSubset(of: supported) else { throw MCPClientError.unsupportedInputSchema }
        if let reference = schema["$ref"] {
            try check(value, against: resolve(reference, root: root), root: root, depth: depth + 1)
        }
        for operation in ["anyOf", "oneOf", "allOf"] {
            guard let raw = schema[operation] else { continue }
            guard let alternatives = raw.arrayValue, !alternatives.isEmpty, alternatives.count <= 32 else {
                throw MCPClientError.unsupportedInputSchema
            }
            var matches = 0
            for alternative in alternatives {
                do {
                    try check(value, against: alternative, root: root, depth: depth + 1)
                    matches += 1
                } catch MCPClientError.invalidArguments { continue }
                // Unknown constraints in any branch must not silently become a successful match.
            }
            let valid = operation == "oneOf" ? matches == 1 : operation == "allOf" ? matches == alternatives.count : matches > 0
            guard valid else { throw MCPClientError.invalidArguments }
        }
        if let rawType = schema["type"] {
            let types: [String]
            if let type = rawType.stringValue { types = [type] }
            else if let list = rawType.arrayValue, list.allSatisfy({ $0.stringValue != nil }) {
                types = list.compactMap(\.stringValue)
            } else { throw MCPClientError.unsupportedInputSchema }
            guard !types.isEmpty, types.allSatisfy({ ["object", "array", "string", "number", "integer", "boolean", "null"].contains($0) }) else {
                throw MCPClientError.unsupportedInputSchema
            }
            guard types.contains(where: { matches(value, type: $0) }) else { throw MCPClientError.invalidArguments }
        }
        if let choices = schema["enum"] {
            guard let list = choices.arrayValue, !list.isEmpty else { throw MCPClientError.unsupportedInputSchema }
            guard list.contains(value) else { throw MCPClientError.invalidArguments }
        }
        if let constant = schema["const"], value != constant { throw MCPClientError.invalidArguments }
        switch value {
        case .object(let object):
            guard schema["properties"] == nil || schema["properties"]?.objectValue != nil else { throw MCPClientError.unsupportedInputSchema }
            let properties = schema["properties"]?.objectValue ?? [:]
            if let required = schema["required"] {
                guard let keys = required.arrayValue, keys.allSatisfy({ $0.stringValue != nil }) else { throw MCPClientError.unsupportedInputSchema }
                guard keys.compactMap(\.stringValue).allSatisfy({ object[$0] != nil }) else { throw MCPClientError.invalidArguments }
            }
            try range(Double(object.count), schema: schema, minimum: "minProperties", maximum: "maxProperties")
            for (key, item) in object {
                if let property = properties[key] { try check(item, against: property, root: root, depth: depth + 1) }
                else if let additional = schema["additionalProperties"] {
                    if additional == .bool(false) { throw MCPClientError.invalidArguments }
                    if additional != .bool(true) { try check(item, against: additional, root: root, depth: depth + 1) }
                }
            }
        case .array(let array):
            try range(Double(array.count), schema: schema, minimum: "minItems", maximum: "maxItems")
            if schema["uniqueItems"] == .bool(true), array.indices.contains(where: { array[..<$0].contains(array[$0]) }) {
                throw MCPClientError.invalidArguments
            }
            if let items = schema["items"] { for item in array { try check(item, against: items, root: root, depth: depth + 1) } }
        case .string(let string):
            try range(Double(string.unicodeScalars.count), schema: schema, minimum: "minLength", maximum: "maxLength")
            if let patternValue = schema["pattern"] {
                guard let pattern = patternValue.stringValue, pattern.utf8.count <= 512,
                      let expression = try? NSRegularExpression(pattern: pattern) else { throw MCPClientError.unsupportedInputSchema }
                // Inputs here are short date strings; bound both sides of the pattern match.
                guard string.utf8.count <= 4_096 else { throw MCPClientError.invalidArguments }
                guard expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else {
                    throw MCPClientError.invalidArguments
                }
            }
        case .number(let number):
            guard number.isFinite else { throw MCPClientError.invalidArguments }
            try range(number, schema: schema, minimum: "minimum", maximum: "maximum")
            if let bound = try numeric("exclusiveMinimum", schema), number <= bound { throw MCPClientError.invalidArguments }
            if let bound = try numeric("exclusiveMaximum", schema), number >= bound { throw MCPClientError.invalidArguments }
            if let divisor = try numeric("multipleOf", schema) {
                guard divisor > 0 else { throw MCPClientError.unsupportedInputSchema }
                let ratio = number / divisor
                guard ratio.isFinite, abs(ratio - ratio.rounded()) < 1e-9 else { throw MCPClientError.invalidArguments }
            }
        case .bool, .null: break
        }
        if let format = schema["format"] {
            guard let name = format.stringValue else { throw MCPClientError.unsupportedInputSchema }
            try checkFormat(name, value: value)
        }
    }

    private static func resolve(_ reference: JSONValue, root: JSONValue) throws -> JSONValue {
        guard let pointer = reference.stringValue, pointer.hasPrefix("#/"), pointer.utf8.count <= 4_096 else {
            throw MCPClientError.unsupportedInputSchema
        }
        var current = root
        for component in pointer.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = current[key] else { throw MCPClientError.unsupportedInputSchema }
            current = next
        }
        guard current.objectValue != nil else { throw MCPClientError.unsupportedInputSchema }
        return current
    }

    private static func declaredProperties(_ schema: JSONValue, root: JSONValue, depth: Int) throws -> Set<String>? {
        guard depth <= 16, schema.objectValue != nil else { throw MCPClientError.unsupportedInputSchema }
        var names: Set<String>?
        if schema["type"]?.stringValue == "object" || schema["properties"] != nil {
            guard schema["properties"] == nil || schema["properties"]?.objectValue != nil else {
                throw MCPClientError.unsupportedInputSchema
            }
            names = Set((schema["properties"]?.objectValue ?? [:]).keys)
        }
        if let reference = schema["$ref"], let referenced = try declaredProperties(resolve(reference, root: root), root: root, depth: depth + 1) {
            names = (names ?? []).union(referenced)
        }
        for operation in ["anyOf", "oneOf", "allOf"] {
            guard let raw = schema[operation] else { continue }
            guard let alternatives = raw.arrayValue, !alternatives.isEmpty, alternatives.count <= 32 else {
                throw MCPClientError.unsupportedInputSchema
            }
            for alternative in alternatives {
                if let found = try declaredProperties(alternative, root: root, depth: depth + 1) {
                    names = (names ?? []).union(found)
                }
            }
        }
        return names
    }

    private static func checkFormat(_ format: String, value: JSONValue) throws {
        switch format {
        case "int32", "int64":
            // Nullable alternatives may attach annotations beside the union.
            if value == .null { return }
            guard let number = value.numberValue, number.isFinite, number.rounded() == number else {
                throw MCPClientError.invalidArguments
            }
            let lower = format == "int32" ? -2_147_483_648.0 : -9_223_372_036_854_775_808.0
            let upperExclusive = format == "int32" ? 2_147_483_648.0 : 9_223_372_036_854_775_808.0
            guard number >= lower, number < upperExclusive else { throw MCPClientError.invalidArguments }
        case "date", "date-time":
            if value == .null { return }
            guard let string = value.stringValue else { throw MCPClientError.invalidArguments }
            if format == "date" {
                guard validDate(string) else { throw MCPClientError.invalidArguments }
            } else {
                let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#
                guard string.utf8.count <= 128, validDate(String(string.prefix(10))),
                      string.range(of: pattern, options: .regularExpression) != nil else { throw MCPClientError.invalidArguments }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = string.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
                guard formatter.date(from: string) != nil else { throw MCPClientError.invalidArguments }
            }
        default: throw MCPClientError.unsupportedInputSchema
        }
    }

    private static func validDate(_ string: String) -> Bool {
        guard string.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return false }
        let pieces = string.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, pieces[0] > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: components) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == components
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.object, "object"), (.array, "array"), (.string, "string"), (.number, "number"),
             (.bool, "boolean"), (.null, "null"): true
        case (.number(let number), "integer"): number.isFinite && number.rounded() == number
        default: false
        }
    }

    private static func numeric(_ key: String, _ schema: JSONValue) throws -> Double? {
        guard let value = schema[key] else { return nil }
        guard let number = value.numberValue, number.isFinite else { throw MCPClientError.unsupportedInputSchema }
        return number
    }

    private static func range(_ value: Double, schema: JSONValue, minimum: String, maximum: String) throws {
        if let lower = try numeric(minimum, schema), value < lower { throw MCPClientError.invalidArguments }
        if let upper = try numeric(maximum, schema), value > upper { throw MCPClientError.invalidArguments }
    }
}
