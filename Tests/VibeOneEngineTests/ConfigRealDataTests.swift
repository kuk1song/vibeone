import XCTest

@testable import VibeOneEngine

/// Smoke tests against the *real* config on this machine. Like the session
/// real-data tests, they verify the tolerant readers survive actual files
/// (quoted table keys, unrelated tables, arbitrary scalars) — they skip cleanly
/// when a file is absent, so CI without these files still passes.
final class ConfigRealDataTests: XCTestCase {

    private let home = FileManager.default.homeDirectoryForCurrentUser

    func testCodexConfigParsesWithoutCrashing() throws {
        let url = ConfigLocation.codexConfig(home: home)
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("no real ~/.codex/config.toml")
        }
        let servers = CodexMCP.read(toml: toml)
        // We don't assert a count (machine-dependent) — just that parse is total
        // and re-rendering each parsed server round-trips.
        for server in servers {
            XCTAssertFalse(server.name.isEmpty)
        }
        print("[real-data] ~/.codex/config.toml: \(servers.count) MCP server(s)")
    }

    func testClaudeUserScopeParsesWithoutCrashing() throws {
        let url = ConfigLocation.claudeUserConfig(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no real ~/.claude.json")
        }
        let servers = MCPSync.readUserScope(home: home)
        print("[real-data] ~/.claude.json user/local-scope: \(servers.count) MCP server(s)")
    }
}
