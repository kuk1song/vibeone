import Foundation

/// A safety deny-list: filesystem roots VibeOne must NEVER touch (ADR-012).
///
/// Defense-in-depth ("双保险"): denied workspaces are both hidden from the session
/// picker (`SessionHandoff.projectSessions(excluding:)`) AND hard-rejected at switch
/// time, so a forbidden path can't be acted on even if it somehow surfaces. The
/// default preset guards the user's work tree (`~/ot`).
///
/// Matching is fail-safe by construction — it errs toward denying:
///   • each entry and every candidate are *canonicalized* — `~` expanded, `.`/`..`
///     resolved, symlinks followed — so neither a `../` detour nor a symlink can
///     smuggle a path past the list (CWE-22 path-traversal hygiene);
///   • a candidate is denied when it EQUALS a denied root or sits anywhere BELOW
///     one, compared on whole path *segments* (so `~/ot` guards `~/ot/work` but not
///     a sibling `~/other` that merely shares a string prefix);
///   • comparison is case-insensitive (the default macOS volume is, and over-
///     denying a case variant is the safe direction);
///   • a candidate that can't be canonicalized is treated as denied (fail-closed).
public struct PathGuard: Sendable {
    /// Canonical, lowercased path-component arrays for each denied root.
    private let deniedRoots: [[String]]
    private let home: URL

    /// Build a guard from raw user entries (absolute paths or `~`-relative). Blank
    /// entries are dropped; the rest are canonicalized once, up front.
    public init(
        deniedPaths: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.home = home
        deniedRoots =
            deniedPaths
            .compactMap { Self.canonicalComponents($0, home: home) }
            .filter { !$0.isEmpty }  // drop blanks and "/" (deny-everything is nonsensical)
    }

    /// The default preset every user starts with: the work tree is off-limits.
    public static func preset(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PathGuard {
        PathGuard(deniedPaths: ["~/ot"], home: home)
    }

    /// True when `path` is (or is inside) any denied root — VibeOne must not touch it.
    public func isDenied(_ path: String) -> Bool {
        guard let candidate = Self.canonicalComponents(path, home: home) else {
            return true  // unresolvable → fail-closed
        }
        return deniedRoots.contains { root in
            candidate.count >= root.count && Array(candidate.prefix(root.count)) == root
        }
    }

    /// Canonicalize a path into lowercased segments: expand a leading `~`, resolve
    /// `.`/`..` and symlinks, then split on path boundaries (dropping the `/` root).
    /// Returns `nil` for a blank/unresolvable path (callers fail closed) but `[]`
    /// for the filesystem root `/` (a real path that is below no deny root).
    private static func canonicalComponents(_ path: String, home: URL) -> [String]? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded: String
        if trimmed == "~" {
            expanded = home.path
        } else if trimmed.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(trimmed.dropFirst(2))).path
        } else {
            expanded = trimmed
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        return url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
    }
}
