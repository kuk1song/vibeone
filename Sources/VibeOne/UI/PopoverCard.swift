import AppKit
import SwiftUI
import VibeOneEngine

/// The VibeOne menu-bar popover — a session switcher shaped like an album player
/// (ADR-006 visual, ADR-008 / ADR-011 interaction):
///
///   • ALBUM = project · SONG = session (Claude / Codex are an album's two sides)
///   • cover    — the living LED face (`FaceCover`), tinted to the cued DESTINATION
///   • title    — "Switch to {destination}" over the project ("now playing")
///   • progress — three SEGMENTS (memory · MCP · skills), each lit when that
///                dimension is aligned; a ‹Sync› action runs a full manual sync
///                (incl global skills). A REAL `ConfigStatus` datum, not playback.
///   • macwindow/terminal — the Codex OPEN-MODE key at the transport's left (the
///                "mode" slot a player gives repeat/shuffle): Desktop app ⇄
///                terminal, the icon IS the mode. Dimmed when destination = Claude.
///   • ⏮ / ⏭   — flip the destination within this project (Claude ⇄ Codex)
///   • ▶ play   — SWITCH: hand the conversation off to the destination, sync the
///                project-level config, and open it (explicit-select, ADR-008).
///   • ☰        — pull up the QUEUE: pick any session across projects
///   • ⋯        — pull up SETTINGS: Codex open mode, protected folders, Quit
///
/// Built entirely from `DesignSystem.swift` tokens — no raw numbers / hex / font
/// sizes here. All data and actions live on `AppState`; this is the view only.
struct PopoverCard: View {
    @ObservedObject var state: AppState

    private var destination: Agent { state.selection }
    private var accent: Color { DS.Colors.accent(for: destination) }

    var body: some View {
        Group {
            if state.settingsOpen {
                SettingsPanel(state: state)
            } else if state.projects.isEmpty {
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

    /// Three discrete segments — memory · MCP · skills — each lit when that
    /// dimension is aligned across both agents. A segmented bar (not a continuous
    /// fill) so you see WHICH dimension is out of sync at a glance.
    private var progress: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                syncSegment(state.configStatus?.memory.inSync ?? false)
                syncSegment(state.configStatus?.mcp.inSync ?? false)
                syncSegment(state.configStatus?.skills.inSync ?? false)
            }
            .frame(height: DS.Size.progressBar)
            HStack(spacing: DS.Spacing.sm) {
                Text("config synced")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text("\(syncedDimensions)/\(totalDimensions)")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                syncButton
            }
        }
    }

    private func syncSegment(_ lit: Bool) -> some View {
        Capsule()
            .fill(lit ? accent : DS.Colors.hairline)
            .frame(maxWidth: .infinity)
    }

    /// Manual FULL sync (memory + MCP + global skills) / retry — the one config
    /// write the auto-on-switch path doesn't cover (global skills). Co-located with
    /// the status it acts on, and deliberately NOT a circular-arrows transport key
    /// (those read as "repeat" in a player). Wired with the apply slice.
    private var syncButton: some View {
        Button {
            state.syncAll()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "arrow.left.arrow.right")
                Text(state.isSyncing ? "Syncing…" : "Sync")
            }
            .font(DS.Typography.caption)
            .foregroundStyle(accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isSyncing)
        .opacity(state.isSyncing ? DS.Opacity.disabled : 1)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: DS.Spacing.md) {
            modeKey
            TransportButton(symbol: "backward.end.fill") { flip() }
            PlayButton(agent: destination) { state.activate() }
                .disabled(!state.canSwitch)
                .opacity(state.canSwitch ? 1 : DS.Opacity.disabled)
            TransportButton(symbol: "forward.end.fill") { flip() }
            TransportButton(symbol: "music.note.list") {
                withAnimation(DS.switchAnimation) { state.queueOpen = true }
            }
        }
    }

    /// Second row aligned under the transport. Most slots are intentionally empty —
    /// whitespace keeps ▶ dominant; only SETTINGS sits here, under the queue (⋯).
    private var secondary: some View {
        HStack(spacing: DS.Spacing.md) {
            clearSlot(DS.Size.transportButton)  // under the mode key
            clearSlot(DS.Size.transportButton)  // under ⏮
            clearSlot(DS.Size.playButton)  // under ▶
            clearSlot(DS.Size.transportButton)  // under ⏭
            TransportButton(symbol: "ellipsis") {
                withAnimation(DS.switchAnimation) { state.settingsOpen = true }
            }
        }
    }

    private func clearSlot(_ width: CGFloat) -> some View {
        Color.clear.frame(width: width, height: DS.Size.transportButton)
    }

    /// The Codex OPEN-MODE key — the "mode" control a player gives to repeat/
    /// shuffle, here at the transport's left. The icon IS the current mode:
    /// `macwindow` (Desktop app) ⇄ `terminal` (CLI). Only Codex has two open modes,
    /// so when the destination is Claude (always a terminal) it's disabled + dimmed
    /// rather than blank, keeping the row stable.
    @ViewBuilder
    private var modeKey: some View {
        let isCodex = destination == .codex
        TransportButton(
            symbol: state.codexOpensDesktop ? "macwindow" : "terminal",
            tint: isCodex ? accent : DS.Colors.textSecondary
        ) {
            withAnimation(DS.switchAnimation) { state.toggleCodexMode() }
        }
        .disabled(!isCodex)
        .opacity(isCodex ? 1 : DS.Opacity.disabled)
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

// MARK: - Settings panel (pull-up under ⋯)

/// The settings surface — a pull-up panel in the popover, opened from the ⋯ "more"
/// key (the same slide-in language as the Queue). Holds the canonical "Open Codex
/// in" toggle (mirrored by the inline player key), the read-only safety deny-list
/// (the editor lands later), and the app's Quit — which a menu-bar-only app needs a
/// home for.
struct SettingsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            header
            section("Open Codex in") { modePicker }
            section("Protected folders") { protectedList }
            Divider().overlay(DS.Colors.hairline)
            footer
        }
        .padding(DS.Spacing.lg)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(DS.Typography.title)
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            Button {
                withAnimation(DS.switchAnimation) { state.settingsOpen = false }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: DS.Size.transportButton, height: DS.Size.transportButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Terminal ⇄ Desktop, the canonical control behind the inline player key.
    private var modePicker: some View {
        HStack(spacing: 0) {
            modeSegment(title: "Terminal", desktop: false)
            modeSegment(title: "Desktop app", desktop: true)
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Colors.hairline))
    }

    private func modeSegment(title: String, desktop: Bool) -> some View {
        let selected = state.codexOpensDesktop == desktop
        return Button {
            withAnimation(DS.switchAnimation) { state.codexOpensDesktop = desktop }
        } label: {
            Text(title)
                .font(DS.Typography.body)
                .foregroundStyle(selected ? Color.white : DS.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.sm)
                .background {
                    if selected {
                        RoundedRectangle(
                            cornerRadius: DS.Radius.control - DS.Spacing.xs, style: .continuous
                        )
                        .fill(DS.Colors.accentCodex)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var protectedList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach(state.protectedPaths, id: \.self) { path in
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "lock.fill").foregroundStyle(DS.Colors.textSecondary)
                    Text(path)
                        .font(DS.Typography.body).foregroundStyle(DS.Colors.textPrimary)
                    Spacer()
                }
            }
            Text("VibeOne never reads or writes these. Editing comes later.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("VibeOne")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(title.uppercased())
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
            content()
        }
    }
}
