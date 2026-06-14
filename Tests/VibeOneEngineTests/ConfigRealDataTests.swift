import Foundation
import Testing

@testable import VibeOneEngine

private let homeDir = FileManager.default.homeDirectoryForCurrentUser
private func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Smoke tests against the *real* config on this machine. Like the session
/// real-data tests, they verify the tolerant readers survive actual files
/// (quoted table keys, unrelated tables, arbitrary scalars). Each is
/// `.enabled(if:)`-gated on the file's presence, so a machine without it (e.g.
/// CI) reports the test as skipped rather than failed.
@Suite("Config readers — real on-disk data")
struct ConfigRealDataTests {

    @Test(
        "Codex config.toml parses without crashing",
        .enabled(if: fileExists(ConfigLocation.codexConfig(home: homeDir))))
    func codexConfigParsesWithoutCrashing() throws {
        let url = ConfigLocation.codexConfig(home: homeDir)
        let toml = try String(contentsOf: url, encoding: .utf8)
        let servers = CodexMCP.read(toml: toml)
        // No count assertion (machine-dependent) — just that parse is total and
        // every parsed server is well-formed.
        for server in servers {
            #expect(!server.name.isEmpty)
        }
    }

    @Test(
        "Claude user-scope MCP parses without crashing",
        .enabled(if: fileExists(ConfigLocation.claudeUserConfig(home: homeDir))))
    func claudeUserScopeParsesWithoutCrashing() {
        let servers = MCPSync.readUserScope(home: homeDir)
        for server in servers {
            #expect(!server.name.isEmpty)
        }
    }
}
