import Foundation

/// Runs one tool call: strict argument decoding, the policy decision, the backend call and
/// the audit entry. There is no path from a tool to the backend that skips `Policy`.
public actor ToolDispatcher {
    private let backend: any ContainerBackend
    private let configurationState: ConfigurationState
    private let paths: ServerPaths
    private let audit: AuditLog
    private let ownedImages: OwnedImages

    /// Limits for the read tools when there is no configuration. Like the configured ones,
    /// they are held to what a result may be through `effective`.
    static let readOnlyLogLimits = Configuration.LogLimits(maximumLines: 200, maximumBytes: 65_536).effective

    /// How long one call may take before it is abandoned. Always inside `ToolStandard.timeLimit`.
    private let deadline: Duration

    public init(
        backend: any ContainerBackend, configurationState: ConfigurationState, paths: ServerPaths, audit: AuditLog,
        ownedImages: OwnedImages, deadline: Duration = ToolCatalog.callDeadline
    ) {
        self.backend = backend
        self.configurationState = configurationState
        self.paths = paths
        self.audit = audit
        self.ownedImages = ownedImages
        self.deadline = deadline
    }

    /// Thrown by handlers when the service, not the policy, failed.
    struct BackendFailure: Error {
        let message: String
    }

    /// The outcome of one call, before it is written to the audit log.
    private struct Completed: Sendable {
        var output: ToolOutput
        var decision: AuditLog.Decision
        var rule: String
        var result: String
    }

    public func call(name: String, arguments: [String: Value]?, progress: ProgressSink = .none) async -> ToolOutput {
        let auditArguments = AuditValue(.object(arguments ?? [:]))
        guard let tool = ToolName(rawValue: name) else {
            await audit.record(tool: name, arguments: auditArguments, decision: .refused, rule: Rule.inputInvalid.rawValue, result: "unknown tool")
            return Self.errorResult("'\(ToolStandard.echo(name))' is not a tool of this server.")
        }
        // The work is abandoned, not stopped, when the deadline passes, so the audit entry is
        // written here, from what the call returned, and a late result never reaches it.
        let completed = await Deadline.run(within: deadline) { await self.complete(tool, arguments: arguments, progress: progress) }
            ?? Completed(
                output: Self.errorResult(Self.timeoutMessage(tool, seconds: Int(deadline.components.seconds))),
                decision: .failed, rule: "policy", result: "did not finish within \(deadline.components.seconds) seconds")
        await audit.record(tool: name, arguments: auditArguments, decision: completed.decision, rule: completed.rule, result: completed.result)
        return completed.output
    }

    private func complete(_ tool: ToolName, arguments: [String: Value]?, progress: ProgressSink) async -> Completed {
        do {
            let output = try await run(tool, arguments: arguments, progress: progress)
            return Completed(output: ToolOutput(text: output.text, isError: false), decision: .allowed, rule: "policy", result: output.summary)
        } catch let refusal as Refusal {
            return Completed(output: Self.errorResult(refusal.description), decision: .refused, rule: refusal.rule.rawValue, result: refusal.reason)
        } catch let failure as BackendFailure {
            return Completed(
                output: Self.errorResult("The container service reported an error: \(Self.clipped(failure.message))"),
                decision: .failed, rule: "policy", result: failure.message)
        } catch {
            let message = String(describing: error)
            return Completed(
                output: Self.errorResult("The container service reported an error: \(Self.clipped(message))"),
                decision: .failed, rule: "policy", result: message)
        }
    }

    /// What the service said, kept short enough that an error stays an error and not a dump.
    static func clipped(_ message: String) -> String {
        message.count > ToolCatalog.serviceMessageWidth ? String(message.prefix(ToolCatalog.serviceMessageWidth)) + "…" : message
    }

    /// The error for a call that reached its deadline. A tool that changes something says
    /// that the change may have been made, and what to look at before trying again.
    static func timeoutMessage(_ tool: ToolName, seconds: Int) -> String {
        let head = "The call did not finish within \(seconds) seconds and was abandoned."
        if tool.isReadOnly {
            return "\(head) This tool only reads, so nothing was changed. Try again; system_status says whether the container service answers."
        }
        return "\(head) The change may still have been made: look with \(tool.listTool) before trying again."
    }

    static func errorResult(_ text: String) -> ToolOutput {
        ToolOutput(text: text, isError: true)
    }

    struct Output {
        var text: String
        var summary: String
    }

    // MARK: Gates

    private func requireConfiguration() throws(Refusal) -> Policy {
        switch configurationState {
        case .loaded(let configuration):
            return Policy(configuration: configuration, paths: paths)
        case .missing:
            throw Refusal(.configurationMissing, "the server was started without policy settings, so only read tools work", allowed: "read tools; write tools when the server runs as the Apple container extension")
        case .writeToolsDisabled:
            throw Refusal(.configurationWriteToolsOff, "write tools are switched off in the extension's settings", allowed: "read tools; write tools once the user turns on \"Allow write tools\" in the extension settings")
        case .invalid(let problem):
            throw Refusal(.configurationInvalid, "the extension's settings are invalid (\(Self.clipped(problem))), so only read tools work", allowed: "read tools; write tools once the user fixes the extension settings")
        }
    }

    /// Every tool except the two system tools needs a running service of the exact version
    /// the server was built against, because its messages are decoded as fixed structures.
    private func requireMatchingService() async throws -> SystemStatus {
        let status = try await backend.systemStatus()
        guard status.running else {
            throw BackendFailure(message: "the container service is not running; system_start starts it")
        }
        guard status.versionMatches else {
            throw Refusal(
                .serviceVersionMismatch,
                "the container service is version \(status.serviceVersion ?? "unknown") but this server was built for \(status.expectedServiceVersion)",
                allowed: "system_status only, until the server is rebuilt for the installed container release")
        }
        return status
    }

    // MARK: Dispatch

    private func run(_ tool: ToolName, arguments raw: [String: Value]?, progress: ProgressSink) async throws -> Output {
        switch tool {
        case .systemStatus:
            _ = try Arguments(raw, allowed: [])
            return try await systemStatus()
        case .systemStart:
            _ = try Arguments(raw, allowed: [])
            let policy = try requireConfiguration()
            return try await systemStart(policy: policy, progress: progress)
        default:
            break
        }

        let policy: Policy?
        if tool.isReadOnly {
            policy = configurationState.configuration.map { Policy(configuration: $0, paths: paths) }
        } else {
            policy = try requireConfiguration()
        }
        let status = try await requireMatchingService()

        switch tool {
        case .systemStatus, .systemStart:
            preconditionFailure("handled above")
        case .containersList:
            let arguments = try Arguments(raw, allowed: ["all", "limit", "offset"])
            let all = try arguments.boolean("all", default: true)
            var containers = try await backend.listContainers()
            if !all { containers = containers.filter(\.isRunning) }
            let protected = Set(configurationState.protectedContainers)
            let items = containers.sorted { $0.id < $1.id }.map { container -> [String: Any] in
                // A protected container shows only that it exists, nothing of its configuration.
                if protected.contains(container.id) {
                    return ["id": container.id, "status": container.status, "protected": true]
                }
                var item = Self.jsonObject(container) as? [String: Any] ?? [:]
                item["owned"] = Policy.isOwned(container.labels)
                item["protected"] = false
                item["infrastructure"] = Policy.isInfrastructure(container.labels)
                return item
            }
            return try Self.listing(
                arguments, key: "containers", things: "containers", rows: items,
                defaultLimit: ToolCatalog.defaultContainerLimit, limits: ToolCatalog.containerLimitRange, narrow: true, narrowWith: ToolName.containerInspect.rawValue)
        case .containerInspect:
            let arguments = try Arguments(raw, allowed: ["id", "fields"])
            let id = try arguments.requiredString("id")
            try Policy.approveContainerAccess(.read, on: try await findContainer(id), protectedContainers: configurationState.protectedContainers)
            let detail = try await backend.inspectContainer(id: id)
            let description = (try? JSONSerialization.jsonObject(with: detail.redactedJSON)) ?? [:]
            let text = try Self.inspection(
                arguments, label: "the description of \(ToolStandard.echo(id))",
                wrapper: ["owned": Policy.isOwned(detail.summary.labels)], memberKey: "container", description: description)
            return Output(text: text, summary: "inspected \(id)")
        case .containerLogs:
            let arguments = try Arguments(raw, allowed: ["id", "limit", "offset", "boot"])
            let id = try arguments.requiredString("id")
            let boot = try arguments.boolean("boot", default: false)
            let limits = policy?.configuration.effectiveLogLimits ?? Self.readOnlyLogLimits
            let (limit, offset) = try arguments.page(
                defaultLimit: min(ToolCatalog.defaultLogLimit, limits.maximumLines), limits: 1...limits.maximumLines)
            try Policy.approveContainerAccess(.read, on: try await findContainer(id), protectedContainers: configurationState.protectedContainers)
            let data = try await backend.logs(id: id, boot: boot)
            // Without a limit, the page aims at one usual page of text, not at the most the settings allow.
            let bytes = arguments.wasGiven("limit") ? limits.maximumBytes : min(limits.maximumBytes, ToolStandard.usualPage)
            return Self.logPage(arguments, id: id, boot: boot, data: data, limit: limit, offset: offset, maximumBytes: bytes)
        case .containerStats:
            let arguments = try Arguments(raw, allowed: ["id"])
            let id = try arguments.requiredString("id")
            let container = try await findContainer(id)
            try Policy.approveContainerAccess(.read, on: container, protectedContainers: configurationState.protectedContainers)
            guard container.isRunning else {
                throw Refusal(.stateNotRunning, "\(id) is \(container.status)", allowed: "statistics of running containers")
            }
            let stats = try await backend.stats(id: id)
            return Output(text: Self.render(Self.jsonObject(stats)), summary: "stats for \(id)")
        case .imagesList:
            let arguments = try Arguments(raw, allowed: ["limit", "offset"])
            let images = try await backend.listImages()
            let owned = await ownedImages.all
            let infrastructure = try await backend.infrastructureImages()
            let items = images.sorted { ($0.reference, $0.digest) < ($1.reference, $1.digest) }.map { image -> [String: Any] in
                var item = Self.jsonObject(image) as? [String: Any] ?? [:]
                item["owned"] = owned.contains(image.reference)
                item["infrastructure"] = image.reference == infrastructure.initImage || image.reference == infrastructure.builderImage
                return item
            }
            return try Self.listing(
                arguments, key: "images", things: "images", rows: items,
                defaultLimit: ToolCatalog.defaultImageLimit, limits: ToolCatalog.imageLimitRange)
        case .imageInspect:
            let arguments = try Arguments(raw, allowed: ["reference", "fields"])
            let reference = try arguments.requiredString("reference")
            guard ImageReference.isWellFormed(reference) else {
                throw Refusal(.inputInvalid, "image reference \(ToolStandard.echo(reference)) is not well formed", allowed: "references such as alpine:3.20")
            }
            let detail = try await backend.inspectImage(reference: reference)
            let description = (try? JSONSerialization.jsonObject(with: detail.json)) ?? [:]
            let owned = await ownedImages.all.contains(detail.summary.reference)
            let text = try Self.inspection(
                arguments, label: "the description of \(ToolStandard.echo(detail.summary.reference))",
                wrapper: ["owned": owned], memberKey: "image", description: description)
            return Output(text: text, summary: "inspected \(detail.summary.reference)")
        case .volumesList:
            let arguments = try Arguments(raw, allowed: ["limit", "offset"])
            let volumes = try await backend.listVolumes()
            let items = volumes.sorted { $0.name < $1.name }.map { volume -> [String: Any] in
                var item = Self.jsonObject(volume) as? [String: Any] ?? [:]
                item["owned"] = Policy.isOwned(volume.labels)
                return item
            }
            return try Self.listing(
                arguments, key: "volumes", things: "volumes", rows: items,
                defaultLimit: ToolCatalog.defaultVolumeLimit, limits: ToolCatalog.volumeLimitRange, narrow: true)
        case .networksList:
            let arguments = try Arguments(raw, allowed: ["limit", "offset"])
            let networks = try await backend.listNetworks()
            let items = networks.sorted { $0.name < $1.name }.map { network -> [String: Any] in
                var item = Self.jsonObject(network) as? [String: Any] ?? [:]
                item["owned"] = Policy.isOwned(network.labels)
                return item
            }
            return try Self.listing(
                arguments, key: "networks", things: "networks", rows: items,
                defaultLimit: ToolCatalog.defaultNetworkLimit, limits: ToolCatalog.networkLimitRange, narrow: true)
        case .diskUsage:
            _ = try Arguments(raw, allowed: [])
            let usage = try await backend.diskUsage()
            return Output(text: Self.render(Self.jsonObject(usage)), summary: "disk usage")

        case .containerRun:
            return try await containerRun(raw, policy: policy!, status: status, progress: progress)
        case .containerStart:
            let arguments = try Arguments(raw, allowed: ["id"])
            let container = try await findContainer(try arguments.requiredString("id"))
            try policy!.approveLifecycle(.start, on: container)
            if container.isRunning {
                return Output(text: Self.render(["id": container.id, "status": "running", "changed": false]), summary: "already running")
            }
            try await backend.startContainer(id: container.id)
            return Output(text: Self.render(["id": container.id, "status": "running", "changed": true]), summary: "started")
        case .containerStop:
            let arguments = try Arguments(raw, allowed: ["id", "timeout_seconds"])
            let container = try await findContainer(try arguments.requiredString("id"))
            try policy!.approveLifecycle(.stop, on: container)
            let timeout = try policy!.approveStopTimeout(
                try arguments.optionalQuantity("timeout_seconds", in: ToolCatalog.stopTimeoutRange))
            if container.status == "stopped" {
                return Output(text: ToolStandard.withNotices(arguments.notices, Self.render(["id": container.id, "status": "stopped", "changed": false])), summary: "already stopped")
            }
            try await backend.stopContainer(id: container.id, timeoutSeconds: timeout)
            return Output(text: ToolStandard.withNotices(arguments.notices, Self.render(["id": container.id, "status": "stopped", "changed": true])), summary: "stopped")
        case .containerExec:
            let arguments = try Arguments(raw, allowed: ["id", "command", "env", "workdir", "user", "timeout_seconds"])
            let limits = policy!.configuration.effectiveExecLimits
            let input = ExecInput(
                id: try arguments.requiredString("id"), command: try arguments.stringArray("command"),
                environment: try arguments.stringArray("env"), workingDirectory: try arguments.string("workdir"),
                user: try arguments.string("user"),
                timeoutSeconds: try arguments.optionalQuantity("timeout_seconds", in: 1...limits.maximumTimeoutSeconds))
            let container = try await findContainer(input.id)
            let specification = try policy!.approveExec(input, on: container)
            let result = try await backend.exec(id: container.id, specification: specification)
            return Self.execResult(result, notices: arguments.notices, timeoutSeconds: specification.timeoutSeconds)
        case .imagePull:
            let arguments = try Arguments(raw, allowed: ["reference", "platform"])
            let reference = try arguments.requiredString("reference")
            let platform = try arguments.string("platform")
            if let platform, platform.range(of: #"^[a-z0-9]+/[a-z0-9_]+(/[a-z0-9]+)?$"#, options: .regularExpression) == nil {
                throw Refusal(.inputInvalid, "platform \(ToolStandard.echo(platform)) is not os/arch[/variant]", allowed: "values such as linux/arm64")
            }
            try policy!.approveRegistry(for: reference, defaultDomain: status.defaultRegistryDomain)
            let normalized = try await backend.normalizeImageReference(reference)
            let wasPresent = try await backend.listImages().contains { $0.reference == normalized }
            let image = try await Self.withTimeout(seconds: policy!.configuration.effectivePullTimeoutSeconds, operation: "pull", look: .imagesList) {
                try await self.backend.pullImage(reference: reference, platform: platform, progress: progress)
            }
            if !wasPresent { await ownedImages.add(image.reference) }
            let owned = await ownedImages.all.contains(image.reference)
            var object = Self.jsonObject(image) as? [String: Any] ?? [:]
            object["owned"] = owned
            return Output(text: Self.render(object), summary: "pulled \(image.reference)")
        case .imageBuild:
            return try await imageBuild(raw, policy: policy!, status: status, progress: progress)
        case .volumeCreate:
            let arguments = try Arguments(raw, allowed: ["name", "size_mib"])
            let name = try arguments.requiredString("name")
            let size = try policy!.approveVolumeCreate(
                name: name, sizeMiB: try arguments.optionalQuantity("size_mib", in: ToolCatalog.volumeSizeRange), existing: try await backend.listVolumes())
            let volume = try await backend.createVolume(name: name, sizeBytes: size, labels: Policy.ownershipLabels)
            return Output(text: ToolStandard.withNotices(arguments.notices, Self.render(Self.jsonObject(volume))), summary: "created volume \(volume.name)")
        case .networkCreate:
            let arguments = try Arguments(raw, allowed: ["name", "internal", "subnet"])
            let name = try arguments.requiredString("name")
            let subnet = try arguments.string("subnet")
            try policy!.approveNetworkCreate(name: name, subnet: subnet, existing: try await backend.listNetworks())
            let network = try await backend.createNetwork(
                name: name, hostOnly: try arguments.boolean("internal", default: false), subnet: subnet, labels: Policy.ownershipLabels)
            return Output(text: Self.render(Self.jsonObject(network)), summary: "created network \(network.name)")

        case .containerDelete:
            let arguments = try Arguments(raw, allowed: ["id"])
            let container = try await findContainer(try arguments.requiredString("id"))
            try policy!.approveContainerDelete(container)
            try await backend.deleteContainer(id: container.id)
            return Output(text: Self.render(["id": container.id, "deleted": true]), summary: "deleted \(container.id)")
        case .imageDelete:
            let arguments = try Arguments(raw, allowed: ["reference"])
            let reference = try arguments.requiredString("reference")
            guard ImageReference.isWellFormed(reference) else {
                throw Refusal(.inputInvalid, "image reference \(ToolStandard.echo(reference)) is not well formed", allowed: "references such as alpine:3.20")
            }
            let normalized = try await backend.normalizeImageReference(reference)
            try policy!.approveImageDelete(
                normalizedReference: normalized, ownedImages: await ownedImages.all, infrastructure: try await backend.infrastructureImages())
            try await backend.deleteImage(reference: normalized)
            await ownedImages.remove(normalized)
            return Output(text: Self.render(["reference": normalized, "deleted": true]), summary: "deleted \(normalized)")
        case .volumeDelete:
            let arguments = try Arguments(raw, allowed: ["name"])
            let name = try arguments.requiredString("name")
            guard let volume = try await backend.listVolumes().first(where: { $0.name == name }) else {
                throw BackendFailure(message: "volume \(ToolStandard.echo(name)) not found")
            }
            try policy!.approveVolumeDelete(volume)
            try await backend.deleteVolume(name: name)
            return Output(text: Self.render(["name": name, "deleted": true]), summary: "deleted volume \(name)")
        case .networkDelete:
            let arguments = try Arguments(raw, allowed: ["name"])
            let name = try arguments.requiredString("name")
            guard let network = try await backend.listNetworks().first(where: { $0.name == name }) else {
                throw BackendFailure(message: "network \(ToolStandard.echo(name)) not found")
            }
            try policy!.approveNetworkDelete(network)
            try await backend.deleteNetwork(name: name)
            return Output(text: Self.render(["name": name, "deleted": true]), summary: "deleted network \(name)")
        }
    }

    private func findContainer(_ id: String) async throws -> ContainerSummary {
        guard ContainerName.isValid(id) else {
            throw Refusal(.inputInvalid, "\(ToolStandard.echo(id)) is not a valid container name", allowed: "names of existing containers")
        }
        guard let container = try await backend.listContainers().first(where: { $0.id == id }) else {
            throw BackendFailure(message: "container \(id) not found")
        }
        return container
    }

    // MARK: Handlers with more steps

    private func systemStatus() async throws -> Output {
        let status = try await backend.systemStatus()
        var object = Self.jsonObject(status) as? [String: Any] ?? [:]
        object["versionMatches"] = status.versionMatches
        switch configurationState {
        case .loaded(let configuration):
            object["configuration"] = [
                "state": "loaded", "source": "extension settings",
                "mountRoots": configuration.mountRoots.map { ["path": $0.path, "writable": $0.writable] },
                "hostPorts": ["min": configuration.hostPorts.minimum, "max": configuration.hostPorts.maximum],
                "registries": configuration.registries,
                "protected": configuration.protectedContainers,
            ]
        case .missing:
            object["configuration"] = ["state": "missing", "effect": "only read tools work: the server was started without policy settings"]
        case .writeToolsDisabled:
            object["configuration"] = ["state": "write tools off", "effect": "only read tools work until the user turns on \"Allow write tools\" in the extension settings"]
        case .invalid(let problem):
            object["configuration"] = ["state": "invalid", "problem": Self.clipped(problem), "effect": "only read tools work"]
        }
        object["auditLog"] = paths.auditFile
        return Output(text: Self.render(object), summary: status.running ? "running" : "not running")
    }

    private func systemStart(policy: Policy, progress: ProgressSink) async throws -> Output {
        let before = try await backend.systemStatus()
        if before.running {
            return Output(
                text: Self.render(["alreadyRunning": true, "serviceVersion": before.serviceVersion ?? "unknown", "versionMatches": before.versionMatches]),
                summary: "already running")
        }
        let report = try await backend.startSystem(progress: progress)
        let after = try await backend.systemStatus()
        var notes = report.notes
        if after.running, !after.versionMatches {
            notes.append("The service is version \(after.serviceVersion ?? "unknown"); this server needs \(after.expectedServiceVersion), so only system_status works until it is rebuilt.")
        }
        // The init image is pulled only from a listed registry; a missing one is reported, not fetched.
        if after.running, after.versionMatches {
            let infrastructure = try await backend.infrastructureImages()
            let local = Set(try await backend.listImages().map(\.reference))
            if !local.contains(infrastructure.initImage) {
                do {
                    try policy.approveRegistry(for: infrastructure.initImage, defaultDomain: after.defaultRegistryDomain)
                    _ = try await Self.withTimeout(seconds: policy.configuration.effectivePullTimeoutSeconds, operation: "init image pull", look: .imagesList) {
                        try await self.backend.pullImage(reference: infrastructure.initImage, platform: nil, progress: progress)
                    }
                    notes.append("Pulled the init image \(infrastructure.initImage).")
                } catch let refusal as Refusal {
                    notes.append("The init image \(infrastructure.initImage) is missing and was not pulled: \(refusal.description)")
                }
            }
        }
        return Output(
            text: Self.render(["alreadyRunning": false, "running": after.running, "serviceVersion": after.serviceVersion ?? "unknown", "notes": notes]),
            summary: after.running ? "started" : "not running after start")
    }

    private func containerRun(_ raw: [String: Value]?, policy: Policy, status: SystemStatus, progress: ProgressSink) async throws -> Output {
        let arguments = try Arguments(
            raw,
            allowed: ["image", "name", "start", "command", "entrypoint", "env", "workdir", "user", "cpus", "memory_mib", "ports", "mounts", "volumes", "network", "read_only_rootfs", "init"])
        let ports = try arguments.objectArray("ports", allowed: ["host_port", "container_port", "protocol"]).map { port throws(Refusal) in
            guard let host = try port.integer("host_port"), let container = try port.integer("container_port") else {
                throw Refusal(.inputInvalid, "every port needs host_port and container_port", allowed: "objects with host_port and container_port")
            }
            return RunInput.Port(hostPort: host, containerPort: container, protocolName: try port.string("protocol") ?? "tcp")
        }
        let mounts = try arguments.objectArray("mounts", allowed: ["host_path", "container_path", "writable"]).map { mount throws(Refusal) in
            RunInput.Mount(
                hostPath: try mount.requiredString("host_path"), containerPath: try mount.requiredString("container_path"),
                writable: try mount.boolean("writable", default: false))
        }
        let volumes = try arguments.objectArray("volumes", allowed: ["volume", "container_path", "read_only"]).map { volume throws(Refusal) in
            RunInput.Volume(
                volume: try volume.requiredString("volume"), containerPath: try volume.requiredString("container_path"),
                readOnly: try volume.boolean("read_only", default: false))
        }
        let input = RunInput(
            image: try arguments.requiredString("image"), name: try arguments.requiredString("name"),
            start: try arguments.boolean("start", default: true), command: try arguments.stringArray("command"),
            entrypoint: try arguments.string("entrypoint"), environment: try arguments.stringArray("env"),
            workingDirectory: try arguments.string("workdir"), user: try arguments.string("user"),
            cpus: try arguments.optionalQuantity("cpus", in: 1...policy.configuration.resources.maximumCPUs),
            memoryMiB: try arguments.optionalQuantity("memory_mib", in: ToolCatalog.smallestMemoryMiB...policy.configuration.resources.maximumMemoryMiB), ports: ports, mounts: mounts,
            volumes: volumes, network: try arguments.string("network"),
            readOnlyRootFilesystem: try arguments.boolean("read_only_rootfs", default: false),
            useInit: try arguments.boolean("init", default: false))

        guard ImageReference.isWellFormed(input.image) else {
            throw Refusal(.inputInvalid, "image reference \(ToolStandard.echo(input.image)) is not well formed", allowed: "references such as alpine:3.20")
        }
        let context = Policy.RunContext(
            normalizedImage: try await backend.normalizeImageReference(input.image),
            localImages: Set(try await backend.listImages().map(\.reference)),
            defaultRegistryDomain: status.defaultRegistryDomain, infrastructure: try await backend.infrastructureImages(),
            existingContainerIDs: Set(try await backend.listContainers().map(\.id)), volumes: try await backend.listVolumes(),
            networks: try await backend.listNetworks(), containerApplicationRoot: status.applicationRoot)
        let specification = try policy.approveRun(input, context: context)
        let wasPresent = context.localImages.contains(specification.image)
        let container = try await Self.withTimeout(seconds: policy.configuration.effectivePullTimeoutSeconds, operation: "run", look: .containersList) {
            try await self.backend.createContainer(specification, progress: progress)
        }
        if !wasPresent { await ownedImages.add(specification.image) }
        let narrowed = Self.narrowed(Self.jsonObject(container) as? [String: Any] ?? [:])
        var notices = arguments.notices
        if narrowed.clipped {
            notices.append(Notice.clipped(field: "Detail", width: ToolCatalog.widestRow, tool: ToolName.containerInspect.rawValue))
        }
        return Output(
            text: ToolStandard.withNotices(notices, Self.render(narrowed.values)),
            summary: "\(specification.start ? "ran" : "created") \(container.id)")
    }

    private func imageBuild(_ raw: [String: Value]?, policy: Policy, status: SystemStatus, progress: ProgressSink) async throws -> Output {
        let arguments = try Arguments(raw, allowed: ["context_path", "tag", "dockerfile", "build_args", "target", "no_cache"])
        let input = BuildInput(
            contextPath: try arguments.requiredString("context_path"), tag: try arguments.requiredString("tag"),
            dockerfile: try arguments.string("dockerfile"), buildArguments: try arguments.stringArray("build_args"),
            target: try arguments.string("target"), noCache: try arguments.boolean("no_cache", default: false))
        guard ImageReference.isWellFormed(input.tag) else {
            throw Refusal(.inputInvalid, "tag \(ToolStandard.echo(input.tag)) is not a valid image reference", allowed: "references such as demo:1")
        }
        let context = Policy.BuildContext(
            normalizedTag: try await backend.normalizeImageReference(input.tag),
            localImages: Set(try await backend.listImages().map(\.reference)), ownedImages: await ownedImages.all,
            defaultRegistryDomain: status.defaultRegistryDomain, infrastructure: try await backend.infrastructureImages(),
            containerApplicationRoot: status.applicationRoot)
        let specification = try policy.approveBuild(input, context: context)
        let images = try await Self.withTimeout(seconds: policy.configuration.effectiveBuildTimeoutSeconds, operation: "build", look: .imagesList) {
            try await self.backend.buildImage(specification, progress: progress)
        }
        for image in images { await ownedImages.add(image.reference) }
        return Output(text: Self.render(["images": images.map { Self.jsonObject($0) }]), summary: "built \(specification.tag)")
    }

    // MARK: Helpers

    /// `look` is the list tool that shows whether the abandoned work was done in part.
    static func withTimeout<T: Sendable>(
        seconds: Int, operation: String, look: ToolName, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw BackendFailure(
                    message: "\(operation) did not finish within \(seconds) seconds and was abandoned. The change may still have been made: look with \(look.rawValue) before trying again")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw BackendFailure(message: "\(operation) produced no result")
            }
            return result
        }
    }

    static func jsonObject<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }

    static func render(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
