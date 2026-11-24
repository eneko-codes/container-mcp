#!/usr/bin/env swift
// Checks that every security limit has a test that fails when the limit is removed.
//
// For each limit, the script edits one line of the source to switch the limit off, rebuilds,
// runs the unit tests and expects at least one to fail, then restores the file. It finishes by
// confirming the working tree is unchanged and the unmodified tests pass again.
//
// Run from the repository root: swift Scripts/check-limit-tests.swift [words to select mutations]

import Foundation

struct Mutation {
    let limit: String
    let description: String
    let file: String
    let find: String
    let replace: String
}

let policy = "Sources/ContainerMCPCore/Policy/Policy.swift"
let dispatcher = "Sources/ContainerMCPCore/Tools/ToolDispatcher.swift"
let configuration = "Sources/ContainerMCPCore/Policy/Configuration.swift"
let paths = "Sources/ContainerMCPCore/Policy/PathResolution.swift"
let arguments = "Sources/ContainerMCPCore/Tools/Arguments.swift"
let audit = "Sources/ContainerMCPCore/Audit/AuditLog.swift"
let rule = "Sources/ContainerMCPCore/Policy/Rule.swift"
let loader = "Sources/ContainerMCPCore/Policy/ConfigurationLoader.swift"

let mutations: [Mutation] = [
    Mutation(limit: "1", description: "write tools work without a configuration", file: dispatcher,
             find: "throw Refusal(.configurationMissing,",
             replace: "return Policy(configuration: Configuration(mountRoots: [], hostPorts: .init(minimum: 1024, maximum: 65535), registries: [], resources: .init(defaultCPUs: 1, maximumCPUs: 1, defaultMemoryMiB: 200, maximumMemoryMiB: 200), logs: .init(maximumLines: 1, maximumBytes: 1), exec: .init(maximumTimeoutSeconds: 1, maximumOutputBytes: 1), pullTimeoutSeconds: 1, buildTimeoutSeconds: 1, protectedContainers: []), paths: paths); _ = Refusal(.configurationMissing,"),
    Mutation(limit: "1", description: "unknown options are accepted", file: configuration,
             find: "guard options.contains(name) else {",
             replace: "guard true else {"),
    Mutation(limit: "1", description: "write tools work when switched off", file: loader,
             find: "guard try ConfigurationArguments.writeToolsEnabled(arguments) else { return .writeToolsDisabled }",
             replace: "_ = try ConfigurationArguments.writeToolsEnabled(arguments)"),
    Mutation(limit: "2", description: "Claude's settings folder is not protected", file: paths,
             find: "            home + \"/.claude\",\n",
             replace: ""),
    Mutation(limit: "2", description: "the real folder of a linked settings file is not protected", file: paths,
             find: "((PathResolution.resolveExisting(home + \"/.claude/settings.json\") ?? home + \"/.claude/settings.json\") as NSString)\n                .deletingLastPathComponent,",
             replace: ""),
    Mutation(limit: "2", description: "protected folders are not checked", file: policy,
             find: "for protectedPath in protected {",
             replace: "for protectedPath in [String]() {"),
    Mutation(limit: "2", description: "paths are not resolved before the check", file: policy,
             find: "guard let resolved = PathResolution.resolveExisting(hostPath) else {",
             replace: "guard let resolved = Optional(hostPath), FileManager.default.fileExists(atPath: hostPath) else {"),
    Mutation(limit: "2", description: "paths outside the roots are accepted", file: policy,
             find: "guard !matchingRoots.isEmpty else {",
             replace: "guard true else {"),
    Mutation(limit: "2", description: "writable mounts do not need a writable root", file: policy,
             find: "guard matchingRoots.contains(where: \\.writable) else {",
             replace: "guard true else {"),
    Mutation(limit: "2", description: "the audit folder is not protected", file: paths,
             find: "            auditDirectory,\n",
             replace: ""),
    Mutation(limit: "3", description: "ports bind every interface", file: policy,
             find: "ports.append(.init(hostAddress: Self.loopbackAddress,",
             replace: "ports.append(.init(hostAddress: \"0.0.0.0\","),
    Mutation(limit: "3", description: "host ports outside the range are accepted", file: policy,
             find: "guard (range.minimum...range.maximum).contains(port.hostPort) else {",
             replace: "guard true else {"),
    Mutation(limit: "4", description: "protected containers can be changed", file: policy,
             find: "if protectedContainers.contains(container.id) {",
             replace: "if false {"),
    Mutation(limit: "4", description: "protected containers can be read", file: policy,
             find: "if protectedContainers.contains(container.id) {",
             replace: "if action != .read && protectedContainers.contains(container.id) {"),
    Mutation(limit: "4", description: "the container tool's own containers can be changed", file: policy,
             find: "if action != .read && isInfrastructure(container.labels) {",
             replace: "if false {"),
    Mutation(limit: "4", description: "protected containers show their details in the list", file: dispatcher,
             find: "if protected.contains(container.id) {",
             replace: "if false {"),
    Mutation(limit: "4", description: "foreign volumes can be deleted", file: policy,
             find: "guard Self.isOwned(volume.labels) else {\n            throw Refusal(.ownershipUnlabelled",
             replace: "guard true else {\n            throw Refusal(.ownershipUnlabelled"),
    Mutation(limit: "4", description: "foreign images can be deleted", file: policy,
             find: "guard ownedImages.contains(normalizedReference) else {",
             replace: "guard true else {"),
    Mutation(limit: "5", description: "key-only environment entries are accepted", file: policy,
             find: "guard let equals = entry.firstIndex(of: \"=\") else {",
             replace: "guard let equals = entry.firstIndex(of: \"=\") ?? Optional(entry.endIndex) else {"),
    Mutation(limit: "6", description: "a command string is split into words", file: arguments,
             find: "guard let items = value.arrayValue else { throw invalid(key, \"an array of strings\") }",
             replace: "if case .string(let line) = value { return line.split(separator: \" \").map(String.init) }\n        guard let items = value.arrayValue else { throw invalid(key, \"an array of strings\") }"),
    Mutation(limit: "7", description: "logs are not capped at the configured lines", file: policy,
             find: "return (min(requested, limits.maximumLines), limits.maximumBytes)",
             replace: "return (requested, limits.maximumBytes)"),
    Mutation(limit: "7", description: "exec timeouts above the maximum are accepted", file: policy,
             find: "guard timeout >= 1, timeout <= maximum else {",
             replace: "guard true else {"),
    Mutation(limit: "7", description: "exec output is not capped", file: policy,
             find: "timeoutSeconds: timeout, maximumOutputBytes: configuration.exec.maximumOutputBytes)",
             replace: "timeoutSeconds: timeout, maximumOutputBytes: Int.max)"),
    Mutation(limit: "7", description: "CPUs above the maximum are accepted", file: policy,
             find: "guard cpus >= 1, cpus <= limits.maximumCPUs else {",
             replace: "guard true else {"),
    Mutation(limit: "7", description: "runs get no default limits", file: policy,
             find: "let cpus = cpus ?? limits.defaultCPUs",
             replace: "let cpus = cpus ?? ProcessInfo.processInfo.processorCount"),
    Mutation(limit: "7", description: "pull and build have no timeout", file: dispatcher,
             find: "try await Task.sleep(for: .seconds(seconds))\n                throw BackendFailure",
             replace: "try await Task.sleep(for: .seconds(3600))\n                throw BackendFailure"),
    Mutation(limit: "8", description: "unlisted registries are accepted", file: policy,
             find: "guard ImageReference.isAllowed(domain: domain, registries: configuration.registries) else {",
             replace: "guard true else {"),
    Mutation(limit: "8", description: "build contexts outside the roots are accepted", file: policy,
             find: "contextDirectory = try approveHostPath(input.contextPath,",
             replace: "contextDirectory = try Policy(configuration: Configuration(mountRoots: [.init(path: \"/\", resolvedPath: \"/\", writable: false)], hostPorts: configuration.hostPorts, registries: configuration.registries, resources: configuration.resources, logs: configuration.logs, exec: configuration.exec, pullTimeoutSeconds: 1, buildTimeoutSeconds: 1, protectedContainers: []), paths: paths).approveHostPath(input.contextPath,"),
    Mutation(limit: "8", description: "base images in the Dockerfile are not checked", file: policy,
             find: "for image in scan.externalImages {",
             replace: "for image in [String]() {"),
    Mutation(limit: "9", description: "environment values are written to the audit log", file: audit,
             find: "return .string(entry[..<equals] + \"=<redacted>\")",
             replace: "return .string(entry)"),
    Mutation(limit: "9", description: "refusals are not logged", file: dispatcher,
             find: "await audit.record(tool: name, arguments: auditArguments, decision: .refused, rule: refusal.rule.rawValue, result: refusal.reason)",
             replace: ""),
    Mutation(limit: "10", description: "refusals do not say what is allowed", file: rule,
             find: "\"Refused by rule \\(rule.rawValue): \\(reason). Allowed: \\(allowed)\"",
             replace: "\"Refused by rule \\(rule.rawValue): \\(reason).\""),
    Mutation(limit: "10", description: "a refusal echoes the environment entry", file: policy,
             find: "\"\\(field)[\\(index)] has an invalid key\"",
             replace: "\"\\(field)[\\(index)] \\(entry) has an invalid key\""),
]

/// Runs a program from the developer tools by name, capturing its output.
func run(_ command: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (127, "cannot run \(command[0]): \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// nil when the mutated source does not build, otherwise whether a test failed.
func testsFail() -> (failed: Bool?, detail: String) {
    let build = run(["swift", "build", "--build-tests"])
    guard build.status == 0 else { return (nil, String(build.output.suffix(2000))) }
    let test = run(["swift", "test", "--skip-build", "--filter", "ContainerMCPCoreTests"])
    let failed = test.output.split(separator: "\n")
        .filter { $0.contains("✘ Test ") && !$0.contains("recorded an issue") }
        .prefix(4).joined(separator: "\n")
    return (test.status != 0, failed)
}

func treeIsClean() -> Bool { run(["git", "diff", "--quiet"]).status == 0 }

guard treeIsClean() else {
    print("The working tree has changes; commit or stash them first.")
    exit(1)
}

let selected = Array(CommandLine.arguments.dropFirst())
var missed = 0
var checked = 0
for mutation in mutations where selected.isEmpty || selected.contains(where: { mutation.description.contains($0) }) {
    let url = URL(fileURLWithPath: mutation.file)
    let original = try String(contentsOf: url, encoding: .utf8)
    guard original.components(separatedBy: mutation.find).count == 2 else {
        print("mutation for limit \(mutation.limit) (\(mutation.description)) does not match exactly once in \(mutation.file)")
        exit(1)
    }
    try original.replacingOccurrences(of: mutation.find, with: mutation.replace).write(to: url, atomically: true, encoding: .utf8)
    let result = testsFail()
    try original.write(to: url, atomically: true, encoding: .utf8)

    checked += 1
    let verdict: String
    switch result.failed {
    case .some(true): verdict = "caught"
    case .some(false): verdict = "NOT CAUGHT"
    case .none: verdict = "BUILD FAILED"
    }
    if verdict != "caught" { missed += 1 }
    print("limit \(mutation.limit.count == 1 ? " " : "")\(mutation.limit): \(mutation.description): \(verdict)")
    if result.failed == true {
        for line in result.detail.split(separator: "\n").prefix(2) {
            print("           \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}

let clean = treeIsClean()
let unmodifiedPass = testsFail().failed == false
print("\nworking tree restored: \(clean); unmodified tests pass: \(unmodifiedPass)")
print("\(checked - missed) of \(checked) limit removals caught by a failing test")
exit(missed == 0 && clean && unmodifiedPass ? 0 : 1)
