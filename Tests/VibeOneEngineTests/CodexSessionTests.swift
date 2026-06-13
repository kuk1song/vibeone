import XCTest

@testable import VibeOneEngine

final class CodexSessionTests: XCTestCase {

    /// Real-shape Codex rollout: a `session_meta` header, a `turn_context` (carries
    /// the model), a dropped `developer` instruction message, a `user` turn, an
    /// ignored `event_msg`, a dropped `reasoning` item, an `assistant` turn, and a
    /// second `user` turn.
    private let fixture = """
        {"type":"session_meta","timestamp":"2026-06-01T10:00:00.000Z","payload":{"id":"019d-old","cwd":"/Users/kuki/proj","model_provider":"openai","cli_version":"0.1.0"}}
        {"type":"turn_context","timestamp":"2026-06-01T10:00:00.500Z","payload":{"cwd":"/Users/kuki/proj","model":"gpt-5.4"}}
        {"type":"response_item","timestamp":"2026-06-01T10:00:01.000Z","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are a helpful assistant."}]}}
        {"type":"response_item","timestamp":"2026-06-01T10:00:02.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello, who are you?"}]}}
        {"type":"event_msg","timestamp":"2026-06-01T10:00:02.500Z","payload":{"type":"task_started"}}
        {"type":"response_item","timestamp":"2026-06-01T10:00:03.000Z","payload":{"type":"reasoning","content":[{"type":"text","text":"thinking..."}]}}
        {"type":"response_item","timestamp":"2026-06-01T10:00:04.000Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I am Codex."}]}}
        {"type":"response_item","timestamp":"2026-06-01T10:00:05.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Great, thanks!"}]}}
        """

    // MARK: Read

    func testReadExtractsConversationDroppingNonChatItems() {
        let s = CodexSession.read(jsonl: fixture)
        XCTAssertEqual(s.sourceAgent, "codex")
        XCTAssertEqual(s.workspace, "/Users/kuki/proj")
        XCTAssertEqual(s.model, "gpt-5.4", "model comes from turn_context, not session_meta")
        XCTAssertEqual(
            s.messages.map(\.role), [.user, .assistant, .user],
            "developer instruction, reasoning, and event_msg lines must be dropped")
        XCTAssertEqual(
            s.messages.map(\.text),
            ["Hello, who are you?", "I am Codex.", "Great, thanks!"])
    }

    // MARK: Write

    func testWriteEmitsMetaTurnContextThenMessages() throws {
        let session = CanonicalSession(
            sourceAgent: "codex", workspace: "/Users/kuki/proj", model: "gpt-5.4",
            messages: [
                .init(role: .user, text: "Hello"),
                .init(role: .assistant, text: "Hi there"),
            ])
        let opts = CodexSession.WriteOptions(
            sessionId: "new-id", cwd: "/Users/kuki/proj", timestamp: { "2026-06-05T00:00:00Z" })

        let lines = CodexSession.write(session, options: opts)
            .split(separator: "\n").map(String.init)
        // meta + turn_context, then per turn BOTH streams: user = event_msg +
        // response_item, assistant = response_item + event_msg.
        XCTAssertEqual(lines.count, 6, "session_meta + turn_context + 2 turns x 2 streams")

        let meta = try json(lines[0])
        XCTAssertEqual(meta["type"] as? String, "session_meta")
        let metaPayload = try XCTUnwrap(meta["payload"] as? [String: Any])
        XCTAssertEqual(metaPayload["id"] as? String, "new-id")
        XCTAssertEqual(metaPayload["cwd"] as? String, "/Users/kuki/proj")

        let turn = try json(lines[1])
        XCTAssertEqual(turn["type"] as? String, "turn_context")
        XCTAssertEqual((turn["payload"] as? [String: Any])?["model"] as? String, "gpt-5.4")

        // user turn: event_msg(user_message) then response_item(message/user).
        let userEvent = try json(lines[2])
        XCTAssertEqual(userEvent["type"] as? String, "event_msg")
        XCTAssertEqual((userEvent["payload"] as? [String: Any])?["type"] as? String, "user_message")
        XCTAssertEqual((userEvent["payload"] as? [String: Any])?["message"] as? String, "Hello")

        let userItem = try json(lines[3])
        let userPayload = try XCTUnwrap(userItem["payload"] as? [String: Any])
        XCTAssertEqual(userPayload["role"] as? String, "user")
        let userPart = try XCTUnwrap((userPayload["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(userPart["type"] as? String, "input_text")
        XCTAssertEqual(userPart["text"] as? String, "Hello")

        // assistant turn: response_item(message/assistant) then event_msg(agent_message).
        let asstPayload = try XCTUnwrap((try json(lines[4]))["payload"] as? [String: Any])
        XCTAssertEqual(asstPayload["role"] as? String, "assistant")
        XCTAssertEqual(
            ((asstPayload["content"] as? [[String: Any]])?.first)?["type"] as? String,
            "output_text")

        let asstEventPayload = try XCTUnwrap((try json(lines[5]))["payload"] as? [String: Any])
        XCTAssertEqual(asstEventPayload["type"] as? String, "agent_message")
        XCTAssertEqual(asstEventPayload["message"] as? String, "Hi there")
    }

    func testWriteEmitsEventMsgStreamForUI() throws {
        // Codex's UI + thread list render from the event_msg stream, not the
        // response_item model history — so both user_message and agent_message must
        // be emitted or the thread shows up empty (verified on Codex 26.609).
        let session = CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: nil,
            messages: [
                .init(role: .user, text: "hi there"),
                .init(role: .assistant, text: "hello back"),
            ])
        let lines = CodexSession.write(
            session, options: .init(sessionId: "id", cwd: "/p", timestamp: { "t" })
        ).split(separator: "\n").map(String.init)

        var userMsg: String?
        var agentMsg: String?
        for line in lines {
            let obj = try json(line)
            guard obj["type"] as? String == "event_msg",
                let p = obj["payload"] as? [String: Any]
            else { continue }
            switch p["type"] as? String {
            case "user_message": userMsg = p["message"] as? String
            case "agent_message": agentMsg = p["message"] as? String
            default: break
            }
        }
        XCTAssertEqual(userMsg, "hi there")
        XCTAssertEqual(agentMsg, "hello back")
    }

    /// Codex (v0.133) refuses to resume a rollout whose `session_meta` lacks a
    /// payload-level `timestamp`, `originator`, or `cli_version` (spike A,
    /// 2026-06-12). Guard those fields so the writer stays resumable.
    func testWriteSessionMetaCarriesResumabilityFields() throws {
        let session = CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: nil,
            messages: [.init(role: .user, text: "hi")])
        let opts = CodexSession.WriteOptions(
            sessionId: "sid", cwd: "/p", timestamp: { "2026-06-12T00:00:00Z" })

        let first = try XCTUnwrap(
            CodexSession.write(session, options: opts).split(separator: "\n").map(String.init).first
        )
        let payload = try XCTUnwrap((try json(first))["payload"] as? [String: Any])

        XCTAssertEqual(payload["timestamp"] as? String, "2026-06-12T00:00:00Z")
        XCTAssertEqual(payload["originator"] as? String, "vibeone")
        XCTAssertEqual(payload["cli_version"] as? String, "0.1.0")
    }

    func testWriteOmitsTurnContextWhenNoModel() {
        let session = CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: nil,
            messages: [.init(role: .user, text: "hi")])
        let lines = CodexSession.write(
            session, options: .init(sessionId: "id", cwd: "/p", timestamp: { "t" })
        ).split(separator: "\n").map(String.init)
        XCTAssertEqual(
            lines.count, 3,
            "session_meta + 1 turn (event_msg + response_item); no turn_context without a model")
    }

    // MARK: Round-trip (the core invariant)

    func testRoundTripPreservesMessagesAndModel() {
        let original = CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: "gpt-5.4",
            messages: [
                .init(role: .user, text: "one"),
                .init(role: .assistant, text: "two"),
                .init(role: .user, text: "three"),
            ])
        let jsonl = CodexSession.write(
            original, options: .init(sessionId: "sid", cwd: "/p", timestamp: { "t" }))
        let reread = CodexSession.read(jsonl: jsonl)

        XCTAssertEqual(reread.messages, original.messages)
        XCTAssertEqual(reread.workspace, "/p")
        XCTAssertEqual(reread.model, "gpt-5.4")
    }

    // MARK: Real-data regression (skips if no local sessions)

    /// Parse a genuine Codex rollout from `~/.codex/sessions` to prove the reader
    /// survives real, messy data — function calls, reasoning, developer prompts.
    func testReadsRealLocalRolloutIfPresent() throws {
        let fm = FileManager.default
        let sessionsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard
            let en = fm.enumerator(at: sessionsDir, includingPropertiesForKeys: nil)
        else {
            throw XCTSkip("no ~/.codex/sessions on this machine")
        }

        var rollout: URL?
        for case let url as URL in en
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            rollout = url
            break
        }
        guard let rollout,
            let content = try? String(contentsOf: rollout, encoding: .utf8)
        else {
            throw XCTSkip("no rollout-*.jsonl found")
        }

        let s = CodexSession.read(jsonl: content)
        XCTAssertEqual(s.sourceAgent, "codex")
        XCTAssertFalse(s.workspace.isEmpty, "real rollout should yield a workspace cwd")
        XCTAssertFalse(s.messages.isEmpty, "real rollout should yield at least one message")
        XCTAssertTrue(s.messages.allSatisfy { !$0.text.isEmpty })
        print(
            "[real-data] \(rollout.lastPathComponent): \(s.messages.count) msgs · "
                + "workspace=\(s.workspace) · model=\(s.model ?? "nil")")
    }

    // MARK: Helpers

    private func json(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}
