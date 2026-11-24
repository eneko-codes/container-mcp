import Foundation
import MCP

@testable import ContainerMCPCore

/// A throwaway home folder with mount roots, protected folders and a symlink that escapes,
/// plus a dispatcher wired to a fake backend.
struct Fixture {
    let base: String
    let home: String
    let paths: ServerPaths
    let readOnlyRoot: String
    let writableRoot: String
    let configuration: Configuration
    let backend: FakeBackend
    let audit: AuditLog
    let ownedImages: OwnedImages
    let dispatcher: ToolDispatcher

    static let ownedLabels = Policy.ownershipLabels

    init(
        containers: [ContainerSummary] = [], images: [ImageSummary] = [], volumes: [VolumeSummary] = [],
        networks: [NetworkSummary]? = nil, adopted: [String] = [], configurationState: ConfigurationState? = nil,
        ownedImageReferences: [String] = [], pullTimeoutSeconds: Int = 60
    ) async throws {
        let created = NSTemporaryDirectory() + "container-mcp-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: created, withIntermediateDirectories: true)
        base = PathResolution.resolveExisting(created)!
        home = base + "/home"
        let manager = FileManager.default
        for folder in [
            "Code/project/src", "Work/app", ".ssh", "Library/Keychains", "Library/Application Support/container-mcp",
            "Library/Logs/container-mcp", "Outside", "Code/build",
        ] {
            try manager.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
        }
        try manager.createSymbolicLink(atPath: home + "/Code/escape", withDestinationPath: home + "/.ssh")
        try manager.createSymbolicLink(atPath: home + "/Code/outside-link", withDestinationPath: home + "/Outside")
        try Data("FROM alpine:3.20\nRUN true\n".utf8).write(to: URL(fileURLWithPath: home + "/Code/build/Dockerfile"))

        paths = ServerPaths(home: home)
        readOnlyRoot = home + "/Code"
        writableRoot = home + "/Work"
        configuration = Configuration(
            mountRoots: [
                .init(path: readOnlyRoot, resolvedPath: readOnlyRoot, writable: false),
                .init(path: writableRoot, resolvedPath: writableRoot, writable: true),
            ],
            hostPorts: .init(minimum: 8000, maximum: 8999),
            registries: ["docker.io", "ghcr.io"],
            resources: .init(defaultCPUs: 2, maximumCPUs: 4, defaultMemoryMiB: 1024, maximumMemoryMiB: 4096),
            logs: .init(maximumLines: 5, maximumBytes: 64),
            exec: .init(maximumTimeoutSeconds: 30, maximumOutputBytes: 4096),
            pullTimeoutSeconds: pullTimeoutSeconds, buildTimeoutSeconds: 60,
            adoptedContainers: adopted)

        var allImages = images
        allImages.append(ImageSummary(reference: "ghcr.io/apple/containerization/vminit:0.54.0", digest: "sha256:init"))
        allImages.append(ImageSummary(reference: "ghcr.io/apple/container-builder-shim/builder:0.13.3", digest: "sha256:builder"))
        backend = FakeBackend(
            containers: containers, images: allImages, volumes: volumes,
            networks: networks ?? [NetworkSummary(name: "default", labels: [:], mode: "nat", builtin: true)])
        audit = AuditLog(path: paths.auditFile)
        ownedImages = OwnedImages(path: nil)
        for reference in ownedImageReferences { await ownedImages.add(reference) }
        dispatcher = ToolDispatcher(
            backend: backend, configurationState: configurationState ?? .loaded(configuration), paths: paths, audit: audit,
            ownedImages: ownedImages)
    }

    var policy: Policy { Policy(configuration: configuration, paths: paths) }

    func call(_ tool: ToolName, _ arguments: [String: Value] = [:]) async -> CallTool.Result {
        await dispatcher.call(name: tool.rawValue, arguments: arguments)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: base)
    }

    static func owned(_ id: String, status: String = "running") -> ContainerSummary {
        ContainerSummary(id: id, image: "docker.io/library/alpine:latest", status: status, labels: ownedLabels)
    }

    static func foreign(_ id: String, status: String = "running") -> ContainerSummary {
        ContainerSummary(id: id, image: "docker.io/library/redis:7", status: status, labels: [:])
    }
}

extension CallTool.Result {
    var text: String {
        content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
    }

    var refused: Bool { isError == true && text.hasPrefix("Refused by rule") }

    func refused(by rule: Rule) -> Bool { isError == true && text.hasPrefix("Refused by rule \(rule.rawValue):") }
}

/// Calls a throwing policy function and returns the refusal, or nil if it was allowed.
func refusal<T>(_ body: () throws(Refusal) -> T) -> Refusal? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}
