import SwiftUI

/// The VibeOne menu-bar popover — a music-player "now playing" card (ADR-006).
///
/// Layout (top → bottom):
///   • cover    — the living LED-face mascot (`FaceCover`), tinted to the active
///                agent; the same identity as the menu-bar icon.
///   • trackInfo — the active agent's name + the project ("now playing").
///   • progress  — a thin line tracking CONFIG SYNC (memory / skills / MCP), a
///                 REAL datum — not a faked playback time.
///   • transport — sync · switch · big launch ("play") · switch · more.
///
/// Built ENTIRELY from `DesignSystem.swift` tokens (no raw numbers / hex / font
/// sizes here). Switching agents animates the cover tint, the title, the progress
/// accent, AND (via shared `AppState`) the menu-bar icon — symmetrically.
///
/// This is the UI shell only. The transport gives light visual feedback; the
/// session-handoff (M2) and config-sync (M3) engines are wired in a later step
/// (see TASK.md / ADR-006). The progress placeholder already has the real shape
/// (N of 3 dimensions), so wiring `ConfigStatus` is a drop-in.
struct PopoverCard: View {
    /// Shared with the menu-bar label so the icon tint follows the selection.
    @ObservedObject var state: AppState

    @State private var launching = false

    private let projectName = "slash-stage"

    private var agent: Agent { state.selection }
    private var other: Agent { agent == .claude ? .codex : .claude }
    private var accent: Color { DS.Colors.accent(for: agent) }

    // Placeholder config-sync state; replaced by a real `ConfigStatus` snapshot
    // when M3 is wired. Shape is honest: N of 3 dimensions (memory / skills / MCP).
    private let syncedDimensions = 2
    private let totalDimensions = 3

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            cover
            trackInfo
            progress
            transport
        }
        .padding(DS.Spacing.lg)
        .frame(width: DS.Size.cardWidth)
        // No background: ride the genuine system popover material (like native
        // Control Center popovers); the dark face panel supplies the contrast.
    }

    // MARK: - Cover

    private var cover: some View {
        FaceCover(accent: accent)
            .frame(width: DS.Size.playerCover, height: DS.Size.playerCover)
    }

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(spacing: DS.Spacing.xs) {
            Text(agent.title)
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(projectName)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    // MARK: - Progress (config sync, not playback)

    private var progress: some View {
        VStack(spacing: DS.Spacing.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.hairline)
                    Capsule().fill(accent)
                        .frame(
                            width: geo.size.width * CGFloat(syncedDimensions)
                                / CGFloat(totalDimensions))
                }
            }
            .frame(height: DS.Size.progressBar)
            HStack {
                Text("config synced")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                Text("\(syncedDimensions)/\(totalDimensions)")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: DS.Spacing.md) {
            TransportButton(symbol: "arrow.triangle.2.circlepath") {}  // sync now (M3)
            TransportButton(symbol: "backward.end.fill") { switchTo(other) }
            PlayButton(agent: agent, action: triggerLaunchFeedback)
            TransportButton(symbol: "forward.end.fill") { switchTo(other) }
            TransportButton(symbol: "ellipsis") {}  // more
        }
    }

    private func switchTo(_ agent: Agent) {
        withAnimation(DS.switchAnimation) { state.selection = agent }
    }

    /// No-op placeholder beyond a 1-second re-entry guard — NO terminal is spawned
    /// in this UI shell. The `SessionHandoff` engine (M2) is wired in a later step,
    /// at which point `launching` drives a real in-progress state on `PlayButton`.
    private func triggerLaunchFeedback() {
        guard !launching else { return }
        launching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { launching = false }
    }
}
