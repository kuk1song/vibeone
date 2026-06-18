import AppKit
import Foundation

/// Opens the *target* agent after a handoff, so the user lands in the just-written
/// session and keeps working — the "play actually takes me there" step.
///
/// Every direction opens for real; the mechanism differs by surface (ADR-009):
///   • Claude Code is a CLI — "open" = a terminal at the session's workspace
///     running the engine's `claude --resume <id>`.
///   • Codex leads with its Desktop app, so that is the default: the `codex://`
///     deep link routes the running Desktop straight to the handed-off thread by
///     id (verified — it opens an externally-written rollout, not a blank chat).
///   • Codex can also open in a terminal (`codex resume <id>`) for users who live
///     in the CLI; selectable via `CodexMode`.
///
/// The handoff only ever wrote a NEW target session, so opening it never disturbs
/// any existing/running conversation in either agent.
enum AgentLauncher {

    /// Where a Codex switch lands. Desktop (the `codex://` deep link) is the
    /// default because Codex's primary surface is its app; terminal mirrors the
    /// Claude direction for CLI users.
    enum CodexMode {
        case desktop
        case terminal
    }

    /// The outcome of an open attempt, surfaced to the popover as one honest line.
    struct Launch {
        var opened: Bool
        var message: String
    }

    static func open(
        agent: Agent,
        sessionId: String,
        resumeCommand: String,
        workspace: String,
        codexMode: CodexMode = .desktop
    ) -> Launch {
        switch agent {
        case .claude:
            let opened = runInTerminal(command: resumeCommand, workspace: workspace)
            return Launch(
                opened: opened,
                message: opened
                    ? "Resumed in Claude Code" : "Session written — run: \(resumeCommand)"
            )
        case .codex:
            switch codexMode {
            case .desktop:
                let opened = openDesktopThread(sessionId: sessionId)
                return Launch(
                    opened: opened,
                    message: opened
                        ? "Opened in Codex" : "Session written — open: \(codexThreadURL(sessionId))"
                )
            case .terminal:
                let command = codexResumeCommand(sessionId: sessionId)
                let opened = runInTerminal(command: command, workspace: workspace)
                return Launch(
                    opened: opened,
                    message: opened ? "Resumed in Codex" : "Session written — run: \(command)")
            }
        }
    }

    // MARK: - Codex Desktop (deep link)

    /// `codex://threads/<uuid>` — the Codex Desktop deep link that opens a specific
    /// thread by its session UUID (developers.openai.com/codex/app/commands). The
    /// running app handles the scheme, so this foregrounds the existing window
    /// without spawning anything or touching any other thread.
    private static func openDesktopThread(sessionId: String) -> Bool {
        guard let url = URL(string: codexThreadURL(sessionId)) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func codexThreadURL(_ sessionId: String) -> String { "codex://threads/\(sessionId)" }

    // MARK: - Codex terminal (resume)

    /// `codex resume <id>` against the real binary. `codex` is usually not on PATH
    /// (it ships inside Codex.app), so resolve the bundled binary first and fall
    /// back to a bare `codex` for users who installed the standalone CLI.
    static func codexResumeCommand(sessionId: String) -> String {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        {
            let bundled = app.appendingPathComponent("Contents/Resources/codex")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return "\(shellQuoted(bundled.path)) resume \(sessionId)"
            }
        }
        return "codex resume \(sessionId)"
    }

    // MARK: - Terminal

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
