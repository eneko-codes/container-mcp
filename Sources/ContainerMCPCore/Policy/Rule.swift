import Foundation

/// Every reason the server can give for refusing a call. The raw value is the identifier
/// written to the audit log and shown in refusals, so it must stay stable.
public enum Rule: String, Sendable, Codable, CaseIterable {
    case configurationMissing = "config.missing"
    case configurationInvalid = "config.invalid"
    case configurationWriteToolsOff = "config.write-tools-off"
    case serviceVersionMismatch = "service.version-mismatch"
    case inputInvalid = "input.invalid"
    case mountOutsideRoots = "mount.outside-roots"
    case mountProtected = "mount.protected"
    case mountWritableNotAllowed = "mount.writable-not-allowed"
    case mountVolumeNotOwned = "mount.volume-not-owned"
    case networkNotAllowed = "network.not-allowed"
    case portOutOfRange = "port.out-of-range"
    case portDuplicate = "port.duplicate"
    case environmentKeyOnly = "env.key-only"
    case environmentInvalid = "env.invalid"
    case ownershipUnlabelled = "ownership.unlabelled"
    case ownershipProtected = "ownership.protected"
    case ownershipInfrastructure = "ownership.infrastructure"
    case ownershipImageNotOwned = "ownership.image-not-owned"
    case ownershipImageTagTaken = "ownership.image-tag-taken"
    case stateNotRunning = "state.not-running"
    case stateRunning = "state.running"
    case resourceCPUs = "resources.cpus"
    case resourceMemory = "resources.memory"
    case boundsExecTimeout = "bounds.exec-timeout"
    case boundsResultSize = "bounds.result-size"
    case imageRegistry = "image.registry"
    case buildContext = "build.context"
}

/// A refusal names the rule, explains what was wrong and says what would be allowed.
/// Messages are built from the server's own words and from identifiers the caller gave,
/// never from environment values or build-argument values.
public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
    public let rule: Rule
    public let reason: String
    public let allowed: String

    public init(_ rule: Rule, _ reason: String, allowed: String) {
        self.rule = rule
        self.reason = reason
        self.allowed = allowed
    }

    /// Most entries of a configured list that a refusal names.
    static let listedEntries = 5

    /// A list from the configuration as a refusal may print it: the first few entries, each
    /// clipped, and how many were left out.
    static func list(_ entries: [String]) -> String {
        let shown = entries.prefix(listedEntries).map(ToolStandard.echo).joined(separator: ", ")
        let others = entries.count - listedEntries
        return others > 0 ? "\(shown) and \(others) more" : shown
    }

    public var description: String {
        "Refused by rule \(rule.rawValue): \(reason). Allowed: \(allowed)"
    }
}
