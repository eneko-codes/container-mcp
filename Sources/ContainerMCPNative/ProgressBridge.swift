import ContainerMCPCore
import Foundation
import TerminalProgress

/// Turns the container library's terminal progress events into MCP progress reports.
/// MCP progress must only grow, so the bridge counts finished phases plus the fraction of
/// the current one, and never reports a smaller number than before.
actor ProgressBridge {
    private let sink: ProgressSink
    private var description = ""
    private var size: Int64 = 0
    private var totalSize: Int64 = 0
    private var items = 0
    private var totalItems = 0
    private var phase = 0
    private var lastReported: Double = 0

    init(_ sink: ProgressSink) {
        self.sink = sink
    }

    nonisolated var handler: ProgressUpdateHandler {
        { [self] events in await self.apply(events) }
    }

    func apply(_ events: [ProgressUpdateEvent]) async {
        for event in events {
            switch event {
            case .setDescription(let text):
                if text != description {
                    description = text
                    phase += 1
                    size = 0
                    totalSize = 0
                    items = 0
                    totalItems = 0
                }
            case .addSize(let value): size += value
            case .setSize(let value): size = value
            case .addTotalSize(let value): totalSize += value
            case .setTotalSize(let value): totalSize = value
            case .addItems(let value): items += value
            case .setItems(let value): items = value
            case .addTotalItems(let value): totalItems += value
            case .setTotalItems(let value): totalItems = value
            default: continue
            }
        }
        let fraction: Double
        if totalSize > 0 {
            fraction = min(1, Double(size) / Double(totalSize))
        } else if totalItems > 0 {
            fraction = min(1, Double(items) / Double(totalItems))
        } else {
            fraction = 0
        }
        let completed = max(lastReported, Double(max(phase - 1, 0)) + fraction)
        lastReported = completed
        await sink.report(completed: completed, total: nil, message: description.isEmpty ? nil : description)
    }

    /// Reports a named step that has no byte or item counts.
    func step(_ text: String) async {
        await apply([.setDescription(text)])
    }
}
