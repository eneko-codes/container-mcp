import Foundation
import MCP
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

/// Limit 4: ownership by label; adopted containers may only be started and stopped.
@Suite struct OwnershipTests {
    @Test func unlabelledContainerCannotBeStartedStoppedExecdOrDeleted() async throws {
        let fixture = try await Fixture(containers: [Fixture.foreign("user-db", status: "stopped"), Fixture.foreign("user-web")])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerStart, ["id": "user-db"]).refused(by: .ownershipUnlabelled))
        #expect(await fixture.call(.containerStop, ["id": "user-web"]).refused(by: .ownershipUnlabelled))
        #expect(await fixture.call(.containerExec, ["id": "user-web", "command": ["ls"]]).refused(by: .ownershipUnlabelled))
        #expect(await fixture.call(.containerDelete, ["id": "user-db"]).refused(by: .ownershipUnlabelled))
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func ownedContainerCanBeManaged() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web", status: "stopped"), Fixture.owned("api")])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerStart, ["id": "web"]).isError != true)
        #expect(await fixture.call(.containerStop, ["id": "api"]).isError != true)
        #expect(await fixture.call(.containerExec, ["id": "api", "command": ["ls"]]).isError != true)
        #expect(await fixture.call(.containerDelete, ["id": "web"]).isError != true)
        #expect(await fixture.backend.calls.count == 4)
    }

    @Test func adoptedContainerCanBeStartedAndStoppedOnly() async throws {
        let fixture = try await Fixture(
            containers: [Fixture.foreign("example-db", status: "stopped"), Fixture.foreign("example-cache")],
            adopted: ["example-db", "example-cache"])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerStart, ["id": "example-db"]).isError != true)
        #expect(await fixture.call(.containerStop, ["id": "example-cache"]).isError != true)
        #expect(await fixture.call(.containerExec, ["id": "example-cache", "command": ["sh"]]).refused(by: .ownershipAdoptedExec))
        #expect(await fixture.call(.containerDelete, ["id": "example-db"]).refused(by: .ownershipAdoptedDelete))
        #expect(await fixture.backend.calls == [.start("example-db"), .stop("example-cache", 5)])
    }

    @Test func runningOwnedContainerIsNotDeleted() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        #expect(await fixture.call(.containerDelete, ["id": "web"]).refused(by: .stateRunning))
    }

    @Test func readToolsWorkOnEveryContainer() async throws {
        let fixture = try await Fixture(containers: [Fixture.foreign("user-db")])
        defer { fixture.remove() }
        #expect(await fixture.call(.containersList).text.contains("user-db"))
        #expect(await fixture.call(.containerInspect, ["id": "user-db"]).isError != true)
        #expect(await fixture.call(.containerLogs, ["id": "user-db"]).isError != true)
        #expect(await fixture.call(.containerStats, ["id": "user-db"]).isError != true)
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

    @Test func scrubRemovesTheServersOwnEnvironment() {
        setenv("CONTAINER_MCP_TEST_TOKEN", "secret", 1)
        setenv("SSH_AUTH_SOCK", "/tmp/agent.sock", 1)
        HostEnvironment.scrub()
        #expect(ProcessInfo.processInfo.environment["CONTAINER_MCP_TEST_TOKEN"] == nil)
        #expect(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] == nil)
        #expect(Set(ProcessInfo.processInfo.environment.keys).isSubset(of: HostEnvironment.kept))
        #expect(ProcessInfo.processInfo.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
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
