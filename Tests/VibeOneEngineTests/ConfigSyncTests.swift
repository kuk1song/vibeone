import Foundation
import Testing

@testable import VibeOneEngine

/// `ConfigSync` orchestrates the three dimensions; these pin its scope gating,
/// per-dimension reporting, and the ADR-013 guarantee that one dimension failing
/// never blocks the others. Each case gets an isolated temp workspace + home
/// (Swift Testing runs in parallel).
struct ConfigSyncTests {

    private struct Sandbox {
        let workspace: URL
        let home: URL
        let fm = FileManager.default

        init() throws {
            let unique = ProcessInfo.processInfo.globallyUniqueString
            workspace = fm.temporaryDirectory.appendingPathComponent("vibeone-sync-ws-\(unique)")
            home = fm.temporaryDirectory.appendingPathComponent("vibeone-sync-home-\(unique)")
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        }

        func cleanup() {
            try? fm.removeItem(at: workspace)
            try? fm.removeItem(at: home)
        }

        func write(_ relative: String, under base: URL, _ contents: String) throws {
            let url = base.appendingPathComponent(relative)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        var claudeSkills: URL { ConfigLocation.claudeSkillsDir(home: home) }
    }

    @Test func projectLevelSyncsMemoryAndProjectMCPButNotSkills() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        // Claude-first project (memory adopts) + a Codex-only MCP server + a
        // Codex-only skill that project-level sync must leave alone.
        try s.write("CLAUDE.md", under: s.workspace, "# rules\nbe terse\n")
        try s.write(".codex/config.toml", under: s.home, "[mcp_servers.fs]\ncommand = \"a\"\n")
        try s.write(".codex/skills/web-access/SKILL.md", under: s.home, "# skill\n")

        let report = ConfigSync.run(
            scope: .projectLevel, workspace: s.workspace.path, home: s.home, timestamp: { "TS" })

        #expect(report.items.map(\.dimension) == [.memory, .mcp])
        #expect(report.allSucceeded)
        #expect(report.anyChanged)
        #expect(MemorySync.status(workspace: s.workspace.path).inSync)
        #expect(MCPSync.readClaude(workspace: s.workspace.path).map(\.name) == ["fs"])
        #expect(
            SkillsSync.listSkills(in: s.claudeSkills).isEmpty,
            "global skills must not sync at project level")
    }

    @Test func fullScopeAlsoSyncsGlobalSkills() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        try s.write("CLAUDE.md", under: s.workspace, "# rules\n")
        try s.write(".codex/skills/web-access/SKILL.md", under: s.home, "# skill\n")

        let report = ConfigSync.run(
            scope: .full, workspace: s.workspace.path, home: s.home, timestamp: { "TS" })

        #expect(report.items.map(\.dimension) == [.memory, .mcp, .skills])
        #expect(report.allSucceeded)
        #expect(SkillsSync.listSkills(in: s.claudeSkills) == ["web-access"])
    }

    @Test func cleanNoOpWhenNothingToSync() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        let report = ConfigSync.run(
            scope: .full, workspace: s.workspace.path, home: s.home, timestamp: { "TS" })
        #expect(report.allSucceeded)
        #expect(!report.anyChanged)
        #expect(report.summaryLine == "Already in sync")
    }

    @Test func partialFailureIsIsolatedPerDimension() throws {
        let s = try Sandbox()
        defer {
            try? s.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.workspace.path)
            s.cleanup()
        }
        // Project files live in a read-only workspace, so the memory write fails.
        // MCP is arranged to write only into the (writable) home config, so it
        // still syncs — one dimension failing must not block the other.
        try s.write("CLAUDE.md", under: s.workspace, "# rules\n")  // adopt target
        try s.write(
            ".mcp.json", under: s.workspace, "{\"mcpServers\":{\"foo\":{\"command\":\"a\"}}}")
        try s.write(".codex/config.toml", under: s.home, "")  // foo missing in Codex → writes home
        try s.fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: s.workspace.path)

        let report = ConfigSync.run(
            scope: .projectLevel, workspace: s.workspace.path, home: s.home, timestamp: { "TS" })

        let memory = try #require(report.items.first { $0.dimension == .memory })
        let mcp = try #require(report.items.first { $0.dimension == .mcp })
        #expect(memory.failed)
        #expect(!mcp.failed)
        #expect(!report.allSucceeded)
        #expect(
            MCPSync.readCodex(home: s.home).map(\.name) == ["foo"],
            "the working dimension still applied")
    }
}
