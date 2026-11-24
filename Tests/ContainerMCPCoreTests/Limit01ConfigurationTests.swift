import Foundation
import Testing

@testable import ContainerMCPCore

/// Limit 1: the configuration is the user's. Read once from a fixed path, never written by a
/// tool; without it only read tools work.
@Suite struct ConfigurationTests {
    static let validJSON = """
        {
          "version": 1,
          "mountRoots": [{ "path": "/tmp", "writable": false }],
          "hostPorts": { "min": 8000, "max": 8999 },
          "registries": ["docker.io"],
          "resources": { "defaultCpus": 2, "maxCpus": 4, "defaultMemoryMiB": 1024, "maxMemoryMiB": 4096 },
          "logs": { "maxLines": 500, "maxBytes": 65536 },
          "exec": { "timeoutSeconds": 60, "maxOutputBytes": 65536 },
          "pull": { "timeoutSeconds": 600 },
          "build": { "timeoutSeconds": 1800 },
          "adopted": ["example-db"]
        }
        """

    func write(_ text: String, mode: Int16 = 0o600) throws -> String {
        let path = NSTemporaryDirectory() + "container-mcp-config-\(UUID().uuidString).json"
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    @Test func validFileLoads() throws {
        let path = try write(Self.validJSON)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let state = ConfigurationLoader.load(path: path)
        let configuration = try #require(state.configuration)
        #expect(configuration.mountRoots.first?.resolvedPath == "/private/tmp")
        #expect(configuration.adoptedContainers == ["example-db"])
    }

    @Test func missingFileIsReportedAsMissing() {
        #expect(ConfigurationLoader.load(path: "/nonexistent/container-mcp/config.json") == .missing(path: "/nonexistent/container-mcp/config.json"))
    }

    @Test func unknownKeyMakesTheFileInvalid() throws {
        let path = try write(Self.validJSON.replacingOccurrences(of: "\"adopted\"", with: "\"adoptd\""))
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .invalid(_, let problem) = ConfigurationLoader.load(path: path) else {
            Issue.record("expected invalid")
            return
        }
        #expect(problem.contains("adoptd"))
    }

    @Test func nestedUnknownKeyMakesTheFileInvalid() throws {
        let path = try write(Self.validJSON.replacingOccurrences(of: "\"maxLines\"", with: "\"maxLines\": 1, \"extra\""))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(ConfigurationLoader.load(path: path).configuration == nil)
    }

    @Test func groupWritableFileIsRefused() throws {
        let path = try write(Self.validJSON, mode: 0o664)
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .invalid(_, let problem) = ConfigurationLoader.load(path: path) else {
            Issue.record("expected invalid")
            return
        }
        #expect(problem.contains("writable by group or others"))
    }

    @Test func symlinkedFileIsRefused() throws {
        let target = try write(Self.validJSON)
        let link = target + ".link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        defer {
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.removeItem(atPath: link)
        }
        #expect(ConfigurationLoader.load(path: link).configuration == nil)
    }

    @Test func relativeMountRootIsRefused() throws {
        let path = try write(Self.validJSON.replacingOccurrences(of: "\"/tmp\"", with: "\"tmp\""))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(ConfigurationLoader.load(path: path).configuration == nil)
    }

    @Test func configurationLivesAtTheFixedPath() {
        let paths = ServerPaths(home: "/Users/user")
        #expect(paths.configurationFile == "/Users/user/Library/Application Support/container-mcp/config.json")
    }

    @Test func withoutConfigurationOnlyReadToolsWork() async throws {
        let fixture = try await Fixture(
            containers: [Fixture.owned("web")], configurationState: .missing(path: "/x/config.json"))
        defer { fixture.remove() }

        for tool in ToolName.allCases where tool.isReadOnly && tool != .containerStats && tool != .containerInspect && tool != .imageInspect && tool != .containerLogs {
            let result = await fixture.call(tool)
            #expect(result.isError != true, "\(tool.rawValue) should work without configuration")
        }
        #expect(await fixture.call(.containerLogs, ["id": "web"]).isError != true)

        for tool in ToolName.allCases where !tool.isReadOnly {
            let result = await fixture.call(tool)
            #expect(result.refused(by: .configurationMissing), "\(tool.rawValue) must be refused without configuration")
        }
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func invalidConfigurationAlsoRefusesWriteTools() async throws {
        let fixture = try await Fixture(configurationState: .invalid(path: "/x/config.json", problem: "bad"))
        defer { fixture.remove() }
        #expect(await fixture.call(.volumeCreate, ["name": "data"]).refused(by: .configurationInvalid))
        #expect(await fixture.call(.volumesList).isError != true)
    }

    /// No tool has a way to reach the configuration file: running every tool leaves it untouched.
    @Test func noToolWritesTheConfiguration() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web", status: "stopped")])
        defer { fixture.remove() }
        let file = fixture.paths.configurationFile
        try Data(Self.validJSON.utf8).write(to: URL(fileURLWithPath: file))
        let before = try Data(contentsOf: URL(fileURLWithPath: file))
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date

        for tool in ToolName.allCases {
            _ = await fixture.call(tool, ["id": "web", "name": "web", "reference": "alpine", "image": "alpine"])
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date == attributesBefore)
    }
}
