import XCTest

@testable import VibeOneEngine

final class MCPSyncTests: XCTestCase {

    private var home: URL!
    private var ws: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        let unique = ProcessInfo.processInfo.globallyUniqueString
        home = fm.temporaryDirectory.appendingPathComponent("vibeone-mcp-home-\(unique)")
        ws = fm.temporaryDirectory.appendingPathComponent("vibeone-mcp-ws-\(unique)")
        try fm.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: ws)
    }

    private func writeClaudeMCP(_ s: String) throws {
        try s.write(to: ws.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    }
    private func writeCodexConfig(_ s: String) throws {
        try s.write(
            to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8
        )
    }
    private func readCodexConfig() throws -> String {
        try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
    }

    func testStatusReportsBidirectionalMissing() throws {
        try writeClaudeMCP("{\"mcpServers\":{\"claudeOnly\":{\"command\":\"a\"}}}")
        try writeCodexConfig("[mcp_servers.codexOnly]\ncommand = \"b\"\n")

        let s = MCPSync.status(workspace: ws.path, home: home)
        XCTAssertEqual(s.claudeServers, ["claudeOnly"])
        XCTAssertEqual(s.codexServers, ["codexOnly"])
        XCTAssertEqual(s.missingInCodex, ["claudeOnly"])
        XCTAssertEqual(s.missingInClaude, ["codexOnly"])
        XCTAssertFalse(s.inSync)
    }

    func testApplyUnionsBothSidesPreservingUnrelatedConfig() throws {
        try writeClaudeMCP("{\"mcpServers\":{\"claudeOnly\":{\"command\":\"a\"}}}")
        try writeCodexConfig(
            """
            model = "gpt-5.4"

            [mcp_servers.codexOnly]
            command = "b"
            """)

        let outcome = try MCPSync.apply(workspace: ws.path, home: home, timestamp: { "TS" })
        XCTAssertEqual(outcome.addedToCodex, ["claudeOnly"])
        XCTAssertEqual(outcome.addedToClaude, ["codexOnly"])
        XCTAssertEqual(outcome.backups.count, 2, "both pre-existing files backed up")

        // Unrelated Codex config preserved; both servers now on both sides.
        let toml = try readCodexConfig()
        XCTAssertTrue(toml.contains("model = \"gpt-5.4\""))
        XCTAssertEqual(CodexMCP.read(toml: toml).map(\.name), ["claudeOnly", "codexOnly"])

        let after = MCPSync.status(workspace: ws.path, home: home)
        XCTAssertTrue(after.inSync)
        XCTAssertEqual(after.claudeServers, ["claudeOnly", "codexOnly"])
        XCTAssertEqual(after.codexServers, ["claudeOnly", "codexOnly"])
    }

    func testApplyIsNoOpWhenAlreadyInSync() throws {
        try writeClaudeMCP("{\"mcpServers\":{\"fs\":{\"command\":\"a\"}}}")
        try writeCodexConfig("[mcp_servers.fs]\ncommand = \"a\"\n")
        let outcome = try MCPSync.apply(workspace: ws.path, home: home, timestamp: { "TS" })
        XCTAssertTrue(outcome.addedToCodex.isEmpty)
        XCTAssertTrue(outcome.addedToClaude.isEmpty)
        XCTAssertTrue(outcome.backups.isEmpty, "nothing changed → nothing backed up")
    }

    func testApplyHandlesMissingFiles() throws {
        // Only Codex has a server; Claude has no .mcp.json at all.
        try writeCodexConfig("[mcp_servers.fs]\ncommand = \"a\"\n")
        let outcome = try MCPSync.apply(workspace: ws.path, home: home, timestamp: { "TS" })
        XCTAssertEqual(outcome.addedToClaude, ["fs"])
        XCTAssertTrue(outcome.addedToCodex.isEmpty)
        // .mcp.json was created.
        XCTAssertEqual(MCPSync.readClaude(workspace: ws.path).map(\.name), ["fs"])
    }

    // MARK: - Agent-internal servers (never synced, never counted)

    /// The internal-plumbing test: a binary living inside the agent's app bundle
    /// (Codex.app before 26.715, ChatGPT.app after the rename) or the bundled
    /// computer-use helper app, whose command is registered with a *relative*
    /// path plus `cwd` — all observed in real configs on this machine.
    func testAgentInternalCoversBothAppErasAndRelativeHelperPath() {
        func stdio(_ command: String) -> MCPServer {
            MCPServer(name: "s", transport: .stdio(command: command, args: [], env: [:]))
        }
        XCTAssertTrue(stdio("/Applications/Codex.app/Contents/Resources/x/node_repl").isAgentInternal)
        XCTAssertTrue(
            stdio("/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl")
                .isAgentInternal)
        XCTAssertTrue(
            stdio(
                "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
            ).isAgentInternal)
        XCTAssertFalse(stdio("/usr/local/bin/mcp-server").isAgentInternal)
        XCTAssertFalse(
            MCPServer(
                name: "docs",
                transport: .remote(
                    url: "https://developers.openai.com/mcp", kind: .http, headers: [:])
            ).isAgentInternal)
    }

    /// Codex Desktop registers its own bundled helper (`node_repl`, shipped
    /// inside the app bundle) in config.toml. That's the app's private plumbing,
    /// not user configuration — it must not leak to the other agent or count as
    /// drift.
    func testStatusIgnoresCodexInternalServers() throws {
        try writeCodexConfig(
            """
            [mcp_servers.node_repl]
            command = "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"

            [mcp_servers.real]
            command = "real-server"
            """)
        let status = MCPSync.status(workspace: ws.path, home: home)
        XCTAssertEqual(status.codexServers, ["real"])
        XCTAssertEqual(status.missingInClaude, ["real"])
    }

    func testApplyDoesNotCopyCodexInternalServerToClaude() throws {
        try writeCodexConfig(
            """
            [mcp_servers.node_repl]
            command = "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"

            [mcp_servers.real]
            command = "real-server"
            """)
        let outcome = try MCPSync.apply(workspace: ws.path, home: home, timestamp: { "TS" })
        XCTAssertEqual(outcome.addedToClaude, ["real"])
        let json = try String(
            contentsOf: ws.appendingPathComponent(".mcp.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("real"))
        XCTAssertFalse(json.contains("node_repl"), "internal server must not leak to Claude")
    }

    /// Internal servers that already leaked into a project's .mcp.json (synced by
    /// an earlier build; this is the real leaked shape — ChatGPT.app-era absolute
    /// path plus the relative-path computer-use helper) must not bounce back into
    /// Codex or count as drift.
    func testApplyIgnoresLeakedInternalServerInClaudeConfig() throws {
        try writeClaudeMCP(
            """
            {"mcpServers":{
              "node_repl":{"command":"/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"},
              "computer-use":{"command":"./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient","args":["mcp"]}
            }}
            """)
        let outcome = try MCPSync.apply(workspace: ws.path, home: home, timestamp: { "TS" })
        XCTAssertEqual(outcome.addedToCodex, [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".codex/config.toml").path),
            "nothing to sync — Codex config must not even be created")
        XCTAssertTrue(MCPSync.status(workspace: ws.path, home: home).inSync)
    }
}
