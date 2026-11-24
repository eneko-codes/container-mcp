import Foundation
import Testing

@testable import ContainerMCPCore

/// Limit 1: the policy is the user's. It comes from the plugin's settings as launch arguments,
/// is read once, can be changed by no tool, and without it, or with write tools switched off,
/// only read tools work.
@Suite struct ConfigurationTests {
    /// What the plugin passes with its default settings and write tools on.
    static func arguments(_ overrides: [String: String] = [:]) -> [String] {
        var values: [String: String] = [
            "write-tools-enabled": "true", "read-only-folders": "/tmp", "writable-folders": "",
            "host-port-min": "8000", "host-port-max": "8999", "registries": "docker.io,ghcr.io",
            "default-cpus": "2", "max-cpus": "4", "default-memory-mib": "1024", "max-memory-mib": "4096",
            "log-max-lines": "500", "log-max-bytes": "65536", "exec-timeout-seconds": "60",
            "exec-max-output-bytes": "65536", "pull-timeout-seconds": "600", "build-timeout-seconds": "1800",
            "adopted-containers": "example-db",
        ]
        for (key, value) in overrides { values[key] = value }
        return ConfigurationArguments.options.flatMap { name in values[name].map { ["--\(name)", $0] } ?? [] }
    }

    @Test func pluginSettingsLoad() throws {
        let configuration = try #require(ConfigurationLoader.load(arguments: Self.arguments()).configuration)
        #expect(configuration.mountRoots == [.init(path: "/tmp", resolvedPath: "/private/tmp", writable: false)])
        #expect(configuration.registries == ["docker.io", "ghcr.io"])
        #expect(configuration.adoptedContainers == ["example-db"])
        #expect(configuration.hostPorts == .init(minimum: 8000, maximum: 8999))
    }

    @Test func listsAreSplitOnCommasAndEmptyListsAreEmpty() throws {
        let configuration = try #require(
            ConfigurationLoader.load(arguments: Self.arguments(["read-only-folders": "/tmp, /usr", "writable-folders": "/private/tmp", "adopted-containers": ""])).configuration)
        #expect(configuration.mountRoots.map(\.path) == ["/tmp", "/usr", "/private/tmp"])
        #expect(configuration.mountRoots.map(\.writable) == [false, false, true])
        #expect(configuration.adoptedContainers.isEmpty)
    }

    @Test func noArgumentsMeansMissing() {
        #expect(ConfigurationLoader.load(arguments: []) == .missing)
    }

    @Test func writeToolsOffMeansDisabled() {
        #expect(ConfigurationLoader.load(arguments: Self.arguments(["write-tools-enabled": "false"])) == .writeToolsDisabled)
    }

    @Test func unknownOptionMakesTheSettingsInvalid() {
        guard case .invalid(let problem) = ConfigurationLoader.load(arguments: Self.arguments() + ["--allow-everything", "true"]) else {
            Issue.record("expected invalid")
            return
        }
        #expect(problem.contains("allow-everything"))
    }

    @Test func missingOrRepeatedOptionMakesTheSettingsInvalid() {
        let withoutPorts = Self.arguments().enumerated().filter { index, _ in
            let pairStart = index - index % 2
            return Self.arguments()[pairStart] != "--host-port-max"
        }.map(\.element)
        #expect(ConfigurationLoader.load(arguments: withoutPorts).configuration == nil)
        #expect(ConfigurationLoader.load(arguments: Self.arguments() + ["--max-cpus", "64"]).configuration == nil)
        #expect(ConfigurationLoader.load(arguments: Array(Self.arguments().dropLast())).configuration == nil)
    }

    @Test func badValuesMakeTheSettingsInvalid() {
        for override in [
            ["read-only-folders": "relative/path"], ["read-only-folders": "/nonexistent-container-mcp"],
            ["host-port-min": "80"], ["host-port-min": "9000", "host-port-max": "8000"], ["max-cpus": "four"],
            ["default-memory-mib": "100"], ["write-tools-enabled": "yes"], ["registries": "docker.io/library"],
            ["adopted-containers": "-bad name"],
        ] {
            #expect(ConfigurationLoader.load(arguments: Self.arguments(override)).configuration == nil, "\(override)")
        }
    }

    @Test func withoutSettingsOnlyReadToolsWork() async throws {
        for state in [ConfigurationState.missing, .writeToolsDisabled] {
            let fixture = try await Fixture(containers: [Fixture.owned("web")], configurationState: state)
            defer { fixture.remove() }
            for tool in ToolName.allCases where tool.isReadOnly && ![.containerStats, .containerInspect, .imageInspect, .containerLogs].contains(tool) {
                #expect(await fixture.call(tool).isError != true, "\(tool.rawValue) should work in state \(state)")
            }
            #expect(await fixture.call(.containerLogs, ["id": "web"]).isError != true)
            let expected: Rule = state == .missing ? .configurationMissing : .configurationWriteToolsOff
            for tool in ToolName.allCases where !tool.isReadOnly {
                #expect(await fixture.call(tool).refused(by: expected), "\(tool.rawValue) must be refused in state \(state)")
            }
            #expect(await fixture.backend.calls.isEmpty)
        }
    }

    @Test func invalidSettingsAlsoRefuseWriteTools() async throws {
        let fixture = try await Fixture(configurationState: .invalid(problem: "bad"))
        defer { fixture.remove() }
        #expect(await fixture.call(.volumeCreate, ["name": "data"]).refused(by: .configurationInvalid))
        #expect(await fixture.call(.volumesList).isError != true)
    }

    /// No tool has a parameter that reaches the policy: the dispatcher's policy is fixed at
    /// startup, so every tool run leaves it as it was.
    @Test func noToolChangesThePolicy() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web", status: "stopped")])
        defer { fixture.remove() }
        for tool in ToolName.allCases {
            _ = await fixture.call(tool, ["id": "web", "name": "web", "reference": "alpine", "image": "alpine"])
        }
        let status = await fixture.call(.systemStatus).text
        #expect(status.contains("\"hostPorts\" : {\n      \"max\" : 8999,\n      \"min\" : 8000"), "\(status)")
        #expect(!ToolCatalog.tools.contains { $0.name.contains("config") || $0.name.contains("policy") || $0.name.contains("setting") })
    }
}
