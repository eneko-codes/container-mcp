import Foundation
import Synchronization
import Testing

@testable import ContainerMCPCore

/// MCP progress as the client sees it: the server's real handler and `serve` loop over a
/// fake backend, with every line it writes collected in order.
@Suite struct ProgressNotificationTests {

    final class Output: Sendable {
        private let lines = Mutex<[String]>([])

        func write(_ line: String) { lines.withLock { $0.append(line) } }

        var messages: [[String: Value]] {
            lines.withLock { $0 }.compactMap { try? JSONDecoder().decode(Value.self, from: Data($0.utf8)).objectValue }
        }
    }

    private func serveRequests(_ requests: [String], to fixture: Fixture, output: Output) async {
        let handler = ContainerMCPServer.handler(tools: ContainerTools(dispatcher: fixture.dispatcher, write: output.write))
        let lines = AsyncStream<String> { continuation in
            for request in requests { continuation.yield(request) }
            continuation.finish()
        }
        await serve(lines: lines, handler: handler, write: output.write)
    }

    private func pull(id: Int, meta: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"image_pull","arguments":{"reference":"alpine:3.20"}\#(meta)}}"#
    }

    @Test func progressPrecedesTheReplyAndOnlyGrows() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // A repeated value, then a second operation counting from zero again, as system_start
        // does when it pulls the init image after starting the service.
        await fixture.backend.set(pullProgress: [0, 0.5, 0.5, 1, 0.25, 0.75])
        let output = Output()
        await serveRequests([pull(id: 1, meta: #","_meta":{"progressToken":"pull-1"}"#)], to: fixture, output: output)

        let messages = output.messages
        let reply = try #require(messages.last)
        #expect(reply["id"] == 1)
        #expect(reply["result"]?.objectValue?["isError"] == false)
        let notifications = messages.dropLast()
        #expect(notifications.allSatisfy { $0["method"] == "notifications/progress" && $0["id"] == nil })
        let parameters = notifications.compactMap { $0["params"]?.objectValue }
        #expect(parameters.allSatisfy { $0["progressToken"] == "pull-1" && $0["message"] == "pulling" })
        #expect(parameters.compactMap { $0["progress"]?.doubleValue } == [0, 0.5, 1, 1.25, 1.75])
    }

    @Test func aCallWithoutATokenGetsNoNotification() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.backend.set(pullProgress: [0, 1])
        let output = Output()
        await serveRequests([pull(id: 2, meta: "")], to: fixture, output: output)
        #expect(output.messages.count == 1)
        #expect(output.messages.first?["id"] == 2)
    }

    @Test func nothingIsWrittenAfterTheReply() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.backend.set(pullProgress: [1])
        let output = Output()
        await serveRequests([pull(id: 3, meta: #","_meta":{"progressToken":7}"#)], to: fixture, output: output)
        #expect(output.messages.count == 2)
        #expect(output.messages.first?["params"]?.objectValue?["progressToken"] == 7)

        // A library task that outlives the call can still hold the sink and report through it.
        let late = try #require(await fixture.backend.lastPullProgress)
        await late.report(completed: 2, message: "late")
        #expect(output.messages.count == 2)
        #expect(output.messages.last?["id"] == 3)
    }

    /// Lines far above PIPE_BUF, written to a pipe from many tasks at once, each arrive whole.
    @Test func concurrentLongLinesStayWhole() async throws {
        let pipe = Pipe()
        let readEnd = pipe.fileHandleForReading
        let received = Task.detached { readEnd.readDataToEndOfFile() }
        let writer = ProtocolWriter(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor)

        let count = 64
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                let letter = Character(UnicodeScalar(UInt8(65 + index % 26)))
                group.addTask { writer.write(String(repeating: letter, count: 8_192)) }
            }
        }
        try pipe.fileHandleForWriting.close()
        let lines = String(decoding: await received.value, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == count + 1)
        #expect(lines.last == "")
        #expect(lines.dropLast().allSatisfy { $0.count == 8_192 && Set($0).count == 1 })
    }
}
