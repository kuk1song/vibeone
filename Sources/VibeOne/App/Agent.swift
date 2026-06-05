import SwiftUI

// MARK: - Agent model
//
// Pure data: identity, the CLI binary to detect/run, and the SF Symbol used in
// the segmented switch. ALL styling (accents, gradients, radii, animation) lives
// in DesignSystem.swift — this file carries no design tokens.

enum Agent: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// CLI binary name to detect / run.
    var binary: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// SF Symbol shown inside the segmented switch (not the brand mark).
    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Hex color helper
//
// Used only inside DesignSystem to define the two token-exact brand accents.

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
