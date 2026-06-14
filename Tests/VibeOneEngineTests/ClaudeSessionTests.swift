import Foundation
import Testing

@testable import VibeOneEngine

/// Representative canonical sessions for the round-trip invariant — each runs as
/// its own parameterized case so a failure points at one shape.
private let claudeRoundTripCases: [NamedSession] = [
    NamedSession(
        name: "multi-turn with model",
        session: CanonicalSession(
            sourceAgent: "claude", workspace: "/p", model: "claude-opus-4-8",
            messages: [
                .init(role: .user, text: "one"),
                .init(role: .assistant, text: "two"),
                .init(role: .user, text: "three"),
            ])),
    NamedSession(
        name: "single user turn, no model",
        session: CanonicalSession(
            sourceAgent: "claude", workspace: "/Users/kuki/proj", model: nil,
            messages: [.init(role: .user, text: "just one")])),
]

@Suite("Claude session codec")
struct ClaudeSessionTests {

    /// Real-shape Claude transcript: a string-content user turn, an array-content
    /// assistant turn, a non-conversational line (must be ignored), and an
    /// array-content user turn.
    let fixture = """
        {"type":"user","uuid":"u1","parentUuid":null,"sessionId":"sess-old","cwd":"/Users/kuki/proj","gitBranch":"main","version":"2.1.140","userType":"external","isSidechain":false,"timestamp":"2026-06-01T10:00:00.000Z","message":{"role":"user","content":"Hello, who are you?"}}
        {"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"sess-old","cwd":"/Users/kuki/proj","gitBranch":"main","version":"2.1.140","timestamp":"2026-06-01T10:00:01.000Z","requestId":"req1","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"I am Claude."}],"stop_reason":"end_turn"}}
        {"type":"file-history-snapshot","uuid":"x1","timestamp":"2026-06-01T10:00:02.000Z"}
        {"type":"user","uuid":"u2","parentUuid":"a1","sessionId":"sess-old","cwd":"/Users/kuki/proj","gitBranch":"main","version":"2.1.140","userType":"external","isSidechain":false,"timestamp":"2026-06-01T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"Great, thanks!"}]}}
        """

    // MARK: Read

    @Test("read extracts conversation in order, ignoring non-chat lines")
    func readExtractsConversationInOrderIgnoringNonChatLines() {
        let s = ClaudeSession.read(jsonl: fixture)
        #expect(s.sourceAgent == "claude")
        #expect(s.workspace == "/Users/kuki/proj")
        #expect(s.model == "claude-opus-4-8")
        #expect(s.messages.map(\.role) == [.user, .assistant, .user])
        #expect(
            s.messages.map(\.text) == ["Hello, who are you?", "I am Claude.", "Great, thanks!"])
    }

    // MARK: Write

    @Test("write produces a parent-chained, resumable transcript")
    func writeProducesResumableChain() throws {
        let session = CanonicalSession(
            sourceAgent: "claude", workspace: "/Users/kuki/proj", model: "claude-opus-4-8",
            messages: [
                .init(role: .user, text: "Hello"),
                .init(role: .assistant, text: "Hi there"),
            ])
        var n = 0
        let opts = ClaudeSession.WriteOptions(
            sessionId: "new-sess", cwd: "/Users/kuki/proj",
            makeUUID: {
                n += 1
                return "u\(n)"
            },
            timestamp: { "2026-06-05T00:00:00Z" })

        let lines = ClaudeSession.write(session, options: opts)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)

        let l1 = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(l1["type"] as? String == "user")
        #expect(l1["sessionId"] as? String == "new-sess")
        #expect(l1["cwd"] as? String == "/Users/kuki/proj")
        #expect(l1["parentUuid"] is NSNull, "first line's parentUuid must be null")

        let l2 = try #require(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(l2["type"] as? String == "assistant")
        #expect(l2["parentUuid"] as? String == "u1", "second line must chain to the first uuid")
        #expect(l2["sessionId"] as? String == "new-sess")
    }

    // MARK: Round-trip (the core invariant)

    @Test("round-trip preserves messages, workspace, and model", arguments: claudeRoundTripCases)
    func roundTripPreservesMessages(_ sample: NamedSession) {
        let original = sample.session
        var c = 0
        let opts = ClaudeSession.WriteOptions(
            sessionId: "sid", cwd: original.workspace,
            makeUUID: {
                c += 1
                return "id\(c)"
            }, timestamp: { "t" })

        let jsonl = ClaudeSession.write(original, options: opts)
        let reread = ClaudeSession.read(jsonl: jsonl)

        #expect(reread.messages == original.messages)
        #expect(reread.workspace == original.workspace)
        #expect(reread.model == original.model)
    }

    // MARK: Real-data regression — each local transcript is its own case

    /// Parse genuine Claude transcripts from `~/.claude/projects` to prove the
    /// reader survives real, messy data — not just the curated fixture. Skipped
    /// when this machine has no sessions (e.g. CI).
    @Test(
        "reads a real local Claude session",
        .enabled(if: !RealData.claudeSessionFiles.isEmpty),
        arguments: RealData.claudeSessionFiles)
    func readsRealLocalSession(_ file: URL) throws {
        let content = try String(contentsOf: file, encoding: .utf8)
        let s = ClaudeSession.read(jsonl: content)
        #expect(s.sourceAgent == "claude")
        #expect(!s.workspace.isEmpty, "real session should yield a workspace cwd")
        #expect(!s.messages.isEmpty, "real session should yield at least one message")
        #expect(s.messages.allSatisfy { !$0.text.isEmpty })
    }
}
