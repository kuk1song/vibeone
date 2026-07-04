import AppKit
import SwiftUI
import VibeOneEngine

/// Shared, observable state behind the popover (and the menu-bar icon tint).
///
/// The popover is a session switcher shaped like an album player (ADR-006 visual,
/// ADR-008 / ADR-011 interaction): each project is an album, its Claude/Codex
/// sessions are the two sides, and `selection` is the *cued destination* — the
/// agent the user would switch INTO. Cueing never switches; the switch only
/// happens when the user presses play (`activate`).
@MainActor
final class AppState: ObservableObject {
    /// The cued destination agent: drives BOTH the cover tint and the menu-bar glyph.
    @Published var selection: Agent = .claude

    /// Real `command -v claude/codex` result, filled in by a background probe.
    @Published var availability = AgentDetector.Availability(
        claudeInstalled: false, codexInstalled: false)

    /// Every project with a session in either agent, newest-active first — the
    /// albums the picker lists (empty until `refresh()` completes).
    @Published var projects: [SessionHandoff.ProjectSessions] = []

    /// Which album (project) is showing.
    @Published var albumIndex = 0

    /// An exact session the user picked from the queue, handed off verbatim. Nil
    /// means "the newest session on the source side" (the ⏮ / ⏭ default).
    @Published var pinnedSource: SessionSummary?

    /// Whether the pull-up queue (session selection) is showing.
    @Published var queueOpen = false

    /// Whether the pull-up settings panel (under ⋯) is showing.
    @Published var settingsOpen = false

    /// Read-only config drift (memory / skills / MCP) for the current album.
    @Published var configStatus: ConfigStatus?

    /// How a Codex switch opens: the Desktop app (the `codex://` deep link —
    /// default, since Codex's primary surface is its app) or a terminal `codex
    /// resume`. Toggled inline in the player (Codex-only) and in Settings; persisted
    /// across launches.
    @Published var codexOpensDesktop: Bool {
        didSet { UserDefaults.standard.set(codexOpensDesktop, forKey: Self.codexDesktopKey) }
    }

    /// True while a switch is in flight (guards against a double-launch).
    @Published var isLaunching = false

    /// True while a manual full ‹Sync› is in flight (guards the button).
    @Published var isSyncing = false

    /// Transient one-line outcome of the last switch (success or failure).
    @Published var feedback: String?

    /// Reference-time of the last ▶ press — the face watches this to play its brief
    /// happy reaction so a switch feels alive (set on press, ignored after the beat).
    @Published var reactionStart: Double?

    /// Folders VibeOne must never touch (ADR-012): hidden from the picker AND
    /// hard-rejected at switch time (defense-in-depth). User-editable in Settings —
    /// add via a folder picker, remove with an inline confirm. Persisted across
    /// launches; the first launch seeds the work tree (`~/ot`) as a starting guard
    /// the user can keep, extend, or remove. Editing only ever changes this LIST —
    /// VibeOne never reads, writes, moves, or deletes anything inside the folders.
    @Published var protectedPaths: [String] {
        didSet {
            // The render-harness instance (autoload: false) is inert: mutating its
            // seeded list must not persist to this machine's prefs or rebuild/refresh.
            guard autoload else { return }
            UserDefaults.standard.set(protectedPaths, forKey: Self.protectedPathsKey)
            rebuildGuard()
        }
    }

    private let home: URL
    private let autoload: Bool
    /// Rebuilt whenever `protectedPaths` changes, so edits take effect immediately.
    private var pathGuard: PathGuard
    /// Monotonic stamps so detached work can tell it has been superseded.
    /// `scanGeneration` guards session enumeration (a slow old scan must not
    /// publish over a newer one) and the post-switch auto-close (a reopened
    /// popover refreshes, and a switch from before that must not steal it);
    /// `configGeneration` orders per-album config reads across album changes.
    private var scanGeneration = 0
    private var configGeneration = 0
    private static let codexDesktopKey = "codexOpensDesktop"
    private static let protectedPathsKey = "protectedPaths"
    /// First-launch seed: guard the work tree until the user decides otherwise.
    private static let defaultProtectedPaths = ["~/ot"]

    /// `autoload: false` builds an inert instance (no disk / shell / persistence
    /// side effects) for the render harness, which seeds the published state directly.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, autoload: Bool = true) {
        self.home = home
        self.autoload = autoload
        // Absent key = first launch → seed the preset. An explicitly emptied list is
        // stored as [] and respected (the user may remove every entry, ~/ot included).
        let stored = UserDefaults.standard.array(forKey: Self.protectedPathsKey) as? [String]
        let paths = stored ?? Self.defaultProtectedPaths
        self.protectedPaths = paths
        self.pathGuard = PathGuard(deniedPaths: paths, home: home)
        self.codexOpensDesktop =
            UserDefaults.standard.object(forKey: Self.codexDesktopKey) as? Bool ?? true
        guard autoload else { return }
        // Each probe spawns a short-lived shell / scans disk — off the main thread,
        // publishing on the main actor so the menu bar appears instantly.
        Task.detached(priority: .userInitiated) {
            let result = AgentDetector.detect()
            await MainActor.run { self.availability = result }
        }
        refresh()
    }

    // MARK: - Derived

    /// The album currently in view, if any.
    var album: SessionHandoff.ProjectSessions? {
        projects.indices.contains(albumIndex) ? projects[albumIndex] : nil
    }

    /// The session that would be handed off: the user's exact pick, else the
    /// newest session on the side OPPOSITE the cued destination — you switch FROM
    /// the other agent INTO `selection`.
    ///
    /// The default skips VibeOne's own handoff copies (it prefers the user's most
    /// recent real session), so pressing ▶ right after a switch never hands a copy
    /// straight back. A copy is still reachable — explicitly pick it from the queue
    /// to switch work you continued inside a handed-off session back (PR-F).
    var source: SessionSummary? {
        if let pinnedSource { return pinnedSource }
        guard let album else { return nil }
        let candidates = selection == .codex ? album.claude : album.codex
        return candidates.first { !$0.generatedByVibeOne } ?? candidates.first
    }

    /// Play is possible only with a real source session and no switch in flight.
    var canSwitch: Bool { source != nil && !isLaunching }

    /// The current album's project name, or an empty-state hint.
    var projectName: String {
        album.map { URL(fileURLWithPath: $0.workspace).lastPathComponent } ?? "no sessions"
    }

    // MARK: - Loading

    /// Re-enumerate sessions and read the current album's config drift. Disk reads
    /// run off the main thread; results publish on the main actor.
    func refresh() {
        guard autoload else { return }  // inert render-harness instance: keep seeded state
        scanGeneration += 1
        let gen = scanGeneration
        let home = home
        let exclusions = pathGuard
        Task.detached(priority: .userInitiated) {
            let projects = SessionHandoff.projectSessions(home: home, excluding: exclusions)
            await MainActor.run {
                guard self.scanGeneration == gen else { return }  // superseded by a newer scan
                self.projects = projects
                // Land on the most recently active project — the one the user is
                // working in right now. A kept index would point at an effectively
                // random album, because the newest-first order shifts between opens.
                self.albumIndex = 0
                self.pinnedSource = nil
                // Re-opening the popover is a fresh start: drop any leftover "Opened
                // in …" line from the switch that just auto-closed it.
                self.feedback = nil
                // Default cue: switch AWAY from the album's most recent agent.
                if let album = self.album { self.selection = album.latestAgent.other }
                self.loadConfig()
            }
        }
    }

    /// Read the current album's `ConfigStatus` off the main thread.
    private func loadConfig() {
        guard let workspace = album?.workspace else {
            configStatus = nil
            return
        }
        configGeneration += 1
        let gen = configGeneration
        let home = home
        Task.detached(priority: .userInitiated) {
            let status = ConfigStatus.read(workspace: workspace, home: home)
            await MainActor.run {
                guard self.configGeneration == gen else { return }  // album changed again
                self.configStatus = status
            }
        }
    }

    // MARK: - Protected folders (deny-list editor, ADR-012)

    /// Add a folder to the never-touch list via the system folder picker. Records
    /// only the chosen PATH — VibeOne never opens, reads, or modifies the folder; it
    /// just learns to avoid it. A duplicate is ignored.
    func addProtectedFolder() {
        // Deterministic open→pick→reopen sequence. We CLOSE the popover ourselves
        // first (the normal toggle path, which reliably syncs the status item to
        // `.off`) rather than letting the modal hide it behind our back — that desync
        // is what made a `.state`-gated reopen a coin flip (observed live: reopen saw
        // `.on` and skipped on ~half the adds). With a known-closed baseline, the
        // post-pick reopen lands every time.
        MenuBarPopover.dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))  // let the close settle
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Protect"
            panel.message = "Choose a folder VibeOne must never read or write."
            // A STANDALONE app-modal panel (not a sheet on the popover): a sheet on an
            // auto-hiding popover gets orphaned — and wedges the app — when the popover
            // hides. App-modal is robust: clicking outside it only beeps, never orphans.
            let response = panel.runModal()
            self.adoptPickedFolder(response, url: panel.url)
            try? await Task.sleep(for: .milliseconds(120))
            MenuBarPopover.reopen()
        }
    }

    /// Record a folder the user chose in the picker. Only the PATH is stored — the
    /// folder itself is never opened, read, or modified. A duplicate is ignored.
    private func adoptPickedFolder(_ response: NSApplication.ModalResponse, url: URL?) {
        guard response == .OK, let url else { return }
        let entry = displayPath(for: url)
        guard !protectedPaths.contains(entry) else { return }
        protectedPaths.append(entry)
    }

    /// Remove an entry from the never-touch list. This only changes which paths
    /// VibeOne avoids — it never touches the folder's contents. The caller confirms
    /// first, since removing one widens what a future switch may write to.
    func removeProtectedFolder(_ entry: String) {
        protectedPaths.removeAll { $0 == entry }
    }

    /// Rebuild the in-memory guard from the current list and re-enumerate, so an
    /// added folder disappears from the picker at once (and a removed one returns).
    /// Touches only the guard and the session list — never the folders' contents.
    private func rebuildGuard() {
        pathGuard = PathGuard(deniedPaths: protectedPaths, home: home)
        refresh()
    }

    /// Collapse the home prefix to `~` so entries stay tidy and match the `~/ot`
    /// preset; `PathGuard` canonicalizes both forms identically, so this is display
    /// only and never changes what gets guarded.
    private func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == home.path { return "~" }
        let prefix = home.path + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    // MARK: - Cueing (selection only — never a switch, per ADR-008)

    /// ⏮ / ⏭ — flip the cued destination between Claude and Codex.
    func flip() {
        selection = selection.other
        pinnedSource = nil
        feedback = nil
    }

    /// The inline Codex mode key (Desktop ⇄ Terminal). Only meaningful when the
    /// destination is Codex; Claude always opens in a terminal.
    func toggleCodexMode() {
        codexOpensDesktop.toggle()
    }

    /// Pick an exact session from the queue: jump to its project, cue the OTHER
    /// agent as the destination, and remember the exact session to hand off.
    func pick(_ summary: SessionSummary) {
        if let idx = projects.firstIndex(where: { $0.workspace == summary.workspace }),
            idx != albumIndex
        {
            albumIndex = idx
            loadConfig()
        }
        selection = (Agent(rawValue: summary.agent) ?? .claude).other
        pinnedSource = summary
        queueOpen = false
        feedback = nil
    }

    // MARK: - The switch

    /// Hand the cued source session off to `selection`, sync the project-level
    /// config so both agents land aligned, and open the target (ADR-013): one
    /// press, both sides ready. The engine only ever CREATES a new target session
    /// (never mutates the source); config sync is additive + backed up; opening is
    /// a separate `AgentLauncher` step (Claude = terminal resume; Codex = Desktop
    /// deep link by default, or terminal resume).
    func activate() {
        guard let source, !isLaunching else { return }
        // Belt-and-suspenders with the enumeration filter: never act on a denied
        // workspace, even if one somehow surfaced (ADR-012 "双保险").
        guard !pathGuard.isDenied(source.workspace) else {
            feedback = "Blocked — \(projectName) is on the never-touch list"
            return
        }
        let destination = selection
        let workspace = source.workspace
        let sourcePath = source.path
        let codexMode: AgentLauncher.CodexMode = codexOpensDesktop ? .desktop : .terminal
        isLaunching = true
        feedback = nil
        reactionStart = Date.timeIntervalSinceReferenceDate  // kick the face's happy reaction
        let gen = scanGeneration

        let home = home
        Log.switching.info(
            "switch → \(destination.rawValue, privacy: .public) [\(self.projectName, privacy: .public)]"
        )
        Task.detached(priority: .userInitiated) {
            do {
                let result: SessionHandoff.Result
                switch destination {
                case .codex:
                    result = try SessionHandoff.claudeToCodex(
                        workspace: workspace, source: sourcePath, home: home)
                case .claude:
                    result = try SessionHandoff.codexToClaude(
                        workspace: workspace, source: sourcePath, home: home)
                }
                // Auto project-level config sync (memory + project MCP); global
                // skills are opt-in via the manual ‹Sync›. Runs before opening so
                // the target lands already aligned.
                let report = ConfigSync.run(scope: .projectLevel, workspace: workspace, home: home)
                if destination == .codex && codexMode == .desktop {
                    // The Desktop open can take seconds when Codex has to cold-start
                    // (launch + settle before any deep link); narrate the wait.
                    await MainActor.run { self.feedback = "Opening in Codex…" }
                }
                let launch = await AgentLauncher.open(
                    agent: destination,
                    sessionId: result.sessionId,
                    resumeCommand: result.resumeCommand,
                    workspace: workspace,
                    codexMode: codexMode)
                await MainActor.run {
                    // Refreshed past this switch = the popover was closed and
                    // reopened mid-flight. The outcome line is still worth
                    // showing, but the auto-close below must not fire — it
                    // would steal the popover the user just reopened.
                    let superseded = self.scanGeneration != gen
                    self.logSyncReport(report)
                    Log.switching.info("\(launch.message, privacy: .public)")
                    self.isLaunching = false
                    self.feedback = Self.switchLine(launch: launch, sync: report)
                    self.loadConfig()  // refresh the segmented status after writing
                    // A real open hands focus to the target agent; get the popover
                    // out of the way once the confirmation line has had a beat to
                    // read — but never before the ▶ reaction finishes, so the "alive"
                    // beat is never cut off mid-squint. If nothing opened, keep it up
                    // — the fallback command must stay visible (and a failure, handled
                    // below, also keeps it up).
                    if launch.opened && !superseded {
                        let reactionStart = self.reactionStart
                        // No reaction plays under Reduce Motion, so don't wait for one.
                        let reduceMotion =
                            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        Task { @MainActor in
                            let elapsed =
                                Date.timeIntervalSinceReferenceDate - (reactionStart ?? 0)
                            let reactionLeft =
                                reduceMotion ? 0 : max(0, FaceCover.reactionDuration - elapsed)
                            try? await Task.sleep(
                                for: max(DS.dismissDelay, .seconds(reactionLeft)))
                            MenuBarPopover.dismiss()
                        }
                    }
                }
            } catch {
                Log.switching.error(
                    "switch failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.isLaunching = false
                    self.feedback = Self.switchFailureMessage(error)
                }
            }
        }
    }

    /// Manual FULL config sync (memory + project MCP + machine-wide skills) and
    /// retry — the ‹Sync› action. Covers the global skills the per-switch path
    /// deliberately skips, and re-runs anything that failed earlier.
    func syncAll() {
        guard let workspace = album?.workspace, !isSyncing else { return }
        guard !pathGuard.isDenied(workspace) else {
            feedback = "Blocked — \(projectName) is on the never-touch list"
            return
        }
        isSyncing = true
        feedback = nil
        let home = home
        Log.sync.info("manual full sync [\(self.projectName, privacy: .public)]")
        Task.detached(priority: .userInitiated) {
            let report = ConfigSync.run(scope: .full, workspace: workspace, home: home)
            await MainActor.run {
                self.logSyncReport(report)
                self.isSyncing = false
                self.feedback = report.summaryLine
                self.loadConfig()
            }
        }
    }

    // MARK: - Observability / messaging

    private func logSyncReport(_ report: ConfigSync.Report) {
        for item in report.items {
            if item.failed {
                Log.sync.error(
                    "\(item.dimension.rawValue, privacy: .public): \(item.summary, privacy: .public)"
                )
            } else {
                Log.sync.info(
                    "\(item.dimension.rawValue, privacy: .public): \(item.summary, privacy: .public)"
                )
            }
        }
    }

    /// The one-line switch outcome: what opened, plus any dimensions that failed
    /// to sync (a successful sync shows itself by lighting the status segments).
    private static func switchLine(launch: AgentLauncher.Launch, sync: ConfigSync.Report) -> String
    {
        guard !sync.allSucceeded else { return launch.message }
        let failed = sync.items.filter(\.failed).map(\.dimension.label).joined(separator: ", ")
        return "\(launch.message) · \(failed) sync failed"
    }

    /// A short, readable reason a switch failed (full detail goes to the log).
    private static func switchFailureMessage(_ error: Error) -> String {
        switch error {
        case SessionHandoff.Failure.noSessionFound:
            return "Switch failed — no session to hand off"
        case SessionHandoff.Failure.emptySession:
            return "Switch failed — the source session looks empty"
        case is SessionReadError:
            return "Switch failed — couldn't read the session"
        default:
            return "Switch failed — couldn't write the target session"
        }
    }
}

extension SessionHandoff.ProjectSessions {
    /// The agent this project was most recently active in — drives the default cue
    /// (you most likely want to switch AWAY from where you just were).
    ///
    /// "Most recent" counts the user's OWN sessions, not VibeOne's handoff copies:
    /// a copy is the newest file right after a switch and would otherwise always
    /// flip the cue the wrong way (back toward the copy). Falls back to the newest
    /// of any kind if a side has only copies (PR-F).
    fileprivate var latestAgent: Agent {
        func recency(_ sessions: [SessionSummary]) -> Date {
            (sessions.first { !$0.generatedByVibeOne } ?? sessions.first)?.modified ?? .distantPast
        }
        return recency(codex) > recency(claude) ? .codex : .claude
    }
}
