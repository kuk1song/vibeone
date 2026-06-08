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

    func testStatusNotInSyncWhenNoMemoryFiles() {
        let s = MemorySync.status(workspace: ws.path)
        XCTAssertFalse(s.agentsExists)
        XCTAssertFalse(s.claudeImportsAgents)
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

    func testApplyThrowsWhenNoAuthoritativeMemory() {
        XCTAssertThrowsError(try MemorySync.apply(workspace: ws.path)) { error in
            XCTAssertEqual(error as? MemorySync.Failure, .noAuthoritativeMemory)
        }
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
