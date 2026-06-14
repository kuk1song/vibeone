import Foundation

/// `SessionStore` adapter for Codex rollout transcripts
/// (`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<id>.jsonl`). Wraps the
/// `CodexSession` codec + `SessionLocation` + crash-safe `AtomicFile` writes
/// behind the port (ADR-007); format facts — including the `event_msg` UI stream
/// a written rollout needs to render — live in `PARSERS.md` §2/§3.
public struct CodexSessionStore: SessionStore {
    public let agent = "codex"
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func read(_ url: URL) throws -> CanonicalSession {
        let ir = CodexSession.read(jsonl: try String(contentsOf: url, encoding: .utf8))
        return try ir.validated(agent: agent, source: url)
    }

    public func write(
        _ session: CanonicalSession, sessionId: String, now: Date
    ) throws -> WrittenSession {
        let iso = ISO8601DateFormatter().string(from: now)
        let target = SessionLocation.codexRolloutURL(home: home, date: now, sessionId: sessionId)
        let jsonl = CodexSession.write(
            session,
            options: .init(sessionId: sessionId, cwd: session.workspace, timestamp: { iso }))
        let backup = try AtomicFile.backup(target, timestamp: iso)
        try AtomicFile.write(jsonl, to: target)
        return WrittenSession(
            sessionId: sessionId, path: target,
            resumeCommand: "codex resume \(sessionId)", backup: backup)
    }

    /// Newest rollout (by mtime) whose recorded `session_meta.cwd` matches
    /// `workspace`. Scans `~/.codex/sessions/**` newest-first, returns the first
    /// match.
    public func latestSession(workspace: String) -> URL? {
        let fm = FileManager.default
        let root = SessionLocation.codexSessionsDir(home: home)
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            candidates.append((url, modifiedDate(url)))
        }
        for (url, _) in candidates.sorted(by: { $0.modified > $1.modified })
        where workspaceOf(url) == workspace {
            return url
        }
        return nil
    }

    // MARK: - Helpers

    /// Read just the `session_meta` (first line) of a rollout for its `cwd`.
    private func workspaceOf(_ url: URL) -> String? {
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

    private func modifiedDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
