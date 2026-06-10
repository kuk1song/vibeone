import AppKit
import SwiftUI

// MARK: - Render harness  (dev tool)
//
// `swift run VibeOne --render <dir>` rasterizes the SHIPPING views to PNGs via
// ImageRenderer, so the popover and menu-bar icon can be eyeballed without a live
// menu-bar popover (which is hard to screenshot). Dev only — gated behind
// `--render`, never part of the running app. Zero dependencies.
@MainActor
enum RenderHarness {
    static func run(outDir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        render(popover(.claude), name: "popover-claude", dir: dir)
        render(popover(.codex), name: "popover-codex", dir: dir)
        // Frozen frames prove the face blinks: open (t=1.0) vs mid-blink (t=0.08).
        render(faceCover(t: 1.0), name: "facecover-open", dir: dir)
        render(faceCover(t: 0.08), name: "facecover-blink", dir: dir)
        render(MenuBarStrip(), name: "menubar", dir: dir)

        exit(0)
    }

    static func popover(_ agent: Agent) -> some View {
        let state = AppState()
        state.selection = agent
        return PopoverCard(state: state)
    }

    static func faceCover(t: Double) -> some View {
        FaceCover(accent: DS.Colors.accentClaude, time: t)
            .frame(width: DS.Size.playerCover, height: DS.Size.playerCover)
            .padding(DS.Spacing.xl)
    }

    static func render(_ view: some View, name: String, dir: URL) {
        let wrapped =
            view
            .frame(width: DS.Size.cardWidth)
            .background(Color(hex: 0x1C1C1E))
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
            let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("render failed: \(name)\n".utf8))
            return
        }
        let url = dir.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("wrote \(url.path)")
    }
}

/// Both agents' menu-bar face icons on light + dark strips, scaled up so the
/// ~20×16 pt glyph is eyeballable for legibility on either menu bar.
private struct MenuBarStrip: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(["light", "dark"], id: \.self) { mode in
                HStack(spacing: DS.Spacing.xl) {
                    ForEach(Agent.allCases) { agent in
                        Image(nsImage: MenuBarIcon.image(for: agent))
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 60, height: 48)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(DS.Spacing.lg)
                .background(mode == "light" ? Color.white : Color.black)
            }
        }
    }
}
