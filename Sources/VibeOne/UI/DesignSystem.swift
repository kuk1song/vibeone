import SwiftUI

// MARK: - Design System
//
// The single source of visual truth for the VibeOne shell. Deliberately SMALL
// (YAGNI): only the tokens + components this one popover card needs. After this
// file exists, NO view may use a raw magic number, hex literal, or font size —
// everything flows from here. That consistency discipline is the whole point.
//
// Token groups:  Spacing · Radius · Colors · Typography
// Components:    BrandMark · AgentSegmentedSwitch · StatusRow · PrimaryActionButton
//
// Colors prefer SwiftUI semantic roles (.primary/.secondary) and system
// materials so light/dark + Reduce Transparency adapt for free. The only literal
// colors are the two brand accents (token-exact), which by definition cannot be
// derived from the system palette.

enum DS {

    // MARK: Spacing (8pt-ish grid)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16  // standard horizontal margin
        static let xl: CGFloat = 24
    }

    // MARK: Radius (ONE scale — no per-element ad-hoc radii)

    enum Radius {
        static let control: CGFloat = 10  // pill track, segments, button
        static let card: CGFloat = 16  // the popover card
    }

    // MARK: Size (layout dimensions kept out of the views)

    enum Size {
        static let cardWidth: CGFloat = 320  // the popover content width
        static let brandMark: CGFloat = 32  // header logo tile
    }

    // MARK: Colors (semantic roles + brand accents)

    enum Colors {
        // Semantic text/line roles — map to system colors so they adapt.
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let hairline = Color.primary.opacity(0.08)

        /// Faint adaptive tint laid over the native popover material so text
        /// areas read calm without killing the vibrant feel. windowBackgroundColor
        /// already flips with light/dark.
        static let surface = Color(nsColor: .windowBackgroundColor).opacity(0.4)

        // Brand accents (token-exact). #D97757 Claude / #10A37F Codex.
        static let accentClaude = Color(hex: 0xD97757)
        static let accentCodex = Color(hex: 0x10A37F)

        /// Logo gradient (orange -> pink) — the VibeOne brand mark fill.
        static let brandGradient = LinearGradient(
            colors: [Color(hex: 0xF59E42), Color(hex: 0xEC4899)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        static let brandGlow = Color(hex: 0xEC4899)

        /// Solid accent for the active agent (status dot, glow, menu-bar tint).
        static func accent(for agent: Agent) -> Color {
            switch agent {
            case .claude: return accentClaude
            case .codex: return accentCodex
            }
        }

        /// Two-stop accent gradient for the active agent (pill + button fill).
        static func gradient(for agent: Agent) -> LinearGradient {
            let stops: [Color]
            switch agent {
            case .claude: stops = [accentClaude, Color(hex: 0xE8946F)]
            case .codex: stops = [accentCodex, Color(hex: 0x1FBF95)]
            }
            return LinearGradient(
                colors: stops,
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // MARK: Typography (Font.system only — no sizes scattered in views)

    enum Typography {
        static let title = Font.system(size: 16, weight: .semibold)  // "VibeOne"
        static let headline = Font.system(size: 14, weight: .semibold)  // controls
        static let body = Font.system(size: 13, weight: .medium)  // status
        static let caption = Font.system(size: 11, weight: .regular)  // sub-labels
        static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    // MARK: Brand

    /// The brand glyph — reused by BOTH the in-app `BrandMark` and the menu-bar
    /// icon so the identity is unified. Lives here (nonisolated) so AppKit menu-bar
    /// code can read it without main-actor isolation.
    static let brandGlyph = "music.note"

    // MARK: Motion

    /// The signature switch animation — the product's silky pill slide.
    static let switchAnimation = Animation.spring(response: 0.3, dampingFraction: 0.72)
}

// MARK: - Components
//
// Each consumes ONLY the tokens above.

/// The VibeOne brand mark: a rounded-square tile with the music-note glyph on the
/// brand gradient. The SAME glyph (`DS.brandGlyph`) is reused for the menu-bar
/// icon so the identity is unified. `size` is the only knob.
struct BrandMark: View {
    var size: CGFloat = DS.Size.brandMark

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(DS.Colors.brandGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: DS.brandGlyph)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: DS.Colors.brandGlow.opacity(0.45), radius: 6, y: 1)
    }
}

/// HERO control — a full-width segmented pill. The selected segment is a filled
/// accent-gradient pill that SLIDES between segments with a spring
/// (`matchedGeometryEffect`) and carries a soft outer glow.
struct AgentSegmentedSwitch: View {
    @Binding var selection: Agent
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Agent.allCases) { segment(for: $0) }
        }
        .padding(DS.Spacing.xs)  // inset so the pill sits in the track
        .background(track)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Colors.hairline, lineWidth: 0.75)
        )
    }

    private var track: some View {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(DS.Colors.hairline)
    }

    @ViewBuilder
    private func segment(for agent: Agent) -> some View {
        let isSelected = selection == agent
        Button {
            withAnimation(DS.switchAnimation) { selection = agent }
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: agent.symbol)
                Text(agent.title)
            }
            .font(DS.Typography.body)
            .foregroundStyle(isSelected ? Color.white : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.sm)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: DS.Radius.control - DS.Spacing.xs,
                        style: .continuous
                    )
                    .fill(DS.Colors.gradient(for: agent))
                    .matchedGeometryEffect(id: "pill", in: pill)
                    .shadow(
                        color: DS.Colors.accent(for: agent).opacity(0.45),
                        radius: 10, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// One row: an accent status dot + primary line, with an optional secondary line.
/// Left-aligned, no internal margins (the caller owns horizontal margins).
struct StatusRow: View {
    var accent: Color
    var primary: String
    var secondary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Circle()
                    .fill(accent)
                    .frame(width: DS.Spacing.sm, height: DS.Spacing.sm)
                    .shadow(color: accent.opacity(0.8), radius: 4)
                Text(primary)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            if let secondary {
                Text(secondary)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The ONE button used everywhere: full-width, ~40pt tall, accent GRADIENT fill,
/// `Radius.control`, with a soft accent glow. No flat/glass variants.
struct PrimaryActionButton: View {
    var title: String
    var accent: Color
    var gradient: LinearGradient
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(gradient)
                )
        }
        .buttonStyle(.plain)
        .shadow(color: accent.opacity(0.45), radius: 10, y: 3)
    }
}
