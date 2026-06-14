import Foundation

/// A **port** (ADR-007): the narrow interface the handoff core needs from "an
/// agent's on-disk sessions". One conforming **adapter** per agent
/// (`ClaudeSessionStore`, `CodexSessionStore`) hides that agent's undocumented,
/// version-volatile storage — so an upstream change is contained to one adapter
/// and never reaches the orchestration (`SessionHandoff`) or the canonical IR.
///
/// Only `read`/`write`/`latestSession` are polymorphic (what the generic handoff
/// uses); agent-specific extras (e.g. Claude's `currentSession`) live on the
/// concrete adapter, not the port.
public protocol SessionStore: Sendable {

    /// The agent this store speaks for: `"claude"` | `"codex"`.
    var agent: String { get }

    /// Newest session file recorded for `workspace`, or nil — the source-side
    /// locator for "hand off the latest session of this project".
    func latestSession(workspace: String) -> URL?

    /// Parse a native session file into the canonical IR. Throws if the file can't
    /// be read, and — as defense-in-depth at this boundary (ADR-010) — throws
    /// `SessionReadError` rather than returning a silently-empty IR when no
    /// workspace or no conversation can be recovered (the signal of format drift).
    func read(_ url: URL) throws -> CanonicalSession

    /// Write `session` as a NEW native, resumable session identified by `sessionId`
    /// (a lowercased UUID), timestamped from `now`. The adapter owns the file
    /// layout, format, and crash-safe write. Invariant: only ever *creates* a new
    /// file — it never mutates an existing session.
    func write(_ session: CanonicalSession, sessionId: String, now: Date) throws -> WrittenSession
}

/// Where a handed-off session landed and how to resume it in the target agent.
public struct WrittenSession: Equatable, Sendable {
    public var sessionId: String
    public var path: URL
    /// Run from the session's workspace to continue it (e.g. `claude --resume <id>`).
    /// Claude scopes id lookup to the original cwd, so the *caller* must launch from
    /// `session.workspace` (PARSERS §1).
    public var resumeCommand: String
    /// Set only if an existing file was backed up first — normally nil, since the id
    /// is freshly generated so nothing is overwritten.
    public var backup: URL?

    public init(sessionId: String, path: URL, resumeCommand: String, backup: URL?) {
        self.sessionId = sessionId
        self.path = path
        self.resumeCommand = resumeCommand
        self.backup = backup
    }
}
