import Foundation

// Entry point. Normal launch runs the SwiftUI app; `--render <dir>` runs the
// dev-only image harness that rasterizes the shipping views to PNGs so the UI can
// be eyeballed without a live menu-bar popover. Replaces `@main` so we can branch
// before the App scene starts.
if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let out =
        CommandLine.arguments.count > idx + 1
        ? CommandLine.arguments[idx + 1] : "/tmp/vibeone-shots"
    MainActor.assumeIsolated { RenderHarness.run(outDir: out) }
} else {
    VibeOneApp.main()
}
