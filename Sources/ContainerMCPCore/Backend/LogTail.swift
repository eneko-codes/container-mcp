import Foundation

/// Cuts log output down to the last lines that fit both limits.
public enum LogTail {
    public struct Result: Sendable, Codable, Equatable {
        public var lines: [String]
        /// True when older output was left out because of a limit.
        public var truncated: Bool
    }

    /// `data` is the end of a log file; `startsAtBeginning` tells whether it is the whole file,
    /// in which case its first line is complete.
    public static func tail(_ data: Data, maximumLines: Int, maximumBytes: Int, startsAtBeginning: Bool) -> Result {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var truncated = false
        if !startsAtBeginning, !lines.isEmpty {
            lines.removeFirst()
            truncated = true
        }
        if lines.count > maximumLines {
            lines = Array(lines.suffix(maximumLines))
            truncated = true
        }
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            let cost = line.utf8.count + 1
            if bytes + cost > maximumBytes {
                truncated = true
                break
            }
            bytes += cost
            kept.append(line)
        }
        return Result(lines: kept.reversed(), truncated: truncated)
    }
}
