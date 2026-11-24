import ContainerAPIClient
import ContainerMCPCore
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

/// Creating a container, adapted from `Utility.containerConfigFromFlags` and
/// `ContainerRun.run` in apple/container 1.7.1. The differences are deliberate:
/// no value is ever read from the host environment, published ports carry the address the
/// policy chose, there is no TTY or stdin, and the container always runs detached.
extension NativeBackend {
    public func createContainer(_ specification: RunSpecification, progress: ProgressSink) async throws -> ContainerSummary {
        let bridge = ProgressBridge(progress)
        let systemConfiguration = try await systemConfiguration()
        let client = ContainerClient()
        guard (try? await client.get(id: specification.name)) == nil else {
            throw ContainerizationError(.exists, message: "container with id \(specification.name) already exists")
        }

        let candidates = try await ClientImage.platforms(reference: specification.image, containerSystemConfig: systemConfiguration)
        let platform = try Self.choosePlatform(from: candidates, reference: specification.image)

        await bridge.step("Fetching image")
        let image = try await ClientImage.fetch(
            reference: specification.image, platform: platform, containerSystemConfig: systemConfiguration,
            progressUpdate: bridge.handler)
        await bridge.step("Unpacking image")
        try await image.getCreateSnapshot(platform: platform, progressUpdate: bridge.handler)

        await bridge.step("Fetching kernel")
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        await bridge.step("Fetching init image")
        let initImage = try await ClientImage.fetch(
            reference: systemConfiguration.vminit.image, platform: .current, containerSystemConfig: systemConfiguration,
            progressUpdate: bridge.handler)
        await bridge.step("Unpacking init image")
        _ = try await initImage.getCreateSnapshot(platform: .current, progressUpdate: bridge.handler)

        let imageConfiguration = try await image.config(for: platform).config
        var configuration = ContainerConfiguration(
            id: specification.name, image: image.description,
            process: try Self.process(for: specification, imageConfiguration: imageConfiguration))
        configuration.platform = platform
        var resources = ContainerConfiguration.Resources()
        resources.cpus = specification.cpus
        resources.memoryInBytes = UInt64(specification.memoryMiB) * 1_048_576
        configuration.resources = resources

        var mounts: [Filesystem] = specification.bindMounts.map {
            Filesystem.virtiofs(source: $0.source, destination: $0.destination, options: $0.readOnly ? ["ro"] : [])
        }
        for volumeMount in specification.volumeMounts {
            let volume = try await ClientVolume.inspect(volumeMount.volume)
            mounts.append(
                Filesystem.volume(
                    name: volume.name, format: volume.format, source: volume.source, destination: volumeMount.destination,
                    options: volumeMount.readOnly ? ["ro"] : []))
        }
        configuration.mounts = mounts

        let networkClient = NetworkClient()
        let networkName: String
        if let requested = specification.network, requested != NetworkClient.defaultNetworkName {
            networkName = try await networkClient.get(id: requested).id
        } else {
            guard let builtin = try await networkClient.builtin else {
                throw ContainerizationError(.invalidState, message: "builtin network is not present")
            }
            networkName = builtin.id
        }
        // The first interface gets the container's qualified name, as the CLI does.
        let hostname: String
        if specification.name.contains(".") {
            hostname = specification.name + "."
        } else if let domain = systemConfiguration.dns.domain {
            hostname = "\(specification.name).\(domain)."
        } else {
            hostname = specification.name
        }
        configuration.networks = [AttachmentConfiguration(network: networkName, options: AttachmentOptions(hostname: hostname, mtu: 1280))]
        configuration.dns = Utility.dnsConfiguration(
            from: .init(domain: nil, nameservers: [], options: [], searchDomains: []),
            defaults: systemConfiguration.container.dns, hostDomainFallback: systemConfiguration.dns.domain)

        configuration.rosetta = Platform.current.architecture == "arm64" && platform.architecture == "amd64"
        configuration.labels = specification.labels
        configuration.publishedPorts = try specification.ports.map {
            try PublishPort(
                hostAddress: try IPAddress($0.hostAddress), hostPort: UInt16($0.hostPort), containerPort: UInt16($0.containerPort),
                proto: $0.protocolName == "udp" ? .udp : .tcp, count: 1)
        }
        configuration.readOnly = specification.readOnlyRootFilesystem
        configuration.useInit = specification.useInit
        configuration.stopSignal = imageConfiguration?.stopSignal
        configuration.runtimeHandler = "container-runtime-\(platform.os)"

        await bridge.step(specification.start ? "Starting container" : "Creating container")
        try await client.create(configuration: configuration, options: ContainerCreateOptions(autoRemove: false), kernel: kernel)
        if specification.start {
            do {
                let process = try await client.bootstrap(id: specification.name, stdio: [nil, nil, nil], dynamicEnv: [:])
                try await process.start()
            } catch {
                // The CLI removes a container that failed to start; it is the server's own.
                try? await client.delete(id: specification.name, force: true)
                throw error
            }
        }
        return Self.summary(try await client.get(id: specification.name))
    }

    /// Prefers this Mac's platform; otherwise the image's only runnable platform.
    static func choosePlatform(from candidates: [Platform], reference: String) throws -> Platform {
        if let native = candidates.first(where: { $0.os == Platform.current.os && $0.architecture == Platform.current.architecture }) {
            return native
        }
        let linux = candidates.filter { $0.os == "linux" }
        guard linux.count == 1, let only = linux.first else {
            throw ContainerizationError(.unsupported, message: "image \(reference) has no single Linux platform this Mac can run (\(candidates))")
        }
        return only
    }

    /// The init process: entrypoint and command resolution follows `Parser.process` in 1.7.1,
    /// but the environment is the image's KEY=value entries plus the approved ones, never the host's.
    static func process(for specification: RunSpecification, imageConfiguration: ContainerizationOCI.ImageConfig?) throws
        -> ProcessConfiguration
    {
        var arguments: [String] = []
        var entrypointOverridden = false
        if let entrypoint = specification.entrypoint, !entrypoint.isEmpty {
            arguments = [entrypoint]
            entrypointOverridden = true
        } else if let entrypoint = imageConfiguration?.entrypoint, !entrypoint.isEmpty, entrypoint != [""] {
            arguments = entrypoint
        }
        if !specification.command.isEmpty {
            arguments += specification.command
        } else if !entrypointOverridden, let command = imageConfiguration?.cmd, !command.isEmpty {
            arguments += command
        }
        guard let executable = arguments.first else {
            throw ContainerizationError(.invalidArgument, message: "the image has no entrypoint or command and none was given")
        }

        var environment: [String: String] = [:]
        var order: [String] = []
        for entry in (imageConfiguration?.env ?? []).filter({ $0.contains("=") }) + specification.environment {
            let key = String(entry.split(separator: "=", maxSplits: 1).first ?? "")
            if environment[key] == nil { order.append(key) }
            environment[key] = entry
        }

        let user: ProcessConfiguration.User
        if let requested = specification.user {
            user = .raw(userString: requested)
        } else if let imageUser = imageConfiguration?.user, !imageUser.isEmpty {
            user = .raw(userString: imageUser)
        } else {
            user = .id(uid: 0, gid: 0)
        }

        let imageWorkingDirectory = imageConfiguration?.workingDir.flatMap { $0.isEmpty ? nil : $0 }
        return ProcessConfiguration(
            executable: executable, arguments: Array(arguments.dropFirst()), environment: order.compactMap { environment[$0] },
            workingDirectory: specification.workingDirectory ?? imageWorkingDirectory ?? "/", terminal: false,
            user: user)
    }
}
