import Foundation
import Testing

@testable import VibeOneEngine

/// `PathGuard` is the safety deny-list: filesystem roots VibeOne must never touch
/// (ADR-012). These cases pin the fail-safe matching contract — canonicalization,
/// segment-boundary containment, case-insensitivity, symlink/`..` resistance, and
/// fail-closed behavior — against a real, isolated temp home so the FS-level
/// properties (symlinks especially) are exercised for real, not mocked.
@Suite struct PathGuardTests {

    /// A throwaway home with a real `ot/work/repo` tree and a sibling `other`,
    /// handed to `body`, then removed. Unique dir → safe under parallel testing.
    private func withHome(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("vibeone-guard-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.createDirectory(
            at: home.appendingPathComponent("ot/work/repo"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: home.appendingPathComponent("other"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: home.appendingPathComponent("projects/foo"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try body(home)
    }

    @Test func deniesExactRoot() throws {
        try withHome { home in
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(guard1.isDenied(home.appendingPathComponent("ot").path))
        }
    }

    @Test func deniesDescendant() throws {
        try withHome { home in
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(guard1.isDenied(home.appendingPathComponent("ot/work/repo").path))
        }
    }

    @Test func allowsSiblingWithSharedPrefix() throws {
        try withHome { home in
            // "~/other" shares the string prefix "~/ot" but is NOT below it.
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(!guard1.isDenied(home.appendingPathComponent("other").path))
        }
    }

    @Test func allowsUnrelatedPath() throws {
        try withHome { home in
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(!guard1.isDenied(home.appendingPathComponent("projects/foo").path))
        }
    }

    @Test func matchingIsCaseInsensitive() throws {
        try withHome { home in
            // Deny one case, query another — fail-safe over-denying (the default
            // macOS volume is case-insensitive anyway).
            let guard1 = PathGuard(deniedPaths: ["~/OT"], home: home)
            #expect(guard1.isDenied(home.appendingPathComponent("ot/work").path))
        }
    }

    @Test func expandsTilde() throws {
        try withHome { home in
            // "~/ot" (entry) must guard the equivalent absolute candidate.
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(guard1.isDenied(home.appendingPathComponent("ot/x").path))
        }
    }

    @Test func resistsDotDotTraversal() throws {
        try withHome { home in
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            let sneaky = home.appendingPathComponent("other/../ot/work/repo").path
            #expect(guard1.isDenied(sneaky))
        }
    }

    @Test func resistsSymlinkBypass() throws {
        try withHome { home in
            // A symlink that points INTO the denied tree must not smuggle a path past.
            let link = home.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: home.appendingPathComponent("ot"))
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(guard1.isDenied(link.appendingPathComponent("work/repo").path))
        }
    }

    @Test func ignoresBlankEntries() throws {
        try withHome { home in
            let guard1 = PathGuard(deniedPaths: ["", "   ", "\n"], home: home)
            #expect(!guard1.isDenied(home.appendingPathComponent("ot/work").path))
        }
    }

    @Test func failsClosedOnEmptyCandidate() throws {
        try withHome { home in
            // An unresolvable candidate is treated as denied (fail-closed).
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(guard1.isDenied(""))
            #expect(guard1.isDenied("   "))
        }
    }

    @Test func doesNotOverMatchFilesystemRoot() throws {
        try withHome { home in
            // A denied root with several segments must not deny "/" (fewer segments).
            let guard1 = PathGuard(deniedPaths: ["~/ot"], home: home)
            #expect(!guard1.isDenied("/"))
        }
    }

    @Test func deniesMultipleRoots() throws {
        try withHome { home in
            // The editor lets a user add more than the preset; a multi-entry list
            // must guard under EACH root, while unrelated paths stay allowed.
            let guard1 = PathGuard(deniedPaths: ["~/ot", "~/projects/foo"], home: home)
            #expect(guard1.isDenied(home.appendingPathComponent("ot/work/repo").path))
            #expect(guard1.isDenied(home.appendingPathComponent("projects/foo").path))
            #expect(!guard1.isDenied(home.appendingPathComponent("other").path))
        }
    }

    @Test func presetGuardsWorkTree() throws {
        try withHome { home in
            // The default preset every user starts with denies ~/ot.
            let preset = PathGuard.preset(home: home)
            #expect(preset.isDenied(home.appendingPathComponent("ot/work/repo").path))
            #expect(!preset.isDenied(home.appendingPathComponent("projects/foo").path))
        }
    }

    @Test func emptyGuardDeniesNothing() throws {
        try withHome { home in
            let guard1 = PathGuard(deniedPaths: [], home: home)
            #expect(!guard1.isDenied(home.appendingPathComponent("ot/work/repo").path))
        }
    }
}
