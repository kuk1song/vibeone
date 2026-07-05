import Foundation

/// Read/write Claude Code session transcripts (`~/.claude/projects/<encoded-cwd>/
/// <uuid>.jsonl`). Format details + the IR mapping are in `local_notes/PARSERS.md`.
public enum ClaudeSession {

    // MARK: - Read

    /// Parse a Claude `.jsonl` transcript into the canonical IR.
    ///
    /// Convenience over `read(lines:)` for an in-memory transcript (tests,
    /// golden masters). Adapters stream from disk instead — a long-running
    /// transcript can reach hundreds of MB, too big to load whole.
    public static func read(jsonl: String) -> CanonicalSession {
        read(
            lines: jsonl.split(separator: "\n", omittingEmptySubsequences: true)
                .lazy.map { Data($0.utf8) })
    }

    /// Parse a stream of raw JSONL records (one `Data` per line) into the
    /// canonical IR — the memory-bounded core `read(jsonl:)` wraps.
    ///
    /// Only `user`/`assistant` lines carry conversation (PARSERS §1); every other
    /// line type (`system`, `file-history-snapshot`, …) is ignored. Lines are
    /// taken in file order. `message.content` may be a plain string OR an array of
    /// typed parts — text parts are concatenated; non-text parts (tool_use/result)
    /// are dropped in v0.
    public static func read(lines: some Sequence<Data>) -> CanonicalSession {
        var messages: [CanonicalMessage] = []
        var workspace = ""
        var model: String?

        for data in lines {
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = obj["type"] as? String,
                type == "user" || type == "assistant"
            else { continue }

            if workspace.isEmpty, let cwd = obj["cwd"] as? String { workspace = cwd }

            guard let message = obj["message"] as? [String: Any],
                let roleStr = message["role"] as? String,
                let role = CanonicalMessage.Role(rawValue: roleStr)
            else { continue }

            if role == .assistant, model == nil, let m = message["model"] as? String { model = m }

            let text = extractText(message["content"])
            guard !text.isEmpty else { continue }  // skip tool-only/empty turns (v0)
            messages.append(CanonicalMessage(role: role, text: text))
        }

        return CanonicalSession(
            sourceAgent: "claude",
            workspace: workspace,
            model: model,
            messages: messages)
    }

    /// `content` is either a String or an array of `{type, text, …}` parts.
    private static func extractText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return
                arr
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Write

    /// Fields the writer must synthesize (PARSERS §3). Generators are injected so
    /// tests are deterministic; production uses real `UUID()`/`Date()`.
    public struct WriteOptions {
        public var sessionId: String  // MUST equal the target file name's uuid
        public var cwd: String  // project root the resume runs from
        public var version: String
        public var makeUUID: () -> String
        public var timestamp: () -> String

        public init(
            sessionId: String,
            cwd: String,
            version: String = "2.1.0",
            makeUUID: @escaping () -> String = { UUID().uuidString },
            timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.version = version
            self.makeUUID = makeUUID
            self.timestamp = timestamp
        }
    }

    /// Render a canonical session as a Claude `.jsonl` transcript that
    /// `claude --resume <sessionId>` can load. The caller writes the result to
    /// `<sessionId>.jsonl` under the cwd's encoded project dir.
    ///
    /// Each message becomes one line, linked into a list via `uuid`/`parentUuid`
    /// (first `parentUuid` is null), all sharing one `sessionId`.
    public static func write(_ session: CanonicalSession, options: WriteOptions) -> String {
        var lines: [String] = []
        var parent: String?

        for msg in session.messages {
            let uuid = options.makeUUID()

            var line: [String: Any] = [
                "type": msg.role.rawValue,
                "uuid": uuid,
                "parentUuid": parent ?? NSNull(),
                "sessionId": options.sessionId,
                "cwd": options.cwd,
                "version": options.version,
                "timestamp": options.timestamp(),
                // Provenance: mark this as VibeOne-written so the picker can keep it
                // pickable yet never auto-pick it as a handoff source (PR-F). Claude
                // ignores unknown top-level keys (PARSERS §1).
                Provenance.claudeKey: Provenance.vibeOne,
            ]

            var message: [String: Any] = ["role": msg.role.rawValue]
            switch msg.role {
            case .user, .tool:
                line["userType"] = "external"
                line["isSidechain"] = false
                message["content"] = msg.text
            case .assistant:
                if let model = session.model { message["model"] = model }
                message["content"] = [["type": "text", "text": msg.text]]
            }
            line["message"] = message

            if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                let str = String(data: data, encoding: .utf8)
            {
                lines.append(str)
            }
            parent = uuid
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
