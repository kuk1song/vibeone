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

    /// Every rollout under `~/.codex/sessions/**`, newest first. The resume id and
    /// workspace both come from each rollout's `session_meta` (its first line);
    /// rollouts without one are skipped.
    public func list() -> [SessionSummary] {
        let fm = FileManager.default
        let root = SessionLocation.codexSessionsDir(home: home)
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        var out: [SessionSummary] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let meta = meta(of: url) else { continue }
            out.append(
                SessionSummary(
                    agent: agent, id: meta.id, workspace: meta.cwd,
                    path: url, modified: modifiedDate(url),
                    generatedByVibeOne: meta.originator == Provenance.vibeOne))
        }
        return out.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.id < $1.id }
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

    /// `(id, cwd, originator)` from a rollout's `session_meta` — its first line —
    /// read via a bounded head read (no whole-file load). Nil unless line 1 is a
    /// `session_meta` carrying both `id` and `cwd`; `originator` is optional (it
    /// identifies a VibeOne-written rollout, PARSERS §3).
    private func meta(of url: URL) -> (id: String, cwd: String, originator: String?)? {
        guard
            let firstLine = FileHead.lines(of: url).first,
            let obj = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))
                as? [String: Any],
            (obj["type"] as? String) == "session_meta",
            let payload = obj["payload"] as? [String: Any],
            let id = payload["id"] as? String, !id.isEmpty,
            let cwd = payload["cwd"] as? String, !cwd.isEmpty
        else { return nil }
        return (id, cwd, payload["originator"] as? String)
    }

    /// Recorded `cwd` of a rollout (for source-side workspace matching).
    private func workspaceOf(_ url: URL) -> String? { meta(of: url)?.cwd }

    private func modifiedDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
