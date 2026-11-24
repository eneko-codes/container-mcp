import ContainerAPIClient
import ContainerMCPCore
import ContainerPersistence
import ContainerPlugin
import ContainerizationError
import Foundation
import SystemPackage

/// Starting the service, adapted from `SystemStart.run` in apple/container 1.7.1. The CLI
/// finds `container-apiserver` next to its own executable; this server is installed
/// elsewhere, so it uses the fixed install root of the official package. It never installs
/// a kernel, never prompts, and passes the service no variable from its own environment.
extension NativeBackend {
    /// Where the official installer package puts the container tool.
    static let installRoot = FilePath("/usr/local")
    static let serviceLabel = "com.apple.container.apiserver"

    public func startSystem(progress: ProgressSink) async throws -> SystemStartReport {
        if (try? await ClientHealthCheck.ping(timeout: .seconds(3))) != nil {
            return SystemStartReport(alreadyRunning: true, notes: [])
        }
        let bridge = ProgressBridge(progress)
        await bridge.step("Registering the container service")

        let appRoot = ApplicationRoot.defaultPath
        try ConfigurationLoader.copyConfigurationToReadOnly(to: appRoot)

        let apiServer = Self.installRoot.appending("bin").appending("container-apiserver")
        // launchd needs the real binary path: Gatekeeper checks the signature relative to the bundle.
        guard let resolved = PathResolution.resolveExisting(apiServer.string) else {
            throw ContainerizationError(.notFound, message: "\(apiServer.string) not found; is the container package installed?")
        }

        let dataPath = appRoot.appending("apiserver")
        try FileManager.default.createDirectory(atPath: dataPath.string, withIntermediateDirectories: true)
        let plist = LaunchPlist(
            label: Self.serviceLabel, arguments: [resolved, "start"],
            environment: [
                ApplicationRoot.environmentName: appRoot.string,
                InstallRoot.environmentName: Self.installRoot.string,
            ],
            limitLoadToSessionType: [.Aqua, .Background, .System], runAtLoad: true, machServices: [Self.serviceLabel])
        let plistPath = dataPath.appending("apiserver.plist")
        try plist.encode().write(to: URL(fileURLWithPath: plistPath.string))
        try ServiceManager.register(plistPath: plistPath.string)

        await bridge.step("Waiting for the container service")
        do {
            _ = try await ClientHealthCheck.ping(timeout: .seconds(60))
        } catch {
            throw ContainerizationError(.internalError, message: "the container service did not answer after registration: \(error)")
        }

        var notes: [String] = []
        if (try? await ClientKernel.getDefaultKernel(for: .current)) == nil {
            notes.append("No default Linux kernel is configured, so containers cannot start yet. The user can install the recommended one in Terminal with: container system kernel set --recommended")
        }
        return SystemStartReport(alreadyRunning: false, notes: notes)
    }
}
