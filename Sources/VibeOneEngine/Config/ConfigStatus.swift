import Foundation

/// One read-only snapshot of all three config dimensions for a project — what
/// the popover renders so a user sees memory / MCP / skills drift at a glance
/// (ARCHITECTURE §4.3). Pure reads; never writes.
public struct ConfigStatus: Equatable, Sendable {
    public var memory: MemorySync.Status
    public var mcp: MCPSync.Status
    public var skills: SkillsSync.Status

    /// All three dimensions aligned across both agents.
    public var allInSync: Bool { memory.inSync && mcp.inSync && skills.inSync }

    public init(memory: MemorySync.Status, mcp: MCPSync.Status, skills: SkillsSync.Status) {
        self.memory = memory
        self.mcp = mcp
        self.skills = skills
    }

    /// Gather memory (workspace root), MCP (project + Codex), and skills (user
    /// home) status in one pass.
    public static func read(
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ConfigStatus {
        ConfigStatus(
            memory: MemorySync.status(workspace: workspace),
            mcp: MCPSync.status(workspace: workspace, home: home),
            skills: SkillsSync.status(home: home))
    }
}
