import Foundation

/// Where each agent keeps its session files (PARSERS §1/§2). Pure path math —
/// no I/O — so it's trivially testable and reused by `SessionHandoff`.
public enum SessionLocation {

    /// Claude derives a project directory name from a workspace path by replacing
    /// **every non-alphanumeric character** with `-` (official Agent SDK docs), so
    /// `/Users/kuki/proj` → `-Users-kuki-proj` and `/Users/kuki/Material_Song` →
    /// `-Users-kuki-Material-Song`. The mapping is lossy/non-invertible — used only
    /// to place a *written* session under a known cwd; never decode a dir name back
    /// (read the cwd from the transcript instead, PARSERS §1).
    public static func claudeProjectDirName(forWorkspace workspace: String) -> String {
        String(workspace.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public static func claudeProjectsDir(home: URL) -> URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`. The file-name UUID
    /// MUST equal the `sessionId` written inside, or `claude --resume` won't match.
    public static func claudeSessionURL(
        home: URL, workspace: String, sessionId: String
    ) -> URL {
        let dirName = claudeProjectDirName(forWorkspace: workspace)
        return claudeProjectsDir(home: home)
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    public static func codexSessionsDir(home: URL) -> URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<YYYY-MM-DDTHH-MM-SS>-<id>.jsonl`.
    ///
    /// Codex discovers a rollout by its `<id>` (filesystem scan — spike A), so the
    /// date bucket isn't load-bearing; we still mirror the native layout so a
    /// hand-written rollout is indistinguishable from a Codex-authored one. The
    /// date dir + filename stamp use the **local** time zone (verified on real
    /// data: a `17-50-03` filename for a `15:50:03Z` session); the in-file
    /// timestamps stay UTC. The `<id>` MUST equal the `session_meta.payload.id`.
    public static func codexRolloutURL(home: URL, date: Date, sessionId: String) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let pad2 = { (n: Int) in String(format: "%02d", n) }
        let year = String(format: "%04d", c.year ?? 0)
        let month = pad2(c.month ?? 0)
        let day = pad2(c.day ?? 0)
        let stamp =
            "\(year)-\(month)-\(day)T\(pad2(c.hour ?? 0))-\(pad2(c.minute ?? 0))-\(pad2(c.second ?? 0))"
        return codexSessionsDir(home: home)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("rollout-\(stamp)-\(sessionId).jsonl")
    }
}
