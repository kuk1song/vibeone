import SwiftUI
import VibeOneEngine

/// The VibeOne menu-bar popover — a session switcher shaped like an album player
/// (ADR-006 visual, ADR-008 / ADR-011 interaction):
///
///   • ALBUM = project · SONG = session (Claude / Codex are an album's two sides)
///   • cover    — the living LED face (`FaceCover`), tinted to the cued DESTINATION
///   • title    — "Switch to {destination}" over the project ("now playing")
///   • progress — a thin line tracking CONFIG SYNC (memory / skills / MCP), a REAL
///                `ConfigStatus` datum — not a faked playback time
///   • ⏮ / ⏭   — flip the destination within this project (Claude ⇄ Codex)
///   • ▶ play   — SWITCH: hand the current conversation off to the destination and
///                open it. Nothing switches until play (explicit-select, ADR-008).
///   • ☰        — (under ⋯) pull up the QUEUE: pick any session across projects
///
/// Built entirely from `DesignSystem.swift` tokens — no raw numbers / hex / font
/// sizes here. All data and actions live on `AppState`; this is the view only.
struct PopoverCard: View {
    @ObservedObject var state: AppState

    private var destination: Agent { state.selection }
    private var accent: Color { DS.Colors.accent(for: destination) }

    var body: some View {
        Group {
            if state.projects.isEmpty {
                emptyState
            } else if state.queueOpen {
                QueueView(state: state)
            } else {
                player
            }
        }
        .frame(width: DS.Size.cardWidth)
        .onAppear { state.refresh() }
        // No background: ride the genuine system popover material; the dark face
        // panel supplies the contrast.
    }

    // MARK: - Player

    private var player: some View {
        VStack(spacing: DS.Spacing.md) {
            FaceCover(accent: accent)
                .frame(width: DS.Size.playerCover, height: DS.Size.playerCover)
                .padding(.top, DS.Spacing.sm)

            VStack(spacing: DS.Spacing.xs) {
                Text("Switch to \(destination.title)")
                    .font(DS.Typography.title)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(state.projectName)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            progress
            transport
            secondary
            feedback
        }
        .padding(DS.Spacing.lg)
    }

    // MARK: - Progress (config sync, not playback)

    private let totalDimensions = 3
    private var syncedDimensions: Int {
        guard let s = state.configStatus else { return 0 }
        return [s.memory.inSync, s.mcp.inSync, s.skills.inSync].filter { $0 }.count
    }

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
            TransportButton(symbol: "arrow.triangle.2.circlepath") {}  // config apply (later)
            TransportButton(symbol: "backward.end.fill") { flip() }
            PlayButton(agent: destination) { state.activate() }
                .disabled(!state.canSwitch)
                .opacity(state.canSwitch ? 1 : DS.Opacity.disabled)
            TransportButton(symbol: "forward.end.fill") { flip() }
            TransportButton(symbol: "ellipsis") {}  // more (later)
        }
    }

    /// Second row aligned under the transport: a left secondary slot (under ⟲) and
    /// the QUEUE button under ⋯ that pulls up session selection (Spotify-style).
    private var secondary: some View {
        HStack(spacing: DS.Spacing.md) {
            TransportButton(symbol: "slider.horizontal.3") {}  // config detail (later)
            Color.clear
                .frame(width: DS.Size.transportButton, height: DS.Size.transportButton)
            Color.clear
                .frame(width: DS.Size.playButton, height: DS.Size.transportButton)
            Color.clear
                .frame(width: DS.Size.transportButton, height: DS.Size.transportButton)
            TransportButton(symbol: "music.note.list") {
                withAnimation(DS.switchAnimation) { state.queueOpen = true }
            }
        }
    }

    /// One transient line confirming the last switch (or its failure).
    private var feedback: some View {
        Text(state.feedback ?? " ")
            .font(DS.Typography.caption)
            .foregroundStyle(accent)
            .opacity(state.feedback == nil ? 0 : 1)
            .lineLimit(1)
    }

    private func flip() {
        withAnimation(DS.switchAnimation) { state.flip() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            FaceCover(accent: DS.Colors.accent(for: .claude))
                .frame(width: DS.Size.playerCover, height: DS.Size.playerCover)
            Text("No sessions yet")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.textPrimary)
            Text("Start a session in Claude Code or Codex, then switch here.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Spacing.xl)
    }
}

// MARK: - Queue (pull-up session picker, grouped by project)

/// The Spotify-style pull-up queue: every project's sessions, grouped, with the
/// currently cued one marked. `scrollable` wraps the list in a `ScrollView` for
/// the live popover; the render harness flattens it (ImageRenderer can't lay out
/// a `ScrollView`).
struct QueueView: View {
    @ObservedObject var state: AppState
    var scrollable = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            header
            if scrollable {
                ScrollView { list }
                    .frame(maxHeight: DS.Size.queueMaxHeight)
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Queue")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            Button {
                withAnimation(DS.switchAnimation) { state.queueOpen = false }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: DS.Size.transportButton, height: DS.Size.transportButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.md)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(state.projects) { project in
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(URL(fileURLWithPath: project.workspace).lastPathComponent)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(.horizontal, DS.Spacing.md)
                    ForEach(project.claude + project.codex) { session in
                        SessionRow(session: session, cued: state.source?.id == session.id) {
                            withAnimation(DS.switchAnimation) { state.pick(session) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.sm)
    }
}

// MARK: - Queue pieces

/// One session = a tappable "song" row: agent-tinted art, the agent name, and how
/// long ago it was active; a waveform marks the currently cued session.
private struct SessionRow: View {
    let session: SessionSummary
    var cued: Bool
    let onTap: () -> Void

    private var agent: Agent { Agent(rawValue: session.agent) ?? .claude }
    private var tint: Color { DS.Colors.accent(for: agent) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.md) {
                SessionArt(agent: agent)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(agent.title)
                        .font(DS.Typography.body)
                        .foregroundStyle(cued ? tint : DS.Colors.textPrimary)
                    Text(RelativeTime.string(for: session.modified))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer()
                if cued {
                    Image(systemName: "waveform")
                        .font(DS.Typography.caption)
                        .foregroundStyle(tint)
                }
            }
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(cued ? tint.opacity(DS.Opacity.selectedTint) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small agent-tinted "album art" tile with the agent glyph, for queue rows.
private struct SessionArt: View {
    let agent: Agent

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(DS.Colors.gradient(for: agent))
            .frame(width: DS.Size.queueArt, height: DS.Size.queueArt)
            .overlay(
                Image(systemName: agent.symbol)
                    .font(DS.Typography.headline)
                    .foregroundStyle(.white))
    }
}

/// Compact relative-age label ("2m ago", "3h ago", "5d ago"). `now` is injectable
/// for deterministic rendering. Time-unit constants only — not design tokens.
enum RelativeTime {
    static func string(for date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }
}
