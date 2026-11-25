/// Strict reading of tool arguments: unknown fields and wrong types are refused before any
/// policy rule runs, whatever the client did with the schema.
///
/// A class, so that reading a quantity can also record that it was moved into its range
/// without every reader being `mutating`. One instance serves one call; the tool puts
/// `notices` before its data.
final class Arguments {
    private let values: [String: Value]
    private let place: String

    /// One sentence for each quantity that was moved into its range, in the order read.
    private(set) var notices: [String] = []

    init(_ values: [String: Value]?, allowed: Set<String>, place: String = "arguments") throws(Refusal) {
        let values = values ?? [:]
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Refusal(.inputInvalid, "unknown field \"\(ToolStandard.echo(unknown))\" in \(place)", allowed: "only the fields in the tool's input schema: \(allowed.sorted().joined(separator: ", "))")
        }
        self.values = values
        self.place = place
    }

    private func invalid(_ key: String, _ expected: String) -> Refusal {
        Refusal(.inputInvalid, "\(place).\(key) must be \(expected)", allowed: "values matching the tool's input schema")
    }

    func string(_ key: String) throws(Refusal) -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let text = value.stringValue else { throw invalid(key, "a string") }
        return text
    }

    func requiredString(_ key: String) throws(Refusal) -> String {
        guard let text = try string(key) else { throw invalid(key, "present") }
        return text
    }

    func integer(_ key: String) throws(Refusal) -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        // `intValue` also takes a whole number sent as 2.0, which JSON does not tell apart from 2.
        guard let number = value.intValue else { throw invalid(key, "an integer") }
        return number
    }

    /// Whether the caller gave `key` (a null counts as not given).
    func wasGiven(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        return !value.isNull
    }

    /// A quantity: a count, a size, a time. Outside its range it is moved to the nearest
    /// allowed value and `notices` says which value was used; nothing is refused for being
    /// too large or too small. `nil` when the argument was not given.
    func optionalQuantity(_ key: String, in range: ClosedRange<Int>) throws(Refusal) -> Int? {
        guard let asked = try integer(key) else { return nil }
        return ToolStandard.clamp(asked, to: range, argument: key, notices: &notices)
    }

    func quantity(_ key: String, default fallback: Int, in range: ClosedRange<Int>) throws(Refusal) -> Int {
        try optionalQuantity(key, in: range) ?? fallback
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    func page(defaultLimit: Int, limits: ClosedRange<Int>) throws(Refusal) -> (limit: Int, offset: Int) {
        (
            try quantity("limit", default: defaultLimit, in: limits),
            try quantity("offset", default: 0, in: ToolCatalog.offsetRange)
        )
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
        case .array(let items): self = .array(items.map(AuditValue.init))
        case .object(let fields): self = .object(fields.mapValues(AuditValue.init))
        }
    }
}
