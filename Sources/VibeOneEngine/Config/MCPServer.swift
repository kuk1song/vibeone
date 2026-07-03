import Foundation

/// Agent-neutral MCP server definition — the pivot for MCP sync, mirroring how
/// `CanonicalSession` pivots session handoff. Claude stores these as JSON
/// (`mcpServers`), Codex as TOML (`[mcp_servers.<id>]`); this is the shape both
/// translate through.
///
/// v0 models the common subset both formats agree on (stdio command/args/env and
/// remote url/headers). Advanced keys — Codex timeouts / tool allowlists,
/// Claude per-server `timeout` — are NOT modeled; the sync never rewrites an
/// existing server, so those keys survive untouched (see `CodexMCP` /
/// `ClaudeMCP`). This boundary is the MCP analogue of PARSERS §4.
public struct MCPServer: Equatable, Sendable {
    public var name: String
    public var transport: Transport

    public enum Transport: Equatable, Sendable {
        /// Local process launched over stdio.
        case stdio(command: String, args: [String], env: [String: String])
        /// Remote endpoint (HTTP / SSE) with optional static headers.
        case remote(url: String, kind: RemoteKind, headers: [String: String])
    }

    /// Which remote transport — preserved so a round trip emits the same JSON
    /// `type`. Codex treats both as a plain `url`, so the distinction only
    /// matters on the Claude side.
    public enum RemoteKind: String, Equatable, Sendable {
        case http, sse
    }

    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }

    /// True when this server is another agent's private plumbing rather than
    /// user configuration — Codex Desktop registers its bundled browser-control
    /// helper (`node_repl`) in its own config.toml, with the binary living
    /// inside Codex.app. Sharing that with the other agent is meaningless (the
    /// command and env are app internals) and only triggers approval prompts,
    /// so sync skips these in both directions and status doesn't count them.
    public var isAgentInternal: Bool {
        guard case .stdio(let command, _, _) = transport else { return false }
        return command.contains("/Codex.app/")
    }
}
