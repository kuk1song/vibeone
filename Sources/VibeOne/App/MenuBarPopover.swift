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
/// `statusItem` key is private). VibeOne targets Developer ID + notarized
/// distribution rather than the App Store (ADR-004; current 0.1 builds are still
/// ad-hoc), so this is acceptable; it's quarantined here so it's a one-line swap
/// the day Apple ships a real API. The `responds(to:)` guard keeps a future OS that
/// drops the key a graceful no-op rather than a crash.
@MainActor
enum MenuBarPopover {

    /// Dismiss the popover if it's currently open. A no-op when it's already closed
    /// (e.g. focus already moved to the target app) — the `.on` check means this
    /// never accidentally OPENS the popover.
    static func dismiss() { toggle(when: .on) }

    /// Re-open the popover if it's currently closed — used to bring the user back to
    /// the list after the folder picker (`addProtectedFolder` closes the popover for
    /// the modal, then calls this once it returns). Mirror of `dismiss()`: the `.off`
    /// check means it only ever OPENS a closed popover, never closes an open one.
    ///
    /// The caller must hand us a known-closed popover (it dismisses first): after a
    /// modal, the status item's `.state` is an unreliable proxy for visibility — it
    /// can read `.on` while the popover is hidden, which made a bare reopen skip on
    /// ~half the attempts (measured). A self-inflicted close keeps `.state` honest.
    static func reopen() { toggle(when: .off) }

    /// Click the menu-bar status item iff it is currently in `state` — the reliable
    /// MenuBarExtra(.window) toggle workaround (Apple FB10185203 / FB11984872). The
    /// state guard makes open/close idempotent and direction-safe.
    private static func toggle(when state: NSControl.StateValue) {
        let statusItemKey = "statusItem"
        let selector = NSSelectorFromString(statusItemKey)
        for window in NSApp.windows
        where window.className.contains("NSStatusBarWindow") && window.responds(to: selector) {
            guard let item = window.value(forKey: statusItemKey) as? NSStatusItem,
                let button = item.button,
                button.state == state
            else { continue }
            button.performClick(button)
        }
    }
}
