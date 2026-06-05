import AppKit
import SwiftUI

/// Builds the menu-bar status-item image for the active agent.
///
/// Design goal: a small, tasteful, ALWAYS-LEGIBLE glyph that hints at the active
/// agent via a subtle accent tint — not a loud colored blob.
///
/// The glyph is the VibeOne brand glyph (`DS.brandGlyph` = "music.note"), so the
/// menu bar and the in-app `BrandMark` share ONE identity. The macOS menu bar
/// would tint a *template* image to a monochrome color, throwing away our accent —
/// so we render a NON-template, color image using SF Symbols' palette rendering:
/// the glyph is drawn in the agent's accent. The accents (#D97757 / #10A37F) are
/// mid-tone and reasonably saturated, so they read on both light and dark menu
/// bars; bold weight gives the thin note body at menu-bar size.
enum MenuBarIcon {

    /// The SF Symbol in the bar = the SAME glyph as the in-app `BrandMark`,
    /// tinted to the active agent — one unified identity across bar and popover.
    static let symbolName = DS.brandGlyph

    /// Point size of the rendered glyph (menu-bar items are ~18pt tall; ~15pt
    /// glyph leaves correct optical padding).
    static let pointSize: CGFloat = 15

    /// Render a tinted, non-template image for the given agent.
    static func image(for agent: Agent) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(.init(paletteColors: [NSColor(DS.Colors.accent(for: agent))]))

        let base =
            NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "VibeOne — \(agent.title)")
            ?? NSImage()

        let img = base.withSymbolConfiguration(config) ?? base
        // NON-template so the OS keeps our accent instead of re-tinting to a
        // monochrome menu-bar color.
        img.isTemplate = false
        return img
    }
}
