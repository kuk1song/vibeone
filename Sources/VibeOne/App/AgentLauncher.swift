import AppKit
import Foundation
import SQLite3

/// Opens the *target* agent after a handoff, so the user lands in the just-written
/// session and keeps working — the "play actually takes me there" step.
///
/// Every direction opens for real; the mechanism differs by surface (ADR-009):
///   • Claude Code is a CLI — "open" = a terminal at the session's workspace
///     running the engine's `claude --resume <id>`.
///   • Codex leads with its Desktop app, so that is the default. The Desktop only
///     lists threads of projects it has been introduced to, and its by-id deep
///     link only opens threads already visible — so the open is a three-step
///     dance (each step verified live, 2026-07): make sure the app is running
///     (a booting app drops deep-link parameters), register the workspace via
///     the supported `codex://threads/new?path=` link if it is new to Codex,
///     then route to the handed-off thread with `codex://threads/<uuid>`.
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
                switch await openDesktopThread(sessionId: sessionId, workspace: workspace) {
                case .opened:
                    return Launch(opened: true, message: "Opened in Codex")
                case .notIndexed:
                    // Codex 26.623 only scans externally-written sessions at
                    // launch — while it's running, a fresh handoff stays
                    // invisible until the next restart (verified live).
                    return Launch(
                        opened: false,
                        message: "Session written — Codex will show it after its next restart")
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
    /// `isFinishedLaunching` fires before the Electron renderer wires its deep-link
    /// handling; a link sent during boot gets its parameters dropped (observed
    /// live), so give a fresh launch a settling beat before the first link.
    private static let codexColdStartGrace: Duration = .seconds(4)
    /// A fresh workspace registration needs a moment before the by-id link can
    /// see the thread it just surfaced.
    private static let codexRegisterSettle: Duration = .seconds(2)
    /// How long to wait for Codex to index a just-written rollout. Indexing is
    /// usually near-instant but can stall entirely (observed live: files still
    /// unindexed after 6 minutes) — after this, fail honestly instead.
    private static let codexIndexTimeout: TimeInterval = 12

    /// How the desktop dance ended, for an honest one-liner.
    private enum DesktopOpen {
        case opened
        /// Written + registered, but Codex never indexed the new thread — the
        /// by-id link would wedge the app on a blank pane, so it was not sent.
        case notIndexed
        case failed
    }

    /// Route the Codex Desktop to the handed-off thread. The by-id deep link only
    /// works for a thread the app already shows, and the app only shows threads of
    /// projects it knows (ADR-009) — so: ensure the app is up, introduce the
    /// workspace through the supported `threads/new?path=` link, then open the
    /// thread. Never touches any other thread or Codex's own state files.
    ///
    /// The workspace is introduced UNCONDITIONALLY: Codex's own record of known
    /// projects (`.codex-global-state.json`) is flushed lazily and drops projects
    /// the user removed, so any read-only pre-check can go stale in both
    /// directions — while re-introducing a known project is harmless (the by-id
    /// link lands on the thread regardless; verified live). Reliability beats the
    /// brief new-chat composer flash.
    @MainActor
    private static func openDesktopThread(sessionId: String, workspace: String) async -> DesktopOpen
    {
        guard await ensureCodexRunning() else {
            Log.switching.error("codex desktop: app not running and could not be launched")
            return .failed
        }
        guard let register = codexNewThreadURL(path: workspace),
            NSWorkspace.shared.open(register)
        else {
            Log.switching.error("codex desktop: workspace registration link was rejected")
            return .failed
        }
        // Codex indexes an externally-written rollout asynchronously, and the
        // by-id link only works for a thread it knows — linking earlier wedges
        // the app on a blank pane (observed live). Wait for the index entry.
        guard await waitForCodexIndex(sessionId: sessionId) else {
            Log.switching.error("codex desktop: thread not indexed in time, by-id link withheld")
            return .notIndexed
        }
        try? await Task.sleep(for: codexRegisterSettle)
        guard let url = URL(string: codexThreadURL(sessionId)) else { return .failed }
        let opened = NSWorkspace.shared.open(url)
        Log.switching.info(
            "codex desktop: thread indexed, open-by-id \(opened ? "accepted" : "rejected", privacy: .public)"
        )
        return opened ? .opened : .failed
    }

    /// Poll Codex's thread index until `sessionId` appears, up to
    /// `codexIndexTimeout`. Read-only: VibeOne never writes Codex's database.
    @MainActor
    private static func waitForCodexIndex(sessionId: String) async -> Bool {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path
        let deadline = Date().addingTimeInterval(codexIndexTimeout)
        while true {
            if codexIndexHasThread(sessionId, dbPath: db) { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// One read-only lookup in Codex's thread index (`~/.codex/state_5.sqlite`,
    /// system SQLite — no dependency). Any failure (file moved, schema changed,
    /// locked) reads as "not indexed": the caller then fails honestly instead of
    /// sending Codex a link to an id it doesn't know.
    ///
    /// Two open modes, because the database alternates between two states: while
    /// Codex holds it open in WAL mode a plain read-only open works; once Codex
    /// checkpoints and closes it (observed after its 26.623 update) the WAL
    /// sidecars are gone and a read-only open fails at prepare — the immutable
    /// URI mode reads that closed state fine.
    private static func codexIndexHasThread(_ sessionId: String, dbPath: String) -> Bool {
        if let hit = indexLookup(sessionId, path: dbPath, flags: SQLITE_OPEN_READONLY) {
            return hit
        }
        let uri = "file:\(dbPath)?immutable=1"
        return indexLookup(sessionId, path: uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            ?? false
    }

    /// Returns nil when the database can't be opened/queried in this mode.
    private static func indexLookup(_ sessionId: String, path: String, flags: Int32) -> Bool? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT 1 FROM threads WHERE id = ?1 LIMIT 1", -1, &statement, nil)
                == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionId, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Make sure the Codex Desktop is running and past its boot phase — a deep
    /// link that itself triggers the launch arrives too early and loses its
    /// parameters, landing the user on the wrong project.
    @MainActor
    private static func ensureCodexRunning() async -> Bool {
        let alreadyRunning =
            NSRunningApplication
            .runningApplications(withBundleIdentifier: codexBundleId).first
        if let alreadyRunning, alreadyRunning.isFinishedLaunching { return true }
        guard
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: codexBundleId),
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

    /// `codex://threads/new?path=<dir>` — the one supported way to introduce a
    /// folder to the Desktop from outside; it registers the workspace root (which
    /// surfaces every same-cwd thread, including ours) and opens a new-chat
    /// composer, which the follow-up by-id link immediately replaces.
    private static func codexNewThreadURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
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
