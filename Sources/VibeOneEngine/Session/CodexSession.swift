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
            originator: String = "vibeone",
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
    /// header, an optional `turn_context` carrying the model, then one
    /// `response_item`/`message` per turn (user → `input_text`, assistant →
    /// `output_text`).
    ///
    /// NOTE: spike A (2026-06-12) verified Codex's bundled engine (v0.133)
    /// discovers a rollout written here by id (filesystem scan, no DB row needed)
    /// and loads/starts it via `codex exec resume`; the DB `threads` table is a
    /// cache it self-heals. The required `session_meta` fields below were pinned by
    /// that spike. Live-resume *content fidelity* (model reciting the handed-off
    /// history) still needs one authed turn — same gap M0 closed for the reverse.
    /// See PARSERS §3/§4 / TASK M0 / memory `codex-app-surface-facts`.
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
