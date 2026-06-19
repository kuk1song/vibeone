import Foundation

/// Runs the three config dimensions (memory · MCP · skills) as one operation and
/// reports honestly what each did (ADR-013). Dimensions apply **independently**:
/// one failing never blocks the others, so a switch is never derailed by, say, a
/// malformed MCP file when memory would have synced fine.
///
/// Scope decides how much runs. The ▶ switch syncs only project-level config
/// automatically (memory + the project's MCP servers); global, machine-wide
/// skills are heavier and surprising to copy on every switch, so they are opt-in
/// through the manual ‹Sync›.
public enum ConfigSync {

    public enum Scope: Sendable {
        /// memory + project MCP — what the ▶ switch syncs automatically.
        case projectLevel
        /// project-level + machine-wide skills — the manual ‹Sync›.
        case full
    }

    public enum Dimension: String, Sendable, CaseIterable {
        case memory, mcp, skills

        public var label: String {
            switch self {
            case .memory: return "Memory"
            case .mcp: return "MCP"
            case .skills: return "Skills"
            }
        }
    }

    /// One dimension's result. A failure folds its description into `summary`
    /// (the caller logs the underlying error); `changed` is false on no-op/failure.
    public struct Item: Sendable, Equatable {
        public let dimension: Dimension
        public let summary: String
        public let changed: Bool
        public let failed: Bool
    }

    public struct Report: Sendable, Equatable {
        public let items: [Item]

        public var allSucceeded: Bool { items.allSatisfy { !$0.failed } }
        public var anyChanged: Bool { items.contains { $0.changed } }

        /// One honest status line: each failed or changed dimension, in order;
        /// "Already in sync" when nothing needed doing.
        public var summaryLine: String {
            let parts = items.compactMap { item -> String? in
                if item.failed { return "\(item.dimension.label) failed" }
                if item.changed { return item.summary }
                return nil
            }
            return parts.isEmpty ? "Already in sync" : parts.joined(separator: " · ")
        }
    }

    public static func run(
        scope: Scope,
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) -> Report {
        var items: [Item] = [
            run(.memory) {
                describe(try MemorySync.apply(workspace: workspace, timestamp: timestamp))
            },
            run(.mcp) {
                describe(try MCPSync.apply(workspace: workspace, home: home, timestamp: timestamp))
            },
        ]
        if scope == .full {
            items.append(run(.skills) { describe(try SkillsSync.apply(home: home)) })
        }
        return Report(items: items)
    }

    // MARK: -

    private static func run(
        _ dimension: Dimension, _ body: () throws -> (summary: String, changed: Bool)
    ) -> Item {
        do {
            let (summary, changed) = try body()
            return Item(dimension: dimension, summary: summary, changed: changed, failed: false)
        } catch {
            return Item(
                dimension: dimension, summary: error.localizedDescription, changed: false,
                failed: true)
        }
    }

    private static func describe(_ outcome: MemorySync.Outcome) -> (summary: String, changed: Bool)
    {
        switch outcome {
        case .noMemory: return ("No memory to sync", false)
        case .alreadySynced: return ("Memory in sync", false)
        case .createdImport, .addedImport: return ("Linked CLAUDE.md → AGENTS.md", true)
        case .adopted: return ("Adopted CLAUDE.md as AGENTS.md", true)
        }
    }

    private static func describe(_ outcome: MCPSync.Outcome) -> (summary: String, changed: Bool) {
        let n = outcome.addedToCodex.count + outcome.addedToClaude.count
        guard n > 0 else { return ("MCP in sync", false) }
        return ("Synced \(n) MCP server\(n == 1 ? "" : "s")", true)
    }

    private static func describe(_ outcome: SkillsSync.Outcome) -> (summary: String, changed: Bool)
    {
        let n = outcome.copiedToCodex.count + outcome.copiedToClaude.count
        guard n > 0 else { return ("Skills in sync", false) }
        return ("Synced \(n) skill\(n == 1 ? "" : "s")", true)
    }
}
