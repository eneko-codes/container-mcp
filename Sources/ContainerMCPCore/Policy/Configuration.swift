import Foundation

/// The user's policy, passed by the plugin as launch arguments from the plugin's settings and
/// read once at startup. No tool can change it.
public struct Configuration: Sendable, Equatable {
    public struct MountRoot: Sendable, Equatable {
        /// Absolute path as written in the file.
        public let path: String
        /// The path with symlinks and `..` resolved; filled in by `ConfigurationLoader`.
        public var resolvedPath: String
        public let writable: Bool

        public init(path: String, resolvedPath: String? = nil, writable: Bool) {
            self.path = path
            self.resolvedPath = resolvedPath ?? path
            self.writable = writable
        }
    }

    public struct PortRange: Sendable, Equatable {
        public let minimum: Int
        public let maximum: Int
        public init(minimum: Int, maximum: Int) {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    public struct Resources: Sendable, Equatable {
        public let defaultCPUs: Int
        public let maximumCPUs: Int
        public let defaultMemoryMiB: Int
        public let maximumMemoryMiB: Int
        public init(defaultCPUs: Int, maximumCPUs: Int, defaultMemoryMiB: Int, maximumMemoryMiB: Int) {
            self.defaultCPUs = defaultCPUs
            self.maximumCPUs = maximumCPUs
            self.defaultMemoryMiB = defaultMemoryMiB
            self.maximumMemoryMiB = maximumMemoryMiB
        }
    }

    public struct LogLimits: Sendable, Equatable {
        public let maximumLines: Int
        public let maximumBytes: Int
        public init(maximumLines: Int, maximumBytes: Int) {
            self.maximumLines = maximumLines
            self.maximumBytes = maximumBytes
        }
    }

    public struct ExecLimits: Sendable, Equatable {
        public let maximumTimeoutSeconds: Int
        public let maximumOutputBytes: Int
        public init(maximumTimeoutSeconds: Int, maximumOutputBytes: Int) {
            self.maximumTimeoutSeconds = maximumTimeoutSeconds
            self.maximumOutputBytes = maximumOutputBytes
        }
    }

    public var mountRoots: [MountRoot]
    public let hostPorts: PortRange
    /// Registry domains, lowercased.
    public let registries: [String]
    public let resources: Resources
    public let logs: LogLimits
    public let exec: ExecLimits
    public let pullTimeoutSeconds: Int
    public let buildTimeoutSeconds: Int
    /// Containers the server must never touch: no start, stop, exec, delete, inspect, logs or stats.
    public let protectedContainers: [String]

    public init(
        mountRoots: [MountRoot],
        hostPorts: PortRange,
        registries: [String],
        resources: Resources,
        logs: LogLimits,
        exec: ExecLimits,
        pullTimeoutSeconds: Int,
        buildTimeoutSeconds: Int,
        protectedContainers: [String]
    ) {
        self.mountRoots = mountRoots
        self.hostPorts = hostPorts
        self.registries = registries.map { $0.lowercased() }
        self.resources = resources
        self.logs = logs
        self.exec = exec
        self.pullTimeoutSeconds = pullTimeoutSeconds
        self.buildTimeoutSeconds = buildTimeoutSeconds
        self.protectedContainers = protectedContainers
    }
}

// MARK: - Launch arguments

/// Reads the policy from `--option value` pairs, the form the plugin's MCP entry passes the
/// saved plugin settings in. Every option must be present exactly once and unknown options
/// are refused, so a typo can never silently drop a limit.
public enum ConfigurationArguments {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
    }

    /// Every option the server accepts, in the order the plugin passes them.
    public static let options = [
        "write-tools-enabled", "read-only-folders", "writable-folders", "host-port-min", "host-port-max",
        "registries", "default-cpus", "max-cpus", "default-memory-mib", "max-memory-mib", "log-max-lines",
        "log-max-bytes", "exec-timeout-seconds", "exec-max-output-bytes", "pull-timeout-seconds",
        "build-timeout-seconds", "protected-containers",
    ]

    /// Options whose value is a list.
    static let listOptions: Set<String> = ["read-only-folders", "writable-folders", "registries", "protected-containers"]

    /// Reads `--option value…` groups. The two hosts pass lists differently: Claude Code joins
    /// a list into one comma-separated argument, while the desktop app expands a list of
    /// folders into one argument per folder. Both are accepted. An option the desktop app
    /// leaves unset arrives as its own `${user_config.…}` placeholder, which counts as empty.
    static func values(_ arguments: [String]) throws -> [String: [String]] {
        var values: [String: [String]] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else { throw Error(description: "\(flag) is not an option") }
            let name = String(flag.dropFirst(2))
            guard options.contains(name) else { throw Error(description: "unknown option --\(name)") }
            guard values[name] == nil else { throw Error(description: "option --\(name) is given twice") }
            var collected: [String] = []
            index += 1
            while index < arguments.count, !arguments[index].hasPrefix("--") {
                if !isPlaceholder(arguments[index]) { collected.append(arguments[index]) }
                index += 1
            }
            if listOptions.contains(name) {
                values[name] = collected.flatMap { $0.split(separator: ",") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else {
                guard collected.count == 1 else { throw Error(description: "option --\(name) needs exactly one value") }
                values[name] = collected
            }
        }
        if let missing = options.first(where: { values[$0] == nil }) {
            throw Error(description: "option --\(missing) is missing")
        }
        return values
    }

    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Whether the user switched the write tools on.
    public static func writeToolsEnabled(_ arguments: [String]) throws -> Bool {
        try boolean(try values(arguments), "write-tools-enabled")
    }

    public static func parse(_ arguments: [String]) throws -> Configuration {
        let values = try values(arguments)

        var mountRoots: [Configuration.MountRoot] = []
        for (name, writable) in [("read-only-folders", false), ("writable-folders", true)] {
            for path in list(values, name) {
                guard path.hasPrefix("/") else { throw Error(description: "--\(name): \(path) must be an absolute path") }
                mountRoots.append(.init(path: path, writable: writable))
            }
        }

        let portRange = Configuration.PortRange(
            minimum: try integer(values, "host-port-min"), maximum: try integer(values, "host-port-max"))
        // Ports below 1024 need privileges on the host; refusing them keeps the range sane.
        guard (1024...65535).contains(portRange.minimum), (1024...65535).contains(portRange.maximum),
            portRange.minimum <= portRange.maximum
        else { throw Error(description: "host ports must satisfy 1024 <= min <= max <= 65535") }

        let registries = list(values, "registries")
        for registry in registries where registry.contains("/") || registry.contains(" ") {
            throw Error(description: "registries must be bare domain names such as docker.io")
        }

        let resources = Configuration.Resources(
            defaultCPUs: try integer(values, "default-cpus"), maximumCPUs: try integer(values, "max-cpus"),
            defaultMemoryMiB: try integer(values, "default-memory-mib"), maximumMemoryMiB: try integer(values, "max-memory-mib"))
        guard resources.defaultCPUs >= 1, resources.defaultCPUs <= resources.maximumCPUs else {
            throw Error(description: "CPUs must satisfy 1 <= default <= max")
        }
        // 200 MiB is the smallest memory the container runtime accepts.
        guard resources.defaultMemoryMiB >= 200, resources.defaultMemoryMiB <= resources.maximumMemoryMiB else {
            throw Error(description: "memory must satisfy 200 <= default <= max MiB")
        }

        let logs = Configuration.LogLimits(
            maximumLines: try integer(values, "log-max-lines"), maximumBytes: try integer(values, "log-max-bytes"))
        guard (1...100_000).contains(logs.maximumLines), (1...10_485_760).contains(logs.maximumBytes) else {
            throw Error(description: "logs must satisfy 1 <= lines <= 100000 and 1 <= bytes <= 10485760")
        }

        let exec = Configuration.ExecLimits(
            maximumTimeoutSeconds: try integer(values, "exec-timeout-seconds"),
            maximumOutputBytes: try integer(values, "exec-max-output-bytes"))
        guard (1...3600).contains(exec.maximumTimeoutSeconds), (1...10_485_760).contains(exec.maximumOutputBytes) else {
            throw Error(description: "exec must satisfy 1 <= timeout <= 3600 seconds and 1 <= output <= 10485760 bytes")
        }

        let pullTimeout = try integer(values, "pull-timeout-seconds")
        let buildTimeout = try integer(values, "build-timeout-seconds")
        guard (1...86_400).contains(pullTimeout), (1...86_400).contains(buildTimeout) else {
            throw Error(description: "pull and build timeouts must be between 1 and 86400 seconds")
        }

        return Configuration(
            mountRoots: mountRoots, hostPorts: portRange, registries: registries, resources: resources, logs: logs,
            exec: exec, pullTimeoutSeconds: pullTimeout, buildTimeoutSeconds: buildTimeout,
            protectedContainers: list(values, "protected-containers"))
    }

    /// Commas separate entries in both hosts' forms, so a comma can never be part of an entry.
    static func list(_ values: [String: [String]], _ name: String) -> [String] {
        values[name] ?? []
    }

    static func integer(_ values: [String: [String]], _ name: String) throws -> Int {
        guard let text = values[name]?.first, let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
            throw Error(description: "--\(name) must be a whole number")
        }
        return number
    }

    static func boolean(_ values: [String: [String]], _ name: String) throws -> Bool {
        switch values[name]?.first {
        case "true": return true
        case "false": return false
        default: throw Error(description: "--\(name) must be true or false")
        }
    }
}
