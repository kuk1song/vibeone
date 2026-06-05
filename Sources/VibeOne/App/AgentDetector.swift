import Foundation

/// Detects whether the agent CLIs are actually installed on this machine.
/// Runs via `/usr/bin/env bash -lc "command -v <bin>"` (a login+interactive
/// shell so PATH matches the user's interactive environment, e.g. nvm /
/// homebrew shims). Copied verbatim from the gallery spike — REAL detection.
enum AgentDetector {

    struct Availability: Sendable {
        var claudeInstalled: Bool
        var codexInstalled: Bool

        func isInstalled(_ agent: Agent) -> Bool {
            switch agent {
            case .claude: return claudeInstalled
            case .codex: return codexInstalled
            }
        }

        /// e.g. "claude ✓ installed · codex ✗ not found"
        var summary: String {
            let c = claudeInstalled ? "claude ✓ installed" : "claude ✗ not found"
            let x = codexInstalled ? "codex ✓ installed" : "codex ✗ not found"
            return "\(c) · \(x)"
        }
    }

    /// Synchronous detection. Cheap (two short-lived processes); call once off
    /// the main thread at launch.
    static func detect() -> Availability {
        Availability(
            claudeInstalled: isOnPath("claude"),
            codexInstalled: isOnPath("codex")
        )
    }

    private static func isOnPath(_ binary: String) -> Bool {
        // Login+interactive shell so user PATH customizations load, then
        // `command -v` (POSIX, like `which`) to test for the binary.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "-lc", "command -v \(binary)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            // `command -v` exits 0 and prints a path when found.
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
