import Foundation

/// Everything the tools need from the container service. The policy layer and the tools
/// only see this protocol, so tests can use a fake and the native adapter stays replaceable.
/// Implementations do no policy checks of their own: they receive specifications that the
/// policy layer has already approved.
public protocol ContainerBackend: Sendable {
    func systemStatus() async throws -> SystemStatus
    func startSystem(progress: ProgressSink) async throws -> SystemStartReport

    func listContainers() async throws -> [ContainerSummary]
    func inspectContainer(id: String) async throws -> ContainerDetail
    func logs(id: String, boot: Bool) async throws -> Data
    func stats(id: String) async throws -> ContainerStatistics

    func listImages() async throws -> [ImageSummary]
    func inspectImage(reference: String) async throws -> ImageDetail
    /// The reference the service would store for `reference`, such as `docker.io/library/alpine:latest`.
    func normalizeImageReference(_ reference: String) async throws -> String
    /// Images the service itself needs for running containers and builds.
    func infrastructureImages() async throws -> InfrastructureImages

    func listVolumes() async throws -> [VolumeSummary]
    func listNetworks() async throws -> [NetworkSummary]
    func diskUsage() async throws -> DiskUsageSummary

    func createContainer(_ specification: RunSpecification, progress: ProgressSink) async throws -> ContainerSummary
    func startContainer(id: String) async throws
    func stopContainer(id: String, timeoutSeconds: Int) async throws
    func exec(id: String, specification: ExecSpecification) async throws -> ExecResult
    func pullImage(reference: String, platform: String?, progress: ProgressSink) async throws -> ImageSummary
    func buildImage(_ specification: BuildSpecification, progress: ProgressSink) async throws -> [ImageSummary]
    func createVolume(name: String, sizeBytes: UInt64?, labels: [String: String]) async throws -> VolumeSummary
    func createNetwork(name: String, hostOnly: Bool, subnet: String?, labels: [String: String]) async throws
        -> NetworkSummary

    func deleteContainer(id: String) async throws
    func deleteImage(reference: String) async throws
    func deleteVolume(name: String) async throws
    func deleteNetwork(name: String) async throws
}

/// Receives progress from long operations. The MCP layer turns it into progress notifications.
public struct ProgressSink: Sendable {
    private let handler: @Sendable (_ completed: Double, _ total: Double?, _ message: String?) async -> Void

    public init(_ handler: @escaping @Sendable (_ completed: Double, _ total: Double?, _ message: String?) async -> Void) {
        self.handler = handler
    }

    public static let none = ProgressSink { _, _, _ in }

    public func report(completed: Double, total: Double? = nil, message: String? = nil) async {
        await handler(completed, total, message)
    }
}

// MARK: - Values the backend returns

public struct SystemStatus: Sendable, Codable, Equatable {
    public var running: Bool
    public var serviceVersion: String?
    public var serviceCommit: String?
    /// The release the server was built against.
    public var expectedServiceVersion: String
    public var applicationRoot: String?
    /// The registry used for references without a domain, such as `docker.io`.
    public var defaultRegistryDomain: String

    public init(
        running: Bool, serviceVersion: String?, serviceCommit: String?, expectedServiceVersion: String,
        applicationRoot: String?, defaultRegistryDomain: String
    ) {
        self.running = running
        self.serviceVersion = serviceVersion
        self.serviceCommit = serviceCommit
        self.expectedServiceVersion = expectedServiceVersion
        self.applicationRoot = applicationRoot
        self.defaultRegistryDomain = defaultRegistryDomain
    }

    public var versionMatches: Bool { serviceVersion == expectedServiceVersion }
}

public struct SystemStartReport: Sendable, Codable, Equatable {
    public var alreadyRunning: Bool
    public var notes: [String]
    public init(alreadyRunning: Bool, notes: [String]) {
        self.alreadyRunning = alreadyRunning
        self.notes = notes
    }
}

public struct PortMapping: Sendable, Codable, Equatable {
    public var hostAddress: String
    public var hostPort: Int
    public var containerPort: Int
    public var protocolName: String
    public init(hostAddress: String, hostPort: Int, containerPort: Int, protocolName: String) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
    }
}

public struct MountSummary: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case bind, volume, tmpfs, other }
    public var kind: Kind
    public var source: String
    public var destination: String
    public var readOnly: Bool
    public init(kind: Kind, source: String, destination: String, readOnly: Bool) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
    }
}

public struct ContainerSummary: Sendable, Codable, Equatable {
    public var id: String
    public var image: String
    /// One of `running`, `stopped`, `stopping`, `unknown`.
    public var status: String
    public var labels: [String: String]
    public var ports: [PortMapping]
    public var mounts: [MountSummary]
    public var networks: [String]
    public var addresses: [String]
    public var cpus: Int
    public var memoryBytes: UInt64
    public var createdAt: Date?
    public var startedAt: Date?

    public init(
        id: String, image: String, status: String, labels: [String: String], ports: [PortMapping] = [],
        mounts: [MountSummary] = [], networks: [String] = [], addresses: [String] = [], cpus: Int = 0,
        memoryBytes: UInt64 = 0, createdAt: Date? = nil, startedAt: Date? = nil
    ) {
        self.id = id
        self.image = image
        self.status = status
        self.labels = labels
        self.ports = ports
        self.mounts = mounts
        self.networks = networks
        self.addresses = addresses
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.createdAt = createdAt
        self.startedAt = startedAt
    }

    public var isRunning: Bool { status == "running" }
}

public struct ContainerDetail: Sendable, Equatable {
    public var summary: ContainerSummary
    /// The service's full description as JSON, with environment values already redacted.
    public var redactedJSON: Data
    public init(summary: ContainerSummary, redactedJSON: Data) {
        self.summary = summary
        self.redactedJSON = redactedJSON
    }
}

public struct ContainerStatistics: Sendable, Codable, Equatable {
    public var id: String
    public var memoryUsageBytes: UInt64?
    public var memoryLimitBytes: UInt64?
    public var cpuUsageMicroseconds: UInt64?
    public var networkReceivedBytes: UInt64?
    public var networkTransmittedBytes: UInt64?
    public var blockReadBytes: UInt64?
    public var blockWriteBytes: UInt64?
    public var processCount: UInt64?
    public init(
        id: String, memoryUsageBytes: UInt64? = nil, memoryLimitBytes: UInt64? = nil, cpuUsageMicroseconds: UInt64? = nil,
        networkReceivedBytes: UInt64? = nil, networkTransmittedBytes: UInt64? = nil, blockReadBytes: UInt64? = nil,
        blockWriteBytes: UInt64? = nil, processCount: UInt64? = nil
    ) {
        self.id = id
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.networkReceivedBytes = networkReceivedBytes
        self.networkTransmittedBytes = networkTransmittedBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.processCount = processCount
    }
}

public struct ImageSummary: Sendable, Codable, Equatable {
    public var reference: String
    public var digest: String
    public var sizeBytes: Int64?
    public init(reference: String, digest: String, sizeBytes: Int64? = nil) {
        self.reference = reference
        self.digest = digest
        self.sizeBytes = sizeBytes
    }
}

public struct ImageDetail: Sendable, Equatable {
    public var summary: ImageSummary
    public var json: Data
    public init(summary: ImageSummary, json: Data) {
        self.summary = summary
        self.json = json
    }
}

public struct InfrastructureImages: Sendable, Equatable {
    /// The image that boots every container's virtual machine.
    public var initImage: String
    /// The BuildKit image the builder container runs.
    public var builderImage: String
    public init(initImage: String, builderImage: String) {
        self.initImage = initImage
        self.builderImage = builderImage
    }
}

public struct VolumeSummary: Sendable, Codable, Equatable {
    public var name: String
    public var labels: [String: String]
    public var sizeBytes: UInt64?
    public var createdAt: Date?
    public init(name: String, labels: [String: String], sizeBytes: UInt64? = nil, createdAt: Date? = nil) {
        self.name = name
        self.labels = labels
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }
}

public struct NetworkSummary: Sendable, Codable, Equatable {
    public var name: String
    public var labels: [String: String]
    public var mode: String
    public var subnet: String?
    public var builtin: Bool
    public init(name: String, labels: [String: String], mode: String, subnet: String? = nil, builtin: Bool) {
        self.name = name
        self.labels = labels
        self.mode = mode
        self.subnet = subnet
        self.builtin = builtin
    }
}

public struct DiskUsageSummary: Sendable, Codable, Equatable {
    public struct Usage: Sendable, Codable, Equatable {
        public var total: Int
        public var active: Int
        public var sizeBytes: UInt64
        public var reclaimableBytes: UInt64
        public init(total: Int, active: Int, sizeBytes: UInt64, reclaimableBytes: UInt64) {
            self.total = total
            self.active = active
            self.sizeBytes = sizeBytes
            self.reclaimableBytes = reclaimableBytes
        }
    }
    public var images: Usage
    public var containers: Usage
    public var volumes: Usage
    public init(images: Usage, containers: Usage, volumes: Usage) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
    }
}

// MARK: - Specifications the policy layer produces

/// A container to create, already approved by the policy layer.
public struct RunSpecification: Sendable, Equatable {
    public struct BindMount: Sendable, Equatable {
        /// Resolved host path.
        public var source: String
        public var destination: String
        public var readOnly: Bool
    }
    public struct VolumeMount: Sendable, Equatable {
        public var volume: String
        public var destination: String
        public var readOnly: Bool
    }
    public struct Port: Sendable, Equatable {
        /// Always `127.0.0.1`; the policy layer never produces another address.
        public var hostAddress: String
        public var hostPort: Int
        public var containerPort: Int
        public var protocolName: String
    }

    public var name: String
    public var image: String
    public var command: [String]
    public var entrypoint: String?
    /// `KEY=value` entries only.
    public var environment: [String]
    public var workingDirectory: String?
    public var user: String?
    public var cpus: Int
    public var memoryMiB: Int
    public var ports: [Port]
    public var bindMounts: [BindMount]
    public var volumeMounts: [VolumeMount]
    public var network: String?
    public var readOnlyRootFilesystem: Bool
    public var useInit: Bool
    public var start: Bool
    public var labels: [String: String]
}

public struct ExecSpecification: Sendable, Equatable {
    public var command: [String]
    public var environment: [String]
    public var workingDirectory: String?
    public var user: String?
    public var timeoutSeconds: Int
    public var maximumOutputBytes: Int
}

public struct ExecResult: Sendable, Codable, Equatable {
    /// Nil when the process was killed at the timeout.
    public var exitCode: Int32?
    public var timedOut: Bool
    public var standardOutput: String
    public var standardError: String
    public var outputTruncated: Bool
    /// How many characters the output limit discarded, which cannot be read again.
    public var omittedCharacters: Int
    public init(
        exitCode: Int32?, timedOut: Bool, standardOutput: String, standardError: String, outputTruncated: Bool,
        omittedCharacters: Int = 0
    ) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputTruncated = outputTruncated
        self.omittedCharacters = omittedCharacters
    }
}

public struct BuildSpecification: Sendable, Equatable {
    /// Resolved folder sent to BuildKit.
    public var contextDirectory: String
    /// Resolved Dockerfile path inside the context.
    public var dockerfile: String
    public var dockerfileContents: Data
    /// Normalized tag.
    public var tag: String
    /// `KEY=value` entries only.
    public var buildArguments: [String]
    public var target: String?
    public var noCache: Bool
    public var labels: [String: String]
}
