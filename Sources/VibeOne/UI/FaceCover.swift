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
    /// When the user last pressed ▶ (reference-time seconds). For `reactionDuration`
    /// after, the face squints into a happy reaction — the mascot reacting to the
    /// switch — then eases back. `nil` = never reacted.
    var reactionStart: Double? = nil

    /// Honour the system "Reduce Motion" setting: decorative animation (the idle
    /// blink and the ▶ reaction) must stop, leaving a calm static face.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let time {
                canvas(t: time)
            } else if reduceMotion {
                canvas(t: 0)  // resting face — no blink, no reaction
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
            draw(ctx, size, frame: FaceArt.cute(t: t, happy: happiness(at: t)))
        }
    }

    // Reaction timing — the ▶ happy beat. The phase lengths are the face's own
    // animation data, but the TOTAL is shared with `AppState` so the popover never
    // auto-closes before the beat finishes (a cut-off reaction looks broken).
    private static let reactionRampIn: Double = 0.18
    private static let reactionHold: Double = 0.85
    private static let reactionRampOut: Double = 0.35
    static let reactionDuration = reactionRampIn + reactionHold + reactionRampOut

    /// 0 → 1 → 0 across the reaction window after ▶: a quick squint-in, a held happy
    /// beat, then a smooth release back to the resting face.
    private func happiness(at t: Double) -> CGFloat {
        guard let start = reactionStart else { return 0 }
        let elapsed = t - start
        let rampIn = Self.reactionRampIn
        let hold = Self.reactionHold
        let rampOut = Self.reactionRampOut
        switch elapsed {
        case ..<0: return 0
        case ..<rampIn: return CGFloat(elapsed / rampIn)
        case ..<(rampIn + hold): return 1
        case ..<(rampIn + hold + rampOut): return CGFloat(1 - (elapsed - rampIn - hold) / rampOut)
        default: return 0
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, frame: FaceArt.Frame) {
        // Square cells sized to the panel width — the dot pitch of the LED panel.
        let cell = size.width / CGFloat(FaceGrid.cols)
        let dot = cell * FaceGrid.dotRatio

        // Unlit grid fills the WHOLE panel edge-to-edge (a real LED panel), so draw
        // as many rows as the height needs — not just the face's 24×15 footprint.
        let panelRows = Int((size.height / cell).rounded(.up))
        let ox = (size.width - cell * CGFloat(FaceGrid.cols)) / 2
        let oy = (size.height - cell * CGFloat(panelRows)) / 2

        func at(_ c: Int, _ r: Int, _ d: CGFloat) -> CGRect {
            let cx = ox + (CGFloat(c) + 0.5) * cell
            let cy = oy + (CGFloat(r) + 0.5) * cell
            return CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        }

        for r in 0..<panelRows {
            for c in 0..<FaceGrid.cols {
                ctx.fill(
                    Path(ellipseIn: at(c, r, dot)),
                    with: .color(accent.opacity(FaceGrid.unlitOpacity)))
            }
        }

        // The face (lit dots) sits CENTERED on the panel at its own scale, so the
        // expression's size is a knob independent of the panel's dot density. At
        // scale 1 the lit dots land exactly on grid cells (vertically centered by an
        // integer row offset); above 1 they scale out from the panel centre.
        let rowOffset = (panelRows - FaceGrid.rows) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let faceDot = dot * FaceGrid.faceScale
        func faceAt(_ c: Int, _ r: Int, _ d: CGFloat) -> CGRect {
            let base = at(c, r + rowOffset, d)
            let cx = center.x + (base.midX - center.x) * FaceGrid.faceScale
            let cy = center.y + (base.midY - center.y) * FaceGrid.faceScale
            return CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        }

        // Soft halo under each lit dot, then the blush, then the lit dots on top.
        let halo = faceDot * FaceGrid.haloScale
        for d in frame.bright {
            ctx.fill(
                Path(ellipseIn: faceAt(d.c, d.r, halo)),
                with: .color(accent.opacity(FaceGrid.haloOpacity)))
        }
        for d in frame.dim {
            ctx.fill(
                Path(ellipseIn: faceAt(d.c, d.r, faceDot)),
                with: .color(accent.opacity(FaceGrid.blushOpacity)))
        }
        for d in frame.bright {
            ctx.fill(Path(ellipseIn: faceAt(d.c, d.r, faceDot)), with: .color(accent))
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
    // Size of the lit FACE relative to the (panel-filling) grid pitch. 1.0 = the
    // expression sits one-dot-per-cell on the grid; >1 enlarges the face, scaling
    // out from the panel centre while the unlit grid still fills the whole panel.
    static let faceScale: CGFloat = 0.7
    static let blinkPeriod: Double = 3.4  // seconds between blinks
    static let leftEye = (c: 7, r: 5)  // row 5 = eyes-up (not centred row 6)
    static let rightEye = (c: 16, r: 5)
    // Glow / render opacities.
    static let unlitOpacity: Double = 0.06
    static let haloScale: CGFloat = 2.2
    static let haloOpacity: Double = 0.20  // per-dot bloom (tuned by feel)
    static let blushOpacity: Double = 0.4
    static let glowOpacity: Double = 0.05  // outer panel glow — kept subtle (tuned)
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

    static func cute(t: Double, happy: CGFloat = 0) -> Frame {
        var f = Frame()
        // The happy reaction squints the eyes shut into smiling lines and lifts the
        // mouth; while active it overrides the idle blink.
        let open = min(blink(t), 1 - happy)
        roundEye(FaceGrid.leftEye, open: open, into: &f.bright)
        roundEye(FaceGrid.rightEye, open: open, into: &f.bright)
        let br = FaceGrid.leftEye.r + 3  // blush sits just below the eyes
        for d in [
            Dot(FaceGrid.leftEye.c - 3, br), Dot(FaceGrid.leftEye.c - 2, br),
            Dot(FaceGrid.rightEye.c + 2, br), Dot(FaceGrid.rightEye.c + 3, br),
        ] {
            f.dim.insert(d)
        }
        smile(into: &f.bright, lift: happy)
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

    /// A gentle upward smile centred under the eyes. `lift` (0…1) raises the whole
    /// mouth a row for the happy reaction.
    private static func smile(into s: inout Set<Dot>, lift: CGFloat = 0) {
        let rise = Int(lift.rounded())
        for c in 9...14 {
            let dx = Double(c) - 11.5
            let curve = Int((dx * dx * 0.14).rounded())
            s.insert(Dot(c, 11 - curve - rise))
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
