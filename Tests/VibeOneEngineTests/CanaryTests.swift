import Foundation
import Testing

@testable import VibeOneEngine

// Drift sentinel — the *local / self-hosted nightly* leg of PR-E E4 (ADR-010 ⑥).
//
// Where the E1 real-data tests are *opportunistic* — `.enabled(if: data-present)`,
// so they skip silently when a directory is missing — this suite is *assertive*.
// It runs only when the canary runner sets `VIBEONE_CANARY=1`, and then it
// *demands* that real sessions exist and still parse. A silent skip is exactly the
// failure mode that would hide the storage move Codex shipped in 26.609 (rollouts
// → `~/.codex/sqlite`): the canary turns "the directory went empty" from a green
// skip into a red failure, before a user hits the breakage.
//
// Parsing goes through the *adapters* (`ClaudeSessionStore`/`CodexSessionStore`),
// so the E3 boundary validation runs against current on-disk data: a format change
// that yields an empty IR throws a located `SessionReadError` instead of passing.
//
// Normal `swift test` (CI, PRs) leaves `VIBEONE_CANARY` unset → the whole suite is
// disabled → zero added CI noise. The *synthetic* leg (install latest CLI →
// generate a session → parse) lives in `.github/workflows/canary.yml`.

private let canaryEnabled = ProcessInfo.processInfo.environment["VIBEONE_CANARY"] == "1"
private let home = FileManager.default.homeDirectoryForCurrentUser

@Suite("Canary — drift sentinel against current on-disk data")
struct CanaryTests {

    // MARK: Claude sessions

    @Test("Claude sessions still exist on disk", .enabled(if: canaryEnabled))
    func claudeStoragePresent() {
        #expect(
            !RealData.claudeSessionFiles.isEmpty,
            """
            canary: no Claude sessions discovered under ~/.claude/projects. \
            On a machine that uses Claude Code this means the storage layout moved \
            (cf. Codex 26.609 → ~/.codex/sqlite). Update SessionLocation/parser.
            """)
    }

    @Test(
        "Claude store parses every current local session",
        .enabled(if: canaryEnabled),
        arguments: RealData.claudeSessionFiles)
    func claudeStoreParses(_ file: URL) throws {
        // `read` runs the E3 boundary validation — a format change that yields an
        // empty IR throws a located SessionReadError rather than passing silently.
        let session = try ClaudeSessionStore(home: home).read(file)
        #expect(session.sourceAgent == "claude")
        #expect(session.messages.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: Codex rollouts

    @Test("Codex rollouts still exist on disk", .enabled(if: canaryEnabled))
    func codexStoragePresent() {
        #expect(
            !RealData.codexRolloutFiles.isEmpty,
            """
            canary: no Codex rollouts discovered under ~/.codex/sessions. The GUI \
            stopped collecting external rollouts in 26.609 but still writes them \
            here; an empty tree means the layout moved again. \
            Update SessionLocation/parser.
            """)
    }

    @Test(
        "Codex store parses every current local rollout",
        .enabled(if: canaryEnabled),
        arguments: RealData.codexRolloutFiles)
    func codexStoreParses(_ file: URL) throws {
        let session = try CodexSessionStore(home: home).read(file)
        #expect(session.sourceAgent == "codex")
        #expect(session.messages.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: Config (MCP translation surface)

    @Test("Codex config.toml still parses", .enabled(if: canaryEnabled))
    func codexConfigParses() throws {
        let url = ConfigLocation.codexConfig(home: home)
        #expect(
            FileManager.default.fileExists(atPath: url.path),
            "canary: ~/.codex/config.toml is missing — Codex config layout moved?")
        for server in CodexMCP.read(toml: try String(contentsOf: url, encoding: .utf8)) {
            #expect(!server.name.isEmpty, "canary: parsed an MCP server with an empty name")
        }
    }
}
