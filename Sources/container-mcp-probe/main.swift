import Darwin
import Foundation
import MCP
import System

// A development-only MCP client: starts the built server over stdio, calls every tool in a
// scenario that creates only `container-mcp-probe-…` resources and deletes them, and prints
// the transcript. Usage: container-mcp-probe <server binary> <scratch folder> <policy options…>
// The policy options are passed to the server as the desktop extension would pass them. The scratch
// folder must hold readonly/src, writable/out and readonly/build/Dockerfile, and those two
// folders must be the read-only and writable folders in the options.

let arguments = CommandLine.arguments
guard arguments.count > 3 else {
    FileHandle.standardError.write(Data("usage: container-mcp-probe <server binary> <scratch folder> <policy options…>\n".utf8))
    exit(2)
}
let serverPath = arguments[1]
let scratch = arguments[2]
let suffix = String(UUID().uuidString.prefix(6)).lowercased()
let name = "container-mcp-probe-\(suffix)"
let image = "docker.io/library/alpine:3.21"
let probeSecret = "probe-secret-\(suffix)"

let toServer = Pipe()
let fromServer = Pipe()
let server = Process()
server.executableURL = URL(fileURLWithPath: serverPath)
server.arguments = Array(arguments.dropFirst(3))
// A variable the server must not pass on to any container.
server.environment = ProcessInfo.processInfo.environment.merging(["CONTAINER_MCP_PROBE_SECRET": probeSecret]) { _, new in new }
server.standardInput = toServer
server.standardOutput = fromServer
FileManager.default.createFile(atPath: scratch + "/server-stderr.log", contents: nil)
server.standardError = FileHandle(forWritingAtPath: scratch + "/server-stderr.log")
try server.run()

let transport = StdioTransport(
    input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
    output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
let client = Client(name: "container-mcp-probe", version: "0.1.0")

actor ProgressLog {
    var count = 0
    var lastMessage: String?
    func record(_ message: String?) {
        count += 1
        if let message { lastMessage = message }
    }
    func take() -> (Int, String?) {
        defer {
            count = 0
            lastMessage = nil
        }
        return (count, lastMessage)
    }
}
let progressLog = ProgressLog()
await client.onNotification(ProgressNotification.self) { message in
    await progressLog.record(message.params.message)
}

let initialize = try await client.connect(transport: transport)
print("## initialize")
print("server: \(initialize.serverInfo.name) \(initialize.serverInfo.version), protocol \(initialize.protocolVersion)")

let (tools, _) = try await client.listTools()
print("\n## tools/list: \(tools.count) tools")
for tool in tools {
    let hints = tool.annotations
    print("- \(tool.name): readOnly=\(hints.readOnlyHint.map(String.init) ?? "-") destructive=\(hints.destructiveHint.map(String.init) ?? "-") idempotent=\(hints.idempotentHint.map(String.init) ?? "-")")
}

var calledTools: Set<String> = []
var failures: [String] = []
var progressCounter = 0

@MainActor func text(_ content: [Tool.Content]) -> String {
    content.compactMap { item -> String? in
        if case .text(let text, _, _) = item { return text }
        return nil
    }.joined()
}

@MainActor func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

/// Calls a tool, prints request and (shortened) response, and checks the expectation.
@MainActor @discardableResult
func call(_ tool: String, _ arguments: [String: Value] = [:], expect: String = "ok", note: String = "") async -> String {
    calledTools.insert(tool)
    progressCounter += 1
    let meta = Metadata(progressToken: .string("probe-\(progressCounter)"))
    let rendered = String(decoding: (try? JSONEncoder().encode(Value.object(arguments))) ?? Data(), as: UTF8.self)
    print("\n→ \(tool) \(rendered)\(note.isEmpty ? "" : "   # \(note)")")
    do {
        let result = try await client.callTool(name: tool, arguments: arguments, meta: meta)
        let body = text(result.content)
        let (notifications, lastMessage) = await progressLog.take()
        let shown = body.count > 900 ? String(body.prefix(900)) + "\n… (\(body.count) characters)" : body
        print("← \(result.isError == true ? "ERROR" : "ok")\(notifications > 0 ? " [\(notifications) progress notifications, last: \(lastMessage ?? "-")]" : "")")
        print(shown)
        let outcome = result.isError == true ? (body.hasPrefix("Refused by rule") ? "refused" : "error") : "ok"
        if outcome != expect {
            failures.append("\(tool): expected \(expect), got \(outcome)")
        }
        return body
    } catch {
        print("← transport error: \(error)")
        failures.append("\(tool): transport error \(error)")
        return ""
    }
}

let readOnly = scratch + "/readonly"
let writable = scratch + "/writable"
let hostPort = 18_000 + Int.random(in: 0..<999)

print("\n## read tools")
let status = await call("system_status")
let initialList = await call("containers_list", ["all": true])
// The server may manage every container that is neither protected nor the container tool's own,
// so the probe refuses to go on while any of the user's containers is left unprotected.
let unprotected = (object(initialList)["containers"] as? [[String: Any]] ?? []).filter {
    ($0["protected"] as? Bool) == false && ($0["owned"] as? Bool) == false && ($0["infrastructure"] as? Bool) == false
}.compactMap { $0["id"] as? String }
guard unprotected.isEmpty else {
    print("STOPPED: these containers are not protected, so the probe could touch them: \(unprotected.joined(separator: ", ")). Pass them in --protected-containers.")
    await client.disconnect()
    server.terminate()
    exit(3)
}
await call("images_list")
await call("volumes_list")
await call("networks_list")
await call("disk_usage")

print("\n## system and images")
await call("system_start", note: "already running: no change")
await call("image_pull", ["reference": "quay.io/prometheus/busybox:latest"], expect: "refused", note: "registry not listed")
await call("image_pull", ["reference": .string(image)])
await call("image_inspect", ["reference": .string(image)])

print("\n## volume and network")
await call("volume_create", ["name": .string(name + "-data"), "size_mib": 64])
await call("network_create", ["name": .string(name + "-net")])

print("\n## run")
await call("container_run", [
    "image": .string(image), "name": .string(name), "command": ["sleep", "600"],
    "env": ["MODE=probe", "API_TOKEN=probe-token-value"],
    "ports": [["host_port": .int(hostPort), "container_port": 8080]],
    "mounts": [
        ["host_path": .string(readOnly + "/src"), "container_path": "/src"],
        ["host_path": .string(writable + "/out"), "container_path": "/out", "writable": true],
    ],
    "volumes": [["volume": .string(name + "-data"), "container_path": "/data"]],
    "network": .string(name + "-net"),
])
await call("container_run", ["image": .string(image), "name": .string(name + "-x"), "mounts": [["host_path": .string(readOnly + "/../../"), "container_path": "/host"]]], expect: "refused", note: "mount escapes the roots")
await call("container_run", ["image": .string(image), "name": .string(name + "-x"), "ports": [["host_port": 22, "container_port": 22]]], expect: "refused", note: "port outside the range")
await call("container_run", ["image": .string(image), "name": .string(name + "-x"), "env": ["HOME"]], expect: "refused", note: "key-only env")
await call("container_run", ["image": .string(image), "name": .string(name + "-x"), "privileged": true], expect: "refused", note: "unknown field")

print("\n## inspect, exec, logs, stats")
let inspected = await call("container_inspect", ["id": .string(name)])
await call("container_exec", ["id": .string(name), "command": ["cat", "/src/greeting.txt"]])
await call("container_exec", ["id": .string(name), "command": ["sh", "-c", "echo written > /out/probe.txt && touch /src/blocked"]], note: "writable /out, read-only /src")
let environment = await call("container_exec", ["id": .string(name), "command": ["env"]])
await call("container_exec", ["id": .string(name), "command": ["sleep", "30"], "timeout_seconds": 2], note: "killed at the timeout")
await call("container_logs", ["id": .string(name), "lines": 20])
await call("container_stats", ["id": .string(name)])

print("\n## lifecycle")
await call("container_delete", ["id": .string(name)], expect: "refused", note: "still running")
await call("container_stop", ["id": .string(name), "timeout_seconds": 2])
await call("container_start", ["id": .string(name)])
await call("container_stop", ["id": .string(name), "timeout_seconds": 2])

print("\n## build")
await call("image_build", ["context_path": .string(readOnly + "/build"), "tag": .string("\(name):1")])

print("\n## protected and infrastructure containers")
let listing = object(await call("containers_list"))["containers"] as? [[String: Any]] ?? []
if let protected = listing.first(where: { ($0["protected"] as? Bool) == true })?["id"] as? String {
    await call("container_stop", ["id": .string(protected)], expect: "refused", note: "listed as protected")
    await call("container_exec", ["id": .string(protected), "command": ["true"]], expect: "refused")
    await call("container_logs", ["id": .string(protected)], expect: "refused")
    await call("container_delete", ["id": .string(protected)], expect: "refused")
}
if let builder = listing.first(where: { ($0["infrastructure"] as? Bool) == true })?["id"] as? String {
    await call("container_delete", ["id": .string(builder)], expect: "refused", note: "the container tool's own")
}

print("\n## cleanup")
await call("container_delete", ["id": .string(name)])
await call("volume_delete", ["name": .string(name + "-data")])
await call("network_delete", ["name": .string(name + "-net")])
await call("image_delete", ["reference": .string("\(name):1")])
await call("image_delete", ["reference": .string(image)])

print("\n## checks")
// The build starts the shared builder; the policy forbids this client to stop it, so it can
// only say when a run left it running.
@MainActor func builderRunning(_ listing: String) -> Bool {
    let containers = object(listing)["containers"] as? [[String: Any]] ?? []
    return containers.contains { ($0["id"] as? String) == "buildkit" && ($0["status"] as? String) == "running" }
}
let finalList = await call("containers_list", ["all": true])
if !builderRunning(initialList) && builderRunning(finalList) {
    print("buildkit was stopped before this run and is running now: stop it with `container stop buildkit`")
}
let allTools = Set(tools.map(\.name))
let missing = allTools.subtracting(calledTools).sorted()
print("tools called: \(calledTools.count) of \(allTools.count)\(missing.isEmpty ? "" : ", not called: \(missing.joined(separator: ", "))")")
if !missing.isEmpty { failures.append("not every tool was called") }
if !status.contains("\"versionMatches\" : true") { failures.append("service version does not match") }
if inspected.contains("probe-token-value") { failures.append("inspect echoed an env value") }
if environment.contains(probeSecret) { failures.append("the server's own environment reached the container") }
print("server environment variable inside the container: \(environment.contains(probeSecret) ? "LEAKED" : "absent")")
print(failures.isEmpty ? "RESULT: all expectations met" : "RESULT: \(failures.count) failures\n- " + failures.joined(separator: "\n- "))

await client.disconnect()
server.terminate()
server.waitUntilExit()
exit(failures.isEmpty ? 0 : 1)
