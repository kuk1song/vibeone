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

    // MARK: - Core (port-only orchestration)

    /// Convert one located session in `from` into a new resumable session in `to`.
    /// Pure orchestration over the `SessionStore` port — zero agent specifics.
    static func handoff(
        source: URL, from: SessionStore, to: SessionStore, sessionId: String, now: Date
    ) throws -> Result {
        let ir = try from.read(source)
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
    /// Generators are injected for deterministic tests; production uses real
    /// `UUID()` / `Date()`.
    public static func codexToClaude(
        workspace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        makeSessionId: () -> String = { UUID().uuidString.lowercased() },
        now: () -> Date = { Date() }
    ) throws -> Result {
        let from = CodexSessionStore(home: home)
        let to = ClaudeSessionStore(home: home)
        guard let source = from.latestSession(workspace: workspace) else {
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
}
