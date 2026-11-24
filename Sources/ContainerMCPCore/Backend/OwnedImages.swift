import Foundation

/// Images carry no labels the server can set when they are pulled, so the server keeps its
/// own list of the images it pulled while they were absent, or built. Only these may be
/// deleted. The list lives in its own state file, never in the configuration.
public actor OwnedImages {
    private struct State: Codable {
        var version = 1
        var ownedImages: [String] = []
    }

    private let path: String?
    private var references: Set<String>

    /// `path` nil keeps the list in memory only, for tests.
    public init(path: String?) {
        self.path = path
        if let path, let data = FileManager.default.contents(atPath: path),
            let state = try? JSONDecoder().decode(State.self, from: data)
        {
            references = Set(state.ownedImages)
        } else {
            references = []
        }
    }

    public var all: Set<String> { references }

    public func add(_ reference: String) {
        references.insert(reference)
        save()
    }

    public func remove(_ reference: String) {
        references.remove(reference)
        save()
    }

    private func save() {
        guard let path else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try encoder.encode(State(ownedImages: references.sorted()))
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            FileHandle.standardError.write(Data("container-mcp: cannot save owned image list: \(error)\n".utf8))
        }
    }
}
