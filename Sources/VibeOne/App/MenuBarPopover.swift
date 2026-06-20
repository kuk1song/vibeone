import AppKit

/// Closes VibeOne's menu-bar popover from code — the "get out of the way after a
/// switch" step (the popover otherwise lingers over the app you just switched into).
///
/// SwiftUI's `MenuBarExtra(.window)` has NO first-party way to dismiss its window
/// programmatically (Apple feedback FB10185203 / FB11984872 are still open). The
/// reliable workaround is to mimic a click on the menu-bar status item, which both
/// closes the window AND resets the item's internal presented-state — a bare
/// `window.close()` leaves the item stuck "on" so the next menu-bar click can't
/// reopen it.
///
/// Reaching the status item needs a sliver of AppKit introspection (the
/// `statusItem` key is private). VibeOne ships Developer-ID-signed + notarized, not
/// through the App Store (ADR-004), so this is acceptable; it's quarantined here so
/// it's a one-line swap the day Apple ships a real API. The `responds(to:)` guard
/// keeps a future OS that drops the key a graceful no-op rather than a crash.
@MainActor
enum MenuBarPopover {

    /// Dismiss the popover if it's currently open. A no-op when it's already closed
    /// (e.g. focus already moved to the target app) — the `.on` check means this
    /// never accidentally OPENS the popover.
    static func dismiss() {
        let statusItemKey = "statusItem"
        let selector = NSSelectorFromString(statusItemKey)
        for window in NSApp.windows
        where window.className.contains("NSStatusBarWindow") && window.responds(to: selector) {
            guard let item = window.value(forKey: statusItemKey) as? NSStatusItem,
                let button = item.button,
                button.state == .on
            else { continue }
            button.performClick(button)
        }
    }
}
