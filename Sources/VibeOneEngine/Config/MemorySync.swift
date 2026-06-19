import Foundation

/// Memory dimension of config sync (PRD §4.1): make `AGENTS.md` the single
/// source of truth for both agents. Codex reads `AGENTS.md` natively; Claude
/// reads `CLAUDE.md`, so VibeOne keeps `CLAUDE.md` as a one-line `@AGENTS.md`
/// import instead of a second copy that can drift.
///
/// When `AGENTS.md` already exists it is the source of truth and is never
/// rewritten — `apply` only ever points `CLAUDE.md` at it. When it is missing
/// but a real `CLAUDE.md` exists, `apply` *adopts*: it seeds `AGENTS.md` from
/// the `CLAUDE.md` content (backing the original up) and reduces `CLAUDE.md` to
/// a pure import, so a Claude-first project becomes shareable with Codex.
public enum MemorySync {

    /// Claude Code's file-import directive (`@path`). Pointing `CLAUDE.md` at
    /// `AGENTS.md` makes Claude load the authoritative brain transitively.
    static let importDirective = "@AGENTS.md"

    // MARK: - Status (read-only)

    public struct Status: Equatable, Sendable {
        /// `AGENTS.md` exists at the workspace root.
        public var agentsExists: Bool
        /// `CLAUDE.md` exists and contains the `@AGENTS.md` import line.
        public var claudeImportsAgents: Bool

        /// Both agents resolve to the same brain.
        public var inSync: Bool { agentsExists && claudeImportsAgents }

        public init(agentsExists: Bool, claudeImportsAgents: Bool) {
            self.agentsExists = agentsExists
            self.claudeImportsAgents = claudeImportsAgents
        }
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
        /// Neither `AGENTS.md` nor an adoptable `CLAUDE.md` exists — nothing
        /// authoritative to sync. A clean no-op, not a failure.
        case noMemory
        /// `CLAUDE.md` already imported `AGENTS.md`; nothing to do.
        case alreadySynced
        /// `CLAUDE.md` didn't exist and was created as a pure import.
        case createdImport
        /// The import line was prepended to an existing `CLAUDE.md`
        /// (its prior content was backed up and preserved below the import).
        case addedImport(backup: URL?)
        /// There was no `AGENTS.md`: it was seeded from `CLAUDE.md`'s content and
        /// `CLAUDE.md` was reduced to a pure import (the original is backed up).
        case adopted(backup: URL?)
    }

    /// Make memory in sync: both agents resolve to one `AGENTS.md` brain.
    ///
    /// - `AGENTS.md` exists → it is authoritative; ensure `CLAUDE.md` imports it
    ///   (create it, prepend the import to existing content, or no-op).
    /// - `AGENTS.md` missing but `CLAUDE.md` has real content → *adopt*: seed
    ///   `AGENTS.md` from it, back the original up, reduce `CLAUDE.md` to the import.
    /// - Neither file (or only a dangling import) → `.noMemory`, nothing written.
    ///
    /// Original `CLAUDE.md` content is never lost: it is either preserved in place
    /// or backed up before being rewritten.
    @discardableResult
    public static func apply(
        workspace: String,
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) },
        fileManager fm: FileManager = .default
    ) throws -> Outcome {
        let agents = ConfigLocation.agentsMemory(workspace: workspace)
        let claude = ConfigLocation.claudeMemory(workspace: workspace)
        let claudeText = try? String(contentsOf: claude, encoding: .utf8)

        guard fm.fileExists(atPath: agents.path) else {
            // No authoritative file yet — adopt CLAUDE.md if it carries real content.
            guard let claudeText, !adoptSeed(from: claudeText).isEmpty else {
                return .noMemory
            }
            // Seed the authoritative file first (so the brain survives a crash),
            // then back up and collapse CLAUDE.md to a pure import.
            try AtomicFile.write(adoptSeed(from: claudeText), to: agents)
            let backup = try AtomicFile.backup(claude, timestamp: timestamp())
            try AtomicFile.write(importDirective + "\n", to: claude)
            return .adopted(backup: backup)
        }

        guard let existing = claudeText else {
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
            isImportLine(line)
        }
    }

    private static func isImportLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == importDirective || trimmed == "@./AGENTS.md"
    }

    /// The content to seed `AGENTS.md` with when adopting: `CLAUDE.md` minus any
    /// bare import line (so the brain never imports itself), with the leading
    /// blank lines that removal leaves behind trimmed. Empty when there is
    /// nothing real to adopt (e.g. `CLAUDE.md` was only a dangling import).
    private static func adoptSeed(from claudeText: String) -> String {
        let kept =
            claudeText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isImportLine($0) }
            .joined(separator: "\n")
        let seed = String(kept.drop(while: { $0 == "\n" }))
        return seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : seed
    }
}
