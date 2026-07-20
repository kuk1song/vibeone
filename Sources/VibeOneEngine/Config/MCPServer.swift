import Foundation

/// Agent-neutral MCP server definition — the pivot for MCP sync, mirroring how
/// `CanonicalSession` pivots session handoff. Claude stores these as JSON
/// (`mcpServers`), Codex as TOML (`[mcp_servers.<id>]`); this is the shape both
/// translate through.
///
/// v0 models the common subset both formats agree on (stdio command/args/env and
/// remote url/headers). Remote `headers` carry Claude's literal semantics —
/// values may use its `${VAR}` env expansion — and `CodexMCP` translates them
/// to/from Codex's official remote fields (`http_headers` / `env_http_headers` /
/// `bearer_token_env_var`). Advanced keys — Codex timeouts / tool allowlists,
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
    /// user configuration — Codex Desktop registers its bundled helpers in its
    /// own config.toml with binaries living inside an app bundle: `node_repl`
    /// under Codex.app (pre-26.715) / ChatGPT.app (the renamed bundle), and the
    /// computer-use client inside "Codex Computer Use.app" (registered with a
    /// *relative* command plus `cwd`, hence no leading slash in that marker).
    /// Sharing these with the other agent is meaningless (the command and env
    /// are app internals) and only triggers approval prompts, so sync skips
    /// them in both directions and status doesn't count them.
    public var isAgentInternal: Bool {
        guard case .stdio(let command, _, _) = transport else { return false }
        let markers = ["/Codex.app/", "/ChatGPT.app/", "Codex Computer Use.app/"]
        return markers.contains { command.contains($0) }
    }
}
