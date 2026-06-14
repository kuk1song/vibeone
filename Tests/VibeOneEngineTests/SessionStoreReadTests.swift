import Foundation
import Testing

@testable import VibeOneEngine

/// Defense-in-depth at the `SessionStore.read` boundary (ADR-010): a reachable
/// but structurally-degenerate file must fail loudly with a typed, located error
/// — never return a silently-empty IR. Each case writes a tiny rollout/transcript
/// to a unique temp file, so the suite stays parallel-safe.
@Suite("SessionStore read boundary (defense-in-depth)")
struct SessionStoreReadTests {

    // MARK: Claude

    @Test("Claude read throws missingWorkspace when no cwd is recoverable")
    func claudeMissingWorkspace() throws {
        // Only non-conversation lines → no cwd, no messages.
        let jsonl = """
            {"type":"file-history-snapshot","uuid":"x1","timestamp":"t"}
            {"type":"summary","summary":"prior context"}
            """
        try withTempSession(jsonl) { url in
            #expect(throws: SessionReadError.missingWorkspace(agent: "claude", url: url)) {
                try ClaudeSessionStore().read(url)
            }
        }
    }

    @Test("Claude read throws noMessages when a cwd parses but no conversation")
    func claudeNoMessages() throws {
        // A user line carrying cwd, but tool-only content → workspace set, 0 messages.
        let jsonl = """
            {"type":"user","cwd":"/Users/dev/proj","message":{"role":"user","content":[{"type":"tool_result","text":"x"}]}}
            """
        try withTempSession(jsonl) { url in
            #expect(throws: SessionReadError.noMessages(agent: "claude", url: url)) {
                try ClaudeSessionStore().read(url)
            }
        }
    }

    @Test("Claude read returns the IR for a valid transcript")
    func claudeValid() throws {
        let jsonl = """
            {"type":"user","cwd":"/Users/dev/proj","message":{"role":"user","content":"hi"}}
            """
        try withTempSession(jsonl) { url in
            let ir = try ClaudeSessionStore().read(url)
            #expect(ir.workspace == "/Users/dev/proj")
            #expect(ir.messages.map(\.text) == ["hi"])
        }
    }

    // MARK: Codex

    @Test("Codex read throws missingWorkspace when session_meta has no cwd")
    func codexMissingWorkspace() throws {
        let jsonl = """
            {"type":"session_meta","payload":{"id":"x","model_provider":"openai"}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            """
        try withTempSession(jsonl) { url in
            #expect(throws: SessionReadError.missingWorkspace(agent: "codex", url: url)) {
                try CodexSessionStore().read(url)
            }
        }
    }

    @Test("Codex read throws noMessages when meta parses but no response_item")
    func codexNoMessages() throws {
        let jsonl = """
            {"type":"session_meta","payload":{"id":"x","cwd":"/Users/dev/proj"}}
            {"type":"turn_context","payload":{"cwd":"/Users/dev/proj","model":"gpt-5.4"}}
            """
        try withTempSession(jsonl) { url in
            #expect(throws: SessionReadError.noMessages(agent: "codex", url: url)) {
                try CodexSessionStore().read(url)
            }
        }
    }

    @Test("Codex read returns the IR for a valid rollout")
    func codexValid() throws {
        let jsonl = """
            {"type":"session_meta","payload":{"id":"x","cwd":"/Users/dev/proj"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}
            """
        try withTempSession(jsonl) { url in
            let ir = try CodexSessionStore().read(url)
            #expect(ir.workspace == "/Users/dev/proj")
            #expect(ir.messages.map(\.text) == ["hi"])
        }
    }
}
