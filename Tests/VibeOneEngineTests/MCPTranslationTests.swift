import XCTest

@testable import VibeOneEngine

final class MCPTranslationTests: XCTestCase {

    // MARK: - Claude JSON read

    func testClaudeReadsStdioAndRemoteServers() {
        let json = """
            {
              "mcpServers": {
                "fs": { "command": "npx", "args": ["-y", "@mcp/fs"], "env": { "ROOT": "/tmp" } },
                "stripe": { "type": "http", "url": "https://mcp.stripe.com" },
                "asana": { "type": "sse", "url": "https://mcp.asana.com/sse" }
              }
            }
            """
        let servers = ClaudeMCP.read(json: json)
        XCTAssertEqual(servers.map(\.name), ["asana", "fs", "stripe"])  // sorted

        guard case .stdio(let command, let args, let env) = servers[1].transport else {
            return XCTFail("fs should be stdio")
        }
        XCTAssertEqual(command, "npx")
        XCTAssertEqual(args, ["-y", "@mcp/fs"])
        XCTAssertEqual(env, ["ROOT": "/tmp"])

        guard case .remote(let url, let kind, _) = servers[2].transport else {
            return XCTFail("stripe should be remote")
        }
        XCTAssertEqual(url, "https://mcp.stripe.com")
        XCTAssertEqual(kind, .http)

        if case .remote(_, let kind, _) = servers[0].transport {
            XCTAssertEqual(kind, .sse)
        } else {
            XCTFail("asana should be remote sse")
        }
    }

    func testClaudeReadToleratesMissingAndMalformed() {
        XCTAssertTrue(ClaudeMCP.read(json: "").isEmpty)
        XCTAssertTrue(ClaudeMCP.read(json: "{not json").isEmpty)
        XCTAssertTrue(ClaudeMCP.read(json: "{\"mcpServers\":{}}").isEmpty)
    }

    // MARK: - Codex TOML read

    func testCodexReadsStdioWithInlineEnvAndArgs() {
        let toml = """
            model = "gpt-5.4"

            [mcp_servers.fs]
            command = "npx"
            args = ["-y", "@mcp/fs"]
            env = { ROOT = "/tmp", MODE = "ro" }
            """
        let servers = CodexMCP.read(toml: toml)
        XCTAssertEqual(servers.map(\.name), ["fs"])
        guard case .stdio(let command, let args, let env) = servers[0].transport else {
            return XCTFail("expected stdio")
        }
        XCTAssertEqual(command, "npx")
        XCTAssertEqual(args, ["-y", "@mcp/fs"])
        XCTAssertEqual(env, ["ROOT": "/tmp", "MODE": "ro"])
    }

    func testCodexReadsEnvSubTableAndRemoteUrl() {
        let toml = """
            [mcp_servers.db]
            command = "db-server"

            [mcp_servers.db.env]
            DB_URL = "postgres://x"

            [mcp_servers.remote]
            url = "https://mcp.example.com/mcp"
            """
        let servers = CodexMCP.read(toml: toml)
        XCTAssertEqual(servers.map(\.name), ["db", "remote"])
        guard case .stdio(_, _, let env) = servers[0].transport else { return XCTFail("db stdio") }
        XCTAssertEqual(env, ["DB_URL": "postgres://x"])
        guard case .remote(let url, _, _) = servers[1].transport else {
            return XCTFail("remote")
        }
        XCTAssertEqual(url, "https://mcp.example.com/mcp")
    }

    func testCodexReadIgnoresUnrelatedTablesAndComments() {
        let toml = """
            # top comment
            model = "gpt-5.4"  # inline comment

            [projects."/Users/kuki/proj"]
            trust_level = "trusted"

            [mcp_servers.fs]
            command = "npx"  # the launcher
            """
        let servers = CodexMCP.read(toml: toml)
        XCTAssertEqual(servers.map(\.name), ["fs"])
    }

    /// Codex Desktop disables servers in place with `enabled = false` (observed
    /// with its bundled computer-use helper). A disabled server is not part of
    /// the effective config, so it must not sync or count as drift — the earlier
    /// behavior dropped the flag and re-enabled the server on the Claude side.
    func testCodexReadSkipsDisabledServers() {
        let toml = """
            [mcp_servers.computer-use]
            command = "./Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient"
            args = ["mcp"]
            cwd = "."
            enabled = false

            [mcp_servers.active]
            command = "run"
            enabled = true
            """
        XCTAssertEqual(CodexMCP.read(toml: toml).map(\.name), ["active"])
    }

    func testCodexReadHandlesQuotedServerName() {
        let toml = """
            [mcp_servers."my server"]
            command = "run"
            """
        XCTAssertEqual(CodexMCP.read(toml: toml).map(\.name), ["my server"])
    }

    // MARK: - Remote headers ↔ the official Codex fields

    /// Codex's remote-server auth lives in three dedicated fields —
    /// `http_headers` (literal values), `env_http_headers` (header → env var
    /// name), `bearer_token_env_var` (Authorization: Bearer from an env var).
    /// They map onto Claude's single literal `headers` map via its `${VAR}`
    /// expansion syntax.
    func testCodexReadsRemoteHeadersFromOfficialFields() {
        let toml = """
            [mcp_servers.linear]
            url = "https://mcp.linear.app/mcp"
            http_headers = { X-Client = "vibeone" }

            [mcp_servers.linear.env_http_headers]
            X-Api-Key = "LINEAR_API_KEY"

            [mcp_servers.issues]
            url = "https://issues.example.com/mcp"
            bearer_token_env_var = "ISSUES_TOKEN"
            """
        let servers = CodexMCP.read(toml: toml)
        XCTAssertEqual(servers.map(\.name), ["issues", "linear"])
        guard case .remote(_, _, let issuesHeaders) = servers[0].transport,
            case .remote(_, _, let linearHeaders) = servers[1].transport
        else { return XCTFail("both should be remote") }
        XCTAssertEqual(issuesHeaders, ["Authorization": "Bearer ${ISSUES_TOKEN}"])
        XCTAssertEqual(
            linearHeaders, ["X-Client": "vibeone", "X-Api-Key": "${LINEAR_API_KEY}"])
    }

    /// `env` is a stdio-only field in Codex config; on a url server it is not
    /// header configuration and must not be read as such.
    func testCodexReadDoesNotTreatEnvAsRemoteHeaders() {
        let toml = """
            [mcp_servers.remote]
            url = "https://mcp.example.com/mcp"
            env = { STRAY = "value" }
            """
        guard case .remote(_, _, let headers) = CodexMCP.read(toml: toml)[0].transport else {
            return XCTFail("expected remote")
        }
        XCTAssertEqual(headers, [:])
    }

    func testCodexRendersRemoteHeadersToOfficialFields() {
        let server = MCPServer(
            name: "api",
            transport: .remote(
                url: "https://api.example.com/mcp", kind: .http,
                headers: [
                    "Authorization": "Bearer ${API_KEY}",
                    "X-Static": "literal-value",
                    "X-Env": "${MY_VAR}",
                ]))
        let block = CodexMCP.render(server)
        XCTAssertTrue(block.contains("bearer_token_env_var = \"API_KEY\""))
        XCTAssertTrue(block.contains("http_headers = { X-Static = \"literal-value\" }"))
        XCTAssertTrue(block.contains("env_http_headers = { X-Env = \"MY_VAR\" }"))
        XCTAssertFalse(block.contains("env = {"), "env is stdio-only, never a header field")

        // The three-way split must be lossless: re-reading recovers the exact map.
        guard case .remote(let url, _, let headers) = CodexMCP.read(toml: block)[0].transport
        else { return XCTFail("expected remote") }
        XCTAssertEqual(url, "https://api.example.com/mcp")
        XCTAssertEqual(
            headers,
            [
                "Authorization": "Bearer ${API_KEY}",
                "X-Static": "literal-value",
                "X-Env": "${MY_VAR}",
            ])
    }

    /// A value that only *embeds* `${VAR}` mid-string has no faithful Codex
    /// field (env_http_headers replaces the whole value) — it stays literal in
    /// http_headers rather than being mangled.
    func testCodexKeepsPartiallyEmbeddedEnvVarLiteral() {
        let server = MCPServer(
            name: "api",
            transport: .remote(
                url: "https://x", kind: .http, headers: ["X-Mixed": "v=${VAR};tail"]))
        let block = CodexMCP.render(server)
        XCTAssertTrue(block.contains("http_headers = { X-Mixed = \"v=${VAR};tail\" }"))
        XCTAssertFalse(block.contains("env_http_headers"))
    }

    // MARK: - Codex write (append-only, preservation)

    func testCodexMergedAppendsAndPreservesExistingVerbatim() {
        let existing = """
            model = "gpt-5.4"

            [mcp_servers.kept]
            command = "old"
            startup_timeout_sec = 30
            """
        let incoming = [
            MCPServer(name: "added", transport: .stdio(command: "npx", args: ["-y"], env: [:]))
        ]
        let out = CodexMCP.merged(incoming, intoTOML: existing)

        // Original content (incl. an advanced key we don't model) survives byte-for-byte.
        XCTAssertTrue(out.contains("model = \"gpt-5.4\""))
        XCTAssertTrue(out.contains("startup_timeout_sec = 30"))
        XCTAssertTrue(out.contains("[mcp_servers.kept]"))
        // New server appended.
        XCTAssertTrue(out.contains("[mcp_servers.added]"))
        XCTAssertEqual(CodexMCP.read(toml: out).map(\.name), ["added", "kept"])
    }

    func testCodexMergedNeverOverwritesExistingServer() {
        let existing = """
            [mcp_servers.fs]
            command = "original"
            """
        let incoming = [
            MCPServer(name: "fs", transport: .stdio(command: "DIFFERENT", args: [], env: [:]))
        ]
        let out = CodexMCP.merged(incoming, intoTOML: existing)
        XCTAssertTrue(out.contains("command = \"original\""))
        XCTAssertFalse(out.contains("DIFFERENT"), "existing server must not be overwritten")
    }

    // MARK: - Claude write (additive, preservation)

    func testClaudeMergedPreservesUnrelatedKeysAndExistingServers() {
        let existing = """
            { "mcpServers": { "fs": { "command": "original" } }, "otherKey": 42 }
            """
        let incoming = [
            MCPServer(name: "fs", transport: .stdio(command: "IGNORED", args: [], env: [:])),
            MCPServer(
                name: "stripe", transport: .remote(url: "https://x", kind: .http, headers: [:])),
        ]
        let out = ClaudeMCP.merged(incoming, intoJSON: existing)
        let reparsed = ClaudeMCP.read(json: out)
        XCTAssertEqual(reparsed.map(\.name), ["fs", "stripe"])
        // Existing fs untouched.
        guard case .stdio(let command, _, _) = reparsed[0].transport else { return XCTFail() }
        XCTAssertEqual(command, "original")
        // Unrelated top-level key preserved.
        XCTAssertTrue(out.contains("\"otherKey\""))
    }

    func testClaudeMergedFromEmptyStartsFresh() {
        let out = ClaudeMCP.merged(
            [MCPServer(name: "fs", transport: .stdio(command: "npx", args: [], env: [:]))],
            intoJSON: "")
        XCTAssertEqual(ClaudeMCP.read(json: out).map(\.name), ["fs"])
    }

    // MARK: - Cross-format round trips (the actual handoff)

    func testRoundTripClaudeToCodexToClaude() {
        let original = [
            MCPServer(
                name: "fs",
                transport: .stdio(command: "npx", args: ["-y", "@mcp/fs"], env: ["ROOT": "/tmp"])),
            MCPServer(
                name: "stripe",
                transport: .remote(
                    url: "https://x", kind: .http,
                    headers: ["Authorization": "Bearer ${STRIPE_KEY}", "X-Client": "vibeone"])),
        ]
        // Claude → TOML → back.
        let toml = CodexMCP.merged(original, intoTOML: "")
        let viaCodex = CodexMCP.read(toml: toml)
        XCTAssertEqual(viaCodex.map(\.name), ["fs", "stripe"])
        if case .stdio(let c, let a, let e) = viaCodex[0].transport {
            XCTAssertEqual(c, "npx")
            XCTAssertEqual(a, ["-y", "@mcp/fs"])
            XCTAssertEqual(e, ["ROOT": "/tmp"])
        } else {
            XCTFail("fs should survive as stdio")
        }
        if case .remote(_, _, let h) = viaCodex[1].transport {
            XCTAssertEqual(h, ["Authorization": "Bearer ${STRIPE_KEY}", "X-Client": "vibeone"])
        } else {
            XCTFail("stripe should survive as remote")
        }
        // Codex → JSON → back.
        let json = ClaudeMCP.merged(viaCodex, intoJSON: "")
        let viaClaude = ClaudeMCP.read(json: json)
        XCTAssertEqual(viaClaude.map(\.name), ["fs", "stripe"])
        if case .remote(_, _, let h) = viaClaude[1].transport {
            XCTAssertEqual(h, ["Authorization": "Bearer ${STRIPE_KEY}", "X-Client": "vibeone"])
        } else {
            XCTFail("stripe should survive as remote in JSON")
        }
    }

    func testRenderEscapesSpecialCharacters() {
        let server = MCPServer(
            name: "weird",
            transport: .stdio(
                command: "a\\b", args: ["say \"hi\""], env: ["K": "v\"x"]))
        let block = CodexMCP.render(server)
        // Re-reading must recover the exact values (escaping is reversible).
        let back = CodexMCP.read(toml: block)
        guard case .stdio(let command, let args, let env) = back[0].transport else {
            return XCTFail()
        }
        XCTAssertEqual(command, "a\\b")
        XCTAssertEqual(args, ["say \"hi\""])
        XCTAssertEqual(env, ["K": "v\"x"])
    }
}
