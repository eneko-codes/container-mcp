import Foundation
import Testing

@testable import ContainerMCPCore

/// The tool surface: typed schemas that reject unknown fields, truthful annotations, and no
/// tool for anything the server must never expose.
@Suite struct ToolSchemaTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyToolNameHasExactlyOneDefinition() {
        #expect(Set(ToolCatalog.tools.map(\.name)) == Set(ToolName.allCases.map(\.rawValue)))
        #expect(ToolCatalog.tools.count == ToolName.allCases.count)
    }

    @Test func everySchemaClosesEveryObject() {
        func check(_ value: Value, path: String) {
            guard let object = value.objectValue else { return }
            if object["type"]?.stringValue == "object" {
                #expect(object["additionalProperties"] == .bool(false), "\(path) must set additionalProperties false")
            }
            for (key, child) in object {
                if let items = child.arrayValue {
                    for (index, item) in items.enumerated() { check(item, path: "\(path).\(key)[\(index)]") }
                } else {
                    check(child, path: "\(path).\(key)")
                }
            }
        }
        for tool in ToolCatalog.tools { check(tool.inputSchema, path: tool.name) }
    }

    @Test func everyToolRejectsUnknownFields() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        for tool in ToolName.allCases {
            let result = await fixture.call(tool, ["unexpected_field": true])
            #expect(result.refused(by: .inputInvalid), "\(tool.rawValue): \(result.text)")
        }
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func annotationsAreTruthful() {
        let byName = Dictionary(uniqueKeysWithValues: ToolCatalog.tools.map { ($0.name, $0.annotations) })
        for tool in ToolName.allCases {
            let annotations = byName[tool.rawValue]
            #expect(annotations?.readOnlyHint == tool.isReadOnly, "\(tool.rawValue) readOnlyHint")
            if !tool.isReadOnly {
                #expect(annotations?.destructiveHint != nil, "\(tool.rawValue) must state destructiveHint")
                #expect(annotations?.idempotentHint != nil, "\(tool.rawValue) must state idempotentHint")
            }
        }
        for tool in [ToolName.containerDelete, .imageDelete, .volumeDelete, .networkDelete, .containerExec, .containerStop, .imageBuild] {
            #expect(byName[tool.rawValue]?.destructiveHint == true, "\(tool.rawValue) is destructive")
        }
        for tool in [ToolName.containerRun, .containerStart, .imagePull, .volumeCreate, .networkCreate, .systemStart] {
            #expect(byName[tool.rawValue]?.destructiveHint == false, "\(tool.rawValue) is additive")
        }
        for tool in [ToolName.containerStart, .containerStop, .imagePull, .systemStart] {
            #expect(byName[tool.rawValue]?.idempotentHint == true, "\(tool.rawValue) is idempotent")
        }
    }

    @Test func forbiddenOperationsHaveNoTool() {
        let names = ToolCatalog.tools.map(\.name).joined(separator: " ")
        for forbidden in ["login", "logout", "push", "prune", "kill", "machine", "cluster", "kube", "dns", "property", "system_stop"] {
            #expect(!names.contains(forbidden), "no tool may mention \(forbidden)")
        }
        for tool in ToolCatalog.tools {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            #expect(properties["all"] == nil || tool.name == "containers_list", "\(tool.name) must not take an all flag")
        }
    }

    @Test func descriptionsSayWhatTheyRefuse() {
        for tool in ToolCatalog.tools where !ToolName(rawValue: tool.name)!.isReadOnly {
            let description = tool.description ?? ""
            #expect(description.contains("Refuses") || description.contains("refuses") || description.contains("Never") || description.contains("Only"), "\(tool.name) must describe its refusals")
        }
    }

    @Test func serviceVersionMismatchRefusesEverythingButSystemStatus() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        await fixture.backend.set(serviceVersion: "1.8.0")
        #expect(await fixture.call(.systemStatus).isError != true)
        #expect(await fixture.call(.containersList).refused(by: .serviceVersionMismatch))
        #expect(await fixture.call(.containerStop, ["id": "web"]).refused(by: .serviceVersionMismatch))
    }

    /// The desktop extension's manifest is written by hand; it must pass every option the
    /// server requires and list exactly the tools the server offers.
    @Test func extensionManifestMatchesTheServer() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require(manifest["server"] as? [String: Any])
        let configuration = try #require(server["mcp_config"] as? [String: Any])
        let arguments = try #require(configuration["args"] as? [String])
        #expect(arguments.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2)) } == ConfigurationArguments.options)
        let tools = try #require(manifest["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        #expect(Set(tools) == Set(ToolName.allCases.map(\.rawValue)))
        #expect(manifest["version"] as? String == ContainerMCPServer.version, "the manifest and the server must state the same version")
    }

    /// The MCP protocol is the copied `MCPServer.swift` over Foundation. The SDK it replaced
    /// must not come back; the other dependencies are the container libraries and stay.
    @Test func packageDoesNotDependOnTheMCPSDK() throws {
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!package.contains("swift-sdk"), "Package.swift declares the MCP Swift SDK")
        #expect(!package.contains("modelcontextprotocol"))
        #expect(!package.contains(#"name: "MCP""#), "a target depends on the SDK's MCP product")
        let resolved = try String(contentsOf: Self.root.appendingPathComponent("Package.resolved"), encoding: .utf8)
        #expect(!resolved.contains("swift-sdk"), "Package.resolved still pins the MCP Swift SDK")
    }

    @Test func unknownToolIsAnError() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = await fixture.dispatcher.call(name: "registry_login", arguments: [:])
        #expect(result.isError == true)
    }
}
