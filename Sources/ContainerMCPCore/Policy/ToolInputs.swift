import Foundation

/// Tool arguments after decoding and type checking, before any policy decision.

public struct RunInput: Sendable, Equatable {
    public struct Port: Sendable, Equatable {
        public var hostPort: Int
        public var containerPort: Int
        public var protocolName: String
        public init(hostPort: Int, containerPort: Int, protocolName: String = "tcp") {
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.protocolName = protocolName
        }
    }
    public struct Mount: Sendable, Equatable {
        public var hostPath: String
        public var containerPath: String
        public var writable: Bool
        public init(hostPath: String, containerPath: String, writable: Bool = false) {
            self.hostPath = hostPath
            self.containerPath = containerPath
            self.writable = writable
        }
    }
    public struct Volume: Sendable, Equatable {
        public var volume: String
        public var containerPath: String
        public var readOnly: Bool
        public init(volume: String, containerPath: String, readOnly: Bool = false) {
            self.volume = volume
            self.containerPath = containerPath
            self.readOnly = readOnly
        }
    }

    public var image: String
    public var name: String
    public var start: Bool
    public var command: [String]
    public var entrypoint: String?
    public var environment: [String]
    public var workingDirectory: String?
    public var user: String?
    public var cpus: Int?
    public var memoryMiB: Int?
    public var ports: [Port]
    public var mounts: [Mount]
    public var volumes: [Volume]
    public var network: String?
    public var readOnlyRootFilesystem: Bool
    public var useInit: Bool

    public init(
        image: String, name: String, start: Bool = true, command: [String] = [], entrypoint: String? = nil,
        environment: [String] = [], workingDirectory: String? = nil, user: String? = nil, cpus: Int? = nil,
        memoryMiB: Int? = nil, ports: [Port] = [], mounts: [Mount] = [], volumes: [Volume] = [],
        network: String? = nil, readOnlyRootFilesystem: Bool = false, useInit: Bool = false
    ) {
        self.image = image
        self.name = name
        self.start = start
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.ports = ports
        self.mounts = mounts
        self.volumes = volumes
        self.network = network
        self.readOnlyRootFilesystem = readOnlyRootFilesystem
        self.useInit = useInit
    }
}

public struct ExecInput: Sendable, Equatable {
    public var id: String
    public var command: [String]
    public var environment: [String]
    public var workingDirectory: String?
    public var user: String?
    public var timeoutSeconds: Int?
    public init(
        id: String, command: [String], environment: [String] = [], workingDirectory: String? = nil,
        user: String? = nil, timeoutSeconds: Int? = nil
    ) {
        self.id = id
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct BuildInput: Sendable, Equatable {
    public var contextPath: String
    public var tag: String
    public var dockerfile: String?
    public var buildArguments: [String]
    public var target: String?
    public var noCache: Bool
    public init(
        contextPath: String, tag: String, dockerfile: String? = nil, buildArguments: [String] = [],
        target: String? = nil, noCache: Bool = false
    ) {
        self.contextPath = contextPath
        self.tag = tag
        self.dockerfile = dockerfile
        self.buildArguments = buildArguments
        self.target = target
        self.noCache = noCache
    }
}
