import XCTest

@testable import VibeOneEngine

final class MemorySyncTests: XCTestCase {

    private var ws: URL!

    override func setUpWithError() throws {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        ws = FileManager.default.temporaryDirectory.appendingPathComponent("vibeone-mem-\(unique)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: ws)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: ws.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - Status

    func testStatusVacuouslyInSyncWhenNoMemoryFiles() {
        // No AGENTS.md, no CLAUDE.md: both agents resolve to the same (empty)
        // brain and `apply` is a `.noMemory` no-op — showing drift here offered
        // a Sync that could not change anything.
        let s = MemorySync.status(workspace: ws.path)
        XCTAssertFalse(s.agentsExists)
        XCTAssertFalse(s.claudeImportsAgents)
        XCTAssertFalse(s.claudeHasContent)
        XCTAssertTrue(s.inSync)
    }

    func testStatusVacuouslyInSyncWhenClaudeIsOnlyADanglingImport() throws {
        // A bare `@AGENTS.md` import with no AGENTS.md resolves to the same
        // empty brain for both agents, and `apply` is `.noMemory` (nothing
        // adoptable) — consistent with the apply test below.
        try write("CLAUDE.md", "@AGENTS.md\n")
        let s = MemorySync.status(workspace: ws.path)
        XCTAssertFalse(s.claudeHasContent)
        XCTAssertTrue(s.inSync)
    }

    func testStatusDriftWhenClaudeHasContentButNoAgents() throws {
        // Real CLAUDE.md content with no AGENTS.md is genuine drift: Codex sees
        // nothing of it, and `apply` would adopt (write files) to fix that.
        try write("CLAUDE.md", "# project rules\n")
        let s = MemorySync.status(workspace: ws.path)
        XCTAssertFalse(s.agentsExists)
        XCTAssertTrue(s.claudeHasContent)
        XCTAssertFalse(s.inSync)
    }

    func testStatusInSyncWhenAgentsExistsAndClaudeImports() throws {
        try write("AGENTS.md", "# brain\n")
        try write("CLAUDE.md", "@AGENTS.md\n")
        let s = MemorySync.status(workspace: ws.path)
        XCTAssertTrue(s.agentsExists)
        XCTAssertTrue(s.claudeImportsAgents)
        XCTAssertTrue(s.inSync)
    }

    func testStatusDriftWhenClaudeHasOwnContent() throws {
        try write("AGENTS.md", "# brain\n")
        try write("CLAUDE.md", "some local notes\n")
        let s = MemorySync.status(workspace: ws.path)
        XCTAssertTrue(s.agentsExists)
        XCTAssertFalse(s.claudeImportsAgents)
        XCTAssertFalse(s.inSync)
    }

    // MARK: - Apply

    func testApplyIsNoMemoryWhenNeitherFileExists() throws {
        // An empty project has nothing authoritative to sync — a clean no-op,
        // not an error (the ▶ switch must not fail on a memory-less project).
        XCTAssertEqual(try MemorySync.apply(workspace: ws.path), .noMemory)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ws.appendingPathComponent("AGENTS.md").path),
            "no AGENTS.md should be conjured from nothing")
    }

    func testApplyAdoptsClaudeContentWhenNoAgents() throws {
        // The Claude-first user: a real CLAUDE.md, no AGENTS.md yet. Adopt makes
        // AGENTS.md authoritative (seeded from CLAUDE.md), then leaves CLAUDE.md
        // as a pure import so both agents resolve to one brain.
        try write("CLAUDE.md", "# project rules\nbe terse\n")

        let outcome = try MemorySync.apply(workspace: ws.path, timestamp: { "TS" })
        guard case .adopted(let backup) = outcome else {
            return XCTFail("expected .adopted, got \(outcome)")
        }

        let agents = try String(
            contentsOf: ws.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertEqual(agents, "# project rules\nbe terse\n", "AGENTS.md seeded verbatim")

        let claude = try String(
            contentsOf: ws.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        XCTAssertEqual(claude, "@AGENTS.md\n", "CLAUDE.md reduced to a pure import")

        let backupURL = try XCTUnwrap(backup)
        XCTAssertEqual(
            try String(contentsOf: backupURL, encoding: .utf8), "# project rules\nbe terse\n",
            "the pre-adopt CLAUDE.md is recoverable")

        XCTAssertTrue(MemorySync.status(workspace: ws.path).inSync)
    }

    func testApplyAdoptStripsDanglingImportFromSeededAgents() throws {
        // CLAUDE.md imports a now-missing AGENTS.md but still carries real notes.
        // Adopt must seed AGENTS.md with the notes only — never the self-import.
        try write("CLAUDE.md", "@AGENTS.md\n\nreal notes\n")

        let outcome = try MemorySync.apply(workspace: ws.path, timestamp: { "TS" })
        guard case .adopted = outcome else {
            return XCTFail("expected .adopted, got \(outcome)")
        }
        let agents = try String(
            contentsOf: ws.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertEqual(agents, "real notes\n")
        XCTAssertFalse(agents.contains("@AGENTS.md"), "no self-referential import in AGENTS.md")
        XCTAssertTrue(MemorySync.status(workspace: ws.path).inSync)
    }

    func testApplyIsNoMemoryWhenClaudeIsOnlyADanglingImport() throws {
        // CLAUDE.md points at a missing AGENTS.md and has nothing else — there is
        // no real content to adopt, so this is a no-op (and nothing is written).
        try write("CLAUDE.md", "@AGENTS.md\n")
        XCTAssertEqual(try MemorySync.apply(workspace: ws.path), .noMemory)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ws.appendingPathComponent("AGENTS.md").path))
        XCTAssertEqual(
            try String(contentsOf: ws.appendingPathComponent("CLAUDE.md"), encoding: .utf8),
            "@AGENTS.md\n", "CLAUDE.md is left untouched")
    }

    func testApplyCreatesImportWhenNoClaudeMd() throws {
        try write("AGENTS.md", "# brain\n")
        let outcome = try MemorySync.apply(workspace: ws.path)
        XCTAssertEqual(outcome, .createdImport)
        let claude = try String(
            contentsOf: ws.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        XCTAssertEqual(claude, "@AGENTS.md\n")
        XCTAssertTrue(MemorySync.status(workspace: ws.path).inSync)
    }

    func testApplyPrependsImportPreservingExistingContentAndBacksUp() throws {
        try write("AGENTS.md", "# brain\n")
        try write("CLAUDE.md", "existing project notes\n")

        let outcome = try MemorySync.apply(workspace: ws.path, timestamp: { "TS" })
        guard case .addedImport(let backup) = outcome else {
            return XCTFail("expected .addedImport, got \(outcome)")
        }
        let backupURL = try XCTUnwrap(backup)
        XCTAssertEqual(
            try String(contentsOf: backupURL, encoding: .utf8), "existing project notes\n",
            "backup must keep the pre-sync CLAUDE.md")

        let claude = try String(
            contentsOf: ws.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        XCTAssertTrue(claude.hasPrefix("@AGENTS.md\n"))
        XCTAssertTrue(claude.contains("existing project notes"), "original content preserved")
        XCTAssertTrue(MemorySync.status(workspace: ws.path).inSync)
    }

    func testApplyIsIdempotent() throws {
        try write("AGENTS.md", "# brain\n")
        try write("CLAUDE.md", "@AGENTS.md\n\nmore\n")
        XCTAssertEqual(try MemorySync.apply(workspace: ws.path), .alreadySynced)
    }
}
