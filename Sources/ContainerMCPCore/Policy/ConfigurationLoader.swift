import Darwin
import Foundation

/// The outcome of reading the configuration at startup. Anything but `.loaded` leaves the
/// server in read-only mode.
public enum ConfigurationState: Sendable, Equatable {
    case loaded(Configuration)
    case missing(path: String)
    case invalid(path: String, problem: String)

    public var configuration: Configuration? {
        if case .loaded(let configuration) = self { return configuration }
        return nil
    }
}

public enum ConfigurationLoader {
    /// Reads and validates the file at `path`. The file must belong to the current user and
    /// must not be writable by group or others, so that only the user can set the policy.
    public static func load(path: String) -> ConfigurationState {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .missing(path: path) : .invalid(path: path, problem: "cannot read the file")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .invalid(path: path, problem: "the configuration must be a regular file, not a symlink or folder")
        }
        guard info.st_uid == getuid() else {
            return .invalid(path: path, problem: "the file must belong to the current user")
        }
        guard (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            return .invalid(path: path, problem: "the file must not be writable by group or others (chmod 600)")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .invalid(path: path, problem: "cannot read the file")
        }
        do {
            var configuration = try ConfigurationFile.decode(data)
            for index in configuration.mountRoots.indices {
                let root = configuration.mountRoots[index]
                guard let resolved = PathResolution.resolveExisting(root.path) else {
                    return .invalid(path: path, problem: "mount root \(root.path) does not exist")
                }
                configuration.mountRoots[index].resolvedPath = resolved
            }
            for name in configuration.adoptedContainers where !ContainerName.isValid(name) {
                return .invalid(path: path, problem: "adopted container name \"\(name)\" is not a valid container name")
            }
            return .loaded(configuration)
        } catch {
            return .invalid(path: path, problem: "\(error)")
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
