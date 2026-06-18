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

    /// Transient one-line outcome of the last switch (success or failure).
    @Published var feedback: String?

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
    var source: SessionSummary? {
        if let pinnedSource { return pinnedSource }
        guard let album else { return nil }
        return selection == .codex ? album.claude.first : album.codex.first
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

    /// Hand the cued source session off to `selection` and open it. The engine
    /// only ever CREATES a new target session (never mutates the source); opening
    /// the agent is a separate `AgentLauncher` step (Claude = terminal resume;
    /// Codex = Desktop deep link by default, or terminal resume).
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
        let home = home
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
                await MainActor.run {
                    let launch = AgentLauncher.open(
                        agent: destination,
                        sessionId: result.sessionId,
                        resumeCommand: result.resumeCommand,
                        workspace: workspace,
                        codexMode: codexMode)
                    self.isLaunching = false
                    self.feedback = launch.message
                }
            } catch {
                await MainActor.run {
                    self.isLaunching = false
                    self.feedback = "Switch failed — \(error)"
                }
            }
        }
    }
}

extension SessionHandoff.ProjectSessions {
    /// The agent this project was most recently active in — drives the default cue
    /// (you most likely want to switch AWAY from where you just were).
    fileprivate var latestAgent: Agent {
        let claudeAt = claude.first?.modified ?? .distantPast
        let codexAt = codex.first?.modified ?? .distantPast
        return codexAt > claudeAt ? .codex : .claude
    }
}
