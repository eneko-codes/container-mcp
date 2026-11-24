import Foundation

/// Finds the images a Dockerfile makes BuildKit fetch, so the registry allowlist also
/// covers builds. BuildKit fetches these itself, so the server can only check them by
/// reading the file before the build starts.
public enum DockerfileScanner {
    public struct Result: Sendable, Equatable {
        /// Image references the build would fetch, in file order.
        public let externalImages: [String]
    }

    public enum Problem: Error, Sendable, Equatable {
        /// A reference uses `$`, so its value is only known to BuildKit.
        case variableReference(String)
    }

    public static func scan(_ text: String) throws(Problem) -> Result {
        var images: [String] = []
        var stageNames: Set<String> = []
        var stageCount = 0
        var seenInstruction = false

        for line in logicalLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                // A `# syntax=` parser directive makes BuildKit fetch a frontend image. Directives
                // only count before the first instruction.
                if !seenInstruction, let image = directiveValue(trimmed, name: "syntax") {
                    try checkLiteral(image)
                    images.append(image)
                }
                continue
            }
            seenInstruction = true
            let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let instruction = words.first?.uppercased() else { continue }

            switch instruction {
            case "FROM":
                let arguments = words.dropFirst().filter { !$0.hasPrefix("--") }
                guard let image = arguments.first else { continue }
                if image.lowercased() != "scratch" && !stageNames.contains(image.lowercased()) {
                    try checkLiteral(image)
                    images.append(image)
                }
                if arguments.count >= 3, arguments[arguments.index(arguments.startIndex, offsetBy: 1)].uppercased() == "AS" {
                    stageNames.insert(arguments[arguments.index(arguments.startIndex, offsetBy: 2)].lowercased())
                }
                stageNames.insert(String(stageCount))
                stageCount += 1
            case "COPY", "ADD", "RUN":
                for word in words.dropFirst() where word.hasPrefix("--") {
                    for source in fromValues(in: word) where !stageNames.contains(source.lowercased()) {
                        try checkLiteral(source)
                        images.append(source)
                    }
                }
            default:
                continue
            }
        }
        return Result(externalImages: images)
    }

    /// Joins lines ending in a backslash, the default Dockerfile escape character.
    static func logicalLines(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasSuffix("\\") {
                current += line.dropLast() + " "
            } else {
                result.append(current + line)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func directiveValue(_ comment: String, name: String) -> String? {
        let body = comment.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let equals = body.firstIndex(of: "=") else { return nil }
        let key = body[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == name else { return nil }
        let value = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `--from=image` on COPY and ADD, and `from=image` inside `--mount=` on RUN.
    static func fromValues(in flag: String) -> [String] {
        let lowered = flag.lowercased()
        if lowered.hasPrefix("--from=") {
            return [String(flag.dropFirst("--from=".count))]
        }
        if lowered.hasPrefix("--mount=") {
            return flag.dropFirst("--mount=".count).split(separator: ",").compactMap { field in
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "from" else { return nil }
                return String(parts[1])
            }
        }
        return []
    }

    static func checkLiteral(_ reference: String) throws(Problem) {
        if reference.contains("$") { throw .variableReference(reference) }
    }
}
