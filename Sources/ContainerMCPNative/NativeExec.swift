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
            standardError: String(decoding: captured.error, as: UTF8.self), outputTruncated: captured.omittedCharacters > 0,
            omittedCharacters: captured.omittedCharacters)
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
/// blocking reads never hold a Swift concurrency thread. What does not fit is read and
/// discarded (a full pipe would block the command) and counted, in characters, so that the
/// result can say how much it left out.
final class OutputCollector: @unchecked Sendable {
    enum Stream { case output, error }

    private let lock = NSLock()
    private let limit: Int
    private var output = Data()
    private var error = Data()
    private var omitted = 0
    private var outputWasCut = false
    private var errorWasCut = false

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

    /// Characters are counted by their first byte, so a character split between two reads
    /// or at the limit is counted once.
    static func characters(in data: some Collection<UInt8>) -> Int {
        data.reduce(0) { $1 & 0xC0 == 0x80 ? $0 : $0 + 1 }
    }

    func append(_ data: Data, to stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        let room = max(limit - output.count - error.count, 0)
        let kept = data.prefix(room)
        if kept.count < data.count {
            omitted += Self.characters(in: data.dropFirst(kept.count))
            switch stream {
            case .output: outputWasCut = true
            case .error: errorWasCut = true
            }
        }
        switch stream {
        case .output: output.append(kept)
        case .error: error.append(kept)
        }
    }

    /// `data` without a trailing character that the limit cut in two, and how many such
    /// characters (zero or one) that was.
    static func wholeCharacters(_ data: Data) -> (data: Data, cut: Int) {
        var start = data.endIndex
        var back = 0
        while start > data.startIndex, back < 4 {
            start = data.index(before: start)
            back += 1
            if data[start] & 0xC0 == 0x80 { continue }
            let length = data[start] >= 0xF0 ? 4 : data[start] >= 0xE0 ? 3 : data[start] >= 0xC0 ? 2 : 1
            return length > back ? (Data(data[data.startIndex..<start]), 1) : (data, 0)
        }
        return (data, 0)
    }

    func result() -> (output: Data, error: Data, omittedCharacters: Int) {
        lock.lock()
        defer { lock.unlock() }
        let wholeOutput = outputWasCut ? Self.wholeCharacters(output) : (data: output, cut: 0)
        let wholeError = errorWasCut ? Self.wholeCharacters(error) : (data: error, cut: 0)
        return (wholeOutput.data, wholeError.data, omitted + wholeOutput.cut + wholeError.cut)
    }
}
