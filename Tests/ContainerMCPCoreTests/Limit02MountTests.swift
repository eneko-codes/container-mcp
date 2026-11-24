import Foundation
import Testing

@testable import ContainerMCPCore

/// Limit 2: host paths are resolved, must lie inside a configured root, are read-only unless
/// the root is writable and the call asks, and protected folders are always refused.
@Suite struct MountTests {
    func approve(_ fixture: Fixture, _ path: String, writable: Bool = false) -> Result<(resolved: String, readOnly: Bool), Refusal> {
        do {
            return .success(try fixture.policy.approveHostPath(path, wantsWritable: writable, containerApplicationRoot: nil))
        } catch {
            return .failure(error)
        }
    }

    func rule(_ result: Result<(resolved: String, readOnly: Bool), Refusal>) -> Rule? {
        if case .failure(let refusal) = result { return refusal.rule }
        return nil
    }

    @Test func folderInsideRootIsMountedReadOnly() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = try approve(fixture, fixture.readOnlyRoot + "/project/src").get()
        #expect(result.resolved == fixture.readOnlyRoot + "/project/src")
        #expect(result.readOnly)
    }

    @Test func symlinkEscapeIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // ~/Code/escape -> ~/.ssh: inside the root by name, protected once resolved.
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/escape")) == .mountProtected)
        // ~/Code/outside-link -> ~/Outside: outside every root once resolved.
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/outside-link")) == .mountOutsideRoots)
    }

    @Test func dotDotEscapeIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/project/../../Outside")) == .mountOutsideRoots)
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/../.ssh")) == .mountProtected)
    }

    @Test func pathOutsideRootsIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(rule(approve(fixture, fixture.home + "/Outside")) == .mountOutsideRoots)
    }

    @Test func protectedFoldersAreAlwaysRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        for path in [
            fixture.home, "/", fixture.home + "/.ssh", fixture.home + "/Library", fixture.home + "/Library/Keychains",
            fixture.paths.stateDirectory, fixture.paths.auditDirectory, fixture.home + "/.claude", fixture.base,
        ] {
            #expect(rule(approve(fixture, path)) == .mountProtected, "\(path) must be refused")
        }
    }

    @Test func caseVariantsOfProtectedFoldersAreRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(rule(approve(fixture, fixture.home + "/LIBRARY")) == .mountProtected)
    }

    /// Claude Code's settings decide what Claude may run; a container that could write them
    /// could widen Claude's own permissions, wherever the settings file really lives.
    @Test func claudeSettingsAreProtectedThroughTheirSymlink() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/dotfiles")) == .mountProtected)
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/dotfiles/claude", writable: false)) == .mountProtected)
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/project")) == nil)
    }

    @Test func protectedFolderInsideARootIsRefused() async throws {
        // Even a root that contains a protected folder cannot expose it.
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var configuration = fixture.configuration
        configuration.mountRoots.append(.init(path: fixture.home, resolvedPath: fixture.home, writable: true))
        let policy = Policy(configuration: configuration, paths: fixture.paths)
        #expect(refusal { () throws(Refusal) in try policy.approveHostPath(fixture.home + "/.ssh", wantsWritable: false, containerApplicationRoot: nil) }?.rule == .mountProtected)
        #expect(refusal { () throws(Refusal) in try policy.approveHostPath(fixture.home + "/Outside", wantsWritable: false, containerApplicationRoot: nil) } == nil)
    }

    @Test func containerApplicationRootIsProtected() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let appRoot = fixture.readOnlyRoot + "/project"
        #expect(refusal { () throws(Refusal) in try fixture.policy.approveHostPath(appRoot + "/src", wantsWritable: false, containerApplicationRoot: appRoot) }?.rule == .mountProtected)
    }

    @Test func writableNeedsAWritableRoot() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/project", writable: true)) == .mountWritableNotAllowed)
        let writable = try approve(fixture, fixture.writableRoot + "/app", writable: true).get()
        #expect(!writable.readOnly)
        // A writable root still mounts read-only unless the call asks.
        #expect(try approve(fixture, fixture.writableRoot + "/app").get().readOnly)
    }

    @Test func missingPathIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(rule(approve(fixture, fixture.readOnlyRoot + "/missing")) == .inputInvalid)
        #expect(rule(approve(fixture, "relative/path")) == .inputInvalid)
    }

    @Test func runToolPassesResolvedReadOnlyMountsToTheBackend() async throws {
        let fixture = try await Fixture(images: [ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a")])
        defer { fixture.remove() }
        let result = await fixture.call(.containerRun, [
            "image": "alpine", "name": "web",
            "mounts": [["host_path": .string(fixture.readOnlyRoot + "/project/../project/src"), "container_path": "/src"]],
        ])
        #expect(result.isError != true, "\(result.text)")
        guard case .create(let specification) = await fixture.backend.calls.first else {
            Issue.record("expected a create call")
            return
        }
        #expect(specification.bindMounts == [.init(source: fixture.readOnlyRoot + "/project/src", destination: "/src", readOnly: true)])
    }

    @Test func runToolRefusesSymlinkEscapeBeforeTheBackend() async throws {
        let fixture = try await Fixture(images: [ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a")])
        defer { fixture.remove() }
        let result = await fixture.call(.containerRun, [
            "image": "alpine", "name": "web",
            "mounts": [["host_path": .string(fixture.readOnlyRoot + "/escape"), "container_path": "/keys"]],
        ])
        #expect(result.refused(by: .mountProtected))
        #expect(await fixture.backend.calls.isEmpty)
    }

    @Test func volumesTheServerDidNotCreateCannotBeMounted() async throws {
        let fixture = try await Fixture(
            images: [ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a")],
            volumes: [VolumeSummary(name: "user-data", labels: [:]), VolumeSummary(name: "ours", labels: Fixture.ownedLabels)])
        defer { fixture.remove() }
        let foreign = await fixture.call(.containerRun, ["image": "alpine", "name": "aa", "volumes": [["volume": "user-data", "container_path": "/data"]]])
        #expect(foreign.refused(by: .mountVolumeNotOwned))
        let ours = await fixture.call(.containerRun, ["image": "alpine", "name": "bb", "volumes": [["volume": "ours", "container_path": "/data"]]])
        #expect(ours.isError != true, "\(ours.text)")
    }
}
