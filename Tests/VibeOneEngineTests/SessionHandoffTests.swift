import XCTest

@testable import VibeOneEngine

final class SessionLocationTests: XCTestCase {

    func testEncodesWorkspaceWithLeadingSlash() {
        XCTAssertEqual(
            SessionLocation.claudeProjectDirName(forWorkspace: "/Users/kuki/proj"),
            "-Users-kuki-proj")
    }

    func testClaudeSessionURLNestsUnderEncodedProjectDir() {
        let home = URL(fileURLWithPath: "/home")
        let url = SessionLocation.claudeSessionURL(
            home: home, workspace: "/Users/kuki/proj", sessionId: "abc")
        XCTAssertEqual(url.path, "/home/.claude/projects/-Users-kuki-proj/abc.jsonl")
    }

    func testCodexRolloutURLNestsByDateAndNamesNatively() {
        let home = URL(fileURLWithPath: "/home")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = SessionLocation.codexRolloutURL(home: home, date: date, sessionId: "abc")

        // Date dir + filename stamp use the local zone (matching real Codex);
        // re-derive the expected values the same way so the test is tz-independent.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let pad2 = { (n: Int) in String(format: "%02d", n) }
        let year = String(format: "%04d", c.year!)
        let month = pad2(c.month!)
        let day = pad2(c.day!)
        let stamp =
            "\(year)-\(month)-\(day)T\(pad2(c.hour!))-\(pad2(c.minute!))-\(pad2(c.second!))"

        XCTAssertEqual(
            url.deletingLastPathComponent().path, "/home/.codex/sessions/\(year)/\(month)/\(day)")
        XCTAssertEqual(url.lastPathComponent, "rollout-\(stamp)-abc.jsonl")
    }
}

final class SessionHandoffTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeone-handoff-\(unique)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Drop a Codex rollout for `workspace` at the given date path, stamped with
    /// `modified` so "newest" is deterministic.
    @discardableResult
    private func writeRollout(
        workspace: String, datePath: String, id: String,
        messages: [(CanonicalMessage.Role, String)], modified: Date
    ) throws -> URL {
        let dir = SessionLocation.codexSessionsDir(home: home)
            .appendingPathComponent(datePath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-\(id).jsonl")
        let session = CanonicalSession(
            sourceAgent: "codex", workspace: workspace, model: "gpt-5.4",
            messages: messages.map { CanonicalMessage(role: $0.0, text: $0.1) })
        let jsonl = CodexSession.write(
            session, options: .init(sessionId: id, cwd: workspace, timestamp: { "t" }))
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testCodexToClaudeWritesResumableClaudeSession() throws {
        let workspace = "/Users/kuki/proj"
        try writeRollout(
            workspace: workspace, datePath: "2026/06/06", id: "id-1",
            messages: [(.user, "one"), (.assistant, "two"), (.user, "three")],
            modified: Date(timeIntervalSince1970: 2000))

        let result = try SessionHandoff.codexToClaude(
            workspace: workspace, home: home,
            makeSessionId: { "fixed-uuid" }, timestamp: { "2026-06-06T00:00:00Z" })

        XCTAssertEqual(result.targetAgent, "claude")
        XCTAssertEqual(result.sessionId, "fixed-uuid")
        XCTAssertEqual(result.resumeCommand, "claude --resume fixed-uuid")
        XCTAssertEqual(result.messageCount, 3)
        XCTAssertNil(result.backup, "fresh target id — nothing to back up")
        XCTAssertEqual(
            result.path,
            SessionLocation.claudeSessionURL(
                home: home, workspace: workspace, sessionId: "fixed-uuid"))

        // The written Claude transcript round-trips the conversation.
        let written = try String(contentsOf: result.path, encoding: .utf8)
        let reread = ClaudeSession.read(jsonl: written)
        XCTAssertEqual(reread.workspace, workspace)
        XCTAssertEqual(reread.messages.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(reread.messages.map(\.role), [.user, .assistant, .user])
    }

    func testPicksNewestRolloutForWorkspaceIgnoringOtherWorkspaces() throws {
        let workspace = "/Users/kuki/proj"
        try writeRollout(
            workspace: workspace, datePath: "2026/06/01", id: "old",
            messages: [(.user, "stale")], modified: Date(timeIntervalSince1970: 1000))
        try writeRollout(
            workspace: workspace, datePath: "2026/06/06", id: "new",
            messages: [(.user, "fresh")], modified: Date(timeIntervalSince1970: 3000))
        // Newest overall, but a different project — must be skipped.
        try writeRollout(
            workspace: "/Users/kuki/other", datePath: "2026/06/07", id: "other",
            messages: [(.user, "nope")], modified: Date(timeIntervalSince1970: 9000))

        let located = try XCTUnwrap(
            SessionHandoff.latestCodexSession(home: home, workspace: workspace))
        XCTAssertEqual(located.lastPathComponent, "rollout-new.jsonl")

        let result = try SessionHandoff.codexToClaude(
            workspace: workspace, home: home, makeSessionId: { "u" }, timestamp: { "t" })
        XCTAssertEqual(
            ClaudeSession.read(jsonl: try String(contentsOf: result.path, encoding: .utf8))
                .messages.map(\.text), ["fresh"])
    }

    func testThrowsWhenNoSessionForWorkspace() {
        XCTAssertThrowsError(
            try SessionHandoff.codexToClaude(
                workspace: "/Users/kuki/proj", home: home,
                makeSessionId: { "u" }, timestamp: { "t" })
        ) { error in
            XCTAssertEqual(error as? SessionHandoff.Failure, .noSessionFound)
        }
    }

    // MARK: - Claude → Codex (reverse)

    /// Write a Claude transcript for `workspace` under its encoded project dir,
    /// stamped with `modified` so "newest" is deterministic.
    @discardableResult
    private func writeClaudeSession(
        workspace: String, id: String, model: String? = nil,
        messages: [(CanonicalMessage.Role, String)], modified: Date
    ) throws -> URL {
        let url = SessionLocation.claudeSessionURL(
            home: home, workspace: workspace, sessionId: id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = CanonicalSession(
            sourceAgent: "claude", workspace: workspace, model: model,
            messages: messages.map { CanonicalMessage(role: $0.0, text: $0.1) })
        let jsonl = ClaudeSession.write(
            session, options: .init(sessionId: id, cwd: workspace, timestamp: { "t" }))
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testClaudeToCodexWritesResumableCodexRollout() throws {
        let workspace = "/Users/kuki/proj"
        try writeClaudeSession(
            workspace: workspace, id: "claude-1", model: "claude-opus-4-7",
            messages: [(.user, "one"), (.assistant, "two"), (.user, "three")],
            modified: Date(timeIntervalSince1970: 2000))

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try SessionHandoff.claudeToCodex(
            workspace: workspace, home: home,
            makeSessionId: { "codex-uuid" }, now: { date })

        XCTAssertEqual(result.targetAgent, "codex")
        XCTAssertEqual(result.sessionId, "codex-uuid")
        XCTAssertEqual(result.resumeCommand, "codex resume codex-uuid")
        XCTAssertEqual(result.messageCount, 3)
        XCTAssertNil(result.backup, "fresh target id — nothing to back up")
        XCTAssertEqual(
            result.path,
            SessionLocation.codexRolloutURL(home: home, date: date, sessionId: "codex-uuid"))
        XCTAssertTrue(result.path.lastPathComponent.hasPrefix("rollout-"))
        XCTAssertTrue(result.path.lastPathComponent.hasSuffix("-codex-uuid.jsonl"))

        // The written rollout round-trips the conversation, model, and cwd.
        let reread = CodexSession.read(jsonl: try String(contentsOf: result.path, encoding: .utf8))
        XCTAssertEqual(reread.workspace, workspace)
        XCTAssertEqual(reread.model, "claude-opus-4-7")
        XCTAssertEqual(reread.messages.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(reread.messages.map(\.role), [.user, .assistant, .user])

        // …and carries the resumability fields Codex requires (PARSERS §3).
        let metaLine = try XCTUnwrap(
            try String(contentsOf: result.path, encoding: .utf8)
                .split(separator: "\n").map(String.init).first)
        let meta = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(metaLine.utf8)) as? [String: Any])
        let payload = try XCTUnwrap(meta["payload"] as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, "codex-uuid")
        XCTAssertEqual(payload["cwd"] as? String, workspace)
        XCTAssertNotNil(payload["timestamp"] as? String)
        XCTAssertEqual(payload["originator"] as? String, "vibeone")
        XCTAssertNotNil(payload["cli_version"] as? String)
    }

    func testClaudeToCodexPicksNewestClaudeSession() throws {
        let workspace = "/Users/kuki/proj"
        try writeClaudeSession(
            workspace: workspace, id: "old",
            messages: [(.user, "stale")], modified: Date(timeIntervalSince1970: 1000))
        try writeClaudeSession(
            workspace: workspace, id: "new",
            messages: [(.user, "fresh")], modified: Date(timeIntervalSince1970: 3000))

        let located = try XCTUnwrap(
            SessionHandoff.latestClaudeSession(home: home, workspace: workspace))
        XCTAssertEqual(located.lastPathComponent, "new.jsonl")

        let result = try SessionHandoff.claudeToCodex(
            workspace: workspace, home: home, makeSessionId: { "u" },
            now: { Date(timeIntervalSince1970: 0) })
        XCTAssertEqual(
            CodexSession.read(jsonl: try String(contentsOf: result.path, encoding: .utf8))
                .messages.map(\.text), ["fresh"])
    }

    func testClaudeToCodexThrowsWhenNoSessionForWorkspace() {
        XCTAssertThrowsError(
            try SessionHandoff.claudeToCodex(
                workspace: "/Users/kuki/proj", home: home,
                makeSessionId: { "u" }, now: { Date(timeIntervalSince1970: 0) })
        ) { error in
            XCTAssertEqual(error as? SessionHandoff.Failure, .noSessionFound)
        }
    }
}
