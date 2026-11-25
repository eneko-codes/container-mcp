/// Builders for JSON Schema input definitions. Every object schema closes itself with
/// `additionalProperties: false`, so clients see exactly which fields exist.
enum Schema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String, pattern: String? = nil, maxLength: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let pattern { schema["pattern"] = .string(pattern) }
        if let maxLength { schema["maxLength"] = .int(maxLength) }
        return .object(schema)
    }

    static func enumeration(_ description: String, _ values: [String]) -> Value {
        .object(["type": "string", "description": .string(description), "enum": .array(values.map { .string($0) })])
    }

    /// A `default` is advertised only where leaving the argument out really means that value.
    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil, default fallback: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        if let fallback { schema["default"] = .int(fallback) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> Value {
        .object(["type": "boolean", "description": .string(description)])
    }

    static func array(_ items: Value, _ description: String, maxItems: Int) -> Value {
        .object(["type": "array", "description": .string(description), "items": items, "maxItems": .int(maxItems)])
    }

    static let containerID = string("Container name or ID.", pattern: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, maxLength: 63)
    static let environment = array(
        string("KEY=value. The key-only form, which would copy a value from the host, is refused.", pattern: "^[A-Za-z_][A-Za-z0-9_]*=", maxLength: 16_384),
        "Environment variables as KEY=value entries.", maxItems: 256)
    static let arguments = array(string("One argument. Never parsed by a shell.", maxLength: 16_384), "Argument array; the first element is the executable.", maxItems: 256)
}
