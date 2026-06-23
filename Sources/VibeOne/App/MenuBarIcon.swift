import AppKit
import SwiftUI

/// Builds the menu-bar status-item image for the active agent.
///
/// It is the SAME identity as the popover's `FaceCover` mascot (ADR-006): the
/// cute face — round eyes + a gentle smile — tinted to the active agent. The dot
/// matrix `FaceCover` uses is too dense to read at menu-bar size, so this draws a
/// crisp, simplified version with AppKit at the real ~20×16 pt: round (near-1:1)
/// eyes and a clearly curved smile.
///
/// The macOS menu bar would tint a *template* image to a flat monochrome color,
/// throwing away our accent — so we render a NON-template, colored image. The
/// accents (#D97757 / #6C81FF) are mid-tone and reasonably saturated, so they
/// read on both light and dark menu bars.
///
/// The coordinates below are this icon's own ~20×16 canvas (illustration path
/// data, like an asset), not shell design tokens; only the accent comes from `DS`.
enum MenuBarIcon {

    /// Render a tinted, non-template face image for the given agent.
    static func image(for agent: Agent) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let color = NSColor(DS.Colors.accent(for: agent))
        color.setFill()
        color.setStroke()

        // Round (near-square) eyes — the "eyes read as eyes, not bars" fix.
        let eyeW: CGFloat = 4.2
        let eyeH: CGFloat = 4.6
        let eyeCenterY: CGFloat = 10.6
        for x in [4.8, 11.0] as [CGFloat] {
            let rect = NSRect(x: x, y: eyeCenterY - eyeH / 2, width: eyeW, height: eyeH)
            NSBezierPath(roundedRect: rect, xRadius: eyeW / 2, yRadius: eyeH / 2).fill()
        }

        // A clearly curved smile.
        let smile = NSBezierPath()
        smile.lineWidth = 1.8
        smile.lineCapStyle = .round
        smile.move(to: NSPoint(x: 5, y: 5.4))
        smile.curve(
            to: NSPoint(x: 15, y: 5.4),
            controlPoint1: NSPoint(x: 7.5, y: 1.3),
            controlPoint2: NSPoint(x: 12.5, y: 1.3))
        smile.stroke()

        image.unlockFocus()
        // NON-template so the OS keeps our accent instead of re-tinting to a
        // monochrome menu-bar color.
        image.isTemplate = false
        return image
    }
}
