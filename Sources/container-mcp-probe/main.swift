import ContainerMCPCore
import Darwin
import Foundation

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

// JSON-RPC over the server's stdio, one JSON message per line. The probe sends one request
// at a time and waits for its reply, so every other line read meanwhile is a notification.
let requests = toServer.fileHandleForWriting
var serverLines = fromServer.fileHandleForReading.bytes.lines.makeAsyncIterator()
var lastRequestID = 0
var failures: [String] = []

struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

@MainActor func json(_ value: Value) -> String {
    String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
}

@MainActor func send(_ message: [String: Value]) throws {
    let line = try JSONEncoder().encode(Value.object(message))
    try requests.write(contentsOf: line + Data("\n".utf8))
}

@MainActor func readMessage() async throws -> [String: Value]? {
    // An iterator stored in a global cannot be advanced in place from an async function.
    var iterator = serverLines
    defer { serverLines = iterator }
    guard let line = try await iterator.next() else { return nil }
    guard let message = try? JSONDecoder().decode(Value.self, from: Data(line.utf8)).objectValue else {
        throw ProbeError(description: "the server wrote a line that is not a JSON object: \(line.prefix(200))")
    }
    return message
}

/// Sends a request and returns its result, handing each progress notification read before
/// the reply to `progress`.
@MainActor func request(
    _ method: String, _ parameters: [String: Value] = [:], progress: ([String: Value]) -> Void = { _ in }
) async throws -> [String: Value] {
    lastRequestID += 1
    let id = Value.int(lastRequestID)
    try send(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": .object(parameters)])
    while let message = try await readMessage() {
        if message["id"] == id {
            if let error = message["error"]?.objectValue {
                throw ProbeError(description: "JSON-RPC error \(error["code"]?.intValue ?? 0): \(error["message"]?.stringValue ?? "")")
            }
            guard let result = message["result"]?.objectValue else { throw ProbeError(description: "a reply with no result") }
            return result
        }
        if message["method"] == "notifications/progress", let parameters = message["params"]?.objectValue {
            progress(parameters)
        } else {
            failures.append("\(method): unexpected message \(json(.object(message)))")
        }
    }
    throw ProbeError(description: "the server closed its output before answering \(method)")
}

let initialize = try await request(
    "initialize",
    [
        "protocolVersion": "2025-11-25", "capabilities": [:],
        "clientInfo": ["name": "container-mcp-probe", "version": "0.1.0"],
    ])
try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
let serverInfo = initialize["serverInfo"]?.objectValue ?? [:]
print("## initialize")
print("server: \(serverInfo["name"]?.stringValue ?? "?") \(serverInfo["version"]?.stringValue ?? "?"), protocol \(initialize["protocolVersion"]?.stringValue ?? "?")")

let tools = try await request("tools/list")["tools"]?.arrayValue?.compactMap(\.objectValue) ?? []
print("\n## tools/list: \(tools.count) tools")
for tool in tools {
    let hints = tool["annotations"]?.objectValue ?? [:]
    func hint(_ name: String) -> String { hints[name]?.boolValue.map(String.init) ?? "-" }
    print("- \(tool["name"]?.stringValue ?? "?"): readOnly=\(hint("readOnlyHint")) destructive=\(hint("destructiveHint")) idempotent=\(hint("idempotentHint"))")
}

var calledTools: Set<String> = []
var progressCounter = 0

/// A sentence about what a result left out comes before its JSON.
@MainActor func object(_ text: String) -> [String: Any] {
    let body = text.firstIndex(of: "{").map { String(text[$0...]) } ?? text
    return (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
}

/// Calls a tool, prints request and (shortened) response, and checks the expectation.
@MainActor @discardableResult
func call(_ tool: String, _ arguments: [String: Value] = [:], expect: String = "ok", note: String = "") async -> String {
    calledTools.insert(tool)
    progressCounter += 1
    let token = Value.string("probe-\(progressCounter)")
    print("\n→ \(tool) \(json(.object(arguments)))\(note.isEmpty ? "" : "   # \(note)")")
    var notifications = 0
    var lastMessage: String?
    var lastProgress: Double?
    do {
        let result = try await request(
            "tools/call", ["name": .string(tool), "arguments": .object(arguments), "_meta": ["progressToken": token]]
        ) { parameters in
            notifications += 1
            // Notifications must stop when a call is answered, so one carrying an earlier
            // call's token here was written after that call's reply.
            guard parameters["progressToken"] == token else {
                failures.append("\(tool): a progress notification of an earlier call arrived after its reply")
                return
            }
            let progress = parameters["progress"]?.doubleValue ?? -.infinity
            if let lastProgress, progress <= lastProgress { failures.append("\(tool): progress did not increase") }
            lastProgress = progress
            if let message = parameters["message"]?.stringValue { lastMessage = message }
        }
        let body = (result["content"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        let isError = result["isError"]?.boolValue == true
        let shown = body.count > 900 ? String(body.prefix(900)) + "\n… (\(body.count) characters)" : body
        print("← \(isError ? "ERROR" : "ok")\(notifications > 0 ? " [\(notifications) progress notifications, last: \(lastMessage ?? "-")]" : "")")
        print(shown)
        let outcome = isError ? (body.hasPrefix("Refused by rule") ? "refused" : "error") : "ok"
        if outcome != expect {
            failures.append("\(tool): expected \(expect), got \(outcome)")
        }
        return body
    } catch {
        print("← protocol error: \(error)")
        failures.append("\(tool): protocol error \(error)")
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
await call("container_logs", ["id": .string(name), "limit": 20])
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
let allTools = Set(tools.compactMap { $0["name"]?.stringValue })
let missing = allTools.subtracting(calledTools).sorted()
print("tools called: \(calledTools.count) of \(allTools.count)\(missing.isEmpty ? "" : ", not called: \(missing.joined(separator: ", "))")")
if !missing.isEmpty { failures.append("not every tool was called") }
if !status.contains("\"versionMatches\" : true") { failures.append("service version does not match") }
if inspected.contains("probe-token-value") { failures.append("inspect echoed an env value") }
if environment.contains(probeSecret) { failures.append("the server's own environment reached the container") }
print("server environment variable inside the container: \(environment.contains(probeSecret) ? "LEAKED" : "absent")")

// Closing the input ends the session: the server answers what it was asked, then exits.
// Anything it writes after the last reply, such as a late progress notification, is a fault.
try? requests.close()
while let message = try? await readMessage() {
    failures.append("the server wrote after its last reply: \(json(.object(message)))")
}
server.waitUntilExit()
print(failures.isEmpty ? "RESULT: all expectations met" : "RESULT: \(failures.count) failures\n- " + failures.joined(separator: "\n- "))
exit(failures.isEmpty ? 0 : 1)
