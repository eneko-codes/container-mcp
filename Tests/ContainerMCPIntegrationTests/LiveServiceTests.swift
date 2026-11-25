import ContainerAPIClient
import Foundation
import Testing

@testable import ContainerMCPCore
@testable import ContainerMCPNative

/// Runs every tool through the real policy and the real container service. Opt in with
/// `CONTAINER_MCP_INTEGRATION=1`; the build test also starts (or recreates) the shared
/// `buildkit` container. Everything created is named `container-mcp-it-…`, carries the
/// server's label, and is removed at the end, even after a failure.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CONTAINER_MCP_INTEGRATION"] == "1"))
struct LiveServiceTests {
    /// Not stored locally before the tests, so pulling it makes it the server's own.
    static let image = "docker.io/library/alpine:3.21"

    let suffix = String(UUID().uuidString.prefix(8)).lowercased()
    var name: String { "container-mcp-it-\(suffix)" }

    struct Harness {
        let scratch: String
        let readOnlyRoot: String
        let writableRoot: String
        let hostPort: Int
        let dispatcher: ToolDispatcher
        let audit: AuditLog
        let paths: ServerPaths
    }

    /// `protected` must list every container that existed before the test, so that no tool
    /// call of the test can touch one of the user's containers.
    func makeHarness(protected: [String]) throws -> Harness {
        let created = NSTemporaryDirectory() + "container-mcp-it-" + suffix
        let scratch = PathResolution.resolveAllowingMissing(created)
        let readOnlyRoot = scratch + "/readonly"
        let writableRoot = scratch + "/writable"
        for folder in [readOnlyRoot + "/src", writableRoot + "/out", readOnlyRoot + "/build", scratch + "/home/.ssh"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try Data("hello from the host\n".utf8).write(to: URL(fileURLWithPath: readOnlyRoot + "/src/greeting.txt"))
        try Data("FROM \(Self.image)\nRUN echo built > /built.txt\nCMD [\"cat\", \"/built.txt\"]\n".utf8)
            .write(to: URL(fileURLWithPath: readOnlyRoot + "/build/Dockerfile"))
        try FileManager.default.createSymbolicLink(atPath: readOnlyRoot + "/escape", withDestinationPath: scratch + "/home/.ssh")

        let hostPort = 18_000 + Int.random(in: 0..<999)
        let configuration = Configuration(
            mountRoots: [
                .init(path: readOnlyRoot, resolvedPath: readOnlyRoot, writable: false),
                .init(path: writableRoot, resolvedPath: writableRoot, writable: true),
            ],
            hostPorts: .init(minimum: 18_000, maximum: 18_999),
            registries: ["docker.io", "ghcr.io"],
            resources: .init(defaultCPUs: 1, maximumCPUs: 2, defaultMemoryMiB: 512, maximumMemoryMiB: 1024),
            logs: .init(maximumLines: 50, maximumBytes: 8192),
            exec: .init(maximumTimeoutSeconds: 20, maximumOutputBytes: 4096),
            pullTimeoutSeconds: 600, buildTimeoutSeconds: 900, protectedContainers: protected)
        let paths = ServerPaths(home: scratch + "/home")
        let audit = AuditLog(path: paths.auditFile)
        let dispatcher = ToolDispatcher(
            backend: NativeBackend(), configurationState: .loaded(configuration), paths: paths, audit: audit,
            ownedImages: OwnedImages(path: nil))
        return Harness(
            scratch: scratch, readOnlyRoot: readOnlyRoot, writableRoot: writableRoot, hostPort: hostPort,
            dispatcher: dispatcher, audit: audit, paths: paths)
    }

    func call(_ harness: Harness, _ tool: ToolName, _ arguments: [String: Value] = [:]) async -> (text: String, error: Bool) {
        let result = await harness.dispatcher.call(name: tool.rawValue, arguments: arguments)
        return (result.text, result.isError == true)
    }

    func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    /// Removes whatever this run created, straight through the backend, whatever state the test left.
    func cleanUp(_ harness: Harness, images: [String], stopBuildkit: Bool) async {
        let backend = NativeBackend()
        if stopBuildkit { try? await backend.stopContainer(id: "buildkit", timeoutSeconds: 5) }
        let containers = (try? await backend.listContainers()) ?? []
        for container in containers where container.id.hasPrefix(name) && Policy.isOwned(container.labels) {
            try? await backend.stopContainer(id: container.id, timeoutSeconds: 2)
            try? await backend.deleteContainer(id: container.id)
        }
        for volume in (try? await backend.listVolumes()) ?? [] where volume.name.hasPrefix(name) && Policy.isOwned(volume.labels) {
            try? await backend.deleteVolume(name: volume.name)
        }
        for network in (try? await backend.listNetworks()) ?? [] where network.name.hasPrefix(name) && Policy.isOwned(network.labels) {
            try? await backend.deleteNetwork(name: network.name)
        }
        for image in images {
            try? await backend.deleteImage(reference: image)
        }
        try? FileManager.default.removeItem(atPath: harness.scratch)
    }

    @Test func everyToolAgainstTheRealService() async throws {
        let backend = NativeBackend()
        let existing = try await backend.listContainers()
        let harness = try makeHarness(protected: existing.filter { !Policy.isInfrastructure($0.labels) }.map(\.id))
        let imagesBefore = Set(try await backend.listImages().map(\.reference))
        try #require(!imagesBefore.contains(Self.image), "\(Self.image) must not exist before the test, so that deleting it is safe")
        let builtTag = "docker.io/library/\(name):1"
        // The build starts the shared buildkit container; the test leaves it as it found it.
        let buildkitWasRunning = try await backend.listContainers().first { $0.id == "buildkit" }?.isRunning ?? false
        do {
            try await exercise(harness, backend: backend, imagesBefore: imagesBefore)
        } catch {
            await cleanUp(harness, images: [Self.image, builtTag], stopBuildkit: !buildkitWasRunning)
            throw error
        }
        await cleanUp(harness, images: [Self.image, builtTag], stopBuildkit: !buildkitWasRunning)
    }

    func exercise(_ harness: Harness, backend: NativeBackend, imagesBefore: Set<String>) async throws {
        // Status and read tools.
        let status = json(await call(harness, .systemStatus).text)
        #expect(status["running"] as? Bool == true)
        #expect(status["versionMatches"] as? Bool == true)
        for tool in [ToolName.containersList, .imagesList, .volumesList, .networksList, .diskUsage] {
            #expect(await call(harness, tool).error == false, "\(tool.rawValue)")
        }
        #expect(await call(harness, .systemStart).text.contains("\"alreadyRunning\" : true"))

        // Pull, with the registry rule enforced by the real normalization.
        #expect(await call(harness, .imagePull, ["reference": "quay.io/prometheus/busybox:latest"]).text.hasPrefix("Refused by rule image.registry"))
        let pull = await call(harness, .imagePull, ["reference": .string(Self.image)])
        #expect(!pull.error, "\(pull.text)")
        #expect(json(pull.text)["owned"] as? Bool == true)
        let inspectImage = await call(harness, .imageInspect, ["reference": .string(Self.image)])
        #expect(!inspectImage.error, "\(inspectImage.text)")

        // Volume and network.
        #expect(!(await call(harness, .volumeCreate, ["name": .string(name + "-data"), "size_mib": 64])).error)
        let network = await call(harness, .networkCreate, ["name": .string(name + "-net")])
        #expect(!network.error, "\(network.text)")

        // Run with every kind of mount, a port, env and a custom network.
        let run = await call(harness, .containerRun, [
            "image": .string(Self.image), "name": .string(name), "command": ["sleep", "300"],
            "env": ["MODE=integration", "TOKEN=it-secret-value"],
            "ports": [["host_port": .int(harness.hostPort), "container_port": 8080]],
            "mounts": [
                ["host_path": .string(harness.readOnlyRoot + "/src"), "container_path": "/src"],
                ["host_path": .string(harness.writableRoot + "/out"), "container_path": "/out", "writable": true],
            ],
            "volumes": [["volume": .string(name + "-data"), "container_path": "/data"]],
            "network": .string(name + "-net"),
        ])
        #expect(!run.error, "\(run.text)")
        #expect(json(run.text)["status"] as? String == "running")

        // The published port listens on loopback only.
        let listeners = try Self.listeners(port: harness.hostPort)
        #expect(!listeners.isEmpty, "something must listen on \(harness.hostPort)")
        #expect(listeners.allSatisfy { $0.hasPrefix("127.0.0.1:") }, "\(listeners)")

        // Inspect shows the label and redacts environment values.
        let inspect = await call(harness, .containerInspect, ["id": .string(name)])
        #expect(inspect.text.contains("TOKEN=<redacted>"))
        #expect(!inspect.text.contains("it-secret-value"))
        #expect(json(inspect.text)["owned"] as? Bool == true)

        // Exec: read-only mount refuses writes, the writable one accepts them, no host variable leaks.
        let read = await call(harness, .containerExec, ["id": .string(name), "command": ["cat", "/src/greeting.txt"]])
        #expect(json(read.text)["standardOutput"] as? String == "hello from the host\n", "\(read.text)")
        let writeReadOnly = await call(harness, .containerExec, ["id": .string(name), "command": ["touch", "/src/new"]])
        #expect(json(writeReadOnly.text)["exitCode"] as? Int != 0, "\(writeReadOnly.text)")
        let writeWritable = await call(harness, .containerExec, ["id": .string(name), "command": ["sh", "-c", "echo out > /out/result.txt"]])
        #expect(json(writeWritable.text)["exitCode"] as? Int == 0, "\(writeWritable.text)")
        #expect((try? String(contentsOfFile: harness.writableRoot + "/out/result.txt", encoding: .utf8)) == "out\n")
        let environment = await call(harness, .containerExec, ["id": .string(name), "command": ["env"]])
        let environmentText = json(environment.text)["standardOutput"] as? String ?? ""
        #expect(environmentText.contains("MODE=integration"))
        #expect(!environmentText.contains("CONTAINER_MCP_INTEGRATION"), "the test process's own variable must not reach the container")
        #expect(!environmentText.contains("SSH_AUTH_SOCK"))

        // Exec bounds: timeout and output cap.
        let slow = await call(harness, .containerExec, ["id": .string(name), "command": ["sleep", "60"], "timeout_seconds": 2])
        #expect(json(slow.text)["timedOut"] as? Bool == true, "\(slow.text)")
        let noisy = await call(harness, .containerExec, ["id": .string(name), "command": ["sh", "-c", "yes | head -c 100000"]])
        #expect(json(noisy.text)["outputTruncated"] as? Bool == true, "\(noisy.text)")
        #expect((json(noisy.text)["standardOutput"] as? String ?? "").utf8.count <= 4096)

        // Logs and stats.
        let logs = await call(harness, .containerLogs, ["id": .string(name), "lines": 10])
        #expect(!logs.error, "\(logs.text)")
        let boot = await call(harness, .containerLogs, ["id": .string(name), "boot": true, "lines": 1000])
        #expect((json(boot.text)["lines"] as? [String] ?? []).count <= 50)
        let stats = await call(harness, .containerStats, ["id": .string(name)])
        #expect(!stats.error, "\(stats.text)")

        // Refusals against the real service: a symlink escape, a protected container, the builder.
        let escape = await call(harness, .containerRun, [
            "image": .string(Self.image), "name": .string(name + "-escape"),
            "mounts": [["host_path": .string(harness.readOnlyRoot + "/escape"), "container_path": "/keys"]],
        ])
        #expect(escape.text.hasPrefix("Refused by rule mount.protected"), "\(escape.text)")
        if let protected = try await backend.listContainers().first(where: { !Policy.isOwned($0.labels) && !Policy.isInfrastructure($0.labels) }) {
            #expect(await call(harness, .containerDelete, ["id": .string(protected.id)]).text.hasPrefix("Refused by rule ownership.protected"))
            #expect(await call(harness, .containerExec, ["id": .string(protected.id), "command": ["true"]]).text.hasPrefix("Refused by rule ownership.protected"))
            #expect(await call(harness, .containerLogs, ["id": .string(protected.id)]).text.hasPrefix("Refused by rule ownership.protected"))
        }
        if let builder = try await backend.listContainers().first(where: { Policy.isInfrastructure($0.labels) }) {
            #expect(await call(harness, .containerDelete, ["id": .string(builder.id)]).text.hasPrefix("Refused by rule ownership.infrastructure"))
        }
        #expect(await call(harness, .containerDelete, ["id": .string(name)]).text.hasPrefix("Refused by rule state.running"))

        // Stop, start, stop.
        #expect(!(await call(harness, .containerStop, ["id": .string(name), "timeout_seconds": 2])).error)
        let restarted = await call(harness, .containerStart, ["id": .string(name)])
        #expect(!restarted.error, "\(restarted.text)")
        #expect(!(await call(harness, .containerStop, ["id": .string(name), "timeout_seconds": 2])).error)

        // Create without starting.
        let created = await call(harness, .containerRun, ["image": .string(Self.image), "name": .string(name + "-idle"), "start": false])
        #expect(json(created.text)["status"] as? String == "stopped", "\(created.text)")

        // Build: uses the shared buildkit container.
        let build = await call(harness, .imageBuild, ["context_path": .string(harness.readOnlyRoot + "/build"), "tag": .string("\(name):1")])
        #expect(!build.error, "\(build.text)")
        let builtRun = await call(harness, .containerRun, ["image": .string("\(name):1"), "name": .string(name + "-built"), "start": false])
        #expect(!builtRun.error, "\(builtRun.text)")

        // Delete everything through the tools.
        for id in [name, name + "-idle", name + "-built"] {
            let deleted = await call(harness, .containerDelete, ["id": .string(id)])
            #expect(!deleted.error, "\(id): \(deleted.text)")
        }
        #expect(!(await call(harness, .volumeDelete, ["name": .string(name + "-data")])).error)
        #expect(!(await call(harness, .networkDelete, ["name": .string(name + "-net")])).error)
        let deletedBuilt = await call(harness, .imageDelete, ["reference": .string("\(name):1")])
        #expect(!deletedBuilt.error, "\(deletedBuilt.text)")
        let deletedPulled = await call(harness, .imageDelete, ["reference": .string(Self.image)])
        #expect(!deletedPulled.error, "\(deletedPulled.text)")

        // Images that existed before the test are untouched.
        let imagesAfter = Set(try await backend.listImages().map(\.reference))
        #expect(imagesBefore.isSubset(of: imagesAfter))

        // The audit log saw every call and never a secret value.
        let audit = try String(contentsOfFile: harness.paths.auditFile, encoding: .utf8)
        #expect(!audit.contains("it-secret-value"))
        #expect(audit.split(separator: "\n").count >= 30)
    }

    /// Listening addresses for a TCP port, from lsof.
    static func listeners(port: Int) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
