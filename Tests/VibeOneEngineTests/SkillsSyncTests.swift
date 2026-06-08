import XCTest

@testable import VibeOneEngine

final class SkillsSyncTests: XCTestCase {

    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        home = fm.temporaryDirectory.appendingPathComponent("vibeone-skills-\(unique)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    /// Create `<skillsDir>/<name>/SKILL.md` (and optionally an extra file).
    private func makeSkill(_ name: String, in skillsDir: URL, body: String = "# skill\n") throws {
        let dir = skillsDir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private var claudeDir: URL { ConfigLocation.claudeSkillsDir(home: home) }
    private var codexDir: URL { ConfigLocation.codexSkillsDir(home: home) }

    func testListSkillsExcludesHiddenAndManifestlessDirs() throws {
        try makeSkill("real", in: claudeDir)
        try makeSkill(".system/inner", in: claudeDir)  // hidden parent → excluded
        try fm.createDirectory(  // dir without SKILL.md → excluded
            at: claudeDir.appendingPathComponent("no-manifest"), withIntermediateDirectories: true)

        XCTAssertEqual(SkillsSync.listSkills(in: claudeDir), ["real"])
    }

    func testStatusReportsBidirectionalMissing() throws {
        try makeSkill("cl-skill", in: claudeDir)
        try makeSkill("cx-skill", in: codexDir)
        let s = SkillsSync.status(home: home)
        XCTAssertEqual(s.claudeSkills, ["cl-skill"])
        XCTAssertEqual(s.codexSkills, ["cx-skill"])
        XCTAssertEqual(s.missingInCodex, ["cl-skill"])
        XCTAssertEqual(s.missingInClaude, ["cx-skill"])
        XCTAssertFalse(s.inSync)
    }

    func testApplyCopiesMissingSkillsBothWays() throws {
        try makeSkill("cl-skill", in: claudeDir, body: "claude one\n")
        try makeSkill("cx-skill", in: codexDir, body: "codex one\n")

        let outcome = try SkillsSync.apply(home: home)
        XCTAssertEqual(outcome.copiedToCodex, ["cl-skill"])
        XCTAssertEqual(outcome.copiedToClaude, ["cx-skill"])

        // Content actually copied, and now both sides agree.
        let copied = try String(
            contentsOf: codexDir.appendingPathComponent("cl-skill/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(copied, "claude one\n")
        XCTAssertTrue(SkillsSync.status(home: home).inSync)
    }

    func testApplyDoesNotOverwriteExistingSkill() throws {
        try makeSkill("shared", in: claudeDir, body: "CLAUDE VERSION\n")
        try makeSkill("shared", in: codexDir, body: "CODEX VERSION\n")
        let outcome = try SkillsSync.apply(home: home)
        XCTAssertTrue(outcome.copiedToCodex.isEmpty)
        XCTAssertTrue(outcome.copiedToClaude.isEmpty)
        // Each side keeps its own version.
        XCTAssertEqual(
            try String(
                contentsOf: codexDir.appendingPathComponent("shared/SKILL.md"), encoding: .utf8),
            "CODEX VERSION\n")
    }
}
