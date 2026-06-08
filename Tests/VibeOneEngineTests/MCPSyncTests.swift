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
}
