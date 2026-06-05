import SwiftUI

/// Shared app state: the active agent (drives the popover AND the menu-bar icon
/// tint) plus the real CLI availability detected once at launch.
@MainActor
final class AppState: ObservableObject {
    @Published var selection: Agent = .claude

    /// Real `command -v claude/codex` result. Starts pessimistic (not found) and
    /// is filled in by a background detect() so the menu bar appears instantly.
    @Published var availability = AgentDetector.Availability(
        claudeInstalled: false, codexInstalled: false
    )

    init() {
        // Detect off the main thread (each probe spawns a short-lived shell),
        // then publish on the main actor.
        Task.detached(priority: .userInitiated) {
            let result = AgentDetector.detect()
            await MainActor.run { self.availability = result }
        }
    }
}
