import Foundation
import Testing
@testable import WindowCore

@Suite struct OpeningTests {
    @Test func aQuietDayIsBareAndUseTakesHoldInSteps() {
        #expect(Opening.state(tokens: 0) == 0)
        #expect(Opening.state(tokens: 1) == 1)
        #expect(Opening.state(tokens: 40_000) == 2)
        #expect(Opening.state(tokens: 250_000) == 3)
        #expect(Opening.state(tokens: 50_000_000) == 3)
        #expect(Opening.growth(for: 0) == 0)
        #expect(abs(Opening.growth(for: 1) - 1.0 / 3) < 1e-9)
        #expect(abs(Opening.growth(for: 2) - 2.0 / 3) < 1e-9)
        #expect(Opening.growth(for: 3) == 1)
        var last = 0
        for tokens in [0.0, 1, 1_000, 40_000, 250_000, 1_000_000] {
            let state = Opening.state(tokens: tokens)
            #expect(state >= last)
            last = state
        }
    }

    @Test func growthHoldsUntilTheDayHasClearlyChanged() {
        #expect(Opening.state(tokens: 100_000, holding: 3) == 3)
        #expect(Opening.state(tokens: 50_000, holding: 3) == 2)
        #expect(Opening.state(tokens: 0, holding: 2) == 0)
        #expect(Opening.state(tokens: 20_000, holding: 2) == 2)
        #expect(Opening.state(tokens: 120_000, holding: 0) == 2)
    }

    @Test func useFadesAcrossADay() {
        #expect(Opening.decayed(100, age: 0) == 100)
        #expect(abs(Opening.decayed(100, age: 12 * 3600) - 50) < 1e-6)
        #expect(Opening.decayed(100, age: 24 * 3600) == 0)
        #expect(Opening.decayed(100, age: -10) == 100)
        #expect(Opening.decayed(100, age: -7200) == 0)
    }
}

@Suite struct AgentLogTests {
    private static let noon = "2026-10-02T12:00:00Z"
    private static let midnight = "2026-10-02T00:00:00Z"

    @Test func datesAreUnixTime() {
        let epoch = AgentLogLine.date(in: #"{"ts":"1970-01-01T00:00:00Z"}"#)
        #expect(epoch == Date(timeIntervalSince1970: 0))
        let later = AgentLogLine.date(in: #"{"timestamp":"1970-01-01T00:00:01.500Z"}"#)
        #expect(later == Date(timeIntervalSince1970: 1.5))
    }

    @Test func eachToolContributesItsOwnTokensOnce() {
        let grok = #"{"ts":"\#(Self.noon)","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000,"cached_prompt_tokens":800,"completion_tokens":25,"reasoning_tokens":9}}"#
        #expect(AgentLogLine.event(in: grok, source: .grok)?.tokens == 1025)

        let codex = #"{"timestamp":"\#(Self.noon)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":99999},"last_token_usage":{"total_tokens":1200}}}}"#
        #expect(AgentLogLine.event(in: codex, source: .codex)?.tokens == 1200)

        let claude = #"{"message":{"id":"abc","usage":{"input_tokens":100,"cache_creation_input_tokens":5,"cache_read_input_tokens":20,"output_tokens":7}},"timestamp":"\#(Self.noon)"}"#
        let event = AgentLogLine.event(in: claude, source: .claude)
        #expect(event?.tokens == 132)
        #expect(event?.messageID == "abc")
    }

    @Test func theLedgerDecaysAndDoesNotReread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        let grok = root.appendingPathComponent("grok.jsonl")
        let grokLine = #"{"ts":"\#(Self.noon)","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000,"completion_tokens":25}}"# + "\n"
        let oldLine = #"{"ts":"2026-10-01T10:00:00Z","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":5000,"completion_tokens":5}}"# + "\n"
        try (oldLine + grokLine).write(to: grok, atomically: true, encoding: .utf8)

        let codexLine = #"{"timestamp":"\#(Self.midnight)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":99999},"last_token_usage":{"total_tokens":2000}}}}"# + "\n"
        try codexLine.write(to: codex.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)

        let claudeLine = #"{"message":{"id":"abc","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}},"timestamp":"\#(Self.noon)"}"# + "\n"
        try (claudeLine + claudeLine).write(to: claude.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let now = AgentLogLine.date(in: #"{"ts":"\#(Self.noon)"}"#)!
        let locations = AgentLocations(grokLog: grok, codexDirectories: [codex], claudeProjects: claude)
        var ledger = AgentLedger()
        let first = AgentScan.read(locations: locations, now: now, ledger: &ledger)
        // Noon counts in full: 1025 from Grok and 100 from Claude, once. Midnight is half of 2000. The day-old line is gone.
        #expect(abs(first - (1025 + 100 + 1000)) < 1)

        let extra = #"{"ts":"\#(Self.noon)","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":40,"completion_tokens":10}}"# + "\n"
        let handle = try FileHandle(forWritingTo: grok)
        handle.seekToEndOfFile()
        handle.write(Data(extra.utf8))
        try handle.close()
        let second = AgentScan.read(locations: locations, now: now, ledger: &ledger)
        #expect(abs(second - (first + 50)) < 1)
    }
}
