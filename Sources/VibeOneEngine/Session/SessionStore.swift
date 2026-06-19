import Foundation

/// A **port** (ADR-007): the narrow interface the handoff core needs from "an
/// agent's on-disk sessions". One conforming **adapter** per agent
/// (`ClaudeSessionStore`, `CodexSessionStore`) hides that agent's undocumented,
/// version-volatile storage — so an upstream change is contained to one adapter
/// and never reaches the orchestration (`SessionHandoff`) or the canonical IR.
///
/// Only `read`/`write`/`latestSession`/`list` are polymorphic (what the generic
/// handoff and the project picker use); agent-specific extras (e.g. Claude's
/// `currentSession`) live on the concrete adapter, not the port.
public protocol SessionStore: Sendable {

    /// The agent this store speaks for: `"claude"` | `"codex"`.
    var agent: String { get }

    /// Newest session file recorded for `workspace`, or nil — the source-side
    /// locator for "hand off the latest session of this project".
    func latestSession(workspace: String) -> URL?

    /// Every session this agent has on disk, each attributed to its workspace and
    /// newest-first — the enumeration the project picker (B1) groups, superseding
    /// the "globally newest one" heuristic. Lightweight by contract: reads each
    /// file's mtime plus only the header prefix needed to recover its workspace and
    /// resume id, never a full IR parse. Sessions whose workspace can't be
    /// recovered are omitted (they can't be grouped or resumed).
    func list() -> [SessionSummary]

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

/// A lightweight, listable handle to one on-disk session — enough to group by
/// project, order by recency, and drive a handoff, without parsing the whole
/// transcript. Produced by `SessionStore.list`.
public struct SessionSummary: Equatable, Sendable, Identifiable {
    /// The agent that owns this session: `"claude"` | `"codex"`.
    public var agent: String
    /// The resume identifier (`claude --resume <id>` / `codex resume <id>`):
    /// Claude's transcript-file UUID, Codex's `session_meta.payload.id`.
    public var id: String
    /// Real project root — the transcript's recorded `cwd` — used to group by
    /// project. Never decoded from Claude's lossy dir name (PARSERS §1).
    public var workspace: String
    /// The session file, ready to hand off verbatim.
    public var path: URL
    /// File modification time — recency for ordering the picker.
    public var modified: Date
    /// True if VibeOne generated this session during a handoff (its file carries
    /// the `Provenance.vibeOne` mark; PARSERS §1/§3). Such copies stay listed and
    /// pickable, but are never the *default* handoff source — that stops a copy
    /// from being silently re-handed-off into an ever-growing echo (PR-F).
    /// Defaults false: an unmarked session is treated as the user's own.
    public var generatedByVibeOne: Bool

    public init(
        agent: String, id: String, workspace: String, path: URL, modified: Date,
        generatedByVibeOne: Bool = false
    ) {
        self.agent = agent
        self.id = id
        self.workspace = workspace
        self.path = path
        self.modified = modified
        self.generatedByVibeOne = generatedByVibeOne
    }
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
