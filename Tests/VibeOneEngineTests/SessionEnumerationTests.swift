import Foundation
import Testing

@testable import VibeOneEngine

// `SessionStore.list` enumerates every session per agent (attributed to its
// workspace), and `SessionHandoff.projectSessions` groups both agents by project —
// the data the B1 picker renders, superseding "globally newest one".
//
// Each test builds its own unique temp home with the *real* writers, so the
// fixtures carry genuine headers (Claude's per-line `cwd`, Codex's `session_meta`)
// — the same bytes `list` must peek at. Unique homes keep this safe under Swift
// Testing's default parallelism (no `.serialized`).

// MARK: - Temp-home fixture builders

private func makeTempHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibeone-enum-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@discardableResult
private func writeClaude(
    home: URL, workspace: String, id: String,
    messages: [(CanonicalMessage.Role, String)] = [(.user, "hi")], modified: Date
) throws -> URL {
    let url = SessionLocation.claudeSessionURL(home: home, workspace: workspace, sessionId: id)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let session = CanonicalSession(
        sourceAgent: "claude", workspace: workspace,
        messages: messages.map { CanonicalMessage(role: $0.0, text: $0.1) })
    let jsonl = ClaudeSession.write(
        session, options: .init(sessionId: id, cwd: workspace, timestamp: { "t" }))
    try jsonl.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

@discardableResult
private func writeCodex(
    home: URL, workspace: String, id: String, date: Date,
    messages: [(CanonicalMessage.Role, String)] = [(.user, "hi")], modified: Date
) throws -> URL {
    let url = SessionLocation.codexRolloutURL(home: home, date: date, sessionId: id)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let session = CanonicalSession(
        sourceAgent: "codex", workspace: workspace, model: "gpt-5.4",
        messages: messages.map { CanonicalMessage(role: $0.0, text: $0.1) })
    let jsonl = CodexSession.write(
        session, options: .init(sessionId: id, cwd: workspace, timestamp: { "t" }))
    try jsonl.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

// MARK: - Claude enumeration

@Suite("Claude session enumeration")
struct ClaudeListTests {

    @Test("lists every transcript across projects, newest first")
    func listsAllNewestFirst() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaude(home: home, workspace: "/Users/kuki/proj-a", id: "a1", modified: at(1000))
        try writeClaude(home: home, workspace: "/Users/kuki/proj-a", id: "a2", modified: at(3000))
        try writeClaude(home: home, workspace: "/Users/kuki/proj-b", id: "b1", modified: at(2000))

        let list = ClaudeSessionStore(home: home).list()

        #expect(list.map(\.id) == ["a2", "b1", "a1"])  // newest mtime first
        #expect(list.allSatisfy { $0.agent == "claude" })
        #expect(
            Dictionary(grouping: list, by: \.id).mapValues { $0[0].workspace } == [
                "a1": "/Users/kuki/proj-a", "a2": "/Users/kuki/proj-a", "b1": "/Users/kuki/proj-b",
            ])
        #expect(list.allSatisfy { $0.path.lastPathComponent == "\($0.id).jsonl" })
    }

    @Test("recovers workspace from the transcript cwd, not the lossy dir name")
    func recoversWorkspaceFromCwd() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A path with a dash: decoding the encoded dir name would be ambiguous.
        try writeClaude(home: home, workspace: "/Users/kuki/slash-stage", id: "x", modified: at(1))

        let list = ClaudeSessionStore(home: home).list()
        #expect(list.count == 1)
        #expect(list.first?.workspace == "/Users/kuki/slash-stage")
    }

    @Test("skips a project dir whose transcripts carry no recoverable cwd")
    func skipsDirWithoutCwd() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = SessionLocation.claudeProjectsDir(home: home)
            .appendingPathComponent("-bogus", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"type":"queue-operation"}"#.write(
            to: dir.appendingPathComponent("z.jsonl"), atomically: true, encoding: .utf8)

        #expect(ClaudeSessionStore(home: home).list().isEmpty)
    }

    @Test("empty when there is no projects dir")
    func emptyWhenNoStore() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ClaudeSessionStore(home: home).list().isEmpty)
    }
}

// MARK: - Codex enumeration

@Suite("Codex session enumeration")
struct CodexListTests {

    @Test("lists every rollout with its resume id and cwd, newest first")
    func listsAllNewestFirst() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCodex(
            home: home, workspace: "/Users/kuki/proj-a", id: "c-old",
            date: at(0), modified: at(1000))
        try writeCodex(
            home: home, workspace: "/Users/kuki/proj-b", id: "c-new",
            date: at(0), modified: at(3000))

        let list = CodexSessionStore(home: home).list()

        #expect(list.map(\.id) == ["c-new", "c-old"])
        #expect(list.allSatisfy { $0.agent == "codex" })
        #expect(list.first?.workspace == "/Users/kuki/proj-b")
        #expect(list.last?.workspace == "/Users/kuki/proj-a")
    }

    @Test("skips a rollout whose first line is not a session_meta")
    func skipsNonMeta() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = SessionLocation.codexSessionsDir(home: home)
            .appendingPathComponent("2026/06/06", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"type":"response_item"}"#.write(
            to: dir.appendingPathComponent("rollout-bogus.jsonl"), atomically: true, encoding: .utf8
        )

        #expect(CodexSessionStore(home: home).list().isEmpty)
    }

    @Test("empty when there is no sessions dir")
    func emptyWhenNoStore() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CodexSessionStore(home: home).list().isEmpty)
    }
}

// MARK: - Cross-agent grouping (composition root)

@Suite("Project grouping across both agents")
struct ProjectSessionsTests {

    @Test("groups both agents by project, ordered by most-recent activity")
    func groupsByProjectOrderedByActivity() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // proj-a: a Claude + a Codex session; proj-b: only Claude (newer overall).
        try writeClaude(home: home, workspace: "/Users/kuki/proj-a", id: "a-cl", modified: at(1000))
        try writeCodex(
            home: home, workspace: "/Users/kuki/proj-a", id: "a-cx", date: at(0), modified: at(2000)
        )
        try writeClaude(home: home, workspace: "/Users/kuki/proj-b", id: "b-cl", modified: at(5000))

        let projects = SessionHandoff.projectSessions(home: home)

        #expect(projects.map(\.workspace) == ["/Users/kuki/proj-b", "/Users/kuki/proj-a"])

        let a = try #require(projects.first { $0.workspace == "/Users/kuki/proj-a" })
        #expect(a.claude.map(\.id) == ["a-cl"])
        #expect(a.codex.map(\.id) == ["a-cx"])

        let b = try #require(projects.first { $0.workspace == "/Users/kuki/proj-b" })
        #expect(b.claude.map(\.id) == ["b-cl"])
        #expect(b.codex.isEmpty)
        #expect(b.lastActive == at(5000))
    }

    @Test("each side is sorted newest-first within a project")
    func sidesSortedNewestFirst() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ws = "/Users/kuki/proj"
        try writeClaude(home: home, workspace: ws, id: "older", modified: at(1000))
        try writeClaude(home: home, workspace: ws, id: "newer", modified: at(4000))

        let projects = SessionHandoff.projectSessions(home: home)
        let p = try #require(projects.first)
        #expect(p.claude.map(\.id) == ["newer", "older"])
    }

    @Test("empty on a home with no sessions at all")
    func emptyHome() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(SessionHandoff.projectSessions(home: home).isEmpty)
    }

    @Test("hides workspaces matched by the safety deny-list")
    func excludesDeniedWorkspaces() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A session inside a denied tree and one outside it.
        try writeClaude(home: home, workspace: "/Users/dev/ot/secret", id: "ot", modified: at(3000))
        try writeClaude(home: home, workspace: "/Users/dev/proj", id: "ok", modified: at(2000))

        let denied = PathGuard(deniedPaths: ["/Users/dev/ot"], home: home)
        let projects = SessionHandoff.projectSessions(home: home, excluding: denied)

        #expect(projects.map(\.workspace) == ["/Users/dev/proj"])  // ot tree gone
    }
}

// MARK: - Real-data smoke (opportunistic)

@Suite("Project enumeration — real on-disk data")
struct ProjectSessionsRealDataTests {

    /// Read-only proof against this machine's real `~/.claude` + `~/.codex`: every
    /// surfaced summary must point at an existing file with an absolute workspace.
    /// Skips on a machine with no sessions (never a failure — that's the canary's job).
    @Test(
        "projectSessions on real data is internally consistent",
        .enabled(if: !RealData.claudeSessionFiles.isEmpty || !RealData.codexRolloutFiles.isEmpty))
    func realDataConsistent() {
        let projects = SessionHandoff.projectSessions()
        #expect(!projects.isEmpty)
        for project in projects {
            #expect(project.workspace.hasPrefix("/"))
            for summary in project.claude + project.codex {
                #expect(summary.workspace == project.workspace)
                #expect(!summary.id.isEmpty)
                #expect(FileManager.default.fileExists(atPath: summary.path.path))
            }
        }
    }
}
