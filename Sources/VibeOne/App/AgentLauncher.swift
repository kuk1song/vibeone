import AppKit
import Foundation

/// Opens the *target* agent after a handoff, so the user lands in the just-written
/// session and keeps working — the "play actually takes me there" step.
///
/// Direction-asymmetric by necessity (ADR-009), and honest about it:
///   • Claude Code is a CLI — "open" = a terminal at the session's workspace
///     running the engine's `claude --resume <id>`. The session resumes for real.
///   • Codex here is the Desktop app (there is no `codex` CLI on PATH). Landing in
///     the exact thread needs the app-server bridge, which is not wired yet — so
///     we do NOT fake it: the rollout is written and resumable, and we say so.
enum AgentLauncher {

    /// The outcome of an open attempt, surfaced to the popover as one honest line.
    struct Launch {
        var opened: Bool
        var message: String
    }

    static func open(agent: Agent, command: String, workspace: String) -> Launch {
        switch agent {
        case .claude:
            let opened = runInTerminal(command: command, workspace: workspace)
            return Launch(
                opened: opened,
                message: opened ? "Resumed in Claude Code" : "Session written — run: \(command)")
        case .codex:
            // The rollout is written & resumable; auto-landing in the Codex Desktop
            // thread is the next step (app-server). Don't claim more than is true.
            return Launch(opened: false, message: "Handed off to Codex — open pending")
        }
    }

    /// Open a terminal at `workspace` running `command`, via a throwaway `.command`
    /// script launched through its default handler (normally Terminal.app). Using
    /// the file handler avoids an AppleScript automation prompt; the terminal of
    /// choice is configurable later.
    private static func runInTerminal(command: String, workspace: String) -> Bool {
        let script = """
            #!/bin/zsh
            cd \(shellQuoted(workspace)) || exit 1
            exec \(command)
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeone-resume-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
            return NSWorkspace.shared.open(url)
        } catch {
            return false
        }
    }

    /// POSIX single-quote a path so spaces and metacharacters survive the shell.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
