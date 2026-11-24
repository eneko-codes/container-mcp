import Foundation

/// The single place where tool input becomes something the backend may act on. Every
/// function is pure: it looks only at its arguments, the configuration and the file system
/// paths it resolves, and either returns an approved specification or throws a `Refusal`.
public struct Policy: Sendable {
    public static let ownershipLabelKey = "container-mcp.managed-by"
    public static let ownershipLabelValue = "container-mcp"
    public static var ownershipLabels: [String: String] { [ownershipLabelKey: ownershipLabelValue] }
    /// Published ports always bind here; no tool input can choose another address.
    public static let loopbackAddress = "127.0.0.1"
    /// The container service refuses more than this many port descriptors.
    static let maximumPorts = 64

    public let configuration: Configuration
    public let paths: ServerPaths

    public init(configuration: Configuration, paths: ServerPaths) {
        self.configuration = configuration
        self.paths = paths
    }

    public static func isOwned(_ labels: [String: String]) -> Bool {
        labels[ownershipLabelKey] == ownershipLabelValue
    }

    // MARK: Mounts

    /// Resolves `hostPath` and checks it against the mount allowlist.
    /// Returns the resolved path and whether the mount is read-only.
    public func approveHostPath(
        _ hostPath: String, wantsWritable: Bool, containerApplicationRoot: String?, purpose: String = "mount"
    ) throws(Refusal) -> (resolved: String, readOnly: Bool) {
        guard hostPath.hasPrefix("/") else {
            throw Refusal(.inputInvalid, "\(purpose) path \(hostPath) is not absolute", allowed: "absolute host paths")
        }
        guard let resolved = PathResolution.resolveExisting(hostPath) else {
            throw Refusal(.inputInvalid, "\(purpose) path \(hostPath) does not exist", allowed: "existing folders")
        }
        let protected = paths.protectedPaths(containerApplicationRoot: containerApplicationRoot)
        let roots = configuration.mountRoots.map(\.path).joined(separator: ", ")
        if resolved == "/" || resolved == PathResolution.resolveAllowingMissing(paths.home) {
            throw Refusal(
                .mountProtected, "\(hostPath) resolves to \(resolved), which may never be used",
                allowed: "folders inside the mount roots (\(roots)) that are not protected")
        }
        for protectedPath in protected {
            if PathResolution.isSameOrInside(resolved, protectedPath) || PathResolution.isSameOrInside(protectedPath, resolved) {
                throw Refusal(
                    .mountProtected, "\(hostPath) resolves to \(resolved), which is or contains the protected path \(protectedPath)",
                    allowed: "folders inside the mount roots (\(roots)) that do not overlap protected paths")
            }
        }
        let matchingRoots = configuration.mountRoots.filter { PathResolution.isSameOrInside(resolved, $0.resolvedPath) }
        guard !matchingRoots.isEmpty else {
            throw Refusal(
                .mountOutsideRoots, "\(hostPath) resolves to \(resolved), outside every mount root",
                allowed: roots.isEmpty ? "nothing: the configuration lists no mount roots" : "paths inside \(roots)")
        }
        if wantsWritable {
            guard matchingRoots.contains(where: \.writable) else {
                let writableRoots = configuration.mountRoots.filter(\.writable).map(\.path)
                throw Refusal(
                    .mountWritableNotAllowed, "\(resolved) is only inside read-only mount roots",
                    allowed: writableRoots.isEmpty
                        ? "read-only mounts: no mount root is marked writable"
                        : "writable mounts inside \(writableRoots.joined(separator: ", ")), or a read-only mount here")
            }
            return (resolved, false)
        }
        return (resolved, true)
    }

    // MARK: Environment and simple fields

    /// Accepts only `KEY=value`. The key-only form would make the container service copy
    /// the value from the server's own environment, which must never reach a container.
    public static func approveEnvironment(_ entries: [String], field: String = "env") throws(Refusal) -> [String] {
        for (index, entry) in entries.enumerated() {
            guard let equals = entry.firstIndex(of: "=") else {
                throw Refusal(
                    .environmentKeyOnly, "\(field)[\(index)] has no \"=\", so its value would come from the host",
                    allowed: "explicit KEY=value entries")
            }
            let key = entry[..<equals]
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw Refusal(
                    .environmentInvalid, "\(field)[\(index)] has an invalid key",
                    allowed: "keys made of letters, digits and underscores, not starting with a digit")
            }
            guard !entry.contains("\0") else {
                throw Refusal(.environmentInvalid, "\(field)[\(index)] contains a NUL byte", allowed: "text values")
            }
        }
        return entries
    }

    static func approveContainerPath(_ path: String, field: String) throws(Refusal) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path != "/", !components.contains(".."), !path.contains("\0") else {
            throw Refusal(.inputInvalid, "\(field) \(path) is not an absolute container path", allowed: "absolute paths such as /data, not / and without ..")
        }
    }

    static func approveUser(_ user: String?) throws(Refusal) {
        guard let user else { return }
        guard user.range(of: #"^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$"#, options: .regularExpression) != nil else {
            throw Refusal(.inputInvalid, "user \(user) is not valid", allowed: "name, uid, name:group or uid:gid")
        }
    }

    static func approveArguments(_ arguments: [String], field: String, allowEmpty: Bool) throws(Refusal) {
        if !allowEmpty && arguments.isEmpty {
            throw Refusal(.inputInvalid, "\(field) is empty", allowed: "an array with the executable first")
        }
        guard arguments.count <= 256, arguments.allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") }) else {
            throw Refusal(.inputInvalid, "\(field) is too long or contains a NUL byte", allowed: "up to 256 arguments of up to 16 KiB")
        }
        if let first = arguments.first, first.isEmpty {
            throw Refusal(.inputInvalid, "\(field)[0] is empty", allowed: "an executable name or path")
        }
    }

    // MARK: Images

    /// Checks that pulling `reference` would only contact a listed registry.
    public func approveRegistry(for reference: String, defaultDomain: String) throws(Refusal) {
        guard ImageReference.isWellFormed(reference) else {
            throw Refusal(.inputInvalid, "image reference \(reference) is not well formed", allowed: "references such as alpine:3.20 or ghcr.io/owner/name:tag")
        }
        let domain = ImageReference.domain(of: reference, defaultDomain: defaultDomain)
        guard ImageReference.isAllowed(domain: domain, registries: configuration.registries) else {
            throw Refusal(
                .imageRegistry, "\(reference) would be fetched from \(domain), which is not listed",
                allowed: configuration.registries.isEmpty ? "no registries: the configuration lists none" : "images from \(configuration.registries.joined(separator: ", "))")
        }
    }

    /// An image that is already stored locally can be used without contacting any registry;
    /// one that is not would be pulled, so the registry rule applies.
    func approveImageUse(normalizedReference: String, localImages: Set<String>, defaultDomain: String) throws(Refusal) {
        if localImages.contains(normalizedReference) { return }
        try approveRegistry(for: normalizedReference, defaultDomain: defaultDomain)
    }

    // MARK: Resources

    func approveResources(cpus: Int?, memoryMiB: Int?) throws(Refusal) -> (cpus: Int, memoryMiB: Int) {
        let limits = configuration.resources
        let cpus = cpus ?? limits.defaultCPUs
        let memory = memoryMiB ?? limits.defaultMemoryMiB
        guard cpus >= 1, cpus <= limits.maximumCPUs else {
            throw Refusal(.resourceCPUs, "\(cpus) CPUs requested", allowed: "1 to \(limits.maximumCPUs) CPUs")
        }
        guard memory >= 200, memory <= limits.maximumMemoryMiB else {
            throw Refusal(.resourceMemory, "\(memory) MiB requested", allowed: "200 to \(limits.maximumMemoryMiB) MiB")
        }
        return (cpus, memory)
    }

    // MARK: container_run

    public struct RunContext: Sendable {
        public var normalizedImage: String
        public var localImages: Set<String>
        public var defaultRegistryDomain: String
        public var infrastructure: InfrastructureImages
        public var existingContainerIDs: Set<String>
        public var volumes: [VolumeSummary]
        public var networks: [NetworkSummary]
        public var containerApplicationRoot: String?

        public init(
            normalizedImage: String, localImages: Set<String>, defaultRegistryDomain: String,
            infrastructure: InfrastructureImages, existingContainerIDs: Set<String>, volumes: [VolumeSummary],
            networks: [NetworkSummary], containerApplicationRoot: String?
        ) {
            self.normalizedImage = normalizedImage
            self.localImages = localImages
            self.defaultRegistryDomain = defaultRegistryDomain
            self.infrastructure = infrastructure
            self.existingContainerIDs = existingContainerIDs
            self.volumes = volumes
            self.networks = networks
            self.containerApplicationRoot = containerApplicationRoot
        }
    }

    public func approveRun(_ input: RunInput, context: RunContext) throws(Refusal) -> RunSpecification {
        guard ContainerName.isValid(input.name) else {
            throw Refusal(.inputInvalid, "container name \(input.name) is not valid", allowed: "2 to 63 characters: letters, digits, _ . - , starting with a letter or digit")
        }
        guard !context.existingContainerIDs.contains(input.name) else {
            throw Refusal(.inputInvalid, "a container named \(input.name) already exists", allowed: "a name no container uses")
        }
        try approveImageUse(normalizedReference: context.normalizedImage, localImages: context.localImages, defaultDomain: context.defaultRegistryDomain)
        try approveImageUse(normalizedReference: context.infrastructure.initImage, localImages: context.localImages, defaultDomain: context.defaultRegistryDomain)

        try Self.approveArguments(input.command, field: "command", allowEmpty: true)
        if let entrypoint = input.entrypoint {
            try Self.approveArguments([entrypoint], field: "entrypoint", allowEmpty: false)
        }
        let environment = try Self.approveEnvironment(input.environment)
        if let workingDirectory = input.workingDirectory {
            try Self.approveContainerPath(workingDirectory, field: "workdir")
        }
        try Self.approveUser(input.user)
        let resources = try approveResources(cpus: input.cpus, memoryMiB: input.memoryMiB)

        guard input.ports.count <= Self.maximumPorts else {
            throw Refusal(.inputInvalid, "\(input.ports.count) ports requested", allowed: "at most \(Self.maximumPorts) ports")
        }
        var seenPorts: Set<String> = []
        var ports: [RunSpecification.Port] = []
        let range = configuration.hostPorts
        for (index, port) in input.ports.enumerated() {
            guard (range.minimum...range.maximum).contains(port.hostPort) else {
                throw Refusal(.portOutOfRange, "ports[\(index)].host_port \(port.hostPort) is outside the allowed range", allowed: "host ports \(range.minimum) to \(range.maximum), bound to \(Self.loopbackAddress)")
            }
            guard (1...65535).contains(port.containerPort) else {
                throw Refusal(.inputInvalid, "ports[\(index)].container_port \(port.containerPort) is not a port", allowed: "1 to 65535")
            }
            guard ["tcp", "udp"].contains(port.protocolName) else {
                throw Refusal(.inputInvalid, "ports[\(index)].protocol \(port.protocolName) is not supported", allowed: "tcp or udp")
            }
            guard seenPorts.insert("\(port.hostPort)/\(port.protocolName)").inserted else {
                throw Refusal(.portDuplicate, "host port \(port.hostPort)/\(port.protocolName) is listed twice", allowed: "each host port once per protocol")
            }
            ports.append(.init(hostAddress: Self.loopbackAddress, hostPort: port.hostPort, containerPort: port.containerPort, protocolName: port.protocolName))
        }

        var destinations: Set<String> = []
        var bindMounts: [RunSpecification.BindMount] = []
        for (index, mount) in input.mounts.enumerated() {
            try Self.approveContainerPath(mount.containerPath, field: "mounts[\(index)].container_path")
            let approved = try approveHostPath(mount.hostPath, wantsWritable: mount.writable, containerApplicationRoot: context.containerApplicationRoot)
            guard destinations.insert(mount.containerPath).inserted else {
                throw Refusal(.inputInvalid, "container path \(mount.containerPath) is used twice", allowed: "one mount per container path")
            }
            bindMounts.append(.init(source: approved.resolved, destination: mount.containerPath, readOnly: approved.readOnly))
        }

        var volumeMounts: [RunSpecification.VolumeMount] = []
        for (index, volume) in input.volumes.enumerated() {
            try Self.approveContainerPath(volume.containerPath, field: "volumes[\(index)].container_path")
            guard let existing = context.volumes.first(where: { $0.name == volume.volume }) else {
                throw Refusal(.inputInvalid, "volume \(volume.volume) does not exist", allowed: "volumes created with volume_create")
            }
            guard Self.isOwned(existing.labels) else {
                throw Refusal(.mountVolumeNotOwned, "volume \(volume.volume) was not created by this server", allowed: "volumes created with volume_create")
            }
            guard destinations.insert(volume.containerPath).inserted else {
                throw Refusal(.inputInvalid, "container path \(volume.containerPath) is used twice", allowed: "one mount per container path")
            }
            volumeMounts.append(.init(volume: volume.volume, destination: volume.containerPath, readOnly: volume.readOnly))
        }

        if let network = input.network {
            guard let existing = context.networks.first(where: { $0.name == network }) else {
                throw Refusal(.inputInvalid, "network \(network) does not exist", allowed: "the default network or one created with network_create")
            }
            guard existing.builtin || Self.isOwned(existing.labels) else {
                throw Refusal(.networkNotAllowed, "network \(network) was not created by this server", allowed: "the default network or one created with network_create")
            }
        }

        return RunSpecification(
            name: input.name, image: context.normalizedImage, command: input.command, entrypoint: input.entrypoint,
            environment: environment, workingDirectory: input.workingDirectory, user: input.user,
            cpus: resources.cpus, memoryMiB: resources.memoryMiB, ports: ports, bindMounts: bindMounts,
            volumeMounts: volumeMounts, network: input.network, readOnlyRootFilesystem: input.readOnlyRootFilesystem,
            useInit: input.useInit, start: input.start, labels: Self.ownershipLabels)
    }

    // MARK: Container lifecycle

    public enum LifecycleAction: String, Sendable {
        case start, stop, exec, delete
    }

    /// Ownership rule: start, stop, exec and delete need the server's label. Containers the
    /// user adopted in the configuration may also be started and stopped, nothing else.
    public func approveLifecycle(_ action: LifecycleAction, on container: ContainerSummary) throws(Refusal) {
        let owned = Self.isOwned(container.labels)
        let adopted = configuration.adoptedContainers.contains(container.id)
        if owned { return }
        switch (action, adopted) {
        case (.start, true), (.stop, true):
            return
        case (.exec, true):
            throw Refusal(.ownershipAdoptedExec, "\(container.id) is adopted, and adopted containers are never exec'd into", allowed: "exec into containers this server created")
        case (.delete, true):
            throw Refusal(.ownershipAdoptedDelete, "\(container.id) is adopted, and adopted containers are never deleted", allowed: "deleting containers this server created")
        default:
            throw Refusal(
                .ownershipUnlabelled, "\(container.id) was not created by this server",
                allowed: action == .start || action == .stop
                    ? "containers this server created, or containers listed under \"adopted\" in the configuration"
                    : "containers this server created")
        }
    }

    public func approveExec(_ input: ExecInput, on container: ContainerSummary) throws(Refusal) -> ExecSpecification {
        try approveLifecycle(.exec, on: container)
        guard container.isRunning else {
            throw Refusal(.stateNotRunning, "\(container.id) is \(container.status)", allowed: "exec into running containers")
        }
        try Self.approveArguments(input.command, field: "command", allowEmpty: false)
        let environment = try Self.approveEnvironment(input.environment)
        if let workingDirectory = input.workingDirectory {
            try Self.approveContainerPath(workingDirectory, field: "workdir")
        }
        try Self.approveUser(input.user)
        let maximum = configuration.exec.maximumTimeoutSeconds
        let timeout = input.timeoutSeconds ?? maximum
        guard timeout >= 1, timeout <= maximum else {
            throw Refusal(.boundsExecTimeout, "timeout_seconds \(timeout) requested", allowed: "1 to \(maximum) seconds")
        }
        return ExecSpecification(
            command: input.command, environment: environment, workingDirectory: input.workingDirectory, user: input.user,
            timeoutSeconds: timeout, maximumOutputBytes: configuration.exec.maximumOutputBytes)
    }

    public func approveContainerDelete(_ container: ContainerSummary) throws(Refusal) {
        try approveLifecycle(.delete, on: container)
        guard container.status == "stopped" else {
            throw Refusal(.stateRunning, "\(container.id) is \(container.status)", allowed: "deleting stopped containers; stop it first")
        }
    }

    public func approveStopTimeout(_ seconds: Int?) throws(Refusal) -> Int {
        let timeout = seconds ?? 5
        guard (0...300).contains(timeout) else {
            throw Refusal(.inputInvalid, "timeout_seconds \(timeout) requested", allowed: "0 to 300 seconds")
        }
        return timeout
    }

    // MARK: Logs

    /// The number of lines and bytes a log call may return.
    public func approveLogs(lines: Int?) throws(Refusal) -> (lines: Int, bytes: Int) {
        let limits = configuration.logs
        let requested = lines ?? limits.maximumLines
        guard requested >= 1 else {
            throw Refusal(.inputInvalid, "lines \(requested) requested", allowed: "1 to \(limits.maximumLines) lines")
        }
        return (min(requested, limits.maximumLines), limits.maximumBytes)
    }

    // MARK: Images, volumes and networks

    public func approveImageDelete(normalizedReference: String, ownedImages: Set<String>, infrastructure: InfrastructureImages) throws(Refusal) {
        guard normalizedReference != infrastructure.initImage, normalizedReference != infrastructure.builderImage else {
            throw Refusal(.ownershipImageNotOwned, "\(normalizedReference) is an image the container service itself needs", allowed: "images this server pulled or built")
        }
        guard ownedImages.contains(normalizedReference) else {
            throw Refusal(.ownershipImageNotOwned, "\(normalizedReference) was not pulled or built by this server", allowed: "images this server pulled or built")
        }
    }

    public func approveVolumeCreate(name: String, sizeMiB: Int?, existing: [VolumeSummary]) throws(Refusal) -> UInt64? {
        guard ContainerName.isValidVolume(name) else {
            throw Refusal(.inputInvalid, "volume name \(name) is not valid", allowed: "letters, digits, _ . - , starting with a letter or digit")
        }
        guard !existing.contains(where: { $0.name == name }) else {
            throw Refusal(.inputInvalid, "a volume named \(name) already exists", allowed: "a name no volume uses")
        }
        guard let sizeMiB else { return nil }
        guard (1...1_048_576).contains(sizeMiB) else {
            throw Refusal(.inputInvalid, "size_mib \(sizeMiB) requested", allowed: "1 to 1048576 MiB")
        }
        return UInt64(sizeMiB) * 1_048_576
    }

    public func approveVolumeDelete(_ volume: VolumeSummary) throws(Refusal) {
        guard Self.isOwned(volume.labels) else {
            throw Refusal(.ownershipUnlabelled, "volume \(volume.name) was not created by this server", allowed: "deleting volumes this server created")
        }
    }

    public func approveNetworkCreate(name: String, subnet: String?, existing: [NetworkSummary]) throws(Refusal) {
        guard ContainerName.isValidNetwork(name) else {
            throw Refusal(.inputInvalid, "network name \(name) is not valid", allowed: "lowercase letters, digits, . _ - , up to 63 characters")
        }
        guard !existing.contains(where: { $0.name == name }) else {
            throw Refusal(.inputInvalid, "a network named \(name) already exists", allowed: "a name no network uses")
        }
        if let subnet, subnet.range(of: #"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$"#, options: .regularExpression) == nil {
            throw Refusal(.inputInvalid, "subnet \(subnet) is not an IPv4 CIDR", allowed: "CIDR such as 192.168.100.0/24")
        }
    }

    public func approveNetworkDelete(_ network: NetworkSummary) throws(Refusal) {
        guard !network.builtin, Self.isOwned(network.labels) else {
            throw Refusal(.ownershipUnlabelled, "network \(network.name) was not created by this server", allowed: "deleting networks this server created")
        }
    }

    // MARK: image_build

    public struct BuildContext: Sendable {
        public var normalizedTag: String
        public var localImages: Set<String>
        public var ownedImages: Set<String>
        public var defaultRegistryDomain: String
        public var infrastructure: InfrastructureImages
        public var containerApplicationRoot: String?
        public init(
            normalizedTag: String, localImages: Set<String>, ownedImages: Set<String>, defaultRegistryDomain: String,
            infrastructure: InfrastructureImages, containerApplicationRoot: String?
        ) {
            self.normalizedTag = normalizedTag
            self.localImages = localImages
            self.ownedImages = ownedImages
            self.defaultRegistryDomain = defaultRegistryDomain
            self.infrastructure = infrastructure
            self.containerApplicationRoot = containerApplicationRoot
        }
    }

    /// BuildKit refuses Dockerfiles from 16 KiB up in container 1.7.1 (apple/container#735).
    static let maximumDockerfileBytes = 16 * 1024

    public func approveBuild(_ input: BuildInput, context: BuildContext) throws(Refusal) -> BuildSpecification {
        let contextDirectory: String
        do {
            contextDirectory = try approveHostPath(input.contextPath, wantsWritable: false, containerApplicationRoot: context.containerApplicationRoot, purpose: "build context").resolved
        } catch {
            throw Refusal(.buildContext, error.reason, allowed: error.allowed)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: contextDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Refusal(.buildContext, "\(input.contextPath) is not a folder", allowed: "a folder inside the mount roots")
        }

        let relative = input.dockerfile ?? "Dockerfile"
        guard !relative.hasPrefix("/") else {
            throw Refusal(.buildContext, "dockerfile \(relative) is absolute", allowed: "a path relative to the build context")
        }
        guard let dockerfile = PathResolution.resolveExisting(contextDirectory + "/" + relative) else {
            throw Refusal(.buildContext, "dockerfile \(relative) does not exist in the context", allowed: "a Dockerfile inside the build context")
        }
        guard PathResolution.isSameOrInside(dockerfile, contextDirectory), dockerfile != contextDirectory else {
            throw Refusal(.buildContext, "dockerfile \(relative) resolves outside the build context", allowed: "a Dockerfile inside the build context")
        }
        guard let contents = FileManager.default.contents(atPath: dockerfile) else {
            throw Refusal(.buildContext, "dockerfile \(relative) cannot be read", allowed: "a readable file")
        }
        guard contents.count < Self.maximumDockerfileBytes else {
            throw Refusal(.inputInvalid, "the Dockerfile is \(contents.count) bytes", allowed: "Dockerfiles under 16 KiB (a limit of container 1.7.1)")
        }
        guard let text = String(data: contents, encoding: .utf8) else {
            throw Refusal(.inputInvalid, "the Dockerfile is not UTF-8 text", allowed: "UTF-8 Dockerfiles")
        }

        let scan: DockerfileScanner.Result
        do {
            scan = try DockerfileScanner.scan(text)
        } catch {
            guard case .variableReference(let reference) = error else { preconditionFailure("unhandled scan problem") }
            throw Refusal(.imageRegistry, "the Dockerfile refers to the image \(reference) through a variable, so its registry cannot be checked", allowed: "literal image references from \(configuration.registries.joined(separator: ", "))")
        }
        for image in scan.externalImages {
            try approveRegistry(for: image, defaultDomain: context.defaultRegistryDomain)
        }
        try approveImageUse(normalizedReference: context.infrastructure.builderImage, localImages: context.localImages, defaultDomain: context.defaultRegistryDomain)
        try approveImageUse(normalizedReference: context.infrastructure.initImage, localImages: context.localImages, defaultDomain: context.defaultRegistryDomain)

        guard ImageReference.isWellFormed(input.tag) else {
            throw Refusal(.inputInvalid, "tag \(input.tag) is not a valid image reference", allowed: "references such as demo:1")
        }
        if context.localImages.contains(context.normalizedTag) && !context.ownedImages.contains(context.normalizedTag) {
            throw Refusal(.ownershipImageTagTaken, "\(context.normalizedTag) already names an image this server did not create", allowed: "a new tag, or a tag of an image this server built or pulled")
        }
        let buildArguments = try Self.approveEnvironment(input.buildArguments, field: "build_args")
        if let target = input.target, target.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil {
            throw Refusal(.inputInvalid, "target \(target) is not a stage name", allowed: "a stage name from the Dockerfile")
        }
        return BuildSpecification(
            contextDirectory: contextDirectory, dockerfile: dockerfile, dockerfileContents: contents, tag: context.normalizedTag,
            buildArguments: buildArguments, target: input.target, noCache: input.noCache, labels: Self.ownershipLabels)
    }
}
