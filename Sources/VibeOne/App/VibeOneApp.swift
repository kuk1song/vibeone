import AppKit
import SwiftUI

/// VibeOne — a menu-bar-only macOS utility to switch a project between Claude
/// Code and Codex.
///
/// The ENTIRE UI is a `MenuBarExtra`: a small tinted glyph in the menu bar that
/// reflects the active agent's accent, and a popover (`.menuBarExtraStyle(.window)`)
/// carrying the VibeOne card. There is NO main window and NO Dock icon — the
/// `AppDelegate` sets the activation policy to `.accessory`, the macOS behavior
/// for a menu-bar-only ("LSUIElement") utility.
///
/// The popover does NOT draw its own material: it rides the system's native
/// vibrant window chrome that `.window` style provides, which auto-adapts to
/// light/dark and to Reduce Transparency for free. Pure SwiftUI + a one-line
/// AppKit hook for the accessory activation policy. Zero third-party deps.
@main
struct VibeOneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            // Popover content.
            PopoverCard(state: state)
        } label: {
            // The menu-bar item itself: a tinted glyph reflecting the active
            // agent. Rendered from a non-template NSImage so the accent survives
            // in both light and dark menu bars.
            Image(nsImage: MenuBarIcon.image(for: state.selection))
        }
        .menuBarExtraStyle(.window)  // popover with native vibrant window chrome
    }
}

/// Menu-bar-only accessory app: NO Dock icon, NO app-switcher entry, NO main
/// window. `.accessory` is the programmatic equivalent of the `LSUIElement`
/// Info.plist flag (which a bare SwiftPM executable has no bundle to carry), so
/// we set it here at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
