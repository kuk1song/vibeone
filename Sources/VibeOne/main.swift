import Foundation
import VibeOneEngine

// Entry point. Normal launch runs the SwiftUI app; `--render <dir>` runs the
// dev-only image harness that rasterizes the shipping views to PNGs so the UI can
// be eyeballed without a live menu-bar popover. `--handoff [workspace]` runs the
// play action's FILE step headlessly. Replaces `@main` so we can branch before the
// App scene starts.
if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let out =
        CommandLine.arguments.count > idx + 1
        ? CommandLine.arguments[idx + 1] : "/tmp/vibeone-shots"
    MainActor.assumeIsolated { RenderHarness.run(outDir: out) }
} else if let idx = CommandLine.arguments.firstIndex(of: "--handoff") {
    // Dev smoke: run only the FILE step of a Claude -> Codex switch (no GUI, no
    // launch). With a workspace arg it hands off that project's newest Claude
    // session; with none, the globally newest. Writes a fresh-UUID Codex rollout
    // only — never touches the source or any other session.
    let next = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : nil
    let workspaceArg = (next?.hasPrefix("-") == false) ? next : nil
    do {
        let result: SessionHandoff.Result
        if let workspace = workspaceArg {
            result = try SessionHandoff.claudeToCodex(workspace: workspace)
        } else if let current = SessionHandoff.currentClaudeSession() {
            result = try SessionHandoff.claudeToCodex(
                workspace: current.workspace, source: current.path)
        } else {
            print("[vibeone] no current Claude session found")
            exit(1)
        }
        print("[vibeone] handoff -> codex: id=\(result.sessionId) msgs=\(result.messageCount)")
        print("[vibeone] target=\(result.path.path)")
    } catch {
        print("[vibeone] handoff failed: \(error)")
        exit(1)
    }
} else {
    VibeOneApp.main()
}
