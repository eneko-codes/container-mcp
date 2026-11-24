import Foundation

/// The user's policy, read once at startup from a fixed path. No tool can change it.
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
    /// Containers the server did not create that it may start and stop, never exec into or delete.
    public let adoptedContainers: [String]

    public init(
        mountRoots: [MountRoot],
        hostPorts: PortRange,
        registries: [String],
        resources: Resources,
        logs: LogLimits,
        exec: ExecLimits,
        pullTimeoutSeconds: Int,
        buildTimeoutSeconds: Int,
        adoptedContainers: [String]
    ) {
        self.mountRoots = mountRoots
        self.hostPorts = hostPorts
        self.registries = registries.map { $0.lowercased() }
        self.resources = resources
        self.logs = logs
        self.exec = exec
        self.pullTimeoutSeconds = pullTimeoutSeconds
        self.buildTimeoutSeconds = buildTimeoutSeconds
        self.adoptedContainers = adoptedContainers
    }
}

// MARK: - Strict JSON decoding

/// Decodes the configuration file, refusing unknown keys at every level so that a typo
/// can never silently drop a limit.
enum ConfigurationFile {
    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    static func decode(_ data: Data) throws -> Configuration {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Error(description: "the file is not valid JSON")
        }
        let root = try dictionary(object, at: "the top level")
        try requireKeys(
            root,
            allowed: ["version", "mountRoots", "hostPorts", "registries", "resources", "logs", "exec", "pull", "build", "adopted"],
            required: ["version", "mountRoots", "hostPorts", "registries", "resources", "logs", "exec", "pull", "build"],
            at: "the top level")

        let version = try integer(root["version"], at: "version")
        guard version == 1 else { throw Error(description: "version must be 1") }

        let rootsArray = try array(root["mountRoots"], at: "mountRoots")
        var mountRoots: [Configuration.MountRoot] = []
        for (index, entry) in rootsArray.enumerated() {
            let place = "mountRoots[\(index)]"
            let rootObject = try dictionary(entry, at: place)
            try requireKeys(rootObject, allowed: ["path", "writable"], required: ["path"], at: place)
            let path = try string(rootObject["path"], at: "\(place).path")
            guard path.hasPrefix("/") else { throw Error(description: "\(place).path must be an absolute path") }
            let writable = try rootObject["writable"].map { try boolean($0, at: "\(place).writable") } ?? false
            mountRoots.append(.init(path: path, writable: writable))
        }

        let ports = try dictionary(root["hostPorts"], at: "hostPorts")
        try requireKeys(ports, allowed: ["min", "max"], required: ["min", "max"], at: "hostPorts")
        let portRange = Configuration.PortRange(
            minimum: try integer(ports["min"], at: "hostPorts.min"),
            maximum: try integer(ports["max"], at: "hostPorts.max"))
        // Ports below 1024 need privileges on the host; refusing them keeps the range sane.
        guard (1024...65535).contains(portRange.minimum), (1024...65535).contains(portRange.maximum),
            portRange.minimum <= portRange.maximum
        else { throw Error(description: "hostPorts must satisfy 1024 <= min <= max <= 65535") }

        let registries = try array(root["registries"], at: "registries").enumerated().map { index, value in
            try string(value, at: "registries[\(index)]")
        }
        for registry in registries where registry.isEmpty || registry.contains("/") {
            throw Error(description: "registries must be bare domain names such as docker.io")
        }

        let resourcesObject = try dictionary(root["resources"], at: "resources")
        try requireKeys(
            resourcesObject, allowed: ["defaultCpus", "maxCpus", "defaultMemoryMiB", "maxMemoryMiB"],
            required: ["defaultCpus", "maxCpus", "defaultMemoryMiB", "maxMemoryMiB"], at: "resources")
        let resources = Configuration.Resources(
            defaultCPUs: try integer(resourcesObject["defaultCpus"], at: "resources.defaultCpus"),
            maximumCPUs: try integer(resourcesObject["maxCpus"], at: "resources.maxCpus"),
            defaultMemoryMiB: try integer(resourcesObject["defaultMemoryMiB"], at: "resources.defaultMemoryMiB"),
            maximumMemoryMiB: try integer(resourcesObject["maxMemoryMiB"], at: "resources.maxMemoryMiB"))
        guard resources.defaultCPUs >= 1, resources.defaultCPUs <= resources.maximumCPUs else {
            throw Error(description: "resources must satisfy 1 <= defaultCpus <= maxCpus")
        }
        // 200 MiB is the smallest memory the container runtime accepts.
        guard resources.defaultMemoryMiB >= 200, resources.defaultMemoryMiB <= resources.maximumMemoryMiB else {
            throw Error(description: "resources must satisfy 200 <= defaultMemoryMiB <= maxMemoryMiB")
        }

        let logsObject = try dictionary(root["logs"], at: "logs")
        try requireKeys(logsObject, allowed: ["maxLines", "maxBytes"], required: ["maxLines", "maxBytes"], at: "logs")
        let logs = Configuration.LogLimits(
            maximumLines: try integer(logsObject["maxLines"], at: "logs.maxLines"),
            maximumBytes: try integer(logsObject["maxBytes"], at: "logs.maxBytes"))
        guard (1...100_000).contains(logs.maximumLines), (1...10_485_760).contains(logs.maximumBytes) else {
            throw Error(description: "logs must satisfy 1 <= maxLines <= 100000 and 1 <= maxBytes <= 10485760")
        }

        let execObject = try dictionary(root["exec"], at: "exec")
        try requireKeys(
            execObject, allowed: ["timeoutSeconds", "maxOutputBytes"], required: ["timeoutSeconds", "maxOutputBytes"],
            at: "exec")
        let exec = Configuration.ExecLimits(
            maximumTimeoutSeconds: try integer(execObject["timeoutSeconds"], at: "exec.timeoutSeconds"),
            maximumOutputBytes: try integer(execObject["maxOutputBytes"], at: "exec.maxOutputBytes"))
        guard (1...3600).contains(exec.maximumTimeoutSeconds), (1...10_485_760).contains(exec.maximumOutputBytes) else {
            throw Error(description: "exec must satisfy 1 <= timeoutSeconds <= 3600 and 1 <= maxOutputBytes <= 10485760")
        }

        let pull = try dictionary(root["pull"], at: "pull")
        try requireKeys(pull, allowed: ["timeoutSeconds"], required: ["timeoutSeconds"], at: "pull")
        let pullTimeout = try integer(pull["timeoutSeconds"], at: "pull.timeoutSeconds")
        let build = try dictionary(root["build"], at: "build")
        try requireKeys(build, allowed: ["timeoutSeconds"], required: ["timeoutSeconds"], at: "build")
        let buildTimeout = try integer(build["timeoutSeconds"], at: "build.timeoutSeconds")
        guard (1...86_400).contains(pullTimeout), (1...86_400).contains(buildTimeout) else {
            throw Error(description: "pull and build timeoutSeconds must be between 1 and 86400")
        }

        let adopted = try (root["adopted"].map { try array($0, at: "adopted") } ?? []).enumerated().map {
            index, value in try string(value, at: "adopted[\(index)]")
        }

        return Configuration(
            mountRoots: mountRoots, hostPorts: portRange, registries: registries, resources: resources,
            logs: logs, exec: exec, pullTimeoutSeconds: pullTimeout, buildTimeoutSeconds: buildTimeout,
            adoptedContainers: adopted)
    }

    private static func requireKeys(_ object: [String: Any], allowed: Set<String>, required: Set<String>, at place: String)
        throws
    {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Error(description: "unknown key \"\(unknown)\" in \(place)")
        }
        if let missing = required.sorted().first(where: { object[$0] == nil }) {
            throw Error(description: "missing key \"\(missing)\" in \(place)")
        }
    }

    private static func dictionary(_ value: Any?, at place: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw Error(description: "\(place) must be an object") }
        return object
    }

    private static func array(_ value: Any?, at place: String) throws -> [Any] {
        guard let items = value as? [Any] else { throw Error(description: "\(place) must be an array") }
        return items
    }

    private static func string(_ value: Any?, at place: String) throws -> String {
        guard let text = value as? String else { throw Error(description: "\(place) must be a string") }
        return text
    }

    // JSONSerialization returns NSNumber for both booleans and numbers; CFBoolean tells them apart.
    private static func integer(_ value: Any?, at place: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == number.doubleValue.rounded(), let exact = Int(exactly: number.doubleValue)
        else { throw Error(description: "\(place) must be an integer") }
        return exact
    }

    private static func boolean(_ value: Any, at place: String) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw Error(description: "\(place) must be true or false")
        }
        return number.boolValue
    }
}
