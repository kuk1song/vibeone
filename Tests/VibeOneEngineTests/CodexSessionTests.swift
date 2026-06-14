import Foundation
import Testing

@testable import VibeOneEngine

/// Representative canonical sessions for the round-trip invariant — including a
/// model-less one (Codex omits `turn_context` then, so the model must round-trip
/// back to nil).
private let codexRoundTripCases: [NamedSession] = [
    NamedSession(
        name: "multi-turn with model",
        session: CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: "gpt-5.4",
            messages: [
                .init(role: .user, text: "one"),
                .init(role: .assistant, text: "two"),
                .init(role: .user, text: "three"),
            ])),
    NamedSession(
        name: "single user turn, no model",
        session: CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: nil,
            messages: [.init(role: .user, text: "just one")])),
]

@Suite("Codex session codec")
struct CodexSessionTests {

    /// Real-shape Codex rollout: a `session_meta` header, a `turn_context` (carries
    /// the model), a dropped `developer` instruction message, a `user` turn, an
    /// ignored `event_msg`, a dropped `reasoning` item, an `assistant` turn, and a
    /// second `user` turn.
    let fixture = """
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

    @Test("read extracts conversation, dropping non-chat items")
    func readExtractsConversationDroppingNonChatItems() {
        let s = CodexSession.read(jsonl: fixture)
        #expect(s.sourceAgent == "codex")
        #expect(s.workspace == "/Users/kuki/proj")
        #expect(s.model == "gpt-5.4", "model comes from turn_context, not session_meta")
        #expect(
            s.messages.map(\.role) == [.user, .assistant, .user],
            "developer instruction, reasoning, and event_msg lines must be dropped")
        #expect(
            s.messages.map(\.text) == ["Hello, who are you?", "I am Codex.", "Great, thanks!"])
    }

    // MARK: Write

    @Test("write emits session_meta + turn_context then both streams per turn")
    func writeEmitsMetaTurnContextThenMessages() throws {
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
        #expect(lines.count == 6, "session_meta + turn_context + 2 turns x 2 streams")

        let meta = try json(lines[0])
        #expect(meta["type"] as? String == "session_meta")
        let metaPayload = try #require(meta["payload"] as? [String: Any])
        #expect(metaPayload["id"] as? String == "new-id")
        #expect(metaPayload["cwd"] as? String == "/Users/kuki/proj")

        let turn = try json(lines[1])
        #expect(turn["type"] as? String == "turn_context")
        #expect((turn["payload"] as? [String: Any])?["model"] as? String == "gpt-5.4")

        // user turn: event_msg(user_message) then response_item(message/user).
        let userEvent = try json(lines[2])
        #expect(userEvent["type"] as? String == "event_msg")
        #expect((userEvent["payload"] as? [String: Any])?["type"] as? String == "user_message")
        #expect((userEvent["payload"] as? [String: Any])?["message"] as? String == "Hello")

        let userItem = try json(lines[3])
        let userPayload = try #require(userItem["payload"] as? [String: Any])
        #expect(userPayload["role"] as? String == "user")
        let userPart = try #require((userPayload["content"] as? [[String: Any]])?.first)
        #expect(userPart["type"] as? String == "input_text")
        #expect(userPart["text"] as? String == "Hello")

        // assistant turn: response_item(message/assistant) then event_msg(agent_message).
        let asstPayload = try #require((try json(lines[4]))["payload"] as? [String: Any])
        #expect(asstPayload["role"] as? String == "assistant")
        #expect(
            ((asstPayload["content"] as? [[String: Any]])?.first)?["type"] as? String
                == "output_text")

        let asstEventPayload = try #require((try json(lines[5]))["payload"] as? [String: Any])
        #expect(asstEventPayload["type"] as? String == "agent_message")
        #expect(asstEventPayload["message"] as? String == "Hi there")
    }

    @Test("write emits the event_msg UI stream (or the thread renders empty)")
    func writeEmitsEventMsgStreamForUI() throws {
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
        #expect(userMsg == "hi there")
        #expect(agentMsg == "hello back")
    }

    /// Codex (v0.133) refuses to resume a rollout whose `session_meta` lacks a
    /// payload-level `timestamp`, `originator`, or `cli_version` (spike A,
    /// 2026-06-12). Guard those fields so the writer stays resumable.
    @Test("write's session_meta carries the resumability fields")
    func writeSessionMetaCarriesResumabilityFields() throws {
        let session = CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: nil,
            messages: [.init(role: .user, text: "hi")])
        let opts = CodexSession.WriteOptions(
            sessionId: "sid", cwd: "/p", timestamp: { "2026-06-12T00:00:00Z" })

        let first = try #require(
            CodexSession.write(session, options: opts).split(separator: "\n").map(String.init).first
        )
        let payload = try #require((try json(first))["payload"] as? [String: Any])

        #expect(payload["timestamp"] as? String == "2026-06-12T00:00:00Z")
        #expect(payload["originator"] as? String == "vibeone")
        #expect(payload["cli_version"] as? String == "0.1.0")
    }

    @Test("write omits turn_context when there is no model")
    func writeOmitsTurnContextWhenNoModel() {
        let session = CanonicalSession(
            sourceAgent: "codex", workspace: "/p", model: nil,
            messages: [.init(role: .user, text: "hi")])
        let lines = CodexSession.write(
            session, options: .init(sessionId: "id", cwd: "/p", timestamp: { "t" })
        ).split(separator: "\n").map(String.init)
        #expect(
            lines.count == 3,
            "session_meta + 1 turn (event_msg + response_item); no turn_context without a model")
    }

    // MARK: Round-trip (the core invariant)

    @Test(
        "round-trip preserves messages, workspace, and model", arguments: codexRoundTripCases)
    func roundTripPreservesMessagesAndModel(_ sample: NamedSession) {
        let original = sample.session
        let jsonl = CodexSession.write(
            original, options: .init(sessionId: "sid", cwd: original.workspace, timestamp: { "t" }))
        let reread = CodexSession.read(jsonl: jsonl)

        #expect(reread.messages == original.messages)
        #expect(reread.workspace == original.workspace)
        #expect(reread.model == original.model)
    }

    // MARK: Real-data regression — each local rollout is its own case

    /// Parse genuine Codex rollouts from `~/.codex/sessions` to prove the reader
    /// survives real, messy data — function calls, reasoning, developer prompts.
    /// Skipped when this machine has no rollouts (e.g. CI).
    @Test(
        "reads a real local Codex rollout",
        .enabled(if: !RealData.codexRolloutFiles.isEmpty),
        arguments: RealData.codexRolloutFiles)
    func readsRealLocalRollout(_ file: URL) throws {
        let content = try String(contentsOf: file, encoding: .utf8)
        let s = CodexSession.read(jsonl: content)
        #expect(s.sourceAgent == "codex")
        #expect(!s.workspace.isEmpty, "real rollout should yield a workspace cwd")
        #expect(!s.messages.isEmpty, "real rollout should yield at least one message")
        #expect(s.messages.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: Helpers

    private func json(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}
