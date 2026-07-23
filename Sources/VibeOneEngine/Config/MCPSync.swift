import Foundation

/// MCP dimension of config sync (PRD §4.1): make the same MCP servers available
/// to both agents **for one project**. Claude keeps project servers as JSON in
/// `<workspace>/.mcp.json`, Codex as TOML in `<workspace>/.codex/config.toml`
/// (officially supported; loaded for trusted projects) — the only dimension
/// that needs format translation.
///
/// Sync is **additive, bidirectional and project-to-project**: each side gains
/// the project servers it is missing from the other; servers already present
/// (by name) are never overwritten, and unrelated config is preserved
/// (ARCHITECTURE §5). The global configs (`~/.codex/config.toml`,
/// `~/.claude.json`) are **never written** — they belong to the user and the
/// apps — but they are read, both for status visibility and so a server an
/// agent can already see globally is not flagged or re-synced as missing.
/// Servers that are an agent's own internal plumbing
/// (`MCPServer.isAgentInternal`) are excluded from both directions and from
/// status.
public enum MCPSync {

    // MARK: - Status (read-only)

    public struct Status: Equatable, Sendable {
        public var claudeServers: [String]  // names in <workspace>/.mcp.json, sorted
        public var codexServers: [String]  // names in <workspace>/.codex/config.toml, sorted
        /// In Claude's project config but present in neither the project nor
        /// the global Codex config (a disabled table still counts as present)
        /// — would be added to the project's Codex config.
        public var missingInCodex: [String]
        /// In Codex's project config but visible to Claude nowhere (project,
        /// user scope, or this workspace's local scope) — would be added to
        /// `.mcp.json`.
        public var missingInClaude: [String]
        /// User/local-scope servers in `~/.claude.json`, all projects included
        /// (visibility only; never a sync target).
        public var userScopeServers: [String]
        /// Servers in the global `~/.codex/config.toml` (visibility only; never
        /// a sync target).
        public var codexGlobalServers: [String]

        public var inSync: Bool { missingInCodex.isEmpty && missingInClaude.isEmpty }

        public init(
            claudeServers: [String], codexServers: [String], missingInCodex: [String],
            missingInClaude: [String], userScopeServers: [String], codexGlobalServers: [String]
        ) {
            self.claudeServers = claudeServers
            self.codexServers = codexServers
            self.missingInCodex = missingInCodex
            self.missingInClaude = missingInClaude
            self.userScopeServers = userScopeServers
            self.codexGlobalServers = codexGlobalServers
        }
    }

    public static func status(
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Status {
        let claude = readClaude(workspace: workspace)
        let codex = readCodex(workspace: workspace)
        let claudeNames = Set(claude.map(\.name))
        let codexNames = Set(codex.map(\.name))
        let codexVisible = codexVisibleNames(workspace: workspace, home: home)
        let claudeVisible = claudeNames.union(
            readUserScopeVisible(workspace: workspace, home: home).map(\.name))
        return Status(
            claudeServers: claude.map(\.name).sorted(),
            codexServers: codex.map(\.name).sorted(),
            missingInCodex: claudeNames.subtracting(codexVisible).sorted(),
            missingInClaude: codexNames.subtracting(claudeVisible).sorted(),
            userScopeServers: readUserScope(home: home).map(\.name).sorted(),
            codexGlobalServers: readCodexGlobal(home: home).map(\.name).sorted())
    }

    // MARK: - Apply (write)

    public struct Outcome: Equatable, Sendable {
        public var addedToCodex: [String]
        public var addedToClaude: [String]
        public var backups: [URL]
    }

    /// Raised when a write would destroy content sync cannot represent.
    /// ConfigSync catches it per-dimension: the MCP line reports the failure,
    /// the other dimensions still run, and the file stays untouched.
    public enum Failure: Error, Equatable, LocalizedError {
        /// `.mcp.json` is not a JSON object, or its `mcpServers` value is not an
        /// object. Merging would silently discard unrepresentable content.
        case malformedClaudeConfig(path: String)
        /// A project config exists but is not UTF-8. Treating a failed decode as
        /// an empty file would overwrite its bytes.
        case nonUTF8Config(path: String)

        public var errorDescription: String? {
            switch self {
            case .malformedClaudeConfig(let path):
                return
                    "\(path) is not a valid Claude MCP JSON object — fix or remove it, then sync again"
            case .nonUTF8Config(let path):
                return "\(path) is not valid UTF-8 — convert it to UTF-8, then sync again"
            }
        }
    }

    /// Make both sides hold the union of the project's MCP servers. Writes only
    /// the two project-level files, and only when they change, backing each up
    /// first (atomic write). Servers an agent already sees globally are skipped,
    /// mirroring `status`.
    @discardableResult
    public static func apply(
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> Outcome {
        let claude = readClaude(workspace: workspace)
        let codex = readCodex(workspace: workspace)
        let codexVisible = codexVisibleNames(workspace: workspace, home: home)
        let claudeVisible = Set(claude.map(\.name))
            .union(readUserScopeVisible(workspace: workspace, home: home).map(\.name))

        var backups: [URL] = []
        var addedToCodex: [String] = []
        var addedToClaude: [String] = []

        // Claude → Codex (TOML), append-only, into the project's config.
        let forCodex = claude.filter { !codexVisible.contains($0.name) }
        if !forCodex.isEmpty {
            let url = ConfigLocation.codexProjectConfig(workspace: workspace)
            let existing = try readUTF8ForWrite(at: url)
            let updated = CodexMCP.merged(forCodex, intoTOML: existing)
            if updated != existing {
                if let backup = try AtomicFile.backup(url, timestamp: timestamp()) {
                    backups.append(backup)
                }
                try AtomicFile.write(updated, to: url)
                addedToCodex = forCodex.map(\.name).sorted()
            }
        }

        // Codex → Claude (JSON), additive merge. Fail closed when the document
        // or mcpServers shape cannot be preserved. Raw keys count as occupied
        // even when their values are not translatable: never overwrite them or
        // claim they were added.
        let forClaude = codex.filter { !claudeVisible.contains($0.name) }
        if !forClaude.isEmpty {
            let url = ConfigLocation.claudeProjectMCP(workspace: workspace)
            let existing = try readUTF8ForWrite(at: url)
            guard let occupiedNames = ClaudeMCP.existingServerNames(in: existing) else {
                throw Failure.malformedClaudeConfig(path: url.path)
            }
            let additions = forClaude.filter { !occupiedNames.contains($0.name) }
            if !additions.isEmpty {
                let updated = ClaudeMCP.merged(additions, intoJSON: existing)
                if let backup = try AtomicFile.backup(url, timestamp: timestamp()) {
                    backups.append(backup)
                }
                try AtomicFile.write(updated, to: url)
                addedToClaude = additions.map(\.name).sorted()
            }
        }

        return Outcome(
            addedToCodex: addedToCodex, addedToClaude: addedToClaude, backups: backups)
    }

    // MARK: - Reads

    /// Read a file that is about to be rewritten. Missing is a valid fresh
    /// target; existing non-UTF-8 bytes are not. Read-only status remains
    /// tolerant, while the destructive path fails closed.
    private static func readUTF8ForWrite(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.nonUTF8Config(path: url.path)
        }
        return text
    }

    static func readClaude(workspace: String) -> [MCPServer] {
        let url = ConfigLocation.claudeProjectMCP(workspace: workspace)
        return ClaudeMCP.read(json: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .filter { !$0.isAgentInternal }
    }

    /// The project's own Codex servers — the Codex side of the sync.
    static func readCodex(workspace: String) -> [MCPServer] {
        let url = ConfigLocation.codexProjectConfig(workspace: workspace)
        return CodexMCP.read(toml: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .filter { !$0.isAgentInternal }
    }

    /// Servers in the global `~/.codex/config.toml` — read-only visibility.
    static func readCodexGlobal(home: URL) -> [MCPServer] {
        let url = ConfigLocation.codexConfig(home: home)
        return CodexMCP.read(toml: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .filter { !$0.isAgentInternal }
    }

    /// Every name with a `[mcp_servers.<id>]` table in the project or global
    /// Codex config — including disabled (`enabled = false`) and internal ones,
    /// which `readCodex`/`readCodexGlobal` deliberately drop. Sync must treat
    /// *presence* as visibility: the append-only writer can never touch an
    /// existing table, so flagging a present name as missing (or reporting it
    /// added) would desync status, outcome and file — and re-adding a disabled
    /// server would resurrect something the user turned off.
    static func codexVisibleNames(workspace: String, home: URL) -> Set<String> {
        let project = ConfigLocation.codexProjectConfig(workspace: workspace)
        let global = ConfigLocation.codexConfig(home: home)
        return CodexMCP.existingServerNames(
            in: (try? String(contentsOf: project, encoding: .utf8)) ?? ""
        )
        .union(
            CodexMCP.existingServerNames(
                in: (try? String(contentsOf: global, encoding: .utf8)) ?? ""))
    }

    /// User/local-scope servers from `~/.claude.json` (top-level `mcpServers` +
    /// every `projects.<path>.mcpServers`). Visibility only.
    static func readUserScope(home: URL) -> [MCPServer] {
        readUserScope(home: home, project: { _ in true })
    }

    /// The `~/.claude.json` servers Claude can actually see *in this workspace*:
    /// top-level user scope (visible everywhere) plus this workspace's own local
    /// scope. Another project's local scope doesn't count here.
    static func readUserScopeVisible(workspace: String, home: URL) -> [MCPServer] {
        readUserScope(home: home, project: { $0 == workspace })
    }

    private static func readUserScope(
        home: URL, project includeProject: (String) -> Bool
    ) -> [MCPServer] {
        let url = ConfigLocation.claudeUserConfig(home: home)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var servers = ClaudeMCP.servers(from: root["mcpServers"] as? [String: Any] ?? [:])
        if let projects = root["projects"] as? [String: Any] {
            for (path, value) in projects {
                guard includeProject(path), let project = value as? [String: Any] else { continue }
                servers += ClaudeMCP.servers(from: project["mcpServers"] as? [String: Any] ?? [:])
            }
        }
        return servers
    }
}
