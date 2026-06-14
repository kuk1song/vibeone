import Foundation
import Testing

@testable import VibeOneEngine

// Continuous privacy guard for the committed golden-master fixtures (ADR-010):
// scrubbing is deterministic, but a future fixture could be added without it.
// This runs in CI (the fixtures are bundled), so any real home path, email, or
// credential that slips into `Tests/.../Fixtures` fails the build.

@Suite("Fixture privacy")
struct FixturePrivacyTests {

    /// Every `.jsonl` under the bundled `Fixtures` directory.
    static let fixtureFiles: [URL] = {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            return []
        }
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "jsonl" { out.append(url) }
        }
        return out
    }()

    /// Fail loudly if discovery breaks — otherwise the parameterized guard below
    /// would run zero cases and silently "pass".
    @Test("the known fixtures are discovered")
    func fixturesAreDiscovered() {
        #expect(
            Self.fixtureFiles.count >= 2,
            "expected to discover the committed fixtures; found \(Self.fixtureFiles.count)")
    }

    @Test(
        "fixtures carry no real home paths, emails, or credentials",
        arguments: fixtureFiles)
    func noLeak(_ file: URL) throws {
        let content = try String(contentsOf: file, encoding: .utf8)

        // Only the scrub sentinels are allowed.
        for path in matches(#"/(?:Users|home)/[^/"\\]+"#, in: content) {
            #expect(
                path == "/Users/dev" || path == "/home/dev",
                "\(file.lastPathComponent): unexpected home path \(path)")
        }
        for email in matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: content) {
            #expect(
                email == "dev@example.com",
                "\(file.lastPathComponent): unexpected email \(email)")
        }
        let credentials = matches(
            #"sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{16}"#,
            in: content)
        #expect(credentials.isEmpty, "\(file.lastPathComponent): credential-like token(s) present")
    }

    private func matches(_ pattern: String, in string: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = string as NSString
        return re.matches(in: string, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
