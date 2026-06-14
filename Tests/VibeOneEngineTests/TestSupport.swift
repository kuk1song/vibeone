import Foundation
import Testing

@testable import VibeOneEngine

// Shared support for the migrated Swift Testing suites (PR-E1). Keeps the
// real-data discovery and the named round-trip samples in one place so the
// per-agent suites stay focused on assertions.

/// A canonical session paired with a short label, so parameterized round-trip
/// cases print a readable name instead of the whole struct.
struct NamedSession: CustomTestStringConvertible, Sendable {
    let name: String
    let session: CanonicalSession
    var testDescription: String { name }
}

/// Write `contents` to a `.jsonl` in a unique temp dir, run `body` with its URL,
/// then delete the dir. The unique dir makes this safe under Swift Testing's
/// default parallelism — no `.serialized` needed.
func withTempSession(_ contents: String, _ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibeone-read-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("session.jsonl")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try body(url)
}

/// Genuine sessions on *this* machine, surfaced one file per case. CI machines
/// have neither directory, so the owning `@Test` is `.enabled(if:)`-gated on a
/// non-empty list and is reported as skipped there — never a failure.
enum RealData {
    /// Upper bound on real-data cases: a machine with thousands of sessions
    /// shouldn't flood the suite. Each surfaced file is still an independent,
    /// individually re-runnable case. Bounded on purpose (no silent truncation:
    /// the cap is named and documented).
    static let maxCases = 50

    /// One representative `.jsonl` transcript per project under
    /// `~/.claude/projects` (capped at `maxCases`).
    static let claudeSessionFiles: [URL] = {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard
            let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [URL] = []
        for dir in dirs {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                let jsonl = files.first(where: { $0.pathExtension == "jsonl" })
            {
                out.append(jsonl)
            }
        }
        return Array(out.prefix(maxCases))
    }()

    /// `rollout-*.jsonl` rollouts under `~/.codex/sessions` (recursive, capped
    /// at `maxCases`).
    static let codexRolloutFiles: [URL] = {
        let fm = FileManager.default
        let sessions = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let en = fm.enumerator(at: sessions, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in en
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            out.append(url)
            if out.count >= maxCases { break }
        }
        return out
    }()
}
