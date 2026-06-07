import Foundation

/// Where each agent keeps its session files (PARSERS §1/§2). Pure path math —
/// no I/O — so it's trivially testable and reused by `SessionHandoff`.
public enum SessionLocation {

    /// Claude derives a project directory name from a workspace path by replacing
    /// every `/` with `-` (so `/Users/kuki/proj` → `-Users-kuki-proj`).
    public static func claudeProjectDirName(forWorkspace workspace: String) -> String {
        workspace.replacingOccurrences(of: "/", with: "-")
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
}
