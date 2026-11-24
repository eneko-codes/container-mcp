import MCP

/// Strict reading of tool arguments: unknown fields and wrong types are refused before any
/// policy rule runs, whatever the client did with the schema.
struct Arguments {
    private let values: [String: Value]
    private let place: String

    init(_ values: [String: Value]?, allowed: Set<String>, place: String = "arguments") throws(Refusal) {
        let values = values ?? [:]
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Refusal(.inputInvalid, "unknown field \"\(unknown)\" in \(place)", allowed: "only the fields in the tool's input schema: \(allowed.sorted().joined(separator: ", "))")
        }
        self.values = values
        self.place = place
    }

    private func invalid(_ key: String, _ expected: String) -> Refusal {
        Refusal(.inputInvalid, "\(place).\(key) must be \(expected)", allowed: "values matching the tool's input schema")
    }

    func string(_ key: String) throws(Refusal) -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        switch value {
        case .string(let text):
            return text
        case .data:
            // The SDK turns strings that look like data: URLs into binary values.
            throw Refusal(.inputInvalid, "\(place).\(key) looks like a data: URL", allowed: "plain text")
        default:
            throw invalid(key, "a string")
        }
    }

    func requiredString(_ key: String) throws(Refusal) -> String {
        guard let text = try string(key) else { throw invalid(key, "present") }
        return text
    }

    func integer(_ key: String) throws(Refusal) -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        if let number = value.intValue { return number }
        if let number = value.doubleValue, number == number.rounded(), let exact = Int(exactly: number) { return exact }
        throw invalid(key, "an integer")
    }

    func boolean(_ key: String, default fallback: Bool) throws(Refusal) -> Bool {
        guard let value = values[key], !value.isNull else { return fallback }
        guard let flag = value.boolValue else { throw invalid(key, "true or false") }
        return flag
    }

    func stringArray(_ key: String) throws(Refusal) -> [String] {
        guard let value = values[key], !value.isNull else { return [] }
        guard let items = value.arrayValue else { throw invalid(key, "an array of strings") }
        var result: [String] = []
        for (index, item) in items.enumerated() {
            guard case .string(let text) = item else { throw invalid("\(key)[\(index)]", "a string") }
            result.append(text)
        }
        return result
    }

    func objectArray(_ key: String, allowed: Set<String>) throws(Refusal) -> [Arguments] {
        guard let value = values[key], !value.isNull else { return [] }
        guard let items = value.arrayValue else { throw invalid(key, "an array of objects") }
        var result: [Arguments] = []
        for (index, item) in items.enumerated() {
            guard let object = item.objectValue else { throw invalid("\(key)[\(index)]", "an object") }
            result.append(try Arguments(object, allowed: allowed, place: "\(place).\(key)[\(index)]"))
        }
        return result
    }
}

extension AuditValue {
    init(_ value: Value) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .int(let number): self = .number(Double(number))
        case .double(let number): self = .number(number)
        case .string(let text): self = .string(text)
        case .data(let mimeType, let data): self = .string("<\(data.count) bytes of \(mimeType ?? "data")>")
        case .array(let items): self = .array(items.map(AuditValue.init))
        case .object(let fields): self = .object(fields.mapValues(AuditValue.init))
        }
    }
}
