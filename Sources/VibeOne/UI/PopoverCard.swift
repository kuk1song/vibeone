import SwiftUI

/// The VibeOne menu-bar popover content — the REAL product shell.
///
/// ONE consistent look, built ENTIRELY from `DesignSystem.swift` (no raw
/// numbers / hex / font sizes here). It lays a faint adaptive `DS.Colors.surface`
/// tint over the system vibrant window chrome that `.menuBarExtraStyle(.window)`
/// provides, so text areas read calm while light/dark + Reduce Transparency keep
/// adapting for free.
///
/// Layout (top → bottom), a single leading alignment axis throughout:
/// header (brand mark + "VibeOne" + project) → divider → segmented Claude/Codex
/// switch → status row → footer (launch button + monospaced command). Switching
/// agents animates the pill, the status dot/text, the footer, AND (via shared
/// state) the menu-bar icon tint — symmetrically for both agents.
struct PopoverCard: View {
    /// Shared with the menu-bar label so the icon tint follows the selection.
    @ObservedObject var state: AppState

    @State private var launching = false

    private let projectName = "slash-stage"
    private let projectDir = "~/slash-stage"

    private var agent: Agent { state.selection }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                AgentSegmentedSwitch(selection: $state.selection)
                StatusRow(
                    accent: DS.Colors.accent(for: agent),
                    primary: "Active · \(agent.title)",
                    secondary: state.availability.summary
                )
                footer
            }
            .padding(DS.Spacing.lg)
        }
        .frame(width: DS.Size.cardWidth)
        // No background: ride the genuine system popover material (like native
        // Control Center popovers). Text stays legible via vibrancy-aware
        // semantic colors (.primary/.secondary).
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Spacing.md) {
            BrandMark()
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("VibeOne")
                    .font(DS.Typography.title)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(projectName)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(DS.Spacing.lg)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Colors.hairline)
            .frame(height: 1)
            .padding(.horizontal, DS.Spacing.lg)  // inset to match content margins
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PrimaryActionButton(
                title: launching ? "Launching…" : "Open in \(agent.title)",
                accent: DS.Colors.accent(for: agent),
                gradient: DS.Colors.gradient(for: agent),
                action: triggerLaunchFeedback
            )
            Text(commandLine)
                .font(DS.Typography.mono)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var commandLine: String {
        "$ \(agent.binary)   (in \(projectDir))"
    }

    /// Light visual feedback only — NO terminal is spawned in this spike.
    private func triggerLaunchFeedback() {
        guard !launching else { return }
        withAnimation(.easeInOut(duration: 0.15)) { launching = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.15)) { launching = false }
        }
    }
}
