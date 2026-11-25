import Foundation
import Testing

@testable import ContainerMCPCore

/// The edges of the tool standard for this server's tools: each bound and one past it, the
/// text of each notice, pages that chain, the longest result and the texts the model reads.
/// Every container, image, volume, network and log line in here is invented.
@Suite("Bounds") struct StandardBoundsTests {

    // MARK: Helpers

    /// A result is JSON, and what it left out is said in plain words before it.
    static func split(_ result: ToolOutput) -> (notices: [String], object: [String: Any]) {
        split(text: result.text)
    }

    static func split(_ output: ToolDispatcher.Output) -> (notices: [String], object: [String: Any]) {
        split(text: output.text)
    }

    static func split(text: String) -> (notices: [String], object: [String: Any]) {
        let start = text.firstIndex(of: "{") ?? text.startIndex
        let head = text[..<start].split(separator: "\n").map(String.init)
        let object = (try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))) as? [String: Any]
        return (head, object ?? [:])
    }

    static func names(_ count: Int, _ prefix: String) -> [String] {
        (0..<count).map { "\(prefix)-\(String(format: "%04d", $0))" }
    }

    /// A container with the widest ordinary row: a long image, three ports, three mounts.
    static func wideContainer(_ id: String) -> ContainerSummary {
        ContainerSummary(
            id: id, image: "ghcr.io/example-org/example-images/service-" + String(repeating: "x", count: 30) + ":1.2.3",
            status: "running", labels: Fixture.ownedLabels,
            ports: (0..<3).map { PortMapping(hostAddress: "127.0.0.1", hostPort: 8000 + $0, containerPort: 80 + $0, protocolName: "tcp") },
            mounts: (0..<3).map {
                MountSummary(kind: .bind, source: "/Users/user/Code/example-project/folder-\($0)", destination: "/data/folder-\($0)", readOnly: true)
            },
            networks: ["default"], addresses: ["192.168.64.10/24"], cpus: 2, memoryBytes: 1_073_741_824,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), startedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    /// One listing tool and a fixture that gives it `count` rows of the widest ordinary
    /// width, in the order the tool states.
    struct Listing: Sendable, CustomTestStringConvertible {
        var tool: ToolName
        var key: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var make: @Sendable (Int) async throws -> Fixture
        var ids: @Sendable ([String: Any]) -> [String]

        var testDescription: String { tool.rawValue }
    }

    static let listings: [Listing] = [
        Listing(
            tool: .containersList, key: "containers", things: "containers", limits: ToolCatalog.containerLimitRange,
            defaultLimit: ToolCatalog.defaultContainerLimit,
            make: { count in
                // Stated order is by id: hand the fixture the rows backwards.
                try await Fixture(containers: names(count, "service").reversed().map(wideContainer))
            },
            ids: { ($0["containers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }),
        Listing(
            tool: .imagesList, key: "images", things: "images", limits: ToolCatalog.imageLimitRange,
            defaultLimit: ToolCatalog.defaultImageLimit,
            make: { count in
                try await Fixture(
                    images: names(count, "registry.example.com/example-org/example-images/image-" + String(repeating: "x", count: 30)).reversed().map {
                        ImageSummary(reference: $0, digest: "sha256:" + String(repeating: "a", count: 64), sizeBytes: 123_456_789)
                    })
            },
            ids: { ($0["images"] as? [[String: Any]] ?? []).compactMap { $0["reference"] as? String }.filter { !$0.contains("vminit") && !$0.contains("builder") } }),
        Listing(
            tool: .volumesList, key: "volumes", things: "volumes", limits: ToolCatalog.volumeLimitRange,
            defaultLimit: ToolCatalog.defaultVolumeLimit,
            make: { count in
                try await Fixture(
                    volumes: names(count, "volume-" + String(repeating: "x", count: 40)).reversed().map {
                        VolumeSummary(name: $0, labels: Fixture.ownedLabels, sizeBytes: 536_870_912_000, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
                    })
            },
            ids: { ($0["volumes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }),
        Listing(
            tool: .networksList, key: "networks", things: "networks", limits: ToolCatalog.networkLimitRange,
            defaultLimit: ToolCatalog.defaultNetworkLimit,
            make: { count in
                // The default network is a row too; the invented ones sort after it.
                try await Fixture(
                    networks: [NetworkSummary(name: "default", labels: [:], mode: "nat", builtin: true)]
                        + names(count - 1, "network-" + String(repeating: "x", count: 40)).reversed().map {
                            NetworkSummary(name: $0, labels: Fixture.ownedLabels, mode: "nat", subnet: "192.168.100.0/24", builtin: false)
                        })
            },
            ids: { ($0["networks"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }),
    ]

    // MARK: Listings

    @Test("A call with no optional argument is one usual page that says what it leaves out", arguments: listings)
    func defaultPage(_ listing: Listing) async throws {
        let count = listing.defaultLimit * 3 + 7
        let fixture = try await listing.make(count)
        defer { fixture.remove() }
        // Image rows also hold the two images the container service needs.
        let total = listing.tool == .imagesList ? count + 2 : count
        let result = await fixture.call(listing.tool)
        #expect(result.isError != true, "\(result.text)")
        let (notices, object) = Self.split(result)
        #expect(
            notices == ["Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page."],
            "\(notices)")
        #expect(result.text.utf16.count <= ToolStandard.usualPage, "\(result.text.utf16.count) characters for \(listing.defaultLimit) rows")
        #expect((object[listing.key] as? [Any])?.count == listing.defaultLimit)
    }

    @Test("A page at the largest limit still fits the longest result", arguments: listings)
    func widestPageFits(_ listing: Listing) async throws {
        let fixture = try await listing.make(listing.limits.upperBound + 10)
        defer { fixture.remove() }
        let result = await fixture.call(listing.tool, ["limit": .int(listing.limits.upperBound)])
        let (notices, object) = Self.split(result)
        #expect(result.text.utf16.count <= ToolStandard.longestResult, "\(result.text.utf16.count) characters")
        #expect((object[listing.key] as? [Any])?.count == listing.limits.upperBound, "\(notices)")
    }

    @Test("A limit one past each end is moved and the result says which was used", arguments: listings)
    func limitIsMoved(_ listing: Listing) async throws {
        let fixture = try await listing.make(listing.limits.upperBound + 5)
        defer { fixture.remove() }
        let high = listing.limits.upperBound + 1
        let above = await fixture.call(listing.tool, ["limit": .int(high)])
        #expect(
            Self.split(above).notices.first == "limit=\(high) is outside \(listing.limits.lowerBound)–\(listing.limits.upperBound); \(listing.limits.upperBound) was used.")
        let below = await fixture.call(listing.tool, ["limit": 0])
        #expect(Self.split(below).notices.first == "limit=0 is outside \(listing.limits.lowerBound)–\(listing.limits.upperBound); \(listing.limits.lowerBound) was used.")
        #expect((Self.split(below).object[listing.key] as? [Any])?.count == 1)
        let negative = await fixture.call(listing.tool, ["offset": -3])
        #expect(Self.split(negative).notices.first == "offset=-3 is outside \(ToolCatalog.offsetRange.lowerBound)–\(ToolCatalog.offsetRange.upperBound); 0 was used.")
    }

    @Test("The second page starts where the first ended, in the stated order, and the last says that is all", arguments: listings)
    func pagesChain(_ listing: Listing) async throws {
        let count = 7
        let fixture = try await listing.make(count)
        defer { fixture.remove() }
        let first = await fixture.call(listing.tool, ["limit": 3])
        let second = await fixture.call(listing.tool, ["limit": 3, "offset": 3])
        let third = await fixture.call(listing.tool, ["limit": 3, "offset": 6])
        let rows = [first, second, third].map { listing.ids(Self.split($0).object) }
        let all = rows.flatMap { $0 }
        let expectedTotal = listing.tool == .imagesList ? count + 2 : count
        #expect(Self.split(first).notices.contains("Showing 1–3 of \(expectedTotal) \(listing.things). Pass offset=3 for the next page."))
        #expect(Self.split(second).notices.contains("Showing 4–6 of \(expectedTotal) \(listing.things). Pass offset=6 for the next page."))
        #expect(all == all.sorted(), "rows are in the stated order, with no repeat and no gap: \(all)")
        #expect(Set(all).count == all.count)
        // Everything the listing holds is reached by following the offsets.
        var seen: [String] = []
        var offset = 0
        while offset < expectedTotal {
            let page = await fixture.call(listing.tool, ["limit": 3, "offset": .int(offset)])
            seen += listing.ids(Self.split(page).object)
            offset += 3
        }
        #expect(seen.count == count)
        let last = await fixture.call(listing.tool, ["limit": 3, "offset": .int(((expectedTotal - 1) / 3) * 3)])
        #expect(Self.split(last).notices.last?.hasSuffix("That is all.") == true, "\(Self.split(last).notices)")
        let past = await fixture.call(listing.tool, ["offset": .int(expectedTotal + 5)])
        #expect(Self.split(past).notices == ["Showing 0 of \(expectedTotal) \(listing.things): offset=\(expectedTotal + 5) is past the end. That is all."])
    }

    @Test("A listing that holds everything carries no notice", arguments: listings)
    func wholeListingHasNoNotice(_ listing: Listing) async throws {
        let fixture = try await listing.make(2)
        defer { fixture.remove() }
        let result = await fixture.call(listing.tool)
        #expect(Self.split(result).notices.isEmpty, "\(Self.split(result).notices)")
        #expect(result.text.hasPrefix("{"))
    }

    @Test("A limit of the wrong type is refused with the form expected", arguments: listings)
    func wrongType(_ listing: Listing) async throws {
        let fixture = try await listing.make(2)
        defer { fixture.remove() }
        let result = await fixture.call(listing.tool, ["limit": "ten"])
        #expect(result.refused(by: .inputInvalid))
        #expect(result.text.contains("must be an integer"), "\(result.text)")
        let fraction = await fixture.call(listing.tool, ["offset": .double(1.5)])
        #expect(fraction.refused(by: .inputInvalid))
    }

    @Test("The renamed argument is refused, with the names that are allowed")
    func oldNameIsRefused() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        let result = await fixture.call(.containerLogs, ["id": "web", "lines": 10])
        #expect(result.refused(by: .inputInvalid))
        #expect(result.text.contains("unknown field \"lines\""), "\(result.text)")
        #expect(result.text.contains("limit"), "\(result.text)")
    }

    @Test("A container row far wider than ordinary loses its widest members and the page says so")
    func wideRowIsNarrowed() async throws {
        var wide = Self.wideContainer("service-wide")
        wide.labels = Fixture.ownedLabels.merging((0..<60).map { ("example.label.\($0)", String(repeating: "v", count: 100)) }) { first, _ in first }
        let fixture = try await Fixture(containers: [Self.wideContainer("service-a"), wide])
        defer { fixture.remove() }
        let result = await fixture.call(.containersList)
        let (notices, object) = Self.split(result)
        #expect(notices == ["Detail is clipped to \(ToolCatalog.widestRow) characters in each row. Read one in full with container_inspect."], "\(notices)")
        let rows = try #require(object["containers"] as? [[String: Any]])
        #expect((rows[0]["labels"] as? [String: String])?.count == 1)
        let labels = try #require(rows[1]["labels"] as? String)
        #expect(labels.hasSuffix("characters, not shown)"), "\(labels)")
        #expect(rows[1]["id"] as? String == "service-wide")
        // The page that holds no wide row says nothing about clipping.
        let narrow = await fixture.call(.containersList, ["limit": 1])
        #expect(!narrow.text.contains("clipped"), "\(narrow.text)")
    }

    @Test("Stopped containers are left out only when asked, and the others still page")
    func allFlag() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("a"), Fixture.owned("b", status: "stopped"), Fixture.owned("c")])
        defer { fixture.remove() }
        let result = await fixture.call(.containersList, ["all": false, "limit": 1])
        #expect(Self.split(result).notices == ["Showing 1–1 of 2 containers. Pass offset=1 for the next page."])
    }

    // MARK: Logs

    private func logLines(_ count: Int) -> Data {
        Data((1...count).map { "line \($0)" }.joined(separator: "\n").utf8)
    }

    @Test("Earlier log lines are reached by offset, counting back from the end, and the pages chain")
    func logPagesChain() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        await fixture.backend.set(logData: logLines(12))
        let things = "lines, counted back from the end of the log"
        let first = await fixture.call(.containerLogs, ["id": "web", "limit": 5])
        #expect(Self.split(first).notices == ["Showing 1–5 of 12 \(things). Pass offset=5 for the next page."])
        #expect(Self.split(first).object["lines"] as? [String] == ["line 8", "line 9", "line 10", "line 11", "line 12"])
        let second = await fixture.call(.containerLogs, ["id": "web", "limit": 5, "offset": 5])
        #expect(Self.split(second).notices == ["Showing 6–10 of 12 \(things). Pass offset=10 for the next page."])
        #expect(Self.split(second).object["lines"] as? [String] == ["line 3", "line 4", "line 5", "line 6", "line 7"])
        let third = await fixture.call(.containerLogs, ["id": "web", "limit": 5, "offset": 10])
        #expect(Self.split(third).notices == ["Showing 11–12 of 12 \(things). That is all."])
        #expect(Self.split(third).object["lines"] as? [String] == ["line 1", "line 2"])
        let past = await fixture.call(.containerLogs, ["id": "web", "offset": 40])
        #expect(Self.split(past).notices == ["Showing 0 of 12 \(things): offset=40 is past the end. That is all."])
        #expect(Self.split(past).object["lines"] as? [String] == [])
    }

    @Test("A log that fits one page and an empty log carry no notice, and no flag says anything")
    func logWholeAndEmpty() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        await fixture.backend.set(logData: logLines(3))
        let whole = await fixture.call(.containerLogs, ["id": "web"])
        #expect(whole.text.hasPrefix("{"), "\(whole.text)")
        #expect(Self.split(whole).object["truncated"] == nil)
        await fixture.backend.set(logData: Data())
        let empty = await fixture.call(.containerLogs, ["id": "web"])
        #expect(empty.text.hasPrefix("{"))
        #expect(Self.split(empty).object["lines"] as? [String] == [])
    }

    @Test("The configured byte limit shortens a page, and the notice says where the next one starts")
    func logByteLimit() async throws {
        let fixture = try await Fixture(
            containers: [Fixture.owned("web")], logs: .init(maximumLines: 100, maximumBytes: 64))
        defer { fixture.remove() }
        // Three lines of 29 characters and a newline: two fit 64 bytes, three do not.
        await fixture.backend.set(logData: Data((1...3).map { "line-\($0)-" + String(repeating: "x", count: 22) }.joined(separator: "\n").utf8))
        let result = await fixture.call(.containerLogs, ["id": "web", "limit": 50])
        #expect(Self.split(result).notices.contains("Showing 1–2 of 3 lines, counted back from the end of the log. Pass offset=2 for the next page."), "\(Self.split(result).notices)")
        let rest = await fixture.call(.containerLogs, ["id": "web", "offset": 2])
        #expect((Self.split(rest).object["lines"] as? [String])?.count == 1)
    }

    @Test("A single line longer than the byte limit is still returned, and is reached whole")
    func logLongLine() async throws {
        let fixture = try await Fixture(
            containers: [Fixture.owned("web")], logs: .init(maximumLines: 100, maximumBytes: 10))
        defer { fixture.remove() }
        let line = String(repeating: "a", count: ToolCatalog.logLineWidth * 2 + 500)
        await fixture.backend.set(logData: Data((line + "\n").utf8))
        var pieces: [String] = []
        var offset = 0
        while true {
            let page = await fixture.call(.containerLogs, ["id": "web", "offset": .int(offset)])
            let lines = Self.split(page).object["lines"] as? [String] ?? []
            if lines.isEmpty { break }
            // Pieces come newest first across pages, oldest first inside a page.
            pieces = lines + pieces
            offset += lines.count
        }
        #expect(pieces.map(\.count) == [ToolCatalog.logLineWidth, ToolCatalog.logLineWidth, 500])
        #expect(pieces.joined() == line)
    }

    @Test("A log read from its end says that older output cannot be reached, on the page that ends it")
    func logOlderOutput() {
        let arguments = try? Arguments(nil, allowed: [])
        let data = Data((1...10).map { "line \($0)" }.joined(separator: "\n").utf8)
        // 10 lines of "line N" are 9 * 7 + 8 + 1 bytes; a read size of that many means the log was cut at its start.
        let output = ToolDispatcher.logPage(arguments!, id: "web", boot: false, data: data, limit: 100, offset: 0, maximumBytes: 10_000, readBytes: data.count)
        #expect(Self.split(output).notices.last == ToolDispatcher.olderLogNotReadable, "\(Self.split(output).notices)")
        #expect((Self.split(output).object["lines"] as? [String])?.first == "line 2", "the fragment at the cut is dropped")
        let earlier = ToolDispatcher.logPage(arguments!, id: "web", boot: false, data: data, limit: 2, offset: 0, maximumBytes: 10_000, readBytes: data.count)
        #expect(!Self.split(earlier).notices.contains(ToolDispatcher.olderLogNotReadable))
    }

    @Test("A setting above what a result may hold acts as that, and the page fits")
    func settingsAreHeld() async throws {
        let big = Configuration.LogLimits(maximumLines: 100_000, maximumBytes: 10_485_760)
        #expect(big.effective.maximumBytes == ToolStandard.longestResult)
        #expect(big.effective.maximumLines == ToolStandard.longestResult)
        let fixture = try await Fixture(
            containers: [Fixture.owned("web")], logs: big,
            exec: .init(maximumTimeoutSeconds: 3600, maximumOutputBytes: 10_485_760))
        defer { fixture.remove() }
        #expect(fixture.configuration.effectiveExecLimits == .init(maximumTimeoutSeconds: ToolCatalog.longestOperationSeconds, maximumOutputBytes: ToolStandard.longestResult))
        // Wide lines, each 1,900 characters of escapes: the page holds fewer lines than asked, and fits.
        let line = String(repeating: "\t", count: 1_900)
        await fixture.backend.set(logData: Data(Array(repeating: line, count: 60).joined(separator: "\n").utf8))
        let result = await fixture.call(.containerLogs, ["id": "web", "limit": 60])
        #expect(result.text.utf16.count <= ToolStandard.longestResult, "\(result.text.utf16.count)")
        let held = (Self.split(result).object["lines"] as? [String])?.count ?? 0
        #expect(held > 0 && held < 60)
        #expect(Self.split(result).notices.contains { $0.hasPrefix("Showing 1–\(held) of 60 lines") }, "\(Self.split(result).notices)")
    }

    @Test("A call without a limit aims at one usual page even when the lines are wide")
    func logDefaultPageIsUsual() async throws {
        let fixture = try await Fixture(
            containers: [Fixture.owned("web")], logs: .init(maximumLines: 500, maximumBytes: 65_536))
        defer { fixture.remove() }
        await fixture.backend.set(logData: Data((1...200).map { "\($0) " + String(repeating: "w", count: 400) }.joined(separator: "\n").utf8))
        let plain = await fixture.call(.containerLogs, ["id": "web"])
        #expect(plain.text.utf16.count <= ToolStandard.usualPage + 1_000, "\(plain.text.utf16.count)")
        #expect(Self.split(plain).notices.first?.hasPrefix("Showing 1–") == true)
        // Asking for a limit lifts that to what the settings allow.
        let asked = await fixture.call(.containerLogs, ["id": "web", "limit": 100])
        #expect(asked.text.utf16.count > ToolStandard.usualPage + 1_000)
        #expect(asked.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("A volume or a network row far wider than ordinary is narrowed, and the page says no tool reads it in full")
    func wideVolumeAndNetworkRows() async throws {
        let labels = Dictionary(uniqueKeysWithValues: (0..<60).map { ("example.label.\($0)", String(repeating: "v", count: 100)) })
        let fixture = try await Fixture(
            volumes: [VolumeSummary(name: "data", labels: labels)],
            networks: [NetworkSummary(name: "default", labels: [:], mode: "nat", builtin: true), NetworkSummary(name: "lab", labels: labels, mode: "nat", builtin: false)])
        defer { fixture.remove() }
        for tool in [ToolName.volumesList, .networksList] {
            let result = await fixture.call(tool)
            #expect(Self.split(result).notices == ["Detail is clipped to \(ToolCatalog.widestRow) characters in each row. No tool reads one in full."], "\(tool): \(Self.split(result).notices)")
            #expect(result.text.utf16.count < ToolStandard.usualPage)
        }
    }

    @Test("The log tool without a configuration is held to the same limits")
    func logWithoutConfiguration() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")], configurationState: .missing)
        defer { fixture.remove() }
        await fixture.backend.set(logData: logLines(500))
        let result = await fixture.call(.containerLogs, ["id": "web", "limit": 5000])
        #expect(Self.split(result).notices.first == "limit=5000 is outside 1–200; 200 was used.", "\(Self.split(result).notices)")
    }

    // MARK: Exec output

    @Test("Exec output that fits says nothing about a cut")
    func execWhole() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")])
        defer { fixture.remove() }
        let result = await fixture.call(.containerExec, ["id": "api", "command": ["ls"]])
        #expect(result.text.hasPrefix("{"), "\(result.text)")
        #expect(Self.split(result).object["outputTruncated"] == nil)
    }

    @Test("Exec output the limit cut says how much, in plain words before the JSON")
    func execCut() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")])
        defer { fixture.remove() }
        await fixture.backend.set(
            execResult: ExecResult(
                exitCode: 0, timedOut: false, standardOutput: String(repeating: "o", count: 3000),
                standardError: String(repeating: "e", count: 1096), outputTruncated: true, omittedCharacters: 5904))
        let result = await fixture.call(.containerExec, ["id": "api", "command": ["ls"]])
        #expect(Self.split(result).notices == ["Cut at 4096 of 10000 characters; the rest cannot be read again."], "\(Self.split(result).notices)")
        #expect(Self.split(result).object["standardOutput"] as? String == String(repeating: "o", count: 3000))
    }

    @Test("Output whose JSON would pass the longest result is cut further, and the sentence stays true")
    func execEscapedOutput() async throws {
        let fixture = try await Fixture(
            containers: [Fixture.owned("api")], exec: .init(maximumTimeoutSeconds: 30, maximumOutputBytes: ToolStandard.longestResult))
        defer { fixture.remove() }
        // Tabs and quotes each take two characters in JSON.
        let output = String(repeating: "\"\t", count: ToolStandard.longestResult / 2)
        await fixture.backend.set(execResult: ExecResult(exitCode: 1, timedOut: false, standardOutput: output, standardError: "boom", outputTruncated: false))
        let result = await fixture.call(.containerExec, ["id": "api", "command": ["ls"]])
        #expect(result.text.utf16.count <= ToolStandard.longestResult, "\(result.text.utf16.count)")
        let (notices, object) = Self.split(result)
        let standardOutput = try #require(object["standardOutput"] as? String)
        let standardError = try #require(object["standardError"] as? String)
        let kept = standardOutput.unicodeScalars.count + standardError.unicodeScalars.count
        #expect(notices == ["Cut at \(kept) of \(output.unicodeScalars.count + 4) characters; the rest cannot be read again."], "\(notices)")
    }

    @Test("A command killed at its timeout says so before the JSON and returns what it wrote")
    func execTimedOut() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("api")])
        defer { fixture.remove() }
        await fixture.backend.set(execResult: ExecResult(exitCode: nil, timedOut: true, standardOutput: "partial\n", standardError: "", outputTruncated: false))
        let result = await fixture.call(.containerExec, ["id": "api", "command": ["sleep", "100"], "timeout_seconds": 7])
        #expect(
            Self.split(result).notices == [
                "Partial: the time limit was reached after 8 characters of output. Narrow by the command.",
                "The command was killed after 7 seconds. Raise timeout_seconds (at most \(ToolCatalog.longestOperationSeconds)) to let it run longer.",
            ], "\(Self.split(result).notices)")
        #expect(Self.split(result).object["standardOutput"] as? String == "partial\n")
    }

    // MARK: One description

    @Test("A description that fits is returned whole, with no notice")
    func inspectWhole() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        let result = await fixture.call(.containerInspect, ["id": "web"])
        #expect(result.text.hasPrefix("{"), "\(result.text)")
    }

    private func description(members: Int, width: Int) -> Data {
        let body = (0..<members).map { "\"member\($0)\": \"" + String(repeating: "x", count: width) + "\"" }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    @Test("A description too long for a result is refused with the size of each member, never cut")
    func inspectRefusedWhole() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        await fixture.backend.set(inspectJSON: description(members: 6, width: 9_000))
        let result = await fixture.call(.containerInspect, ["id": "web"])
        #expect(result.refused(by: .boundsResultSize), "\(result.text)")
        #expect(result.text.contains("fields naming some of its members, largest first: member0 (9"), "\(result.text)")
        #expect(result.text.contains("and 1 more"), "\(result.text)")
        #expect(result.text.utf16.count < ToolStandard.longestError)
    }

    @Test("Chosen members are returned and the others are announced with the call that returns them")
    func inspectFields() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        await fixture.backend.set(inspectJSON: description(members: 6, width: 9_000))
        let result = await fixture.call(.containerInspect, ["id": "web", "fields": ["member0", "member1"]])
        #expect(result.isError != true, "\(result.text)")
        #expect(
            Self.split(result).notices == ["4 members (member2, member3, member4, member5) are not shown. Pass fields=[\"member2\",\"member3\",\"member4\",\"member5\"] to include them."],
            "\(Self.split(result).notices)")
        let container = try #require(Self.split(result).object["container"] as? [String: Any])
        #expect(Set(container.keys) == ["member0", "member1"])
        let unknown = await fixture.call(.containerInspect, ["id": "web", "fields": ["nothing"]])
        #expect(unknown.refused(by: .inputInvalid))
        #expect(unknown.text.contains("no member named nothing"), "\(unknown.text)")
    }

    @Test("One member that is itself too long cannot be narrowed, and the refusal says so")
    func inspectUnnarrowable() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")])
        defer { fixture.remove() }
        await fixture.backend.set(inspectJSON: description(members: 2, width: 45_000))
        let result = await fixture.call(.containerInspect, ["id": "web", "fields": ["member0"]])
        #expect(result.refused(by: .boundsResultSize), "\(result.text)")
        #expect(result.text.contains("nothing: it cannot be narrowed further"), "\(result.text)")
    }

    @Test("An image description is bounded the same way")
    func inspectImage() async throws {
        let fixture = try await Fixture(images: [ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a")])
        defer { fixture.remove() }
        await fixture.backend.set(imageInspectJSON: description(members: 3, width: 20_000))
        let whole = await fixture.call(.imageInspect, ["reference": "alpine"])
        #expect(whole.refused(by: .boundsResultSize), "\(whole.text)")
        let part = await fixture.call(.imageInspect, ["reference": "alpine", "fields": ["member1"]])
        #expect(part.isError != true, "\(part.text)")
        #expect(Self.split(part).notices.count == 1)
    }

    // MARK: Quantities and identifiers

    @Test("A stop timeout outside its range is moved and said; a port outside its range is refused")
    func quantitiesAndIdentifiers() async throws {
        let fixture = try await Fixture(containers: [Fixture.owned("web")], images: [ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a")])
        defer { fixture.remove() }
        let stop = await fixture.call(.containerStop, ["id": "web", "timeout_seconds": 100_000])
        let last = ToolCatalog.stopTimeoutRange.upperBound
        #expect(Self.split(stop).notices == ["timeout_seconds=100000 is outside 0–\(last); \(last) was used."], "\(stop.text)")
        guard case .stop(_, let seconds) = await fixture.backend.calls.last else {
            Issue.record("expected stop")
            return
        }
        #expect(seconds == last)
        let volume = await fixture.call(.volumeCreate, ["name": "data", "size_mib": 0])
        #expect(Self.split(volume).notices.first == "size_mib=0 is outside \(ToolCatalog.volumeSizeRange.lowerBound)–\(ToolCatalog.volumeSizeRange.upperBound); 1 was used.", "\(volume.text)")
        let port = await fixture.call(.containerRun, ["image": "alpine", "name": "web2", "ports": [["host_port": 8080, "container_port": 70_000]]])
        #expect(port.refused(by: .inputInvalid), "\(port.text)")
        let calls = await fixture.backend.calls.count
        #expect(calls == 2, "the refused call reached nothing")
    }

    @Test("A policy refusal of an exec timeout above the maximum still holds when asked directly")
    func policyRefusesExecTimeout() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let input = ExecInput(id: "api", command: ["ls"], timeoutSeconds: 31)
        #expect(refusal { () throws(Refusal) in try fixture.policy.approveExec(input, on: Fixture.owned("api")) }?.rule == .boundsExecTimeout)
    }

    // MARK: Errors and time

    @Test("An error repeats only the start of what the caller wrote, and a long list is cut")
    func errorsEcho() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let long = String(repeating: "n", count: 400)
        for result in [
            await fixture.call(.containerStart, ["id": .string("-" + long)]),
            await fixture.call(.volumeDelete, ["name": .string(long)]),
            await fixture.call(.imageInspect, ["reference": .string("!" + long)]),
            await fixture.call(.containerRun, ["image": "alpine", "name": .string(long)]),
            await fixture.call(.containerStart, [.init(stringLiteral: long): 1]),
        ] {
            #expect(result.isError == true)
            #expect(!result.text.contains(String(repeating: "n", count: 100)), "\(result.text.prefix(300))")
            #expect(result.text.utf16.count < 1_500)
        }
        let unknownTool = await fixture.dispatcher.call(name: long, arguments: [:])
        #expect(unknownTool.isError == true)
        #expect(!unknownTool.text.contains(String(repeating: "n", count: 100)))
        #expect(Refusal.list((1...12).map { "root-\($0)" }) == "root-1, root-2, root-3, root-4, root-5 and 7 more")
    }

    @Test("A call that passes its deadline is answered with what may have happened")
    func deadline() async throws {
        let fixture = try await Fixture(deadline: .seconds(1))
        defer { fixture.remove() }
        await fixture.backend.set(pullDelaySeconds: 5)
        let started = Date()
        let result = await fixture.call(.imagePull, ["reference": "alpine:3.20"])
        #expect(result.isError == true)
        #expect(result.text == "The call did not finish within 1 seconds and was abandoned. The change may still have been made: look with images_list before trying again.", "\(result.text)")
        #expect(Date().timeIntervalSince(started) < 4)
        let audit = try String(contentsOfFile: fixture.paths.auditFile, encoding: .utf8)
        #expect(audit.contains("\"decision\":\"failed\""))
    }

    @Test("A read tool that passes its deadline says nothing was changed")
    func readDeadlineMessage() {
        let message = ToolDispatcher.timeoutMessage(.containersList, seconds: 190)
        #expect(message.contains("only reads, so nothing was changed"))
        #expect(ToolDispatcher.timeoutMessage(.containerExec, seconds: 190).contains("look with containers_list"))
        #expect(ToolDispatcher.timeoutMessage(.volumeCreate, seconds: 190).contains("look with volumes_list"))
        #expect(ToolDispatcher.timeoutMessage(.networkDelete, seconds: 190).contains("look with networks_list"))
        #expect(ToolDispatcher.timeoutMessage(.systemStart, seconds: 190).contains("look with system_status"))
    }

    @Test("Every time the server allows sits inside the time limit")
    func timesFit() {
        #expect(ToolCatalog.callDeadline < ToolStandard.timeLimit)
        #expect(Duration.seconds(ToolCatalog.longestOperationSeconds) < ToolCatalog.callDeadline)
    }

    // MARK: Text the model reads

    @Test("The instructions and every description are within the limit")
    func texts() {
        #expect(ToolStandard.overlongTexts(instructions: ContainerMCPServer.instructions, catalog: ToolCatalog.tools).isEmpty)
        #expect(ContainerMCPServer.instructions.utf16.count <= ToolStandard.longestDescription)
    }

    @Test("The bounds the descriptions state are the ones the code enforces")
    func statedBounds() throws {
        func description(_ tool: ToolName) -> String { ToolCatalog.tools.first { $0.name == tool.rawValue }?.description ?? "" }
        func properties(_ tool: ToolName) throws -> [String: Value] {
            try #require(ToolCatalog.tools.first { $0.name == tool.rawValue }?.inputSchema.objectValue?["properties"]?.objectValue)
        }
        for (tool, limits, fallback) in [
            (ToolName.containersList, ToolCatalog.containerLimitRange, ToolCatalog.defaultContainerLimit),
            (.imagesList, ToolCatalog.imageLimitRange, ToolCatalog.defaultImageLimit),
            (.volumesList, ToolCatalog.volumeLimitRange, ToolCatalog.defaultVolumeLimit),
            (.networksList, ToolCatalog.networkLimitRange, ToolCatalog.defaultNetworkLimit),
        ] {
            let limit = try #require(try properties(tool)["limit"]?.objectValue)
            #expect(limit["minimum"] == .int(limits.lowerBound))
            #expect(limit["maximum"] == .int(limits.upperBound))
            #expect(limit["default"] == .int(fallback))
            #expect(description(tool).contains("\(fallback) "), "\(tool)")
            #expect(description(tool).contains("\(limits.upperBound))"), "\(tool)")
            let offset = try #require(try properties(tool)["offset"]?.objectValue)
            #expect(offset["minimum"] == .int(ToolCatalog.offsetRange.lowerBound))
            #expect(offset["maximum"] == .int(ToolCatalog.offsetRange.upperBound))
        }
        #expect(description(.containerLogs).contains("\(ToolCatalog.defaultLogLimit) lines"))
        #expect(description(.containerLogs).contains("\(ToolCatalog.logLineWidth) characters"))
        #expect(description(.containerLogs).contains("\(LogTail.readBytes / 1_048_576) MiB"))
        #expect(description(.containerExec).contains("\(ToolCatalog.longestOperationSeconds) seconds"))
        #expect(description(.containerExec).contains("\(ToolStandard.longestResult) characters"))
        #expect(description(.containerInspect).contains("\(ToolStandard.longestResult) characters"))
        let stop = try #require(try properties(.containerStop)["timeout_seconds"]?.objectValue)
        #expect(stop["maximum"] == .int(ToolCatalog.stopTimeoutRange.upperBound))
        let instructions = ContainerMCPServer.instructions
        #expect(instructions.contains("\(ToolStandard.timeLimit.components.seconds) seconds"))
        #expect(instructions.contains("\(ToolCatalog.longestOperationSeconds) seconds"))
    }

    /// The manifest is plain JSON and cannot take its figures from the constants, so this
    /// holds each one it states to the one the code enforces.
    @Test("The manifest states the limits the code enforces")
    func manifestFigures() throws {
        let data = try Data(contentsOf: ToolSchemaTests.root.appendingPathComponent("extension/manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(manifest["user_config"] as? [String: [String: Any]])
        func description(_ key: String) throws -> String { try #require(settings[key]?["description"] as? String) }
        let result = "at most \(ToolStandard.longestResult) apply"
        #expect(try description("log_max_lines").contains(result))
        #expect(try description("log_max_bytes").contains(result))
        #expect(try description("exec_max_output_bytes").contains(result))
        let seconds = "at most \(ToolCatalog.longestOperationSeconds) apply"
        #expect(try description("exec_timeout_seconds").contains(seconds))
        #expect(try description("pull_timeout_seconds").contains(seconds))
        #expect(try description("build_timeout_seconds").contains(seconds))
        #expect(try description("exec_timeout_seconds").contains("within \(ToolStandard.timeLimit.components.seconds) seconds"))
        let long = try #require(manifest["long_description"] as? String)
        #expect(long.contains("answered within \(ToolStandard.timeLimit.components.seconds) seconds"))
    }

    @Test("The README states the same figures")
    func readmeFigures() throws {
        let readme = try String(contentsOf: ToolSchemaTests.root.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("\(ToolStandard.longestResult)"))
        #expect(readme.contains("\(ToolCatalog.longestOperationSeconds) seconds"))
        #expect(readme.contains("\(ToolStandard.timeLimit.components.seconds) seconds"))
        #expect(readme.contains("\(ToolCatalog.defaultLogLimit)"))
    }
}
