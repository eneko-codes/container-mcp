import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerMCPCore
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import NIOPosix

extension NativeBackend {
    /// Adapted from `ImagePull.run` in apple/container 1.7.1: pull, then unpack.
    public func pullImage(reference: String, platform: String?, progress: ProgressSink) async throws -> ImageSummary {
        let bridge = ProgressBridge(progress)
        let configuration = try await systemConfiguration()
        let requested = try platform.map { try Platform(from: $0) }
        await bridge.step("Fetching image")
        let image = try await ClientImage.pull(
            reference: reference, platform: requested, containerSystemConfig: configuration, progressUpdate: bridge.handler)
        await bridge.step("Unpacking image")
        try await image.unpack(platform: requested, progressUpdate: bridge.handler)
        let size = try? await ClientImage.getFullImageSize(image: image)
        return ImageSummary(reference: image.reference, digest: image.digest, sizeBytes: size)
    }

    /// The BuildKit shim listens on this vsock port in container 1.7.1 (`BuildOptions.vsockPort`).
    static let builderVsockPort: UInt32 = 8088

    /// Adapted from `BuildOptions.runLinuxBuild` in apple/container 1.7.1, without the terminal:
    /// BuildKit's own output goes to the server's stderr, never to stdout, which carries MCP.
    public func buildImage(_ specification: BuildSpecification, progress: ProgressSink) async throws -> [ImageSummary] {
        let bridge = ProgressBridge(progress)
        let configuration = try await systemConfiguration()

        await bridge.step("Starting the builder")
        try await Builder.start(
            cpus: nil, memory: nil, log: log, ssh: false, progressUpdate: bridge.handler, containerSystemConfig: configuration)

        await bridge.step("Connecting to the builder")
        let builder = try await connectToBuilder(configuration: configuration, bridge: bridge)

        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let buildID = UUID().uuidString
        let workFolder = health.appRoot.appendingPathComponent(Builder.builderResourceDir).appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }

        var export = try Builder.BuildExport(from: "type=oci")
        export.destination = workFolder.appendingPathComponent("out.tar")
        let ignoreFile = try? Data(contentsOf: URL(fileURLWithPath: specification.dockerfile + ".dockerignore"))
        let platform = try Platform(from: "linux/\(Platform.current.architecture)")

        let config = Builder.BuildConfig(
            buildID: buildID, contentStore: RemoteContentStoreClient(), buildArgs: specification.buildArguments, secrets: [:],
            ssh: "", contextDir: specification.contextDirectory, dockerfile: specification.dockerfileContents,
            dockerignore: ignoreFile,
            labels: specification.labels.map { "\($0.key)=\($0.value)" }.sorted(), noCache: specification.noCache,
            platforms: [platform], terminal: nil, tags: [specification.tag], target: specification.target ?? "", quiet: false,
            exports: [export], cacheIn: [], cacheOut: [], pull: false, containerSystemConfig: configuration)

        await bridge.step("Building")
        try await builder.build(config)

        await bridge.step("Loading the built image")
        guard let archive = export.destination else {
            throw ContainerizationError(.internalError, message: "the build produced no archive")
        }
        let loaded = try await ClientImage.load(from: archive.path(percentEncoded: false), force: false)
        guard loaded.rejectedMembers.isEmpty else {
            throw ContainerizationError(.internalError, message: "the built archive contains invalid members")
        }
        var images: [ImageSummary] = []
        for image in loaded.images {
            try await image.unpack(platform: nil, progressUpdate: bridge.handler)
            let tagged = try await image.tag(new: specification.tag)
            let size = try? await ClientImage.getFullImageSize(image: tagged)
            images.append(ImageSummary(reference: tagged.reference, digest: tagged.digest, sizeBytes: size))
        }
        return images
    }

    /// Dials the builder over vsock until BuildKit answers, as the CLI does, for up to five minutes.
    private func connectToBuilder(configuration: ContainerSystemConfig, bridge: ProgressBridge) async throws -> Builder {
        let client = ContainerClient()
        let deadline = Date().addingTimeInterval(300)
        var lastError: (any Error)?
        while Date() < deadline {
            try Task.checkCancellation()
            // Builder.build shuts this group down when the build completes.
            let group = MultiThreadedEventLoopGroup(numberOfThreads: ProcessInfo.processInfo.activeProcessorCount)
            do {
                let socket = try await client.dial(id: "buildkit", port: Self.builderVsockPort)
                let builder = try await Builder(socket: socket, group: group, logger: log)
                _ = try await builder.info()
                return builder
            } catch {
                lastError = error
                try? await group.shutdownGracefully()
                try await Task.sleep(for: .seconds(5))
            }
        }
        throw ContainerizationError(.timeout, message: "timed out connecting to the builder: \(lastError.map { "\($0)" } ?? "no answer")")
    }
}
