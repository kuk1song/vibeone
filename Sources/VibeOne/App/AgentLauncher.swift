import AppKit
import Foundation
import VibeOneEngine

/// Opens the *target* agent after a handoff, so the user lands in the just-written
/// session and keeps working — the "play actually takes me there" step.
///
/// Every direction opens for real; the mechanism differs by surface (ADR-009):
///   • Claude Code is a CLI — "open" = a terminal at the session's workspace
///     running the engine's `claude --resume <id>`.
///   • Codex leads with its Desktop app, so that is the default. A rollout written
///     outside Codex 26.715 is not auto-indexed, so VibeOne first registers it via
///     the bundled official `codex app-server` protocol, then routes to it with
///     `codex://threads/<uuid>` (ADR-009).
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

    @MainActor
    static func open(
        agent: Agent,
        sessionId: String,
        resumeCommand: String,
        workspace: String,
        codexMode: CodexMode = .desktop
    ) async -> Launch {
        switch agent {
        case .claude:
            let opened = runInTerminal(command: resumeCommand, workspace: workspace)
            return Launch(
                opened: opened,
                message: opened
                    ? "Resumed in Claude Code" : "Session written — run: \(resumeCommand)"
            )
        case .codex:
            // Defense-in-depth at the port boundary: the id feeds a URL and a
            // shell command, so refuse anything but the UUID the engine writes.
            guard UUID(uuidString: sessionId) != nil else {
                return Launch(opened: false, message: "Session written — unexpected session id")
            }
            switch codexMode {
            case .desktop:
                // A vanished project folder can't be registered as a workspace, so
                // the desktop dance would fail confusingly — say what happened.
                guard FileManager.default.fileExists(atPath: workspace) else {
                    return Launch(
                        opened: false, message: "Session written — project folder no longer exists")
                }
                switch await openDesktopThread(sessionId: sessionId) {
                case .opened:
                    return Launch(opened: true, message: "Opened in Codex")
                case .registrationFailed:
                    let command = codexResumeCommand(sessionId: sessionId)
                    return Launch(
                        opened: false,
                        message: "Session written — run: \(command)")
                case .failed:
                    return Launch(
                        opened: false,
                        message: "Session written — open: \(codexThreadURL(sessionId))")
                }
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

    private static let codexBundleId = "com.openai.codex"

    /// How long a cold Codex launch may take before we give up on the GUI open.
    private static let codexLaunchTimeout: TimeInterval = 30
    /// Whole-handshake limit for one short-lived app-server registration.
    private static let codexRegistrationTimeout: TimeInterval = 8
    /// `isFinishedLaunching` fires before the Electron renderer wires its deep-link
    /// handling; a link sent during boot gets its parameters dropped (observed
    /// live), so give a fresh launch a settling beat before the first link.
    private static let codexColdStartGrace: Duration = .seconds(4)
    /// How registration + GUI routing ended, for an honest one-liner.
    private enum DesktopOpen {
        case opened
        /// The rollout still exists, but Codex did not confirm registration. A
        /// by-id deep link is withheld because unknown ids can open a blank pane.
        case registrationFailed
        case failed
    }

    /// Route Codex Desktop to a handed-off thread. Registration happens before
    /// launching the GUI, so a cold start sees the new row on its first frame; on
    /// a hot app the same registration is valid without a restart (ADR-009).
    ///
    /// VibeOne talks only to the app-server process and never edits Codex's SQLite
    /// index. The by-id link is sent only after `thread/resume` returns the exact
    /// requested id.
    @MainActor
    private static func openDesktopThread(sessionId: String) async -> DesktopOpen {
        guard
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: codexBundleId)
        else {
            Log.switching.error("codex desktop: app bundle not found")
            return .failed
        }
        let bundledCodex = appURL.appendingPathComponent("Contents/Resources/codex")
        guard FileManager.default.isExecutableFile(atPath: bundledCodex.path) else {
            Log.switching.error("codex desktop: bundled codex executable not found")
            return .registrationFailed
        }

        let appVersion =
            (Bundle(url: appURL)?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
        let clientVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development"
        let command = CodexAppServerClient.Command(executableURL: bundledCodex)

        do {
            try await Task.detached(priority: .userInitiated) {
                try CodexAppServerClient.registerThread(
                    sessionId,
                    command: command,
                    clientVersion: clientVersion,
                    timeout: codexRegistrationTimeout)
            }.value
            Log.switching.notice(
                "codex desktop \(appVersion, privacy: .public): thread registered via app-server"
            )
        } catch {
            Log.switching.error(
                "codex desktop \(appVersion, privacy: .public): registration failed: \(error.localizedDescription, privacy: .public)"
            )
            return .registrationFailed
        }

        guard await ensureCodexRunning(appURL: appURL) else {
            Log.switching.error("codex desktop: app not running and could not be launched")
            return .failed
        }
        guard let url = URL(string: codexThreadURL(sessionId)) else { return .failed }
        let opened = NSWorkspace.shared.open(url)
        Log.switching.notice(
            "codex desktop: registered thread open-by-id \(opened ? "accepted" : "rejected", privacy: .public)"
        )
        return opened ? .opened : .failed
    }

    /// Make sure the Codex Desktop is running and past its boot phase — a deep
    /// link that itself triggers the launch arrives too early and loses its
    /// parameters, landing the user on the wrong project.
    @MainActor
    private static func ensureCodexRunning(appURL: URL) async -> Bool {
        let alreadyRunning =
            NSRunningApplication
            .runningApplications(withBundleIdentifier: codexBundleId).first
        if let alreadyRunning, alreadyRunning.isFinishedLaunching { return true }
        guard
            let app = try? await NSWorkspace.shared.openApplication(
                at: appURL, configuration: NSWorkspace.OpenConfiguration())
        else { return false }
        let deadline = Date().addingTimeInterval(codexLaunchTimeout)
        while !app.isFinishedLaunching && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard app.isFinishedLaunching else { return false }
        try? await Task.sleep(for: codexColdStartGrace)
        return true
    }

    /// `codex://threads/<uuid>` — the Codex Desktop deep link that opens a specific
    /// thread by its session UUID (developers.openai.com/codex/app/commands).
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
