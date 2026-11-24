import Foundation

/// The outcome of reading the policy at startup. Anything but `.loaded` leaves the server in
/// read-only mode.
public enum ConfigurationState: Sendable, Equatable {
    case loaded(Configuration)
    /// The server was started without policy options, for example outside the plugin.
    case missing
    /// The user left the plugin's "write tools" setting off.
    case writeToolsDisabled
    case invalid(problem: String)

    public var configuration: Configuration? {
        if case .loaded(let configuration) = self { return configuration }
        return nil
    }
}

public enum ConfigurationLoader {
    /// Reads the policy from the server's launch arguments.
    public static func load(arguments: [String]) -> ConfigurationState {
        guard !arguments.isEmpty else { return .missing }
        do {
            guard try ConfigurationArguments.writeToolsEnabled(arguments) else { return .writeToolsDisabled }
            var configuration = try ConfigurationArguments.parse(arguments)
            for index in configuration.mountRoots.indices {
                let root = configuration.mountRoots[index]
                guard let resolved = PathResolution.resolveExisting(root.path) else {
                    return .invalid(problem: "the folder \(root.path) does not exist")
                }
                configuration.mountRoots[index].resolvedPath = resolved
            }
            for name in configuration.adoptedContainers where !ContainerName.isValid(name) {
                return .invalid(problem: "adopted container name \"\(name)\" is not a valid container name")
            }
            return .loaded(configuration)
        } catch {
            return .invalid(problem: "\(error)")
        }
    }
}

/// Naming rules the container service applies; checked early so refusals are clear.
public enum ContainerName {
    /// Mirrors `ManagedContainer.nameValid` in apple/container 1.7.1.
    public static func isValid(_ name: String) -> Bool {
        guard name.count <= 63 else { return false }
        return name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    /// Mirrors `VolumeStorage.isValidVolumeName` in apple/container 1.7.1.
    public static func isValidVolume(_ name: String) -> Bool {
        guard name.count <= 255 else { return false }
        return name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    /// Mirrors `NetworkResource.nameValid` in apple/container 1.7.1.
    public static func isValidNetwork(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
    }
}
