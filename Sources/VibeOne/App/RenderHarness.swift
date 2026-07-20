import AppKit
import SwiftUI
import VibeOneEngine

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

        render(popover(destination: .codex), name: "popover-switch-to-codex", dir: dir)
        render(
            PopoverCard(state: seededState(destination: .codex, codexDesktop: false)),
            name: "popover-switch-to-codex-terminal", dir: dir)
        render(popover(destination: .claude), name: "popover-switch-to-claude", dir: dir)
        render(queue(), name: "popover-queue", dir: dir)
        render(settings(), name: "popover-settings", dir: dir)
        // Frozen frames prove the face blinks: open (t=1.0) vs mid-blink (t=0.08).
        render(faceCover(t: 1.0), name: "facecover-open", dir: dir)
        render(faceCover(t: 0.08), name: "facecover-blink", dir: dir)
        render(MenuBarStrip(), name: "menubar", dir: dir)

        exit(0)
    }

    /// A popover seeded with deterministic sample sessions (the live `AppState`
    /// loads from disk asynchronously, too late for a synchronous render).
    static func popover(destination: Agent) -> some View {
        PopoverCard(state: seededState(destination: destination))
    }

    /// The pull-up queue, flattened (no `ScrollView`) so ImageRenderer lays it out.
    static func queue() -> some View {
        QueueView(state: seededState(destination: .codex), scrollable: false)
    }

    private static func seededState(destination: Agent, codexDesktop: Bool = true) -> AppState {
        let state = AppState(autoload: false)
        state.projects = sampleProjects()
        state.selection = destination
        state.codexOpensDesktop = codexDesktop
        // Sample deny-list so the Settings render shows the editable list with rows
        // (the inert harness instance neither persists nor refreshes from this).
        state.protectedPaths = ["~/ot", "~/clients/acme"]
        // Sample drift (memory + MCP aligned, skills not) so the segmented bar shows
        // its lit/unlit contrast — preview data, like the sample projects above, not
        // this machine's real status.
        state.configStatus = sampleStatus()
        return state
    }

    /// The pull-up settings panel (opened from ⋯).
    static func settings() -> some View {
        SettingsPanel(state: seededState(destination: .codex))
    }

    /// Three projects (albums) with mixed agents — what `projectSessions()` returns.
    /// Ages are relative to launch so the "Nm/Nh/Nd ago" labels read naturally.
    static func sampleProjects() -> [SessionHandoff.ProjectSessions] {
        let now = Date()
        func summary(_ agent: Agent, _ project: String, ago: TimeInterval, generated: Bool = false)
            -> SessionSummary
        {
            SessionSummary(
                agent: agent.rawValue,
                id: "\(agent.rawValue)-\(project)\(generated ? "-copy" : "")",
                workspace: "/Users/dev/\(project)",
                path: URL(fileURLWithPath: "/tmp/\(agent.rawValue)-\(project).jsonl"),
                modified: now.addingTimeInterval(-ago),
                generatedByVibeOne: generated)
        }
        return [
            .init(
                workspace: "/Users/dev/slash-stage",
                claude: [summary(.claude, "slash-stage", ago: 120)],
                // A VibeOne handoff copy (newest) plus the user's own session: the
                // queue lists both, but the player default skips the copy (PR-F).
                codex: [
                    summary(.codex, "slash-stage", ago: 60, generated: true),
                    summary(.codex, "slash-stage", ago: 3600),
                ]),
            .init(
                workspace: "/Users/dev/PrivateGpt",
                claude: [summary(.claude, "PrivateGpt", ago: 10800)], codex: []),
            .init(
                workspace: "/Users/dev/rag-pipeline",
                claude: [], codex: [summary(.codex, "rag-pipeline", ago: 90000)]),
        ]
    }

    /// Sample config drift = 2/3 (memory + MCP aligned, skills not) so the segmented
    /// status bar renders with visible lit/unlit segments. Preview data only.
    static func sampleStatus() -> ConfigStatus {
        ConfigStatus(
            memory: .init(agentsExists: true, claudeImportsAgents: true, claudeHasContent: true),
            mcp: .init(
                claudeServers: ["filesystem"], codexServers: ["filesystem"],
                missingInCodex: [], missingInClaude: [], userScopeServers: [],
                codexGlobalServers: []),
            skills: .init(
                claudeSkills: ["web-access"], codexSkills: [],
                missingInCodex: ["web-access"], missingInClaude: []))
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
