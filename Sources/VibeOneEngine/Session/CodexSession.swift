import Foundation

/// Read/write Codex CLI rollout transcripts
/// (`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<id>.jsonl`).
/// Format details + the IR mapping are in `local_notes/PARSERS.md` §2/§3.
public enum CodexSession {

    // MARK: - Read

    /// Parse a Codex rollout `.jsonl` into the canonical IR.
    ///
    /// Convenience over `read(lines:)` for an in-memory rollout (tests, golden
    /// masters). Adapters stream from disk instead — rollouts grow unboundedly
    /// with session length, too big to assume loadable whole.
    public static func read(jsonl: String) -> CanonicalSession {
        read(
            lines: jsonl.split(separator: "\n", omittingEmptySubsequences: true)
                .lazy.map { Data($0.utf8) })
    }

    /// Parse a stream of raw JSONL records (one `Data` per line) into the
    /// canonical IR — the memory-bounded core `read(jsonl:)` wraps.
    ///
    /// `session_meta` (first line) carries `cwd`; the model name lives in
    /// `turn_context.payload.model` (verified on real data — `session_meta` only
    /// has `model_provider`). Conversation lives in `response_item` lines whose
    /// `payload.type == "message"`: user text is in `input_text` parts, assistant
    /// text in `output_text`/`text` parts. `developer`-role messages (base/system
    /// instructions) and `reasoning` / `web_search_call` / `function_call*`
    /// payloads are dropped in v0 (PARSERS §4); `event_msg` UI lines are ignored.
    public static func read(lines: some Sequence<Data>) -> CanonicalSession {
        var messages: [CanonicalMessage] = []
        var workspace = ""
        var model: String?

        for data in lines {
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = obj["type"] as? String,
                let payload = obj["payload"] as? [String: Any]
            else { continue }

            switch type {
            case "session_meta":
                if workspace.isEmpty, let cwd = payload["cwd"] as? String { workspace = cwd }
            case "turn_context":
                if model == nil, let m = payload["model"] as? String { model = m }
            case "response_item":
                guard (payload["type"] as? String) == "message",
                    let roleStr = payload["role"] as? String,
                    let role = mapRole(roleStr)
                else { continue }
                let text = extractText(payload["content"])
                guard !text.isEmpty else { continue }
                messages.append(CanonicalMessage(role: role, text: text))
            default:
                continue  // event_msg / unknown — not conversation
            }
        }

        return CanonicalSession(
            sourceAgent: "codex",
            workspace: workspace,
            model: model,
            messages: messages)
    }

    /// Codex message roles: `developer` (base/system instructions — dropped, the
    /// handoff carries only conversation), `user`, `assistant`.
    private static func mapRole(_ raw: String) -> CanonicalMessage.Role? {
        switch raw {
        case "user": return .user
        case "assistant": return .assistant
        default: return nil
        }
    }

    /// `content` is an array of `{type, text}` parts: user uses `input_text`,
    /// assistant `output_text` (occasionally `text`).
    private static func extractText(_ content: Any?) -> String {
        guard let arr = content as? [[String: Any]] else { return content as? String ?? "" }
        return
            arr
            .filter {
                switch $0["type"] as? String {
                case "input_text", "output_text", "text": return true
                default: return false
                }
            }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    // MARK: - Write

    /// Fields the writer must synthesize for a resumable rollout (PARSERS §3).
    /// Injected generators keep tests deterministic.
    ///
    /// `originator` + `cliVersion` are REQUIRED for Codex to accept the rollout:
    /// codex (v0.133) rejects a `session_meta` missing either, plus a payload-level
    /// `timestamp`, with `does not start with session metadata`. Values are free
    /// strings (verified on real `codex exec resume`), so we label the provenance
    /// honestly as `vibeone`. See PARSERS §3 / memory `codex-app-surface-facts`.
    public struct WriteOptions {
        public var sessionId: String  // MUST equal the rollout file name's <id>
        public var cwd: String
        public var modelProvider: String
        public var originator: String
        public var cliVersion: String
        public var timestamp: () -> String

        public init(
            sessionId: String,
            cwd: String,
            modelProvider: String = "openai",
            originator: String = Provenance.vibeOne,
            cliVersion: String = "0.1.0",
            timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.modelProvider = modelProvider
            self.originator = originator
            self.cliVersion = cliVersion
            self.timestamp = timestamp
        }
    }

    /// Render a canonical session as a Codex rollout `.jsonl`: a `session_meta`
    /// header, an optional `turn_context` carrying the model, then EACH turn in
    /// BOTH streams Codex keeps — a `response_item`/`message` (the model-API
    /// history; user → `input_text`, assistant → `output_text`) and an `event_msg`
    /// (`user_message`/`agent_message`), which the Codex app renders the thread and
    /// its list preview from.
    ///
    /// NOTE: Codex discovers a rollout written here by id (filesystem scan) and
    /// indexes it into its `threads` store on open — verified on Codex 26.609,
    /// which keys threads in `~/.codex/sqlite/state_5.sqlite` (`rollout_path` +
    /// `cwd`). The `session_meta` resumability fields below are required; writing
    /// only `response_item` (no `event_msg`) still ingests the thread but renders
    /// it EMPTY in the UI, which is why both streams are emitted. See PARSERS §2/§3
    /// / memory `codex-app-surface-facts`.
    public static func write(_ session: CanonicalSession, options: WriteOptions) -> String {
        var lines: [String] = []

        let meta: [String: Any] = [
            "type": "session_meta",
            "timestamp": options.timestamp(),
            // Codex requires id + cwd + payload-level timestamp + originator +
            // cli_version to accept the rollout (spike A); model_provider is kept
            // though optional.
            "payload": [
                "id": options.sessionId,
                "timestamp": options.timestamp(),
                "cwd": options.cwd,
                "originator": options.originator,
                "cli_version": options.cliVersion,
                "model_provider": options.modelProvider,
            ],
        ]
        appendLine(meta, to: &lines)

        if let model = session.model {
            let turnContext: [String: Any] = [
                "type": "turn_context",
                "timestamp": options.timestamp(),
                "payload": ["cwd": options.cwd, "model": model],
            ]
            appendLine(turnContext, to: &lines)
        }

        // Each turn is written to BOTH streams Codex keeps: the `response_item`
        // model-API history (what a resumed model re-reads as context) AND the
        // `event_msg` UI stream the Codex app renders the thread + list preview
        // from. response_item alone ingests the thread but shows it EMPTY in the UI
        // (verified on Codex 26.609).
        for msg in session.messages {
            switch msg.role {
            case .user, .tool:
                appendLine(
                    eventMessage("user_message", text: msg.text, timestamp: options.timestamp()),
                    to: &lines)
                appendLine(
                    responseMessage(
                        role: "user", partType: "input_text", text: msg.text,
                        timestamp: options.timestamp()),
                    to: &lines)
            case .assistant:
                appendLine(
                    responseMessage(
                        role: "assistant", partType: "output_text", text: msg.text,
                        timestamp: options.timestamp()),
                    to: &lines)
                appendLine(
                    eventMessage("agent_message", text: msg.text, timestamp: options.timestamp()),
                    to: &lines)
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// A `response_item` conversation line — the model-API history (PARSERS §2).
    private static func responseMessage(
        role: String, partType: String, text: String, timestamp: String
    ) -> [String: Any] {
        [
            "type": "response_item",
            "timestamp": timestamp,
            "payload": [
                "type": "message",
                "role": role,
                "content": [["type": partType, "text": text]],
            ],
        ]
    }

    /// An `event_msg` UI line (`user_message`/`agent_message`) — what the Codex app
    /// renders the thread and its list preview from (PARSERS §2).
    private static func eventMessage(
        _ type: String, text: String, timestamp: String
    ) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": ["type": type, "message": text],
        ]
    }

    private static func appendLine(_ obj: [String: Any], to lines: inout [String]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
            let str = String(data: data, encoding: .utf8)
        {
            lines.append(str)
        }
    }
}
