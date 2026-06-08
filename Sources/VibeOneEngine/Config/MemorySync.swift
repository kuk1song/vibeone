import Foundation

/// Memory dimension of config sync (PRD §4.1): make `AGENTS.md` the single
/// source of truth for both agents. Codex reads `AGENTS.md` natively; Claude
/// reads `CLAUDE.md`, so VibeOne keeps `CLAUDE.md` as a one-line `@AGENTS.md`
/// import instead of a second copy that can drift.
///
/// v0 is deliberately conservative: it only ever *adds* the import to
/// `CLAUDE.md` and never rewrites `AGENTS.md`. Seeding `AGENTS.md` from an
/// existing `CLAUDE.md` (the "adopt" path) is left for later.
public enum MemorySync {

    /// Claude Code's file-import directive (`@path`). Pointing `CLAUDE.md` at
    /// `AGENTS.md` makes Claude load the authoritative brain transitively.
    static let importDirective = "@AGENTS.md"

    public enum Failure: Error, Equatable {
        /// No `AGENTS.md` at the workspace root — nothing authoritative to import.
        case noAuthoritativeMemory
    }

    // MARK: - Status (read-only)

    public struct Status: Equatable, Sendable {
        /// `AGENTS.md` exists at the workspace root.
        public var agentsExists: Bool
        /// `CLAUDE.md` exists and contains the `@AGENTS.md` import line.
        public var claudeImportsAgents: Bool

        /// Both agents resolve to the same brain.
        public var inSync: Bool { agentsExists && claudeImportsAgents }
    }

    /// Inspect the workspace without writing anything.
    public static func status(
        workspace: String,
        fileManager fm: FileManager = .default
    ) -> Status {
        let agents = ConfigLocation.agentsMemory(workspace: workspace)
        let claude = ConfigLocation.claudeMemory(workspace: workspace)
        let claudeText = (try? String(contentsOf: claude, encoding: .utf8)) ?? ""
        return Status(
            agentsExists: fm.fileExists(atPath: agents.path),
            claudeImportsAgents: importsAgents(claudeText))
    }

    // MARK: - Apply (write)

    public enum Outcome: Equatable, Sendable {
        /// `CLAUDE.md` already imported `AGENTS.md`; nothing to do.
        case alreadySynced
        /// `CLAUDE.md` didn't exist and was created as a pure import.
        case createdImport
        /// The import line was prepended to an existing `CLAUDE.md`
        /// (its prior content was backed up and preserved below the import).
        case addedImport(backup: URL?)
    }

    /// Ensure `CLAUDE.md` imports `AGENTS.md`. Requires `AGENTS.md` to exist
    /// (it is the source of truth). Existing `CLAUDE.md` content is preserved:
    /// the import is prepended, the original is backed up first.
    @discardableResult
    public static func apply(
        workspace: String,
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) },
        fileManager fm: FileManager = .default
    ) throws -> Outcome {
        let agents = ConfigLocation.agentsMemory(workspace: workspace)
        guard fm.fileExists(atPath: agents.path) else {
            throw Failure.noAuthoritativeMemory
        }

        let claude = ConfigLocation.claudeMemory(workspace: workspace)
        guard let existing = try? String(contentsOf: claude, encoding: .utf8) else {
            // No CLAUDE.md yet — create one that is just the import.
            try AtomicFile.write(importDirective + "\n", to: claude)
            return .createdImport
        }

        if importsAgents(existing) { return .alreadySynced }

        let backup = try AtomicFile.backup(claude, timestamp: timestamp())
        try AtomicFile.write(importDirective + "\n\n" + existing, to: claude)
        return .addedImport(backup: backup)
    }

    // MARK: -

    /// True if any line is exactly the import (`@AGENTS.md` or `@./AGENTS.md`),
    /// ignoring surrounding whitespace.
    private static func importsAgents(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == importDirective || trimmed == "@./AGENTS.md"
        }
    }
}
