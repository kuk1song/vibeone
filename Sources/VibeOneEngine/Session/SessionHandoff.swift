import Foundation

/// The "switch": take a project's in-flight conversation in one agent and write
/// it as a native, resumable session in the other (ARCHITECTURE §4.1).
///
/// v0 implements the M0-verified direction **Codex → Claude** end to end. The
/// reverse (Claude → Codex) reuses `CodexSession.write` but stays gated on a
/// local `codex` binary for live-resume verification (PARSERS §4 / TASK M0).
///
/// Invariant: the handoff only ever *creates* a new target session; it never
/// mutates the source file.
public enum SessionHandoff {

    /// What the caller (UI / CLI) needs to act on the switch.
    public struct Result: Equatable, Sendable {
        public var targetAgent: String
        public var sessionId: String
        public var path: URL
        /// Run from `workspace` to continue the conversation in the target agent.
        public var resumeCommand: String
        public var messageCount: Int
        /// Set only if an existing target was backed up first (normally nil — the
        /// target id is freshly generated, so nothing is overwritten).
        public var backup: URL?
    }

    public enum Failure: Error, Equatable {
        case noSessionFound
        case emptySession
    }

    /// Locate the most recent Codex rollout for `workspace`, convert it, and write
    /// a resumable Claude transcript under `~/.claude/projects/<encoded-cwd>/`.
    ///
    /// Generators are injected for deterministic tests; production uses real
    /// `UUID()` / `Date()`.
    public static func codexToClaude(
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        makeSessionId: () -> String = { UUID().uuidString },
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> Result {
        guard let source = latestCodexSession(home: home, workspace: workspace) else {
            throw Failure.noSessionFound
        }
        let ir = CodexSession.read(jsonl: try String(contentsOf: source, encoding: .utf8))
        guard !ir.messages.isEmpty else { throw Failure.emptySession }

        let sessionId = makeSessionId()
        let target = SessionLocation.claudeSessionURL(
            home: home, workspace: workspace, sessionId: sessionId)
        let jsonl = ClaudeSession.write(
            ir,
            options: .init(sessionId: sessionId, cwd: workspace, timestamp: timestamp))

        let backup = try AtomicFile.backup(target, timestamp: timestamp())
        try AtomicFile.write(jsonl, to: target)

        return Result(
            targetAgent: "claude",
            sessionId: sessionId,
            path: target,
            resumeCommand: "claude --resume \(sessionId)",
            messageCount: ir.messages.count,
            backup: backup)
    }

    /// Newest Codex rollout whose `session_meta.cwd` matches `workspace`, or nil.
    /// Scans `~/.codex/sessions/**`, sorts by modification time (newest first),
    /// and returns the first whose recorded cwd matches.
    public static func latestCodexSession(home: URL, workspace: String) -> URL? {
        let fm = FileManager.default
        let root = SessionLocation.codexSessionsDir(home: home)
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((url, modified))
        }

        for (url, _) in candidates.sorted(by: { $0.modified > $1.modified })
        where workspaceOfRollout(url) == workspace {
            return url
        }
        return nil
    }

    /// Read just the `session_meta` (first line) of a rollout for its `cwd`.
    private static func workspaceOfRollout(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
            let firstLine = content.split(
                separator: "\n", maxSplits: 1, omittingEmptySubsequences: true
            ).first,
            let obj = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))
                as? [String: Any],
            (obj["type"] as? String) == "session_meta",
            let payload = obj["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }
}
