import XCTest

@testable import VibeOneEngine

final class ClaudeSessionTests: XCTestCase {

    /// Real-shape Claude transcript: a string-content user turn, an array-content
    /// assistant turn, a non-conversational line (must be ignored), and an
    /// array-content user turn.
    private let fixture = """
        {"type":"user","uuid":"u1","parentUuid":null,"sessionId":"sess-old","cwd":"/Users/kuki/proj","gitBranch":"main","version":"2.1.140","userType":"external","isSidechain":false,"timestamp":"2026-06-01T10:00:00.000Z","message":{"role":"user","content":"Hello, who are you?"}}
        {"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"sess-old","cwd":"/Users/kuki/proj","gitBranch":"main","version":"2.1.140","timestamp":"2026-06-01T10:00:01.000Z","requestId":"req1","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"I am Claude."}],"stop_reason":"end_turn"}}
        {"type":"file-history-snapshot","uuid":"x1","timestamp":"2026-06-01T10:00:02.000Z"}
        {"type":"user","uuid":"u2","parentUuid":"a1","sessionId":"sess-old","cwd":"/Users/kuki/proj","gitBranch":"main","version":"2.1.140","userType":"external","isSidechain":false,"timestamp":"2026-06-01T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"Great, thanks!"}]}}
        """

    // MARK: Read

    func testReadExtractsConversationInOrderIgnoringNonChatLines() {
        let s = ClaudeSession.read(jsonl: fixture)
        XCTAssertEqual(s.sourceAgent, "claude")
        XCTAssertEqual(s.workspace, "/Users/kuki/proj")
        XCTAssertEqual(s.model, "claude-opus-4-8")
        XCTAssertEqual(s.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(
            s.messages.map(\.text),
            ["Hello, who are you?", "I am Claude.", "Great, thanks!"])
    }

    // MARK: Write

    func testWriteProducesResumableChain() throws {
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
        XCTAssertEqual(lines.count, 2)

        let l1 = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(l1["type"] as? String, "user")
        XCTAssertEqual(l1["sessionId"] as? String, "new-sess")
        XCTAssertEqual(l1["cwd"] as? String, "/Users/kuki/proj")
        XCTAssertTrue(l1["parentUuid"] is NSNull, "first line's parentUuid must be null")

        let l2 = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(l2["type"] as? String, "assistant")
        XCTAssertEqual(
            l2["parentUuid"] as? String, "u1", "second line must chain to the first uuid")
        XCTAssertEqual(l2["sessionId"] as? String, "new-sess")
    }

    // MARK: Round-trip (the core invariant)

    func testRoundTripPreservesMessages() {
        let original = CanonicalSession(
            sourceAgent: "claude", workspace: "/p", model: "m",
            messages: [
                .init(role: .user, text: "one"),
                .init(role: .assistant, text: "two"),
                .init(role: .user, text: "three"),
            ])
        var c = 0
        let opts = ClaudeSession.WriteOptions(
            sessionId: "sid", cwd: "/p",
            makeUUID: {
                c += 1
                return "id\(c)"
            }, timestamp: { "t" })

        let jsonl = ClaudeSession.write(original, options: opts)
        let reread = ClaudeSession.read(jsonl: jsonl)

        XCTAssertEqual(reread.messages, original.messages)
        XCTAssertEqual(reread.workspace, "/p")
        XCTAssertEqual(reread.model, "m")
    }

    // MARK: Real-data regression (skips if no local sessions)

    /// Parse a genuine Claude transcript from `~/.claude/projects` to prove the
    /// reader survives real, messy data — not just the curated fixture.
    func testReadsRealLocalSessionIfPresent() throws {
        let fm = FileManager.default
        let projectsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard
            let projectDirs = try? fm.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: nil)
        else {
            throw XCTSkip("no ~/.claude/projects on this machine")
        }

        var sessionFile: URL?
        for dir in projectDirs {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                let jsonl = files.first(where: { $0.pathExtension == "jsonl" })
            {
                sessionFile = jsonl
                break
            }
        }
        guard let sessionFile,
            let content = try? String(contentsOf: sessionFile, encoding: .utf8)
        else {
            throw XCTSkip("no .jsonl session found")
        }

        let s = ClaudeSession.read(jsonl: content)
        XCTAssertEqual(s.sourceAgent, "claude")
        XCTAssertFalse(s.workspace.isEmpty, "real session should yield a workspace cwd")
        XCTAssertFalse(s.messages.isEmpty, "real session should yield at least one message")
        XCTAssertTrue(s.messages.allSatisfy { !$0.text.isEmpty })
        print(
            "[real-data] \(sessionFile.lastPathComponent): \(s.messages.count) msgs · workspace=\(s.workspace) · model=\(s.model ?? "nil")"
        )
    }
}
