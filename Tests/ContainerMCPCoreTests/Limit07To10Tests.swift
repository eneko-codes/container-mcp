import Foundation
import Testing

@testable import ContainerMCPCore

private let alpine = ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a")

private func json(_ result: ToolOutput) throws -> [String: Any] {
    // Notices come first, then a blank line, then the JSON.
    let text = result.text
    let start = text.range(of: "\n\n{").map { text.index($0.lowerBound, offsetBy: 2) } ?? text.startIndex
    return try #require(try JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any])
}

/// Limit 7: logs, exec, pull, build and resources are bounded by the configuration.
@Suite struct BoundsTests {
    @Test func logsAreCappedAtTheConfiguredLines() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        await fixture.backend.set(logData: Data((1...20).map { "l\($0)" }.joined(separator: "\n").utf8))
        let result = await fixture.call(.containerLogs, ["id": "web", "limit": 1000])
        // The fixture allows 5 lines a page: the request is moved to it, and the result says so.
        #expect(result.text.hasPrefix("limit=1000 is outside 1–5; 5 was used.\nShowing 1–5 of 20 lines, counted back from the end of the log. Pass offset=5 for the next page.\n\n{"), "\(result.text)")
        let object = try json(result)
        #expect(object["lines"] as? [String] == ["l16", "l17", "l18", "l19", "l20"])
        #expect(object["truncated"] == nil)
    }

    @Test func logsAreCappedAtTheConfiguredBytes() {
        let data = Data((String(repeating: "x", count: 40) + "\n" + String(repeating: "y", count: 40) + "\n").utf8)
        let rows = LogTail.rows(data, startsAtBeginning: true, width: 2000)
        let page = LogTail.page(of: rows, offset: 0, limit: 5, maximumBytes: 64)
        #expect(page == [String(repeating: "y", count: 40)])
        #expect(page.reduce(0) { $0 + $1.utf8.count + 1 } <= 64)
    }

    @Test func partialFirstLineIsDropped() {
        let rows = LogTail.rows(Data("tial line\nwhole\n".utf8), startsAtBeginning: false, width: 2000)
        #expect(rows == ["whole"])
    }

    @Test func execTimeoutAboveTheMaximumIsMovedAndSaid() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")])
        defer { fixture.remove() }
        let result = await fixture.call(.containerExec, ["id": "api", "command": ["sleep", "100"], "timeout_seconds": 31])
        #expect(result.isError != true, "\(result.text)")
        #expect(result.text.hasPrefix("timeout_seconds=31 is outside 1–30; 30 was used.\n\n{"), "\(result.text)")
        guard case .exec(_, let specification) = await fixture.backend.calls.first else {
            Issue.record("expected exec")
            return
        }
        #expect(specification.timeoutSeconds == 30)
    }

    @Test func execGetsTimeoutAndOutputCapWithoutTTYOrStdin() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")])
        defer { fixture.remove() }
        _ = await fixture.call(.containerExec, ["id": "api", "command": ["ls"]])
        guard case .exec(_, let specification) = await fixture.backend.calls.first else {
            Issue.record("expected exec")
            return
        }
        #expect(specification.timeoutSeconds == 30)
        #expect(specification.maximumOutputBytes == 4096)
        for field in ["tty", "interactive", "stdin", "detach"] {
            #expect(await fixture.call(.containerExec, ["id": "api", "command": ["ls"], .init(stringLiteral: field): true]).refused(by: .inputInvalid))
        }
    }

    @Test func execIntoStoppedContainerIsRefused() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api", status: "stopped")])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerExec, ["id": "api", "command": ["ls"]]).refused(by: .stateNotRunning))
    }

    @Test func runGetsDefaultResources() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        _ = await fixture.call(.containerRun, ["image": "alpine", "name": "web"])
        guard case .create(let specification) = await fixture.backend.calls.first else {
            Issue.record("expected create")
            return
        }
        #expect(specification.cpus == 2)
        #expect(specification.memoryMiB == 1024)
    }

    @Test func resourcesOutsideTheLimitsAreMovedAndSaid() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        let result = await fixture.call(.containerRun, ["image": "alpine", "name": "web", "cpus": 5, "memory_mib": 100])
        #expect(result.isError != true, "\(result.text)")
        #expect(result.text.hasPrefix("cpus=5 is outside 1–4; 4 was used.\nmemory_mib=100 is outside 200–4096; 200 was used.\n\n{"), "\(result.text)")
        guard case .create(let specification) = await fixture.backend.calls.first else {
            Issue.record("expected create")
            return
        }
        #expect(specification.cpus == 4)
        #expect(specification.memoryMiB == 200)
    }

    @Test func policyStillRefusesResourcesAboveTheMaximum() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(refusal { () throws(Refusal) in try fixture.policy.approveResources(cpus: 5, memoryMiB: nil) }?.rule == .resourceCPUs)
        #expect(refusal { () throws(Refusal) in try fixture.policy.approveResources(cpus: nil, memoryMiB: 4097) }?.rule == .resourceMemory)
    }

    @Test func pullStopsAtTheConfiguredTimeout() async throws {
        let fixture = try await Fixture(pullTimeoutSeconds: 1)
        defer { fixture.remove() }
        await fixture.backend.set(pullDelaySeconds: 5)
        let started = Date()
        let result = await fixture.call(.imagePull, ["reference": "alpine:3.20"])
        #expect(result.isError == true)
        #expect(result.text.contains("did not finish within 1 seconds"))
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func pullReportsProgress() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // The dispatcher passes the caller's reporter straight to the backend; here the fake
        // reports nothing, so this only checks that a reporter is accepted on every long tool.
        let reporter = ProgressSink { _, _, _ in }
        let result = await fixture.dispatcher.call(name: "image_pull", arguments: ["reference": "alpine:3.20"], progress: reporter)
        #expect(result.isError != true)
    }
}

/// Limit 8: pulls only from listed registries; build contexts inside allowed roots.
@Suite struct ImageTests {
    @Test func pullFromAnUnlistedRegistryIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        for reference in ["quay.io/prometheus/node-exporter:v1", "localhost:5000/app:1", "registry.example.com/team/app"] {
            #expect(await fixture.call(.imagePull, ["reference": .string(reference)]).refused(by: .imageRegistry), "\(reference)")
        }
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func listedRegistriesAndDockerHubAliasesArePulled() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        for reference in ["alpine:3.20", "library/redis:7", "registry-1.docker.io/library/nginx", "ghcr.io/owner/app:1"] {
            #expect(await fixture.call(.imagePull, ["reference": .string(reference)]).isError != true, "\(reference)")
        }
    }

    @Test func runWithAnImageThatWouldBePulledFromAnUnlistedRegistryIsRefused() async throws {
        let fixture = try await Fixture(images: [ImageSummary(reference: "quay.io/local/kept:1", digest: "sha256:k")])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerRun, ["image": "quay.io/other/app:1", "name": "web"]).refused(by: .imageRegistry))
        // Already stored locally: no registry is contacted, so it may run.
        #expect(await fixture.call(.containerRun, ["image": "quay.io/local/kept:1", "name": "web"]).isError != true)
    }

    @Test func buildContextOutsideTheRootsIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // The folder has a Dockerfile, so only the root check can refuse it.
        try Data("FROM alpine\n".utf8).write(to: URL(fileURLWithPath: fixture.home + "/Outside/Dockerfile"))
        let outside = await fixture.call(.imageBuild, ["context_path": .string(fixture.home + "/Outside"), "tag": "demo:1"])
        #expect(outside.refused(by: .buildContext))
        #expect(outside.text.contains("outside every mount root"), "\(outside.text)")
        #expect(await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/escape"), "tag": "demo:1"]).refused(by: .buildContext))
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func buildInsideARootReachesTheBackend() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:1", "build_args": ["MODE=dev"]])
        #expect(result.isError != true, "\(result.text)")
        guard case .build(let specification) = await fixture.backend.calls.first else {
            Issue.record("expected build")
            return
        }
        #expect(specification.contextDirectory == fixture.readOnlyRoot + "/build")
        #expect(specification.tag == "docker.io/library/demo:1")
        #expect(specification.labels == Fixture.ownedLabels)
    }

    @Test func dockerfileOutsideTheContextIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try Data("FROM alpine\n".utf8).write(to: URL(fileURLWithPath: fixture.readOnlyRoot + "/Dockerfile.outer"))
        #expect(await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:1", "dockerfile": "../Dockerfile.outer"]).refused(by: .buildContext))
    }

    @Test func baseImageFromAnUnlistedRegistryIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let dockerfiles = [
            "FROM quay.io/other/base:1\n",
            "FROM alpine AS build\nFROM scratch\nCOPY --from=quay.io/other/tools:1 /bin/x /x\n",
            "# syntax=quay.io/other/frontend:1\nFROM alpine\n",
            "FROM alpine\nRUN --mount=type=bind,from=quay.io/other/data:1,target=/d true\n",
        ]
        for dockerfile in dockerfiles {
            try Data(dockerfile.utf8).write(to: URL(fileURLWithPath: fixture.readOnlyRoot + "/build/Dockerfile"))
            #expect(await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:1"]).refused(by: .imageRegistry), "\(dockerfile)")
        }
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func baseImageNamedThroughAVariableIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try Data("ARG BASE=alpine\nFROM ${BASE}\n".utf8).write(to: URL(fileURLWithPath: fixture.readOnlyRoot + "/build/Dockerfile"))
        #expect(await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:1"]).refused(by: .imageRegistry))
    }

    @Test func stagesAndScratchAreNotImages() throws {
        let result = try DockerfileScanner.scan("FROM alpine:3.20 AS build\nRUN make\nFROM scratch\nCOPY --from=build /out /out\nCOPY --from=0 /a /a\n")
        #expect(result.externalImages == ["alpine:3.20"])
    }

    @Test func tagOfAnImageTheServerDidNotCreateIsRefused() async throws {
        let fixture = try await Fixture(images: [ImageSummary(reference: "docker.io/library/demo:1", digest: "sha256:u")])
        defer { fixture.remove() }
        #expect(await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:1"]).refused(by: .ownershipImageTagTaken))
    }
}

/// Limit 9: one append-only JSON line per call, environment values redacted, refusals included.
@Suite struct AuditTests {
    func entries(_ fixture: Fixture) throws -> [[String: Any]] {
        let text = try String(contentsOfFile: fixture.paths.auditFile, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func everyCallIsOneLineIncludingRefusals() async throws {
        let fixture = try await Fixture(containers: [Fixture.foreign("user-db")], images: [alpine], protected: ["user-db"])
        defer { fixture.remove() }
        _ = await fixture.call(.containersList)
        _ = await fixture.call(.containerDelete, ["id": "user-db"])
        _ = await fixture.call(.containerRun, ["image": "alpine", "name": "web"])
        let lines = try entries(fixture)
        #expect(lines.count == 3)
        #expect(lines.map { $0["tool"] as? String } == ["containers_list", "container_delete", "container_run"])
        #expect(lines.map { $0["decision"] as? String } == ["allowed", "refused", "allowed"])
        #expect(lines[1]["rule"] as? String == "ownership.protected")
        #expect(lines[0]["rule"] as? String == "policy")
        for line in lines {
            #expect(line["time"] is String)
            #expect(line["result"] is String)
            #expect(line["arguments"] is [String: Any])
        }
    }

    @Test func environmentAndBuildArgumentValuesAreRedacted() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")], images: [alpine])
        defer { fixture.remove() }
        _ = await fixture.call(.containerRun, ["image": "alpine", "name": "web", "env": ["API_TOKEN=s3cr3t-run"]])
        _ = await fixture.call(.containerExec, ["id": "api", "command": ["true"], "env": ["PASSWORD=s3cr3t-exec"]])
        _ = await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:2", "build_args": ["KEY=s3cr3t-build"]])
        let text = try String(contentsOfFile: fixture.paths.auditFile, encoding: .utf8)
        #expect(!text.contains("s3cr3t"))
        #expect(text.contains("API_TOKEN=<redacted>"))
        #expect(text.contains("PASSWORD=<redacted>"))
        #expect(text.contains("KEY=<redacted>"))
    }

    @Test func logFileIsPrivateAndAppendOnly() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = await fixture.call(.volumesList)
        _ = await fixture.call(.networksList)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.paths.auditFile)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try entries(fixture).count == 2)
    }

    /// The state and audit folders are inside ~/Library today; naming them keeps them protected if that changes.
    @Test func stateAuditAndClaudeSettingsFoldersAreNamedAsProtected() {
        let paths = ServerPaths(home: "/Users/user")
        let protected = paths.protectedPaths(containerApplicationRoot: nil)
        #expect(protected.contains(PathResolution.resolveAllowingMissing(paths.auditDirectory)))
        #expect(protected.contains(PathResolution.resolveAllowingMissing(paths.stateDirectory)))
        #expect(protected.contains(PathResolution.resolveAllowingMissing(paths.home + "/.claude")))
    }

    @Test func auditFolderCannotBeMounted() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var configuration = fixture.configuration
        configuration.mountRoots.append(.init(path: fixture.paths.auditDirectory, resolvedPath: fixture.paths.auditDirectory, writable: true))
        let policy = Policy(configuration: configuration, paths: fixture.paths)
        #expect(refusal { () throws(Refusal) in try policy.approveHostPath(fixture.paths.auditDirectory, wantsWritable: true, containerApplicationRoot: nil) }?.rule == .mountProtected)
    }
}

/// Limit 10: refusals name the rule and what would be allowed, and never echo a secret.
@Suite struct RefusalTests {
    @Test func refusalNamesRuleAndAllowance() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        let result = await fixture.call(.containerRun, ["image": "alpine", "name": "web", "ports": [["host_port": 22, "container_port": 22]]])
        #expect(result.text.hasPrefix("Refused by rule port.out-of-range:"))
        #expect(result.text.contains("Allowed: host ports 8000 to 8999, bound to 127.0.0.1"))
    }

    @Test func refusalsNeverEchoEnvironmentValues() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")], images: [alpine])
        defer { fixture.remove() }
        let results = [
            await fixture.call(.containerRun, ["image": "alpine", "name": "web", "env": ["TOKEN=s3cr3t-a"], "ports": [["host_port": 22, "container_port": 22]]]),
            await fixture.call(.containerRun, ["image": "alpine", "name": "web", "env": ["9BAD=s3cr3t-b"]]),
            await fixture.call(.containerExec, ["id": "api", "command": ["x"], "env": ["TOKEN=s3cr3t-c", "KEYONLY"]]),
            await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:1", "build_args": ["1X=s3cr3t-d"]]),
        ]
        for result in results {
            #expect(result.refused)
            #expect(!result.text.contains("s3cr3t"), "\(result.text)")
        }
        let audit = try String(contentsOfFile: fixture.paths.auditFile, encoding: .utf8)
        #expect(!audit.contains("s3cr3t"))
    }

    @Test func everyRuleHasAStableIdentifier() {
        #expect(Set(Rule.allCases.map(\.rawValue)).count == Rule.allCases.count)
    }
}
