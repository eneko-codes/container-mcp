import ContainerAPIClient
import ContainerMCPCore
import ContainerResource
import ContainerizationError
import Foundation

/// Running a command in a container, adapted from `ContainerExec.run` in apple/container
/// 1.7.1, without a TTY or stdin, with a hard timeout and a cap on captured output.
extension NativeBackend {
    public func exec(id: String, specification: ExecSpecification) async throws -> ExecResult {
        let client = ContainerClient()
        let container = try await client.get(id: id)
        guard container.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        guard let executable = specification.command.first else {
            throw ContainerizationError(.invalidArgument, message: "no command specified for exec")
        }

        var configuration = container.configuration.initProcess
        configuration.executable = executable
        configuration.arguments = Array(specification.command.dropFirst())
        configuration.terminal = false
        configuration.environment.append(contentsOf: specification.environment)
        if let workingDirectory = specification.workingDirectory { configuration.workingDirectory = workingDirectory }
        if let user = specification.user { configuration.user = .raw(userString: user) }

        let standardOutput = Pipe()
        let standardError = Pipe()
        let collector = OutputCollector(limit: specification.maximumOutputBytes)
        let outputDone = collector.drain(standardOutput.fileHandleForReading, into: .output)
        let errorDone = collector.drain(standardError.fileHandleForReading, into: .error)

        let process = try await client.createProcess(
            containerId: id, processId: UUID().uuidString.lowercased(), configuration: configuration,
            stdio: [nil, standardOutput.fileHandleForWriting, standardError.fileHandleForWriting])
        try await process.start()
        // The service holds its own duplicates; closing ours lets the readers see end of file.
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()

        let exit = await Self.race(seconds: specification.timeoutSeconds) { try await process.wait() }
        var timedOut = false
        var exitCode: Int32?
        switch exit {
        case .finished(let code):
            exitCode = code
        case .failed(let error):
            throw error
        case .timedOut:
            timedOut = true
            try? await process.kill(SIGKILL)
            if case .finished(let code) = await Self.race(seconds: 5, { try await process.wait() }) { exitCode = code }
        }
        // A background child can keep the pipes open after the command exits; wait briefly, then stop reading.
        _ = await Self.race(seconds: 2) {
            await outputDone.value
            await errorDone.value
        }
        try? standardOutput.fileHandleForReading.close()
        try? standardError.fileHandleForReading.close()

        let captured = collector.result()
        return ExecResult(
            exitCode: timedOut ? nil : exitCode, timedOut: timedOut,
            standardOutput: String(decoding: captured.output, as: UTF8.self),
            standardError: String(decoding: captured.error, as: UTF8.self), outputTruncated: captured.truncated)
    }

    enum RaceOutcome<T: Sendable>: Sendable {
        case finished(T)
        case failed(any Error)
        case timedOut
    }

    static func race<T: Sendable>(seconds: Int, _ body: @escaping @Sendable () async throws -> T) async -> RaceOutcome<T> {
        await withTaskGroup(of: RaceOutcome<T>.self) { group in
            group.addTask {
                do { return .finished(try await body()) } catch { return .failed(error) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}

/// Collects stdout and stderr up to a shared byte limit, reading on dispatch threads so
/// blocking reads never hold a Swift concurrency thread.
final class OutputCollector: @unchecked Sendable {
    enum Stream { case output, error }

    private let lock = NSLock()
    private let limit: Int
    private var output = Data()
    private var error = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func drain(_ handle: FileHandle, into stream: Stream) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let chunk: Data
                        do {
                            guard let data = try handle.read(upToCount: 65_536), !data.isEmpty else { break }
                            chunk = data
                        } catch {
                            break
                        }
                        self.append(chunk, to: stream)
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func append(_ data: Data, to stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        let room = limit - output.count - error.count
        guard room > 0 else {
            truncated = true
            return
        }
        let kept = data.prefix(room)
        if kept.count < data.count { truncated = true }
        switch stream {
        case .output: output.append(kept)
        case .error: error.append(kept)
        }
    }

    func result() -> (output: Data, error: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (output, error, truncated)
    }
}
