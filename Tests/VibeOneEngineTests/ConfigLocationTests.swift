import XCTest

@testable import VibeOneEngine

final class ConfigLocationTests: XCTestCase {

    func testMemoryPathsSitAtWorkspaceRoot() {
        let ws = "/Users/kuki/proj"
        XCTAssertEqual(
            ConfigLocation.agentsMemory(workspace: ws).path, "/Users/kuki/proj/AGENTS.md")
        XCTAssertEqual(
            ConfigLocation.claudeMemory(workspace: ws).path, "/Users/kuki/proj/CLAUDE.md")
    }

    func testClaudeProjectMCPIsDotMcpJsonAtRoot() {
        XCTAssertEqual(
            ConfigLocation.claudeProjectMCP(workspace: "/Users/kuki/proj").path,
            "/Users/kuki/proj/.mcp.json")
    }

    func testCodexProjectConfigSitsUnderWorkspaceDotCodex() {
        XCTAssertEqual(
            ConfigLocation.codexProjectConfig(workspace: "/Users/kuki/proj").path,
            "/Users/kuki/proj/.codex/config.toml")
    }

    func testCodexConfigAndUserConfigPaths() {
        let home = URL(fileURLWithPath: "/Users/kuki")
        XCTAssertEqual(
            ConfigLocation.codexConfig(home: home).path, "/Users/kuki/.codex/config.toml")
        XCTAssertEqual(ConfigLocation.claudeUserConfig(home: home).path, "/Users/kuki/.claude.json")
    }

    func testSkillsDirs() {
        let home = URL(fileURLWithPath: "/Users/kuki")
        XCTAssertEqual(
            ConfigLocation.claudeSkillsDir(home: home).path, "/Users/kuki/.claude/skills")
        XCTAssertEqual(ConfigLocation.codexSkillsDir(home: home).path, "/Users/kuki/.codex/skills")
    }
}
