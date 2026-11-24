#!/usr/bin/env python3 -I
"""Checks that every security limit has a test that fails when the limit is removed.

For each limit, the script edits one line of the source to switch the limit off, rebuilds,
runs the unit tests and expects at least one to fail, then restores the file. It finishes by
confirming the working tree is unchanged and the unmodified tests pass again.

Run from the repository root: Scripts/check_limit_tests.py [words to select mutations by description]
"""

import subprocess
import sys
from pathlib import Path

POLICY = "Sources/ContainerMCPCore/Policy/Policy.swift"
DISPATCHER = "Sources/ContainerMCPCore/Tools/ToolDispatcher.swift"
CONFIGURATION = "Sources/ContainerMCPCore/Policy/Configuration.swift"
PATHS = "Sources/ContainerMCPCore/Policy/PathResolution.swift"
ARGUMENTS = "Sources/ContainerMCPCore/Tools/Arguments.swift"
AUDIT = "Sources/ContainerMCPCore/Audit/AuditLog.swift"
RULE = "Sources/ContainerMCPCore/Policy/Rule.swift"

# (limit, description, file, text to find, replacement)
MUTATIONS = [
    ("1", "write tools work without a configuration", DISPATCHER,
     'throw Refusal(.configurationMissing,', 'return Policy(configuration: Configuration(mountRoots: [], hostPorts: .init(minimum: 1024, maximum: 65535), registries: [], resources: .init(defaultCPUs: 1, maximumCPUs: 1, defaultMemoryMiB: 200, maximumMemoryMiB: 200), logs: .init(maximumLines: 1, maximumBytes: 1), exec: .init(maximumTimeoutSeconds: 1, maximumOutputBytes: 1), pullTimeoutSeconds: 1, buildTimeoutSeconds: 1, adoptedContainers: []), paths: paths); _ = Refusal(.configurationMissing,'),
    ("1", "unknown configuration keys are accepted", CONFIGURATION,
     'if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {',
     'if let unknown = Optional<String>.none {'),
    ("2", "protected folders are not checked", POLICY,
     'for protectedPath in protected {', 'for protectedPath in [String]() {'),
    ("2", "paths are not resolved before the check", POLICY,
     'guard let resolved = PathResolution.resolveExisting(hostPath) else {',
     'guard let resolved = Optional(hostPath), FileManager.default.fileExists(atPath: hostPath) else {'),
    ("2", "paths outside the roots are accepted", POLICY,
     'guard !matchingRoots.isEmpty else {', 'guard true else {'),
    ("2", "writable mounts do not need a writable root", POLICY,
     'guard matchingRoots.contains(where: \\.writable) else {', 'guard true else {'),
    ("2", "the audit folder is not protected", PATHS,
     '            auditDirectory,\n', ''),
    ("3", "ports bind every interface", POLICY,
     'ports.append(.init(hostAddress: Self.loopbackAddress,', 'ports.append(.init(hostAddress: "0.0.0.0",'),
    ("3", "host ports outside the range are accepted", POLICY,
     'guard (range.minimum...range.maximum).contains(port.hostPort) else {', 'guard true else {'),
    ("4", "unlabelled containers are treated as owned", POLICY,
     'let owned = Self.isOwned(container.labels)', 'let owned = true'),
    ("4", "adopted containers can be exec'd into and deleted", POLICY,
     'case (.start, true), (.stop, true):', 'case (.start, true), (.stop, true), (.exec, true), (.delete, true):'),
    ("4", "foreign volumes can be deleted", POLICY,
     'guard Self.isOwned(volume.labels) else {\n            throw Refusal(.ownershipUnlabelled', 'guard true else {\n            throw Refusal(.ownershipUnlabelled'),
    ("4", "foreign images can be deleted", POLICY,
     'guard ownedImages.contains(normalizedReference) else {', 'guard true else {'),
    ("5", "key-only environment entries are accepted", POLICY,
     'guard let equals = entry.firstIndex(of: "=") else {', 'guard let equals = entry.firstIndex(of: "=") ?? Optional(entry.endIndex) else {'),
    ("6", "a command string is split into words", ARGUMENTS,
     'guard let items = value.arrayValue else { throw invalid(key, "an array of strings") }',
     'if case .string(let line) = value { return line.split(separator: " ").map(String.init) }\n        guard let items = value.arrayValue else { throw invalid(key, "an array of strings") }'),
    ("7", "logs are not capped at the configured lines", POLICY,
     'return (min(requested, limits.maximumLines), limits.maximumBytes)', 'return (requested, limits.maximumBytes)'),
    ("7", "exec timeouts above the maximum are accepted", POLICY,
     'guard timeout >= 1, timeout <= maximum else {', 'guard true else {'),
    ("7", "exec output is not capped", POLICY,
     'timeoutSeconds: timeout, maximumOutputBytes: configuration.exec.maximumOutputBytes)', 'timeoutSeconds: timeout, maximumOutputBytes: Int.max)'),
    ("7", "CPUs above the maximum are accepted", POLICY,
     'guard cpus >= 1, cpus <= limits.maximumCPUs else {', 'guard true else {'),
    ("7", "runs get no default limits", POLICY,
     'let cpus = cpus ?? limits.defaultCPUs', 'let cpus = cpus ?? ProcessInfo.processInfo.processorCount'),
    ("7", "pull and build have no timeout", DISPATCHER,
     'try await Task.sleep(for: .seconds(seconds))\n                throw BackendFailure', 'try await Task.sleep(for: .seconds(3600))\n                throw BackendFailure'),
    ("8", "unlisted registries are accepted", POLICY,
     'guard ImageReference.isAllowed(domain: domain, registries: configuration.registries) else {', 'guard true else {'),
    ("8", "build contexts outside the roots are accepted", POLICY,
     'contextDirectory = try approveHostPath(input.contextPath,',
     'contextDirectory = try Policy(configuration: Configuration(mountRoots: [.init(path: "/", resolvedPath: "/", writable: false)], hostPorts: configuration.hostPorts, registries: configuration.registries, resources: configuration.resources, logs: configuration.logs, exec: configuration.exec, pullTimeoutSeconds: 1, buildTimeoutSeconds: 1, adoptedContainers: []), paths: paths).approveHostPath(input.contextPath,'),
    ("8", "base images in the Dockerfile are not checked", POLICY,
     'for image in scan.externalImages {', 'for image in [String]() {'),
    ("9", "environment values are written to the audit log", AUDIT,
     'return .string(entry[..<equals] + "=<redacted>")', 'return .string(entry)'),
    ("9", "refusals are not logged", DISPATCHER,
     'await audit.record(tool: name, arguments: auditArguments, decision: .refused, rule: refusal.rule.rawValue, result: refusal.reason)', ''),
    ("10", "refusals do not say what is allowed", RULE,
     '"Refused by rule \\(rule.rawValue): \\(reason). Allowed: \\(allowed)"', '"Refused by rule \\(rule.rawValue): \\(reason)."'),
    ("10", "a refusal echoes the environment entry", POLICY,
     '"\\(field)[\\(index)] has an invalid key"', '"\\(field)[\\(index)] \\(entry) has an invalid key"'),
]


def run(command):
    return subprocess.run(command, capture_output=True, text=True)


def tests_fail():
    build = run(["swift", "build", "--build-tests"])
    if build.returncode != 0:
        return None, build.stdout[-2000:] + build.stderr[-2000:]
    test = run(["swift", "test", "--skip-build", "--filter", "ContainerMCPCoreTests"])
    failed = [line for line in test.stdout.splitlines() if "✘ Test " in line and "recorded an issue" not in line]
    return test.returncode != 0, "\n".join(failed[:4])


def main():
    if run(["git", "diff", "--quiet"]).returncode != 0:
        sys.exit("The working tree has changes; commit or stash them first.")
    selected = sys.argv[1:]
    results = []
    for limit, description, file, old, new in MUTATIONS:
        if selected and not any(word in description for word in selected):
            continue
        path = Path(file)
        original = path.read_text()
        if original.count(old) != 1:
            sys.exit(f"mutation for limit {limit} ({description}) does not match exactly once in {file}")
        path.write_text(original.replace(old, new))
        try:
            failed, detail = tests_fail()
        finally:
            path.write_text(original)
        verdict = "caught" if failed else ("BUILD FAILED" if failed is None else "NOT CAUGHT")
        results.append((limit, description, verdict, detail))
        print(f"limit {limit:>2}: {description}: {verdict}", flush=True)
        if detail and failed:
            for line in detail.splitlines()[:2]:
                print(f"           {line.strip()}", flush=True)

    clean = run(["git", "diff", "--quiet"]).returncode == 0
    final, _ = tests_fail()
    print(f"\nworking tree restored: {clean}; unmodified tests pass: {final is False}")
    missed = [r for r in results if r[2] != "caught"]
    print(f"{len(results) - len(missed)} of {len(results)} limit removals caught by a failing test")
    sys.exit(0 if not missed and clean and final is False else 1)


if __name__ == "__main__":
    main()
