import Foundation
import Testing

@testable import VibeOneEngine

// Golden-master regression over scrubbed REAL sessions (ADR-010). The fixtures
// keep the full real structure of a Claude transcript / Codex rollout (every
// line type, the dual-stream) with all content scrubbed (see
// `scripts/scrub-session.swift`). Each fixture is parsed to the IR and checked
// two ways:
//   1. snapshot — the IR rendering must equal a committed baseline, so a parser
//      drift (renamed field, changed nesting) shows up as a diff;
//   2. round-trip — write(read(fixture)) re-read must preserve the conversation.
// Run `VIBEONE_RECORD=1 swift test --filter GoldenMasterTests` to (re)record
// the baselines after an intended change.

private let claudeFixtures = [Fixture(agent: "claude", name: "mixed-content")]
private let codexFixtures = [Fixture(agent: "codex", name: "dual-stream")]

@Suite("Golden master — real (scrubbed) sessions")
struct GoldenMasterTests {

    @Test("Claude fixture matches snapshot and round-trips", arguments: claudeFixtures)
    func claude(_ fx: Fixture) throws {
        let ir = ClaudeSession.read(jsonl: try fx.load())
        try GoldenMaster.verify(ir, fixture: fx)

        var c = 0
        let rendered = ClaudeSession.write(
            ir,
            options: .init(
                sessionId: "sid", cwd: ir.workspace,
                makeUUID: {
                    c += 1
                    return "id\(c)"
                }, timestamp: { "t" }))
        let reread = ClaudeSession.read(jsonl: rendered)
        #expect(reread.messages == ir.messages)
        #expect(reread.workspace == ir.workspace)
        #expect(reread.model == ir.model)
    }

    @Test("Codex fixture matches snapshot and round-trips", arguments: codexFixtures)
    func codex(_ fx: Fixture) throws {
        let ir = CodexSession.read(jsonl: try fx.load())
        try GoldenMaster.verify(ir, fixture: fx)

        let rendered = CodexSession.write(
            ir, options: .init(sessionId: "sid", cwd: ir.workspace, timestamp: { "t" }))
        let reread = CodexSession.read(jsonl: rendered)
        #expect(reread.messages == ir.messages)
        #expect(reread.workspace == ir.workspace)
        #expect(reread.model == ir.model)
    }
}

// MARK: - Support

/// A bundled golden-master input (`Tests/.../Fixtures/<agent>/<name>.jsonl`).
struct Fixture: CustomTestStringConvertible, Sendable {
    let agent: String
    let name: String
    var testDescription: String { "\(agent)/\(name)" }

    func load() throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/\(agent)")
        else {
            throw GoldenMasterError.missingFixture("\(agent)/\(name).jsonl")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

enum GoldenMasterError: Error { case missingFixture(String) }

enum GoldenMaster {

    /// Compare the parsed IR to its committed snapshot. With `VIBEONE_RECORD` set,
    /// (re)write the snapshot to the source tree (via `#filePath`) instead of
    /// asserting — read and record hit the SAME path, so there is no bundle staleness.
    static func verify(
        _ ir: CanonicalSession, fixture: Fixture, sourceFile: StaticString = #filePath
    ) throws {
        let produced = try render(ir)
        let snapshotURL = URL(fileURLWithPath: "\(sourceFile)")
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots/\(fixture.agent)/\(fixture.name).json")

        if ProcessInfo.processInfo.environment["VIBEONE_RECORD"] != nil {
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try produced.write(to: snapshotURL, atomically: true, encoding: .utf8)
            return
        }

        guard let expected = try? String(contentsOf: snapshotURL, encoding: .utf8) else {
            Issue.record(
                "missing snapshot \(fixture.agent)/\(fixture.name).json — run `VIBEONE_RECORD=1 swift test --filter GoldenMasterTests` to create it"
            )
            return
        }
        #expect(
            produced == expected,
            "snapshot mismatch for \(fixture.agent)/\(fixture.name) — if intended, re-record with VIBEONE_RECORD=1"
        )
    }

    private static func render(_ ir: CanonicalSession) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(IRSnapshot(ir))
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Stable, diff-friendly projection of the IR — exactly the fields the handoff
    /// depends on, so a snapshot diff pinpoints what the parser stopped recovering.
    private struct IRSnapshot: Codable {
        struct Message: Codable {
            let role: String
            let text: String
        }
        let sourceAgent: String
        let workspace: String
        let model: String?
        let messageCount: Int
        let messages: [Message]

        init(_ s: CanonicalSession) {
            sourceAgent = s.sourceAgent
            workspace = s.workspace
            model = s.model
            messageCount = s.messages.count
            messages = s.messages.map { Message(role: $0.role.rawValue, text: $0.text) }
        }
    }
}
