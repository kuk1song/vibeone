// swift-tools-version: 6.2
import PackageDescription

// VibeOne — a native macOS menu-bar utility that makes a single project switch
// seamlessly between Claude Code and Codex: it keeps their config (memory /
// skills / MCP) in sync AND hands off the in-flight conversation, so the two
// agents share one context.
//
// One package, two targets:
//   • VibeOne        — the MenuBarExtra app (SwiftUI). Run with `swift run`.
//   • VibeOneEngine  — agent-neutral session-handoff + config logic. Pure
//                      Foundation, no UI, so it unit-tests fast (`swift test`).
//
// Zero third-party dependencies. macOS 26 / Swift 6.2 (see local_notes ADRs).
let package = Package(
    name: "VibeOne",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "VibeOne", targets: ["VibeOne"]),
        .library(name: "VibeOneEngine", targets: ["VibeOneEngine"]),
    ],
    targets: [
        .executableTarget(
            name: "VibeOne",
            dependencies: ["VibeOneEngine"]
        ),
        .target(name: "VibeOneEngine"),
        .testTarget(
            name: "VibeOneEngineTests",
            dependencies: ["VibeOneEngine"],
            // Golden-master inputs (scrubbed real sessions). `.copy` keeps the
            // JSONL byte-exact; `.process` would not. Read via `Bundle.module`.
            // Expected snapshots are NOT bundled — they live next to the test
            // source and are read/recorded symmetrically via `#filePath` (ADR-010),
            // so they are `exclude`d rather than declared as resources.
            exclude: ["Snapshots"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
