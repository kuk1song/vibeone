import Foundation

/// Where each agent keeps the three synced config dimensions — memory, MCP,
/// skills (PRD §4.1, ARCHITECTURE §4.2). Pure path math, no I/O, so it is
/// trivially testable and reused by the per-dimension sync types.
///
/// Two axes decide a path:
/// - **project vs. user**: memory + project-scope MCP live at the *workspace*
///   root (the unit VibeOne syncs is a project); skills + Codex's MCP live under
///   the user home.
/// - **format owner**: Claude reads `CLAUDE.md` / JSON; Codex reads `AGENTS.md` /
///   TOML. The mapping itself lives in the per-dimension types.
public enum ConfigLocation {

    // MARK: - Memory (project root)

    /// `AGENTS.md` — the authoritative project brain. Codex reads it natively;
    /// Claude reaches it through a `@AGENTS.md` import in `CLAUDE.md`.
    public static func agentsMemory(workspace: String) -> URL {
        workspaceURL(workspace).appendingPathComponent("AGENTS.md")
    }

    /// `CLAUDE.md` — Claude's project memory; VibeOne keeps it pointing at
    /// `AGENTS.md` rather than duplicating content (see `MemorySync`).
    public static func claudeMemory(workspace: String) -> URL {
        workspaceURL(workspace).appendingPathComponent("CLAUDE.md")
    }

    // MARK: - MCP

    /// Claude's project-scoped MCP file (`<workspace>/.mcp.json`) — the
    /// VCS-friendly, project-level home VibeOne reads and writes (Claude MCP doc;
    /// user-scope `~/.claude.json` servers are read-only context in v0).
    public static func claudeProjectMCP(workspace: String) -> URL {
        workspaceURL(workspace).appendingPathComponent(".mcp.json")
    }

    /// Claude's user-level config (`~/.claude.json`) — holds user/local-scope
    /// `mcpServers`. v0 reads it for status visibility only.
    public static func claudeUserConfig(home: URL) -> URL {
        home.appendingPathComponent(".claude.json")
    }

    /// Codex's project-level config (`<workspace>/.codex/config.toml`) — the
    /// Codex-side home of project MCP servers and the file sync writes.
    /// Officially supported; Codex loads it for trusted projects.
    public static func codexProjectConfig(workspace: String) -> URL {
        workspaceURL(workspace).appendingPathComponent(".codex/config.toml")
    }

    /// Codex's global config file (`~/.codex/config.toml`) — MCP servers live in
    /// `[mcp_servers.<id>]` tables alongside unrelated config. It belongs to the
    /// user and the app (Codex Desktop registers its bundled helpers there), so
    /// sync reads it for visibility but never writes it.
    public static func codexConfig(home: URL) -> URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    // MARK: - Skills (user home)

    public static func claudeSkillsDir(home: URL) -> URL {
        home.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    public static func codexSkillsDir(home: URL) -> URL {
        home.appendingPathComponent(".codex/skills", isDirectory: true)
    }

    // MARK: -

    private static func workspaceURL(_ workspace: String) -> URL {
        URL(fileURLWithPath: workspace, isDirectory: true)
    }
}
