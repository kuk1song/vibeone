import Foundation

/// The "switch": take a project's in-flight conversation in one agent and write
/// it as a native, resumable session in the other (ARCHITECTURE §4.1).
///
/// This is the **domain core** (ADR-007): `handoff` orchestrates
/// `from.read → IR → to.write` against the `SessionStore` **port** and never
/// touches an agent's concrete storage format — the `ClaudeSessionStore` /
/// `CodexSessionStore` adapters do, so an upstream change is contained to one
/// adapter. The `codexToClaude` / `claudeToCodex` entry points are the thin
/// composition root that picks which adapter is source vs target.
///
/// "Hand off" (writing the file) is decoupled from launching the target surface:
/// `Result.resumeCommand` is the CLI form; opening a Desktop App / IDE is a
/// separate `AgentLauncher` step chosen by the caller (ARCHITECTURE §4.1,
/// ADR-009).
///
/// Invariant: the handoff only ever *creates* a new target session; it never
/// mutates the source file.
public enum SessionHandoff {

    /// What the caller (UI / CLI) needs to act on the switch.
    public struct Result: Equatable, Sendable {
        public var targetAgent: String
        public var sessionId: String
        public var path: URL
        /// Run from `workspace` to continue the conversation in the target agent.
        public var resumeCommand: String
        public var messageCount: Int
        /// Set only if an existing target was backed up first (normally nil — the
        /// target id is freshly generated, so nothing is overwritten).
        public var backup: URL?
    }

    public enum Failure: Error, Equatable {
        case noSessionFound
        case emptySession
    }

    /// A located session plus the real project path it belongs to — what the UI
    /// needs to display the project and drive the handoff.
    public struct CurrentSession: Equatable, Sendable {
        public var path: URL
        public var workspace: String

        public init(path: URL, workspace: String) {
            self.path = path
            self.workspace = workspace
        }
    }

    /// One project's sessions across both agents (each list newest-first) — the row
    /// the B1 picker renders. Supersedes "globally newest one" (`currentClaudeSession`).
    public struct ProjectSessions: Equatable, Sendable, Identifiable {
        public var workspace: String
        public var claude: [SessionSummary]
        public var codex: [SessionSummary]

        public var id: String { workspace }
        /// Most recent activity across both agents — drives project ordering.
        public var lastActive: Date { (claude + codex).map(\.modified).max() ?? .distantPast }

        public init(workspace: String, claude: [SessionSummary], codex: [SessionSummary]) {
            self.workspace = workspace
            self.claude = claude
            self.codex = codex
        }
    }

    // MARK: - Core (port-only orchestration)

    /// Convert one located session in `from` into a new resumable session in `to`.
    /// Pure orchestration over the `SessionStore` port — zero agent specifics.
    static func handoff(
        source: URL, from: SessionStore, to: SessionStore, sessionId: String, now: Date
    ) throws -> Result {
        let ir = try from.read(source)
        // Backstop: the built-in adapters already reject an empty parse at their
        // read boundary (SessionReadError, ADR-010); this keeps the invariant at
        // the orchestration layer too, for any SessionStore that doesn't validate.
        guard !ir.messages.isEmpty else { throw Failure.emptySession }
        let written = try to.write(ir, sessionId: sessionId, now: now)
        return Result(
            targetAgent: to.agent,
            sessionId: written.sessionId,
            path: written.path,
            resumeCommand: written.resumeCommand,
            messageCount: ir.messages.count,
            backup: written.backup)
    }

    // MARK: - Directions (composition root: which adapter is source vs target)

    /// Locate the most recent Codex rollout for `workspace`, convert it, and write
    /// a resumable Claude transcript under `~/.claude/projects/<encoded-cwd>/`.
    ///
    /// `source` is the exact rollout to hand off; when nil it falls back to the
    /// newest in `workspace`. Callers that already located the session (e.g. the
    /// picker, which lets the user choose a specific session) should pass it, so
    /// *that* conversation is handed off rather than whichever is newest by mtime —
    /// the symmetric counterpart of `claudeToCodex(source:)`.
    ///
    /// Generators are injected for deterministic tests; production uses real
    /// `UUID()` / `Date()`.
    public static func codexToClaude(
        workspace: String,
        source: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        makeSessionId: () -> String = { UUID().uuidString.lowercased() },
        now: () -> Date = { Date() }
    ) throws -> Result {
        let from = CodexSessionStore(home: home)
        let to = ClaudeSessionStore(home: home)
        guard let source = source ?? from.latestSession(workspace: workspace) else {
            throw Failure.noSessionFound
        }
        return try handoff(
            source: source, from: from, to: to, sessionId: makeSessionId(), now: now())
    }

    /// Locate the most recent Claude transcript for `workspace`, convert it, and
    /// write a resumable Codex rollout under `~/.codex/sessions/<YYYY>/<MM>/<DD>/`.
    /// The reverse of `codexToClaude`.
    ///
    /// `source` is the exact transcript to hand off; when nil it falls back to the
    /// newest in `workspace`. Callers that already located the session (e.g. via
    /// `currentClaudeSession`) should pass it — that path is exact, whereas finding
    /// by `workspace` round-trips through Claude's lossy dir encoding (every
    /// non-alphanumeric char maps to `-`, PARSERS §1), which only resolves for
    /// paths without such characters.
    public static func claudeToCodex(
        workspace: String,
        source: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        makeSessionId: () -> String = { UUID().uuidString.lowercased() },
        now: () -> Date = { Date() }
    ) throws -> Result {
        let from = ClaudeSessionStore(home: home)
        let to = CodexSessionStore(home: home)
        guard let source = source ?? from.latestSession(workspace: workspace) else {
            throw Failure.noSessionFound
        }
        return try handoff(
            source: source, from: from, to: to, sessionId: makeSessionId(), now: now())
    }

    // MARK: - Locators (thin wrappers over the adapters)

    /// Newest Claude transcript for `workspace`, or nil.
    public static func latestClaudeSession(home: URL, workspace: String) -> URL? {
        ClaudeSessionStore(home: home).latestSession(workspace: workspace)
    }

    /// Newest Codex rollout whose recorded cwd matches `workspace`, or nil.
    public static func latestCodexSession(home: URL, workspace: String) -> URL? {
        CodexSessionStore(home: home).latestSession(workspace: workspace)
    }

    /// The Claude session the user is most likely working in right now (globally
    /// newest transcript across all projects). See `ClaudeSessionStore.currentSession`.
    public static func currentClaudeSession(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CurrentSession? {
        ClaudeSessionStore(home: home).currentSession()
    }

    // MARK: - Enumeration (project picker)

    /// Every project that has a session in either agent, each carrying both agents'
    /// sessions (newest-first), projects ordered by most-recent activity. This is
    /// what the B1 picker renders — the user selects a project and a side, then
    /// drives `claudeToCodex` / `codexToClaude`. Supersedes `currentClaudeSession`'s
    /// "globally newest one".
    public static func projectSessions(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ProjectSessions] {
        // Both adapters return newest-first, so each filtered side stays ordered.
        let all = ClaudeSessionStore(home: home).list() + CodexSessionStore(home: home).list()
        return Dictionary(grouping: all, by: \.workspace)
            .map { workspace, sessions in
                ProjectSessions(
                    workspace: workspace,
                    claude: sessions.filter { $0.agent == "claude" },
                    codex: sessions.filter { $0.agent == "codex" })
            }
            .sorted {
                $0.lastActive != $1.lastActive
                    ? $0.lastActive > $1.lastActive : $0.workspace < $1.workspace
            }
    }
}
