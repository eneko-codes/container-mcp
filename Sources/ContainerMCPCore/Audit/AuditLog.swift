import Darwin
import Foundation

/// One JSON line per tool call, appended to a file only the user can read. Refusals and
/// failures are logged as well as successes.
public actor AuditLog {
    public enum Decision: String, Sendable, Codable {
        case allowed, refused, failed
    }

    public struct Entry: Sendable, Codable, Equatable {
        public var time: String
        public var tool: String
        public var arguments: AuditValue
        public var decision: Decision
        /// The rule that refused the call, or `policy` when every rule allowed it.
        public var rule: String
        public var result: String
    }

    private let path: String?
    private var memory: [Entry] = []

    /// `path` nil keeps entries in memory only, for tests.
    public init(path: String?) {
        self.path = path
    }

    public var recordedEntries: [Entry] { memory }

    public func record(tool: String, arguments: AuditValue, decision: Decision, rule: String, result: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Entry(
            time: formatter.string(from: Date()), tool: tool, arguments: arguments.redacted(), decision: decision,
            rule: rule, result: String(result.prefix(500)))
        memory.append(entry)
        guard let path else { return }
        do {
            try append(entry, to: path)
        } catch {
            // The audit log must never take the server down; the failure goes to stderr.
            FileHandle.standardError.write(Data("container-mcp: cannot write audit log: \(error)\n".utf8))
        }
    }

    private func append(_ entry: Entry, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        // O_APPEND makes every write land at the end, even if something else has the file open.
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// A JSON value for audit entries, with redaction of secrets built in.
public indirect enum AuditValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AuditValue])
    case object([String: AuditValue])

    /// Fields whose entries are `KEY=value` pairs: the values are replaced, the keys kept.
    static let keyValueFields: Set<String> = ["env", "build_args"]

    public func redacted() -> AuditValue {
        switch self {
        case .object(let fields):
            var result: [String: AuditValue] = [:]
            for (key, value) in fields {
                if Self.keyValueFields.contains(key), case .array(let entries) = value {
                    result[key] = .array(entries.map(Self.redactPair))
                } else {
                    result[key] = value.redacted()
                }
            }
            return .object(result)
        case .array(let items):
            return .array(items.map { $0.redacted() })
        default:
            return self
        }
    }

    static func redactPair(_ value: AuditValue) -> AuditValue {
        guard case .string(let entry) = value else { return .string("<redacted>") }
        guard let equals = entry.firstIndex(of: "=") else { return .string(entry) }
        return .string(entry[..<equals] + "=<redacted>")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AuditValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AuditValue].self))
        }
    }
}
