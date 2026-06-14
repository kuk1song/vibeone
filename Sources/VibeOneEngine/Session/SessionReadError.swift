import Foundation

/// Raised at a `SessionStore.read` boundary (ADR-007 / ADR-010 defense-in-depth)
/// when a file is reachable but does NOT structurally parse into a usable
/// session. The codecs are deliberately tolerant (they skip lines they don't
/// understand), so without this guard an upstream format change would surface as
/// a silently-empty `CanonicalSession` far from its cause. Throwing here — with
/// the agent and the file path — turns that silent failure into a loud, located
/// one: the forensic record a caller (or a failing test) needs to pinpoint drift.
public enum SessionReadError: Error, Equatable, CustomStringConvertible {

    /// No `cwd` could be recovered (Claude's per-line `cwd` / Codex's
    /// `session_meta.cwd`): the file isn't a recognizable session, or the field
    /// that carries the workspace moved/renamed upstream.
    case missingWorkspace(agent: String, url: URL)

    /// A workspace was found but no conversation parsed: an empty session, or the
    /// per-message line shape drifted (e.g. a renamed `response_item` / role key).
    case noMessages(agent: String, url: URL)

    public var description: String {
        switch self {
        case .missingWorkspace(let agent, let url):
            return
                "[\(agent)] read \(url.path): no workspace (cwd) recovered — not a recognizable "
                + "session or the cwd field drifted (see PARSERS.md)"
        case .noMessages(let agent, let url):
            return
                "[\(agent)] read \(url.path): no conversation parsed — empty session or the "
                + "per-message format drifted (see PARSERS.md)"
        }
    }
}

extension CanonicalSession {

    /// Boundary check for the adapters' `read` (ADR-010): promote a degenerate
    /// parse to a typed, located error instead of returning a silently-empty IR.
    /// `agent`/`source` are threaded into the error so the failure names itself.
    func validated(agent: String, source: URL) throws -> CanonicalSession {
        guard !workspace.isEmpty else {
            throw SessionReadError.missingWorkspace(agent: agent, url: source)
        }
        guard !messages.isEmpty else {
            throw SessionReadError.noMessages(agent: agent, url: source)
        }
        return self
    }
}
