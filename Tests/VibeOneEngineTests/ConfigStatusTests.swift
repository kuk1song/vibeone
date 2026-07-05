import XCTest

@testable import VibeOneEngine

final class ConfigStatusTests: XCTestCase {

    private var home: URL!
    private var ws: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        home = fm.temporaryDirectory.appendingPathComponent("vibeone-cfg-home-\(unique)")
        ws = fm.temporaryDirectory.appendingPathComponent("vibeone-cfg-ws-\(unique)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
        try? fm.removeItem(at: ws)
    }

    func testEmptyProjectIsVacuouslyInSync() {
        let status = ConfigStatus.read(workspace: ws.path, home: home)
        // Nothing to sync on any dimension: no memory files, no MCP servers, no
        // skills. Every dimension is vacuously aligned — the sync actions would
        // all be no-ops, so showing drift would offer a Sync that cannot act.
        XCTAssertTrue(status.memory.inSync)
        XCTAssertTrue(status.mcp.inSync)
        XCTAssertTrue(status.skills.inSync)
        XCTAssertTrue(status.allInSync)
    }

    func testFullyConfiguredProjectIsAllInSync() throws {
        // Memory aligned.
        try "# brain\n".write(
            to: ws.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "@AGENTS.md\n".write(
            to: ws.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        // MCP aligned (same server both sides).
        try "{\"mcpServers\":{\"fs\":{\"command\":\"a\"}}}"
            .write(to: ws.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try fm.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.fs]\ncommand = \"a\"\n"
            .write(
                to: home.appendingPathComponent(".codex/config.toml"), atomically: true,
                encoding: .utf8)
        // Skills: both empty → aligned.

        let status = ConfigStatus.read(workspace: ws.path, home: home)
        XCTAssertTrue(status.memory.inSync)
        XCTAssertTrue(status.mcp.inSync)
        XCTAssertTrue(status.skills.inSync)
        XCTAssertTrue(status.allInSync)
    }
}
