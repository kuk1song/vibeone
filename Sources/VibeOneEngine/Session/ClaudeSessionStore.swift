import Foundation

/// `SessionStore` adapter for Claude Code transcripts
/// (`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`). Wraps the `ClaudeSession`
/// format codec + `SessionLocation` path math + crash-safe `AtomicFile` writes
/// behind the port (ADR-007); format/encoding facts live in `PARSERS.md` §1.
public struct ClaudeSessionStore: SessionStore {
    public let agent = "claude"
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func read(_ url: URL) throws -> CanonicalSession {
        ClaudeSession.read(jsonl: try String(contentsOf: url, encoding: .utf8))
    }

    public func write(
        _ session: CanonicalSession, sessionId: String, now: Date
    ) throws -> WrittenSession {
        let iso = ISO8601DateFormatter().string(from: now)
        let target = SessionLocation.claudeSessionURL(
            home: home, workspace: session.workspace, sessionId: sessionId)
        let jsonl = ClaudeSession.write(
            session,
            options: .init(sessionId: sessionId, cwd: session.workspace, timestamp: { iso }))
        let backup = try AtomicFile.backup(target, timestamp: iso)
        try AtomicFile.write(jsonl, to: target)
        return WrittenSession(
            sessionId: sessionId, path: target,
            resumeCommand: "claude --resume \(sessionId)", backup: backup)
    }

    /// Newest `.jsonl` (by mtime) under this workspace's encoded project dir. The
    /// dir already scopes to one workspace, so this is a plain newest-in-dir scan.
    public func latestSession(workspace: String) -> URL? {
        let dir = SessionLocation.claudeProjectsDir(home: home)
            .appendingPathComponent(
                SessionLocation.claudeProjectDirName(forWorkspace: workspace),
                isDirectory: true)
        return newestJSONL(in: dir)
    }

    /// The Claude session the user is most likely in *right now*: the globally
    /// most-recently-modified transcript across **all** projects (the active file
    /// is appended every turn). The workspace is read from the transcript's own
    /// `cwd`, never decoded from the dir name — Claude's encoding is lossy (`/`,
    /// `.`, `_`, and every other non-alphanumeric char all map to `-`, PARSERS §1).
    /// Returns nil if no transcript with a readable `cwd` exists.
    ///
    /// NOTE: superseded as the *switch trigger* by B1's explicit picker (ADR-008);
    /// kept as the enumeration base PR-B will build `list()` on.
    public func currentSession() -> SessionHandoff.CurrentSession? {
        let fm = FileManager.default
        let root = SessionLocation.claudeProjectsDir(home: home)
        guard
            let projectDirs = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return nil }

        var candidates: [(url: URL, modified: Date)] = []
        for dir in projectDirs {
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                candidates.append((url, modifiedDate(url)))
            }
        }
        for (url, _) in candidates.sorted(by: { $0.modified > $1.modified }) {
            if let workspace = workspaceOf(url), !workspace.isEmpty {
                return SessionHandoff.CurrentSession(path: url, workspace: workspace)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func newestJSONL(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        return
            entries
            .filter { $0.pathExtension == "jsonl" }
            .map { (url: $0, modified: modifiedDate($0)) }
            .sorted { $0.modified > $1.modified }
            .first?.url
    }

    /// First recorded `cwd` in a transcript (its project root). Claude stamps every
    /// user/assistant line with `cwd`, so the first one suffices.
    private func workspaceOf(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }

    private func modifiedDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
