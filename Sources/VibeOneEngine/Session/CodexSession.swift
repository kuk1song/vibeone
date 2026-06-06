import Foundation

/// Read/write Codex CLI rollout transcripts
/// (`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<id>.jsonl`).
/// Format details + the IR mapping are in `local_notes/PARSERS.md` §2/§3.
public enum CodexSession {

    // MARK: - Read

    /// Parse a Codex rollout `.jsonl` into the canonical IR.
    ///
    /// `session_meta` (first line) carries `cwd`; the model name lives in
    /// `turn_context.payload.model` (verified on real data — `session_meta` only
    /// has `model_provider`). Conversation lives in `response_item` lines whose
    /// `payload.type == "message"`: user text is in `input_text` parts, assistant
    /// text in `output_text`/`text` parts. `developer`-role messages (base/system
    /// instructions) and `reasoning` / `web_search_call` / `function_call*`
    /// payloads are dropped in v0 (PARSERS §4); `event_msg` UI lines are ignored.
    public static func read(jsonl: String) -> CanonicalSession {
        var messages: [CanonicalMessage] = []
        var workspace = ""
        var model: String?

        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
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
    public struct WriteOptions {
        public var sessionId: String  // MUST equal the rollout file name's <id>
        public var cwd: String
        public var modelProvider: String
        public var timestamp: () -> String

        public init(
            sessionId: String,
            cwd: String,
            modelProvider: String = "openai",
            timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.modelProvider = modelProvider
            self.timestamp = timestamp
        }
    }

    /// Render a canonical session as a Codex rollout `.jsonl`: a `session_meta`
    /// header, an optional `turn_context` carrying the model, then one
    /// `response_item`/`message` per turn (user → `input_text`, assistant →
    /// `output_text`).
    ///
    /// NOTE: the Claude→Codex direction is not yet verified end-to-end against a
    /// real `codex resume` (no local `codex` binary at M0 — see PARSERS §4 / TASK
    /// M0). This emits the shape observed in real rollouts and is covered by
    /// structural + round-trip tests; live-resume verification is deferred.
    public static func write(_ session: CanonicalSession, options: WriteOptions) -> String {
        var lines: [String] = []

        let meta: [String: Any] = [
            "type": "session_meta",
            "timestamp": options.timestamp(),
            "payload": [
                "id": options.sessionId,
                "cwd": options.cwd,
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

        for msg in session.messages {
            let (role, partType): (String, String)
            switch msg.role {
            case .assistant: (role, partType) = ("assistant", "output_text")
            case .user, .tool: (role, partType) = ("user", "input_text")
            }
            let item: [String: Any] = [
                "type": "response_item",
                "timestamp": options.timestamp(),
                "payload": [
                    "type": "message",
                    "role": role,
                    "content": [["type": partType, "text": msg.text]],
                ],
            ]
            appendLine(item, to: &lines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendLine(_ obj: [String: Any], to lines: inout [String]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
            let str = String(data: data, encoding: .utf8)
        {
            lines.append(str)
        }
    }
}
