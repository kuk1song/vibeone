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

    /// Folders VibeOne must never touch (ADR-012). Shown read-only in Settings; the
    /// editor lands later. The default preset guards the work tree.
    let protectedPaths = ["~/ot"]

    private let home: URL
    private let pathGuard: PathGuard
    private static let codexDesktopKey = "codexOpensDesktop"

    /// `autoload: false` builds an inert instance (no disk / shell probes) for the
    /// render harness, which seeds the published state directly.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, autoload: Bool = true) {
        self.home = home
        self.pathGuard = PathGuard(deniedPaths: protectedPaths, home: home)
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
        let home = home
        let exclusions = pathGuard
        Task.detached(priority: .userInitiated) {
            let projects = SessionHandoff.projectSessions(home: home, excluding: exclusions)
            await MainActor.run {
                self.projects = projects
                self.albumIndex = min(self.albumIndex, max(0, projects.count - 1))
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
        let home = home
        Task.detached(priority: .userInitiated) {
            let status = ConfigStatus.read(workspace: workspace, home: home)
            await MainActor.run { self.configStatus = status }
        }
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
                await MainActor.run {
                    self.logSyncReport(report)
                    let launch = AgentLauncher.open(
                        agent: destination,
                        sessionId: result.sessionId,
                        resumeCommand: result.resumeCommand,
                        workspace: workspace,
                        codexMode: codexMode)
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
                    if launch.opened {
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
