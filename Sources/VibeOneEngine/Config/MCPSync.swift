import Foundation

/// MCP dimension of config sync (PRD §4.1): make the same MCP servers available
/// to both agents. Claude keeps them as JSON in `<workspace>/.mcp.json`, Codex
/// as TOML in `~/.codex/config.toml` — the only dimension that needs format
/// translation.
///
/// Sync is **additive and bidirectional**: each side gains the servers it is
/// missing from the other; servers already present (by name) are never
/// overwritten, and unrelated config is preserved (ARCHITECTURE §5). v0 scope is
/// project-scope Claude (`.mcp.json`); user-scope `~/.claude.json` servers are
/// surfaced in status for visibility only.
public enum MCPSync {

    // MARK: - Status (read-only)

    public struct Status: Equatable, Sendable {
        public var claudeServers: [String]  // names in .mcp.json, sorted
        public var codexServers: [String]  // names in config.toml, sorted
        /// In Claude's `.mcp.json` but not Codex (would be added to Codex).
        public var missingInCodex: [String]
        /// In Codex's config.toml but not Claude (would be added to Claude).
        public var missingInClaude: [String]
        /// User/local-scope servers in `~/.claude.json` (visibility only; v0
        /// doesn't sync these).
        public var userScopeServers: [String]

        public var inSync: Bool { missingInCodex.isEmpty && missingInClaude.isEmpty }
    }

    public static func status(
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Status {
        let claude = readClaude(workspace: workspace)
        let codex = readCodex(home: home)
        let claudeNames = Set(claude.map(\.name))
        let codexNames = Set(codex.map(\.name))
        return Status(
            claudeServers: claude.map(\.name).sorted(),
            codexServers: codex.map(\.name).sorted(),
            missingInCodex: claudeNames.subtracting(codexNames).sorted(),
            missingInClaude: codexNames.subtracting(claudeNames).sorted(),
            userScopeServers: readUserScope(home: home).map(\.name).sorted())
    }

    // MARK: - Apply (write)

    public struct Outcome: Equatable, Sendable {
        public var addedToCodex: [String]
        public var addedToClaude: [String]
        public var backups: [URL]
    }

    /// Make both sides hold the union of project-scope MCP servers. Writes only
    /// the files that change, backing each up first (atomic write).
    @discardableResult
    public static func apply(
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> Outcome {
        let claude = readClaude(workspace: workspace)
        let codex = readCodex(home: home)
        let claudeNames = Set(claude.map(\.name))
        let codexNames = Set(codex.map(\.name))

        var backups: [URL] = []
        var addedToCodex: [String] = []
        var addedToClaude: [String] = []

        // Claude → Codex (TOML), append-only.
        let forCodex = claude.filter { !codexNames.contains($0.name) }
        if !forCodex.isEmpty {
            let url = ConfigLocation.codexConfig(home: home)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = CodexMCP.merged(forCodex, intoTOML: existing)
            if let backup = try AtomicFile.backup(url, timestamp: timestamp()) {
                backups.append(backup)
            }
            try AtomicFile.write(updated, to: url)
            addedToCodex = forCodex.map(\.name).sorted()
        }

        // Codex → Claude (JSON), additive merge.
        let forClaude = codex.filter { !claudeNames.contains($0.name) }
        if !forClaude.isEmpty {
            let url = ConfigLocation.claudeProjectMCP(workspace: workspace)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = ClaudeMCP.merged(forClaude, intoJSON: existing)
            if let backup = try AtomicFile.backup(url, timestamp: timestamp()) {
                backups.append(backup)
            }
            try AtomicFile.write(updated, to: url)
            addedToClaude = forClaude.map(\.name).sorted()
        }

        return Outcome(
            addedToCodex: addedToCodex, addedToClaude: addedToClaude, backups: backups)
    }

    // MARK: - Reads

    static func readClaude(workspace: String) -> [MCPServer] {
        let url = ConfigLocation.claudeProjectMCP(workspace: workspace)
        return ClaudeMCP.read(json: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    static func readCodex(home: URL) -> [MCPServer] {
        let url = ConfigLocation.codexConfig(home: home)
        return CodexMCP.read(toml: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// User/local-scope servers from `~/.claude.json` (top-level `mcpServers` +
    /// every `projects.<path>.mcpServers`). Visibility only in v0.
    static func readUserScope(home: URL) -> [MCPServer] {
        let url = ConfigLocation.claudeUserConfig(home: home)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var servers = ClaudeMCP.servers(from: root["mcpServers"] as? [String: Any] ?? [:])
        if let projects = root["projects"] as? [String: Any] {
            for case let project as [String: Any] in projects.values {
                servers += ClaudeMCP.servers(from: project["mcpServers"] as? [String: Any] ?? [:])
            }
        }
        return servers
    }
}
