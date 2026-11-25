import Foundation
import Testing

@testable import ContainerMCPCore

private let alpine = ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a")

private func createdSpecification(_ fixture: Fixture) async -> RunSpecification? {
    for call in await fixture.backend.calls {
        if case .create(let specification) = call { return specification }
    }
    return nil
}

/// Limit 3: published ports bind 127.0.0.1 only, inside the configured range.
@Suite struct PortTests {
    @Test func portsAlwaysBindLoopback() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        let result = await fixture.call(.containerRun, [
            "image": "alpine", "name": "web",
            "ports": [["host_port": 8080, "container_port": 80], ["host_port": 8081, "container_port": 53, "protocol": "udp"]],
        ])
        #expect(result.isError != true, "\(result.text)")
        let specification = try #require(await createdSpecification(fixture))
        #expect(specification.ports.map(\.hostAddress) == ["127.0.0.1", "127.0.0.1"])
    }

    @Test func callCannotChooseAHostAddress() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        for field in ["host_address", "host_ip", "address"] {
            let result = await fixture.call(.containerRun, [
                "image": "alpine", "name": "web",
                "ports": [["host_port": 8080, "container_port": 80, .init(stringLiteral: field): "0.0.0.0"]],
            ])
            #expect(result.refused(by: .inputInvalid), "\(field) must be an unknown field")
        }
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func hostPortOutsideRangeIsRefused() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        for port in [80, 7999, 9000, 65535] {
            let result = await fixture.call(.containerRun, ["image": "alpine", "name": "web", "ports": [["host_port": .int(port), "container_port": 80]]])
            #expect(result.refused(by: .portOutOfRange), "host port \(port)")
        }
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func duplicateHostPortIsRefused() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        let result = await fixture.call(.containerRun, [
            "image": "alpine", "name": "web",
            "ports": [["host_port": 8080, "container_port": 80], ["host_port": 8080, "container_port": 81]],
        ])
        #expect(result.refused(by: .portDuplicate))
    }
}

/// Limit 4: every container may be managed except those the user protected, which no tool
/// may touch, and the container tool's own; everything the server creates carries its label.
@Suite struct OwnershipTests {
    static let builder = ContainerSummary(
        id: "buildkit", image: "ghcr.io/apple/container-builder-shim/builder:0.13.3", status: "running",
        labels: ["com.apple.container.resource.role": "builder", "com.apple.container.plugin": "builder"])

    @Test func protectedContainersCannotBeTouchedAtAll() async throws {
        let fixture = try await Fixture(
            containers: [Fixture.foreign("example-db", status: "stopped"), Fixture.foreign("example-cache")],
            protected: ["example-db", "example-cache"])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerStart, ["id": "example-db"]).refused(by: .ownershipProtected))
        #expect(await fixture.call(.containerStop, ["id": "example-cache"]).refused(by: .ownershipProtected))
        #expect(await fixture.call(.containerExec, ["id": "example-cache", "command": ["sh"]]).refused(by: .ownershipProtected))
        #expect(await fixture.call(.containerDelete, ["id": "example-db"]).refused(by: .ownershipProtected))
        #expect(await fixture.call(.containerInspect, ["id": "example-db"]).refused(by: .ownershipProtected))
        #expect(await fixture.call(.containerLogs, ["id": "example-cache"]).refused(by: .ownershipProtected))
        #expect(await fixture.call(.containerStats, ["id": "example-cache"]).refused(by: .ownershipProtected))
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func protectedContainersShowOnlyNameAndStatusInTheList() async throws {
        let fixture = try await Fixture(containers: [Fixture.foreign("example-db")], protected: ["example-db"])
        defer { fixture.remove() }
        let text = await fixture.call(.containersList).text
        #expect(text.contains("\"protected\" : true"))
        #expect(!text.contains("redis"), "a protected container's image must not be shown")
    }

    @Test func protectedListAppliesWhileWriteToolsAreOff() async throws {
        let fixture = try await Fixture(containers: [Fixture.foreign("example-db")])
        defer { fixture.remove() }
        var configuration = fixture.configuration
        configuration = Configuration(
            mountRoots: configuration.mountRoots, hostPorts: configuration.hostPorts, registries: configuration.registries,
            resources: configuration.resources, logs: configuration.logs, exec: configuration.exec,
            pullTimeoutSeconds: 60, buildTimeoutSeconds: 60, protectedContainers: ["example-db"])
        let dispatcher = ToolDispatcher(
            backend: fixture.backend, configurationState: .writeToolsDisabled(configuration), paths: fixture.paths,
            audit: AuditLog(path: nil), ownedImages: OwnedImages(path: nil))
        let result = await dispatcher.call(name: "container_logs", arguments: ["id": "example-db"])
        #expect(result.refused(by: .ownershipProtected))
    }

    @Test func otherContainersCanBeManagedEvenIfTheServerDidNotCreateThem() async throws {
        let fixture = try await Fixture(containers: [Fixture.foreign("user-db", status: "stopped"), Fixture.foreign("user-web")], protected: ["something-else"])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerStart, ["id": "user-db"]).isError != true)
        #expect(await fixture.call(.containerStop, ["id": "user-web"]).isError != true)
        #expect(await fixture.call(.containerExec, ["id": "user-web", "command": ["ls"]]).isError != true)
        #expect(await fixture.call(.containerDelete, ["id": "user-db"]).isError != true)
        #expect(await fixture.backend.calls.count == 4)
    }

    @Test func theContainerToolsOwnContainersCanBeReadButNotChanged() async throws {
        let fixture = try await Fixture(containers: [Self.builder])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerStop, ["id": "buildkit"]).refused(by: .ownershipInfrastructure))
        #expect(await fixture.call(.containerExec, ["id": "buildkit", "command": ["ls"]]).refused(by: .ownershipInfrastructure))
        #expect(await fixture.call(.containerDelete, ["id": "buildkit"]).refused(by: .ownershipInfrastructure))
        #expect(await fixture.call(.containerLogs, ["id": "buildkit"]).isError != true)
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func runningContainerIsNotDeleted() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerDelete, ["id": "web"]).refused(by: .stateRunning))
    }

    @Test func createdResourcesCarryTheLabel() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        _ = await fixture.call(.containerRun, ["image": "alpine", "name": "web"])
        _ = await fixture.call(.volumeCreate, ["name": "data"])
        _ = await fixture.call(.networkCreate, ["name": "backend"])
        let calls = await fixture.backend.calls
        #expect(calls.count == 3)
        guard case .create(let specification) = calls[0] else { return }
        #expect(specification.labels == Fixture.ownedLabels)
        #expect(calls[1] == .createVolume("data", Fixture.ownedLabels))
        #expect(calls[2] == .createNetwork("backend", Fixture.ownedLabels))
    }

    @Test func foreignVolumesNetworksAndImagesCannotBeDeleted() async throws {
        let fixture = try await Fixture(
            images: [ImageSummary(reference: "docker.io/library/redis:7", digest: "sha256:r")],
            volumes: [VolumeSummary(name: "user-data", labels: [:])],
            networks: [
                NetworkSummary(name: "default", labels: [:], mode: "nat", builtin: true),
                NetworkSummary(name: "user-net", labels: [:], mode: "nat", builtin: false),
            ])
        defer { fixture.remove() }
        #expect(await fixture.call(.volumeDelete, ["name": "user-data"]).refused(by: .ownershipUnlabelled))
        #expect(await fixture.call(.networkDelete, ["name": "user-net"]).refused(by: .ownershipUnlabelled))
        #expect(await fixture.call(.networkDelete, ["name": "default"]).refused(by: .ownershipUnlabelled))
        #expect(await fixture.call(.imageDelete, ["reference": "redis:7"]).refused(by: .ownershipImageNotOwned))
        #expect(await fixture.call(.imageDelete, ["reference": "ghcr.io/apple/containerization/vminit:0.54.0"]).refused(by: .ownershipImageNotOwned))
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func ownedVolumesNetworksAndImagesCanBeDeleted() async throws {
        let fixture = try await Fixture(
            images: [ImageSummary(reference: "docker.io/library/demo:1", digest: "sha256:d")],
            volumes: [VolumeSummary(name: "data", labels: Fixture.ownedLabels)],
            networks: [NetworkSummary(name: "backend", labels: Fixture.ownedLabels, mode: "nat", builtin: false)],
            ownedImageReferences: ["docker.io/library/demo:1"])
        defer { fixture.remove() }
        #expect(await fixture.call(.volumeDelete, ["name": "data"]).isError != true)
        #expect(await fixture.call(.networkDelete, ["name": "backend"]).isError != true)
        #expect(await fixture.call(.imageDelete, ["reference": "demo:1"]).isError != true)
        #expect(await fixture.backend.calls == [.deleteVolume("data"), .deleteNetwork("backend"), .deleteImage("docker.io/library/demo:1")])
    }

    @Test func pullingAnImageThatWasAlreadyPresentDoesNotMakeItOwned() async throws {
        let fixture = try await Fixture(images: [ImageSummary(reference: "docker.io/library/redis:7", digest: "sha256:r")])
        defer { fixture.remove() }
        _ = await fixture.call(.imagePull, ["reference": "redis:7"])
        #expect(await fixture.call(.imageDelete, ["reference": "redis:7"]).refused(by: .ownershipImageNotOwned))
        _ = await fixture.call(.imagePull, ["reference": "nginx:1"])
        #expect(await fixture.call(.imageDelete, ["reference": "nginx:1"]).isError != true)
    }
}

/// Limit 5: environment variables only as KEY=value; the host environment never reaches a container.
@Suite struct EnvironmentTests {
    @Test func keyOnlyEntryIsRefusedForRunExecAndBuild() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")], images: [alpine])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerRun, ["image": "alpine", "name": "web", "env": ["HOME"]]).refused(by: .environmentKeyOnly))
        #expect(await fixture.call(.containerExec, ["id": "api", "command": ["env"], "env": ["PATH"]]).refused(by: .environmentKeyOnly))
        #expect(await fixture.call(.imageBuild, ["context_path": .string(fixture.readOnlyRoot + "/build"), "tag": "demo:1", "build_args": ["TOKEN"]]).refused(by: .environmentKeyOnly))
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func explicitEntriesPassUnchangedAndAlone() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        setenv("CONTAINER_MCP_TEST_SECRET", "from-host", 1)
        defer { unsetenv("CONTAINER_MCP_TEST_SECRET") }
        let result = await fixture.call(.containerRun, ["image": "alpine", "name": "web", "env": ["MODE=dev", "EMPTY="]])
        #expect(result.isError != true, "\(result.text)")
        let specification = try #require(await createdSpecification(fixture))
        #expect(specification.environment == ["MODE=dev", "EMPTY="])
    }

    @Test func invalidKeyIsRefused() {
        #expect(refusal { () throws(Refusal) in try Policy.approveEnvironment(["1BAD=x"]) }?.rule == .environmentInvalid)
        #expect(refusal { () throws(Refusal) in try Policy.approveEnvironment(["=x"]) }?.rule == .environmentInvalid)
    }

    /// The real scrub runs in the server binary at startup; the process-wide unsetenv is not run
    /// here because the test process also carries the integration tests' opt-in variable.
    /// The integration suite checks the end result: no host variable inside a container.
    @Test func scrubKeepsOnlyTheVariablesFoundationNeeds() {
        let names = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SSH_AUTH_SOCK", "AWS_SECRET_ACCESS_KEY", "BUILDKIT_COLORS", "NO_COLOR", "CONTAINER_DEBUG"]
        #expect(Set(HostEnvironment.namesToRemove(from: names)) == ["SSH_AUTH_SOCK", "AWS_SECRET_ACCESS_KEY", "BUILDKIT_COLORS", "NO_COLOR", "CONTAINER_DEBUG"])
    }

    @Test func currentNamesReadsTheProcessEnvironment() {
        setenv("CONTAINER_MCP_TEST_NAME", "x", 1)
        defer { unsetenv("CONTAINER_MCP_TEST_NAME") }
        #expect(HostEnvironment.currentNames().contains("CONTAINER_MCP_TEST_NAME"))
    }
}

/// Limit 6: arguments stay arrays from the tool input to the backend; nothing is a shell string.
@Suite struct ShellTests {
    @Test func execCommandReachesTheBackendAsTheSameArray() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")])
        defer { fixture.remove() }
        let command: [String] = ["sh", "-c", "echo $HOME; rm -rf /", "x y", "$(whoami)", "`id`", "a;b|c&&d"]
        let result = await fixture.call(.containerExec, ["id": "api", "command": .array(command.map { .string($0) })])
        #expect(result.isError != true, "\(result.text)")
        guard case .exec(_, let specification) = await fixture.backend.calls.first else {
            Issue.record("expected exec")
            return
        }
        #expect(specification.command == command)
    }

    @Test func commandStringIsRefused() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")], images: [alpine])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerExec, ["id": "api", "command": "ls -la"]).refused(by: .inputInvalid))
        #expect(await fixture.call(.containerRun, ["image": "alpine", "name": "web", "command": "sleep 10"]).refused(by: .inputInvalid))
        #expect(await fixture.call(.containerExec, ["id": "api", "command": []]).refused(by: .inputInvalid))
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func runCommandReachesTheBackendAsTheSameArray() async throws {
        let fixture = try await Fixture(images: [alpine])
        defer { fixture.remove() }
        let command: [String] = ["sleep", "$(reboot)", "10; halt"]
        _ = await fixture.call(.containerRun, ["image": "alpine", "name": "web", "command": .array(command.map { .string($0) })])
        let specification = try #require(await createdSpecification(fixture))
        #expect(specification.command == command)
    }
}
