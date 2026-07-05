import SwiftUI

// MARK: - Design System
//
// The single source of visual truth for the VibeOne shell. Deliberately SMALL
// (YAGNI): only the tokens + components this one popover card needs. After this
// file exists, NO view may use a raw magic number, hex literal, or font size —
// everything flows from here. That consistency discipline is the whole point.
//
// Token groups:  Spacing · Radius · Size · Opacity · Colors · Typography · Motion
// Components:    PlayButton · TransportButton
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
        static let cardWidth: CGFloat = 264  // the popover content width

        // "Now playing" player (ADR-006 / ADR-014).
        static let playerCover: CGFloat = 132  // square LED-face cover (empty state)
        static let playerBanner: CGFloat = 160  // wide LED-banner cover height (player)
        static let playButton: CGFloat = 45  // centered big launch circle
        static let transportButton: CGFloat = 32  // side icon buttons
        static let progressBar: CGFloat = 3  // config-sync progress line height

        // Pull-up queue (session picker, ADR-011).
        static let queueArt: CGFloat = 38  // per-session "album art" tile
        static let queueMaxHeight: CGFloat = 300  // queue scroll cap inside the popover
    }

    // MARK: Opacity (the only sanctioned alpha values — never inline in a view)

    enum Opacity {
        static let selectedTint = 0.14  // accent wash behind a selected row
        static let disabled = 0.4  // a dimmed, non-actionable control
    }

    // MARK: Colors (semantic roles + brand accents)

    enum Colors {
        // Semantic text/line roles — map to system colors so they adapt.
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let hairline = Color.primary.opacity(0.08)

        /// The near-black backing of the LED-dot-matrix face cover, so the lit
        /// accent dots glow like a tiny panel regardless of light/dark. The one
        /// non-adaptive surface — it is the "screen" the mascot lives on.
        static let facePanel = Color(hex: 0x0C0C0E)

        // Brand accents (token-exact). #D97757 Claude / #6C81FF Codex — the
        // periwinkle-indigo of Codex's current app icon (sampled from the shipping
        // icon; OpenAI's 2025 identity moved off the legacy #10A37F green).
        static let accentClaude = Color(hex: 0xD97757)
        static let accentCodex = Color(hex: 0x6C81FF)

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
            case .codex: stops = [accentCodex, Color(hex: 0x9AAAFF)]
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
    }

    // MARK: Motion

    /// The signature switch animation — the product's silky pill slide.
    static let switchAnimation = Animation.spring(response: 0.3, dampingFraction: 0.72)

    /// Minimum lingering time after a successful switch before the popover
    /// auto-closes — long enough to read the one-line "Opened in …" confirmation.
    /// The actual close waits for the LONGER of this and the ▶ reaction finishing
    /// (`FaceCover.reactionDuration`), so the "alive" beat is never cut off.
    static let dismissDelay: Duration = .milliseconds(800)
}

// MARK: - Components
//
// Each consumes ONLY the tokens above.

/// The centered "play" of the transport row: a circular accent-GRADIENT button
/// with a `play.fill` glyph. This is the primary launch action ("play" the agent).
struct PlayButton: View {
    var agent: Agent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(DS.Colors.gradient(for: agent))
                    .frame(width: DS.Size.playButton, height: DS.Size.playButton)
                Image(systemName: "play.fill")
                    .font(.system(size: DS.Size.playButton * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        // No glow — the play circle reads on its own (tuned to a flat finish).
        .accessibilityLabel("Switch to \(agent.title)")
    }
}

/// A flat secondary icon button used either side of `PlayButton` (sync / switch /
/// more). Tappable across its full square; no fill — the play circle is the only
/// emphasized control. `label` is the VoiceOver name: required, because the SF
/// Symbol defaults mislead here (⏮ is "flip destination", not "skip back").
struct TransportButton: View {
    var symbol: String
    var label: String
    var tint: Color = DS.Colors.textSecondary  // accent for a live/stateful control
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DS.Size.transportButton * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: DS.Size.transportButton, height: DS.Size.transportButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
