import Foundation

/// Agent-neutral conversation — the pivot for session handoff:
/// `A.read → CanonicalSession → B.write`.
///
/// The authoritative field definition + the per-agent mapping + the fidelity
/// boundaries live in `local_notes/PARSERS.md`. v0 carries user/assistant text
/// (tool calls are deferred per PARSERS §4).
public struct CanonicalSession: Equatable, Sendable {
    public var sourceAgent: String  // "claude" | "codex"
    public var workspace: String  // cwd / project root
    public var model: String?
    public var messages: [CanonicalMessage]

    public init(
        sourceAgent: String,
        workspace: String,
        model: String? = nil,
        messages: [CanonicalMessage]
    ) {
        self.sourceAgent = sourceAgent
        self.workspace = workspace
        self.model = model
        self.messages = messages
    }
}

public struct CanonicalMessage: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user, assistant, tool
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}
