import ContainerAPIClient
import ContainerMCPCore
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging

/// Talks to the installed container service through apple/container's own client library,
/// the code the `container` command uses. It runs no other program except `/bin/launchctl`
/// when starting the service, exactly as the `container` command does.
public struct NativeBackend: ContainerBackend {
    /// The release this server is built against; must match the exact pin in Package.swift.
    public static let expectedServiceVersion = "1.7.1"

    let log: Logger

    public init() {
        var logger = Logger(label: "container-mcp.native")
        logger.logLevel = .warning
        log = logger
    }

    // MARK: System

    public func systemStatus() async throws -> SystemStatus {
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
            let configuration = try? await ClientHealthCheck.loadContainerSystemConfig()
            return SystemStatus(
                running: true, serviceVersion: health.apiServerVersion, serviceCommit: health.apiServerCommit,
                expectedServiceVersion: Self.expectedServiceVersion,
                applicationRoot: health.appRoot.path(percentEncoded: false),
                defaultRegistryDomain: configuration?.registry.domain ?? "docker.io")
        } catch {
            return SystemStatus(
                running: false, serviceVersion: nil, serviceCommit: nil, expectedServiceVersion: Self.expectedServiceVersion,
                applicationRoot: nil, defaultRegistryDomain: "docker.io")
        }
    }

    func systemConfiguration() async throws -> ContainerSystemConfig {
        try await ClientHealthCheck.loadContainerSystemConfig()
    }

    // MARK: Containers

    public func listContainers() async throws -> [ContainerSummary] {
        try await ContainerClient().list().map(Self.summary)
    }

    public func inspectContainer(id: String) async throws -> ContainerDetail {
        var snapshot = try await ContainerClient().get(id: id)
        snapshot.configuration.initProcess.environment = snapshot.configuration.initProcess.environment.map(Self.redact)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return ContainerDetail(summary: Self.summary(snapshot), redactedJSON: try encoder.encode(snapshot))
    }

    static func redact(_ entry: String) -> String {
        guard let equals = entry.firstIndex(of: "=") else { return entry }
        return entry[..<equals] + "=<redacted>"
    }

    public func logs(id: String, boot: Bool) async throws -> Data {
        let handles = try await ContainerClient().logs(id: id)
        let index = boot ? 1 : 0
        guard handles.indices.contains(index) else { return Data() }
        let handle = handles[index]
        defer { try? handle.close() }
        // Read at most the last 20 MiB; the dispatcher keeps far less.
        let size = try handle.seekToEnd()
        let start = size > 20_971_520 ? size - 20_971_520 : 0
        try handle.seek(toOffset: start)
        return try handle.readToEnd() ?? Data()
    }

    public func stats(id: String) async throws -> ContainerMCPCore.ContainerStatistics {
        let stats = try await ContainerClient().stats(id: id)
        return ContainerMCPCore.ContainerStatistics(
            id: stats.id, memoryUsageBytes: stats.memoryUsageBytes, memoryLimitBytes: stats.memoryLimitBytes,
            cpuUsageMicroseconds: stats.cpuUsageUsec, networkReceivedBytes: stats.networkRxBytes,
            networkTransmittedBytes: stats.networkTxBytes, blockReadBytes: stats.blockReadBytes,
            blockWriteBytes: stats.blockWriteBytes, processCount: stats.numProcesses)
    }

    public func startContainer(id: String) async throws {
        let client = ContainerClient()
        let container = try await client.get(id: id)
        if container.status == .running { return }
        for mount in container.configuration.mounts where mount.isVirtiofs {
            guard FileManager.default.fileExists(atPath: mount.source) else {
                throw ContainerizationError(.invalidState, message: "mount source path '\(mount.source)' does not exist")
            }
        }
        // No stdio handles and an empty dynamic environment: the CLI would pass SSH_AUTH_SOCK here.
        let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil], dynamicEnv: [:])
        do {
            try await process.start()
        } catch {
            try? await client.stop(id: id)
            throw error
        }
    }

    public func stopContainer(id: String, timeoutSeconds: Int) async throws {
        try await ContainerClient().stop(id: id, opts: ContainerStopOptions(timeoutInSeconds: Int32(timeoutSeconds), signal: nil))
    }

    public func deleteContainer(id: String) async throws {
        try await ContainerClient().delete(id: id, force: false)
    }

    static func summary(_ snapshot: ContainerSnapshot) -> ContainerSummary {
        let configuration = snapshot.configuration
        return ContainerSummary(
            id: snapshot.id,
            image: configuration.image.reference,
            status: snapshot.status.rawValue,
            labels: configuration.labels,
            ports: configuration.publishedPorts.map {
                PortMapping(hostAddress: $0.hostAddress.description, hostPort: Int($0.hostPort), containerPort: Int($0.containerPort), protocolName: $0.proto.rawValue)
            },
            mounts: configuration.mounts.map { mount in
                let kind: MountSummary.Kind =
                    mount.isVirtiofs ? .bind : mount.isVolume ? .volume : mount.isTmpfs ? .tmpfs : .other
                return MountSummary(
                    kind: kind, source: mount.volumeName ?? mount.source, destination: mount.destination,
                    readOnly: mount.options.readonly)
            },
            networks: configuration.networks.map(\.network),
            addresses: snapshot.networks.map { $0.ipv4Address.description },
            cpus: configuration.resources.cpus,
            memoryBytes: configuration.resources.memoryInBytes,
            createdAt: configuration.creationDate,
            startedAt: snapshot.startedDate)
    }

    // MARK: Images

    public func listImages() async throws -> [ImageSummary] {
        var result: [ImageSummary] = []
        for image in try await ClientImage.list() {
            let size = try? await ClientImage.getFullImageSize(image: image)
            result.append(ImageSummary(reference: image.reference, digest: image.digest, sizeBytes: size))
        }
        return result
    }

    public func inspectImage(reference: String) async throws -> ImageDetail {
        let configuration = try await systemConfiguration()
        let image = try await ClientImage.get(reference: reference, containerSystemConfig: configuration)
        let resource = try await image.toImageResource(containerSystemConfig: configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let size = try? await ClientImage.getFullImageSize(image: image)
        return ImageDetail(
            summary: ImageSummary(reference: image.reference, digest: image.digest, sizeBytes: size),
            json: try encoder.encode(resource))
    }

    public func normalizeImageReference(_ reference: String) async throws -> String {
        try ClientImage.normalizeReference(reference, containerSystemConfig: try await systemConfiguration())
    }

    public func infrastructureImages() async throws -> InfrastructureImages {
        let configuration = try await systemConfiguration()
        return InfrastructureImages(initImage: configuration.vminit.image, builderImage: configuration.build.image)
    }

    public func deleteImage(reference: String) async throws {
        // garbageCollect false and no orphaned-blob cleanup: deleting one reference never
        // touches content another image or an unfinished pull still uses.
        try await ClientImage.delete(reference: reference, garbageCollect: false)
    }

    // MARK: Volumes and networks

    public func listVolumes() async throws -> [VolumeSummary] {
        try await ClientVolume.list().map {
            VolumeSummary(name: $0.name, labels: $0.labels, sizeBytes: $0.sizeInBytes, createdAt: $0.creationDate)
        }
    }

    public func createVolume(name: String, sizeBytes: UInt64?, labels: [String: String]) async throws -> VolumeSummary {
        var options: [String: String] = [:]
        if let sizeBytes { options["size"] = String(sizeBytes) }
        let volume = try await ClientVolume.create(name: name, driver: "local", driverOpts: options, labels: labels)
        return VolumeSummary(name: volume.name, labels: volume.labels, sizeBytes: volume.sizeInBytes, createdAt: volume.creationDate)
    }

    public func deleteVolume(name: String) async throws {
        try await ClientVolume.delete(name: name)
    }

    public func listNetworks() async throws -> [NetworkSummary] {
        try await NetworkClient().list().map(Self.summary)
    }

    public func createNetwork(name: String, hostOnly: Bool, subnet: String?, labels: [String: String]) async throws
        -> NetworkSummary
    {
        let configuration = try NetworkConfiguration(
            name: name, mode: hostOnly ? .hostOnly : .nat, ipv4Subnet: try subnet.map { try CIDRv4($0) },
            labels: try ResourceLabels(labels), plugin: "container-network-vmnet")
        return Self.summary(try await NetworkClient().create(configuration: configuration))
    }

    public func deleteNetwork(name: String) async throws {
        try await NetworkClient().delete(id: name)
    }

    static func summary(_ network: NetworkResource) -> NetworkSummary {
        NetworkSummary(
            name: network.name, labels: network.labels.dictionary, mode: network.configuration.mode.rawValue,
            subnet: network.configuration.ipv4Subnet?.description ?? network.status.ipv4Subnet.description,
            builtin: network.isBuiltin)
    }

    public func diskUsage() async throws -> DiskUsageSummary {
        let stats = try await ClientDiskUsage.get()
        func convert(_ usage: ResourceUsage) -> DiskUsageSummary.Usage {
            .init(total: usage.total, active: usage.active, sizeBytes: usage.sizeInBytes, reclaimableBytes: usage.reclaimable)
        }
        return DiskUsageSummary(images: convert(stats.images), containers: convert(stats.containers), volumes: convert(stats.volumes))
    }
}
