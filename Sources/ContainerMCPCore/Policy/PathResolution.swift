import Darwin
import Foundation

/// Path handling for the mount allowlist. Every comparison is made between paths that
/// `realpath(3)` has resolved, so `..`, symlinks and letter case on case-insensitive
/// volumes cannot make a path look like it is somewhere it is not.
public enum PathResolution {
    /// Resolves an existing path. Returns nil when the path does not exist or cannot be read.
    public static func resolveExisting(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolves a path that may not exist yet: the deepest existing ancestor is resolved
    /// and the remaining components are appended after lexical normalization.
    public static func resolveAllowingMissing(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if let resolved = resolveExisting(standardized) { return resolved }
        let parent = (standardized as NSString).deletingLastPathComponent
        guard parent != standardized else { return standardized }
        return (resolveAllowingMissing(parent) as NSString).appendingPathComponent(
            (standardized as NSString).lastPathComponent)
    }

    /// True when `path` is `ancestor` or lies below it. Both must already be resolved.
    public static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }
}

/// Fixed locations the server uses, all under the current user's home folder.
public struct ServerPaths: Sendable, Equatable {
    public static let serverName = "container-mcp"

    public let home: String
    /// Holds the server's own state, never the policy, which comes from the plugin's settings.
    public let stateDirectory: String
    public let stateFile: String
    public let auditDirectory: String
    public let auditFile: String

    public init(home: String) {
        self.home = home
        stateDirectory = home + "/Library/Application Support/" + Self.serverName
        stateFile = stateDirectory + "/state.json"
        auditDirectory = home + "/Library/Logs/" + Self.serverName
        auditFile = auditDirectory + "/audit.jsonl"
    }

    /// The home folder from the user database, not from `$HOME`, which the client controls.
    public static func forCurrentUser() -> ServerPaths {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let status = getpwuid_r(getuid(), &record, &buffer, buffer.count, &result)
        if status == 0, result != nil, let directory = record.pw_dir {
            return ServerPaths(home: String(cString: directory))
        }
        return ServerPaths(home: NSHomeDirectory())
    }

    /// Paths that may never be mounted, nor any folder inside them, nor any folder that
    /// contains them. A folder containing `~/.ssh` (the home folder, `/Users`, `/`) is
    /// refused for that reason.
    public func protectedPaths(containerApplicationRoot: String?) -> [String] {
        var paths = [
            stateDirectory,
            auditDirectory,
            // Claude Code's user settings hold the policy (pluginConfigs); a container that could
            // write them could loosen its own limits. The settings file may be a symlink, so its
            // real folder is protected too.
            home + "/.claude",
            ((PathResolution.resolveExisting(home + "/.claude/settings.json") ?? home + "/.claude/settings.json") as NSString)
                .deletingLastPathComponent,
            home + "/.ssh",
            home + "/Library",
            "/Library/Keychains",
            "/System/Library/Keychains",
            "/private/var/db/SystemKeychains",
            // The container tool's own data: its user config, its install root data and its app root.
            home + "/.config/container",
            "/usr/local/libexec/container",
            home + "/Library/Application Support/com.apple.container",
        ]
        if let containerApplicationRoot { paths.append(containerApplicationRoot) }
        return paths.map(PathResolution.resolveAllowingMissing)
    }
}
