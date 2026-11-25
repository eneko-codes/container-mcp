import Foundation
import Testing

@testable import ContainerMCPNative

/// The collector that keeps a command's output within its limit. It lives with the native
/// backend, and these tests need no container service, so they run with every `swift test`.
@Suite struct OutputCollectorTests {

    private func collect(_ chunks: [(Data, OutputCollector.Stream)], limit: Int) -> (output: String, error: String, omitted: Int) {
        let collector = OutputCollector(limit: limit)
        for (chunk, stream) in chunks { collector.append(chunk, to: stream) }
        let result = collector.result()
        return (String(decoding: result.output, as: UTF8.self), String(decoding: result.error, as: UTF8.self), result.omittedCharacters)
    }

    @Test func outputWithinTheLimitOmitsNothing() {
        let result = collect([(Data("hello\n".utf8), .output), (Data("oops\n".utf8), .error)], limit: 11)
        #expect(result.output == "hello\n")
        #expect(result.error == "oops\n")
        #expect(result.omitted == 0)
    }

    @Test func theLimitIsSharedAndWhatItCutIsCounted() {
        let result = collect([(Data("aaaa".utf8), .output), (Data("bbbb".utf8), .error), (Data("cccc".utf8), .output)], limit: 6)
        #expect(result.output == "aaaa")
        #expect(result.error == "bb")
        #expect(result.omitted == 6)
    }

    @Test func aCharacterCutInTwoIsDroppedWholeAndCountedOnce() {
        // "é" is two bytes; a limit of three bytes keeps "aé" and cuts the next "é" in two.
        let result = collect([(Data("aéé".utf8), .output)], limit: 4)
        #expect(result.output == "aé")
        #expect(result.omitted == 1)
        #expect(!result.output.contains("\u{FFFD}"))
    }

    @Test func aCharacterSplitBetweenReadsIsCountedOnce() {
        let bytes = Array("é😀".utf8)
        let result = collect([(Data(bytes[0..<1]), .output), (Data(bytes[1..<4]), .output), (Data(bytes[4...]), .output)], limit: 0)
        #expect(result.output == "")
        #expect(result.omitted == 2)
    }

    @Test func outputThatEndsInInvalidBytesIsNotCountedAsCut() {
        let result = collect([(Data([0x61, 0xE2]), .output)], limit: 10)
        #expect(result.omitted == 0)
    }
}
