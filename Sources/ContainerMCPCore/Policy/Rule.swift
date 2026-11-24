import Foundation

/// Every reason the server can give for refusing a call. The raw value is the identifier
/// written to the audit log and shown in refusals, so it must stay stable.
public enum Rule: String, Sendable, Codable, CaseIterable {
    case configurationMissing = "config.missing"
    case configurationInvalid = "config.invalid"
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
    case ownershipAdoptedDelete = "ownership.adopted-delete"
    case ownershipAdoptedExec = "ownership.adopted-exec"
    case ownershipImageNotOwned = "ownership.image-not-owned"
    case ownershipImageTagTaken = "ownership.image-tag-taken"
    case stateNotRunning = "state.not-running"
    case stateRunning = "state.running"
    case resourceCPUs = "resources.cpus"
    case resourceMemory = "resources.memory"
    case boundsExecTimeout = "bounds.exec-timeout"
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

    public var description: String {
        "Refused by rule \(rule.rawValue): \(reason). Allowed: \(allowed)"
    }
}
