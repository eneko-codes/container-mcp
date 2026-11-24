import Foundation

@testable import ContainerMCPCore

/// An in-memory container service that records every call, so tests can check both what
/// the policy refused and exactly what reached the backend.
actor FakeBackend: ContainerBackend {
    enum Call: Equatable {
        case create(RunSpecification)
        case start(String)
        case stop(String, Int)
        case exec(String, ExecSpecification)
        case pull(String)
        case build(BuildSpecification)
        case createVolume(String, [String: String])
        case createNetwork(String, [String: String])
        case startSystem
        case deleteContainer(String)
        case deleteImage(String)
        case deleteVolume(String)
        case deleteNetwork(String)
    }

    var calls: [Call] = []
    var containers: [ContainerSummary]
    var images: [ImageSummary]
    var volumes: [VolumeSummary]
    var networks: [NetworkSummary]
    var logData = Data()
    var running = true
    var serviceVersion = "1.7.1"
    var pullDelaySeconds: Double = 0
    var execResult = ExecResult(exitCode: 0, timedOut: false, standardOutput: "ok\n", standardError: "", outputTruncated: false)

    let infrastructure = InfrastructureImages(
        initImage: "ghcr.io/apple/containerization/vminit:0.54.0",
        builderImage: "ghcr.io/apple/container-builder-shim/builder:0.13.3")

    init(
        containers: [ContainerSummary] = [], images: [ImageSummary] = [], volumes: [VolumeSummary] = [],
        networks: [NetworkSummary] = [NetworkSummary(name: "default", labels: [:], mode: "nat", builtin: true)]
    ) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
        self.networks = networks
    }

    func set(logData: Data) { self.logData = logData }
    func set(running: Bool) { self.running = running }
    func set(serviceVersion: String) { self.serviceVersion = serviceVersion }
    func set(pullDelaySeconds: Double) { self.pullDelaySeconds = pullDelaySeconds }
    func add(image: String) { images.append(ImageSummary(reference: image, digest: "sha256:\(image.count)")) }

    func systemStatus() async throws -> SystemStatus {
        SystemStatus(
            running: running, serviceVersion: running ? serviceVersion : nil, serviceCommit: nil,
            expectedServiceVersion: "1.7.1", applicationRoot: nil, defaultRegistryDomain: "docker.io")
    }

    func startSystem(progress: ProgressSink) async throws -> SystemStartReport {
        calls.append(.startSystem)
        running = true
        return SystemStartReport(alreadyRunning: false, notes: [])
    }

    func listContainers() async throws -> [ContainerSummary] { containers }

    func inspectContainer(id: String) async throws -> ContainerDetail {
        guard let container = containers.first(where: { $0.id == id }) else { throw FakeError.notFound }
        return ContainerDetail(summary: container, redactedJSON: Data(#"{"id":"\#(id)"}"#.utf8))
    }

    func logs(id: String, boot: Bool) async throws -> Data { logData }

    func stats(id: String) async throws -> ContainerStatistics { ContainerStatistics(id: id, processCount: 1) }

    func listImages() async throws -> [ImageSummary] { images }

    func inspectImage(reference: String) async throws -> ImageDetail {
        let normalized = try await normalizeImageReference(reference)
        guard let image = images.first(where: { $0.reference == normalized }) else { throw FakeError.notFound }
        return ImageDetail(summary: image, json: Data("{}".utf8))
    }

    /// A simplified version of the service's normalization: default registry docker.io,
    /// `library/` for single-name Docker Hub images and `:latest` when no tag is given.
    func normalizeImageReference(_ reference: String) async throws -> String {
        var value = reference
        let domain = ImageReference.domain(of: value, defaultDomain: "docker.io")
        let hasDomain = value.split(separator: "/").first.map { String($0).lowercased() == domain } ?? false
        if !hasDomain {
            value = value.contains("/") ? "docker.io/\(value)" : "docker.io/library/\(value)"
        }
        let lastComponent = value.split(separator: "/").last ?? ""
        if !lastComponent.contains(":") && !value.contains("@") { value += ":latest" }
        return value
    }

    func infrastructureImages() async throws -> InfrastructureImages { infrastructure }

    func listVolumes() async throws -> [VolumeSummary] { volumes }
    func listNetworks() async throws -> [NetworkSummary] { networks }

    func diskUsage() async throws -> DiskUsageSummary {
        let zero = DiskUsageSummary.Usage(total: 0, active: 0, sizeBytes: 0, reclaimableBytes: 0)
        return DiskUsageSummary(images: zero, containers: zero, volumes: zero)
    }

    func createContainer(_ specification: RunSpecification, progress: ProgressSink) async throws -> ContainerSummary {
        calls.append(.create(specification))
        let container = ContainerSummary(
            id: specification.name, image: specification.image, status: specification.start ? "running" : "stopped",
            labels: specification.labels)
        containers.append(container)
        return container
    }

    func startContainer(id: String) async throws { calls.append(.start(id)) }
    func stopContainer(id: String, timeoutSeconds: Int) async throws { calls.append(.stop(id, timeoutSeconds)) }

    func exec(id: String, specification: ExecSpecification) async throws -> ExecResult {
        calls.append(.exec(id, specification))
        return execResult
    }

    func pullImage(reference: String, platform: String?, progress: ProgressSink) async throws -> ImageSummary {
        calls.append(.pull(reference))
        if pullDelaySeconds > 0 { try await Task.sleep(for: .seconds(pullDelaySeconds)) }
        let normalized = try await normalizeImageReference(reference)
        let image = ImageSummary(reference: normalized, digest: "sha256:pulled")
        images.append(image)
        return image
    }

    func buildImage(_ specification: BuildSpecification, progress: ProgressSink) async throws -> [ImageSummary] {
        calls.append(.build(specification))
        let image = ImageSummary(reference: specification.tag, digest: "sha256:built")
        images.append(image)
        return [image]
    }

    func createVolume(name: String, sizeBytes: UInt64?, labels: [String: String]) async throws -> VolumeSummary {
        calls.append(.createVolume(name, labels))
        let volume = VolumeSummary(name: name, labels: labels, sizeBytes: sizeBytes)
        volumes.append(volume)
        return volume
    }

    func createNetwork(name: String, hostOnly: Bool, subnet: String?, labels: [String: String]) async throws -> NetworkSummary {
        calls.append(.createNetwork(name, labels))
        let network = NetworkSummary(name: name, labels: labels, mode: hostOnly ? "hostOnly" : "nat", subnet: subnet, builtin: false)
        networks.append(network)
        return network
    }

    func deleteContainer(id: String) async throws { calls.append(.deleteContainer(id)) }
    func deleteImage(reference: String) async throws { calls.append(.deleteImage(reference)) }
    func deleteVolume(name: String) async throws { calls.append(.deleteVolume(name)) }
    func deleteNetwork(name: String) async throws { calls.append(.deleteNetwork(name)) }
}

enum FakeError: Error { case notFound }
