import Foundation

/// Skills dimension of config sync (PRD §4.1): `SKILL.md` is already a shared
/// open format, so a skill is just a directory that both agents can read. Claude
/// keeps them in `~/.claude/skills/<name>/`, Codex in `~/.codex/skills/<name>/`.
///
/// Sync is **additive and bidirectional**: a skill present on one side is copied
/// to the other when missing; existing skills are never overwritten. A "skill"
/// is a non-hidden immediate subdirectory containing a `SKILL.md` — which
/// naturally excludes Codex's runtime dirs (`.system/`, `codex-primary-runtime`,
/// neither of which is a user `SKILL.md` skill).
public enum SkillsSync {

    private static let manifest = "SKILL.md"

    // MARK: - Listing

    /// Names of user skills under `dir` (sorted). A skill = non-hidden directory
    /// containing a `SKILL.md`. Missing dir → empty.
    public static func listSkills(in dir: URL, fileManager fm: FileManager = .default) -> [String] {
        guard
            let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        return entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let isDir =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            guard fm.fileExists(atPath: url.appendingPathComponent(manifest).path) else {
                return nil
            }
            return name
        }
        .sorted()
    }

    // MARK: - Status (read-only)

    public struct Status: Equatable, Sendable {
        public var claudeSkills: [String]
        public var codexSkills: [String]
        public var missingInCodex: [String]  // in Claude, not Codex
        public var missingInClaude: [String]  // in Codex, not Claude

        public var inSync: Bool { missingInCodex.isEmpty && missingInClaude.isEmpty }

        public init(
            claudeSkills: [String], codexSkills: [String], missingInCodex: [String],
            missingInClaude: [String]
        ) {
            self.claudeSkills = claudeSkills
            self.codexSkills = codexSkills
            self.missingInCodex = missingInCodex
            self.missingInClaude = missingInClaude
        }
    }

    public static func status(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager fm: FileManager = .default
    ) -> Status {
        let claude = listSkills(in: ConfigLocation.claudeSkillsDir(home: home), fileManager: fm)
        let codex = listSkills(in: ConfigLocation.codexSkillsDir(home: home), fileManager: fm)
        let claudeSet = Set(claude)
        let codexSet = Set(codex)
        return Status(
            claudeSkills: claude,
            codexSkills: codex,
            missingInCodex: claudeSet.subtracting(codexSet).sorted(),
            missingInClaude: codexSet.subtracting(claudeSet).sorted())
    }

    // MARK: - Apply (copy)

    public struct Outcome: Equatable, Sendable {
        public var copiedToCodex: [String]
        public var copiedToClaude: [String]
    }

    /// Copy each missing skill directory to the side that lacks it. Additive:
    /// a skill already present on the target is skipped (never overwritten).
    @discardableResult
    public static func apply(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager fm: FileManager = .default
    ) throws -> Outcome {
        let claudeDir = ConfigLocation.claudeSkillsDir(home: home)
        let codexDir = ConfigLocation.codexSkillsDir(home: home)
        let status = status(home: home, fileManager: fm)

        var toCodex: [String] = []
        for name in status.missingInCodex {
            try copySkill(name, from: claudeDir, to: codexDir, fileManager: fm)
            toCodex.append(name)
        }
        var toClaude: [String] = []
        for name in status.missingInClaude {
            try copySkill(name, from: codexDir, to: claudeDir, fileManager: fm)
            toClaude.append(name)
        }
        return Outcome(copiedToCodex: toCodex, copiedToClaude: toClaude)
    }

    /// Recursively copy one skill dir. Creates the destination skills dir if
    /// needed; refuses to clobber an existing destination skill.
    private static func copySkill(
        _ name: String, from source: URL, to dest: URL, fileManager fm: FileManager
    ) throws {
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { return }
        try fm.copyItem(at: source.appendingPathComponent(name, isDirectory: true), to: target)
    }
}
