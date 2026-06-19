import Foundation

/// VibeOne stamps every session it generates during a handoff, so the picker can
/// tell its own copies apart from the user's real work (PR-F).
///
/// A handoff *copies* a conversation into the other agent's format; that copy is a
/// real, resumable session and rightly appears in the picker. Without a mark it
/// would also be offered as a handoff *source* — and since it is the newest file
/// right after a switch, the default ▶ would hand the copy straight back, growing
/// an echo of copies-of-copies (observed during PR-C testing).
///
/// The mark lets the app keep generated copies **visible and pickable** while
/// never choosing one as the *default* source. It is provenance only — it never
/// changes how a session is parsed or resumed.
public enum Provenance {
    /// The provenance value VibeOne writes. Codex carries it natively in
    /// `session_meta.payload.originator` (a free string Codex requires to accept a
    /// rollout, PARSERS §3); Claude has no such field, so VibeOne adds the same
    /// `originator` key as additive top-level metadata on each line — Claude's
    /// JSONL already carries ~20 version-varying top-level keys and ignores unknown
    /// ones (PARSERS §1).
    public static let vibeOne = "vibeone"

    /// The top-level key VibeOne adds to each Claude transcript line to record
    /// provenance (Codex records it under `session_meta.payload.originator`).
    static let claudeKey = "originator"
}
