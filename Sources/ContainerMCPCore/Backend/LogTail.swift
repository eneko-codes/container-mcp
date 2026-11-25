import Foundation

/// Turns the end of a log into rows a page can be cut from.
///
/// A log is read newest first, because that is the end an operator wants and the end that
/// stays put as the log grows: row 1 is the last line, and `offset` counts rows back from it.
public enum LogTail {

    /// The most that is read from the end of a log, so that a very large one cannot fill
    /// the server's memory. Older output cannot be reached.
    public static let readBytes = 20_971_520

    /// The rows of a log, newest first. `data` is the end of a log; `startsAtBeginning` says
    /// whether it is the whole log, and when it is not, its first line is a fragment and is
    /// dropped. A line longer than `width` characters is split into rows of at most `width`
    /// (still newest first, so the pieces of one line come out in reverse order), so that
    /// every character of a very long line can be reached.
    public static func rows(_ data: Data, startsAtBeginning: Bool, width: Int) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        if !startsAtBeginning, !lines.isEmpty { lines.removeFirst() }
        var rows: [String] = []
        rows.reserveCapacity(lines.count)
        for line in lines.reversed() {
            guard line.count > width else {
                rows.append(line)
                continue
            }
            var pieces: [String] = []
            var start = line.startIndex
            while start < line.endIndex {
                let end = line.index(start, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
                pieces.append(String(line[start..<end]))
                start = end
            }
            rows.append(contentsOf: pieces.reversed())
        }
        return rows
    }

    /// The page that starts `offset` rows in: at most `limit` rows, and stopping earlier when
    /// the next row would take the page past `maximumBytes` of text (a newline counted after
    /// each row). A page always holds one row when there is one, so that a page can always
    /// be followed by the next. Newest first, as `rows` has them.
    public static func page(of rows: [String], offset: Int, limit: Int, maximumBytes: Int) -> [String] {
        var page: [String] = []
        var bytes = 0
        for row in rows.dropFirst(offset).prefix(limit) {
            let cost = row.utf8.count + 1
            if !page.isEmpty, bytes + cost > maximumBytes { break }
            bytes += cost
            page.append(row)
        }
        return page
    }
}
