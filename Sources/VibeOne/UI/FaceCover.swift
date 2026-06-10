import SwiftUI

/// VibeOne's living LED-dot-matrix face — the popover's "album cover" and the
/// brand's mascot (ADR-006). A glowing dot grid (a tiny LED panel) renders a CUTE
/// expression: round eyes that blink, a soft blush, and a gentle smile. It tints
/// to the active agent's accent and fills whatever square the caller gives it.
///
/// This is the SwiftUI/Canvas face shown INSIDE the popover. The menu-bar status
/// item draws a simplified, crisp version of the SAME identity (`MenuBarIcon`),
/// because a 24×15 dot grid is too dense to read at ~20×16 pt.
///
/// The dot-grid coordinates below are the face's own internal coordinate system
/// (like the path data of an illustration), NOT shell design tokens — only the
/// panel COLOR is hoisted to `DesignSystem` (the no-bare-hex rule). Radius/accent
/// still come from `DS`.
struct FaceCover: View {
    var accent: Color
    /// Freeze a single frame (the dev render harness only); `nil` = live-animated.
    var time: Double? = nil

    var body: some View {
        Group {
            if let time {
                canvas(t: time)
            } else {
                TimelineView(.animation) { timeline in
                    canvas(t: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Colors.facePanel)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shadow(
            color: accent.opacity(FaceGrid.glowOpacity), radius: FaceGrid.glowRadius,
            y: FaceGrid.glowY)
    }

    private func canvas(t: Double) -> some View {
        Canvas { ctx, size in
            draw(ctx, size, frame: FaceArt.cute(t: t))
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, frame: FaceArt.Frame) {
        let cell = min(size.width / CGFloat(FaceGrid.cols), size.height / CGFloat(FaceGrid.rows))
        let dot = cell * FaceGrid.dotRatio
        let ox = (size.width - cell * CGFloat(FaceGrid.cols)) / 2
        let oy = (size.height - cell * CGFloat(FaceGrid.rows)) / 2

        func at(_ c: Int, _ r: Int, _ d: CGFloat) -> CGRect {
            let cx = ox + (CGFloat(c) + 0.5) * cell
            let cy = oy + (CGFloat(r) + 0.5) * cell
            return CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        }

        // Unlit panel grid (the dark dots between lit ones).
        for r in 0..<FaceGrid.rows {
            for c in 0..<FaceGrid.cols {
                ctx.fill(
                    Path(ellipseIn: at(c, r, dot)),
                    with: .color(accent.opacity(FaceGrid.unlitOpacity)))
            }
        }
        // Soft halo under each lit dot, then the blush, then the lit dots on top.
        let halo = dot * FaceGrid.haloScale
        for d in frame.bright {
            ctx.fill(
                Path(ellipseIn: at(d.c, d.r, halo)),
                with: .color(accent.opacity(FaceGrid.haloOpacity)))
        }
        for d in frame.dim {
            ctx.fill(
                Path(ellipseIn: at(d.c, d.r, dot)),
                with: .color(accent.opacity(FaceGrid.blushOpacity)))
        }
        for d in frame.bright {
            ctx.fill(Path(ellipseIn: at(d.c, d.r, dot)), with: .color(accent))
        }
    }
}

// MARK: - Face artwork (internal coordinate system)

/// The face's own 24×15 LED matrix + render parameters. Eyes sit on the upper
/// third (the balanced "eyes-up" layout chosen in ADR-006), well clear of the
/// mouth. Local to the illustration — not shell tokens.
private enum FaceGrid {
    static let cols = 24
    static let rows = 15
    static let dotRatio: CGFloat = 0.62  // dot diameter / cell
    static let blinkPeriod: Double = 3.4  // seconds between blinks
    static let leftEye = (c: 7, r: 5)  // row 5 = eyes-up (not centred row 6)
    static let rightEye = (c: 16, r: 5)
    // Glow / render opacities.
    static let unlitOpacity: Double = 0.06
    static let haloScale: CGFloat = 2.2
    static let haloOpacity: Double = 0.16
    static let blushOpacity: Double = 0.4
    static let glowOpacity: Double = 0.45
    static let glowRadius: CGFloat = 18
    static let glowY: CGFloat = 8
}

/// One lit cell on the dot grid.
private struct Dot: Hashable {
    let c: Int
    let r: Int
    init(_ c: Int, _ r: Int) {
        self.c = c
        self.r = r
    }
}

/// Computes the lit cells for the cute expression at time `t`.
private enum FaceArt {
    struct Frame {
        var bright: Set<Dot> = []  // full accent (eyes + smile)
        var dim: Set<Dot> = []  // accent * blushOpacity (cheeks)
    }

    static func cute(t: Double) -> Frame {
        var f = Frame()
        let open = blink(t)
        roundEye(FaceGrid.leftEye, open: open, into: &f.bright)
        roundEye(FaceGrid.rightEye, open: open, into: &f.bright)
        let br = FaceGrid.leftEye.r + 3  // blush sits just below the eyes
        for d in [
            Dot(FaceGrid.leftEye.c - 3, br), Dot(FaceGrid.leftEye.c - 2, br),
            Dot(FaceGrid.rightEye.c + 2, br), Dot(FaceGrid.rightEye.c + 3, br),
        ] {
            f.dim.insert(d)
        }
        smile(into: &f.bright)
        return f
    }

    /// Genuinely round eye: a 5×5 circle with the 4 corners trimmed. Squashes to a
    /// flat line as `open` → 0 (a blink).
    private static func roundEye(_ ctr: (c: Int, r: Int), open: CGFloat, into s: inout Set<Dot>) {
        let rowsHalf = max(0, Int((2.0 * Double(open)).rounded()))
        for r in -rowsHalf...rowsHalf {
            let isEdge = abs(r) == rowsHalf && rowsHalf > 0
            for c in -2...2 {
                if isEdge && abs(c) == 2 { continue }  // trim corners → round
                s.insert(Dot(ctr.c + c, ctr.r + r))
            }
        }
    }

    /// A gentle upward smile centred under the eyes.
    private static func smile(into s: inout Set<Dot>) {
        for c in 9...14 {
            let dx = Double(c) - 11.5
            let lift = Int((dx * dx * 0.14).rounded())
            s.insert(Dot(c, 11 - lift))
        }
    }

    /// Quick blink: open for most of the period, a fast close-and-open at the top.
    private static func blink(_ t: Double) -> CGFloat {
        let p = t.truncatingRemainder(dividingBy: FaceGrid.blinkPeriod)
        guard p < 0.16 else { return 1 }
        return abs(p - 0.08) / 0.08
    }
}

#Preview("Face cover") {
    FaceCover(accent: DS.Colors.accentClaude)
        .frame(width: DS.Size.playerCover, height: DS.Size.playerCover)
        .padding(DS.Spacing.xl)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
}
