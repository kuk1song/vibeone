import Foundation
import Testing

@testable import VibeOneEngine

/// `FileHead.firstLine` must agree with `FileHead.lines(...).first` — the call
/// it replaces on the Codex enumeration path — while decoding only up to the
/// first newline instead of materializing every line in the head window.
@Suite("FileHead first-line read")
struct FileHeadTests {

    private func firstLine(of contents: String) throws -> String? {
        var out: String?
        try withTempSession(contents) { url in out = FileHead.firstLine(of: url) }
        return out
    }

    @Test("returns the first line of a multi-line file")
    func multiLine() throws {
        #expect(
            try firstLine(of: "{\"type\":\"session_meta\"}\n{\"type\":\"event_msg\"}\n")
                == "{\"type\":\"session_meta\"}")
    }

    @Test("returns the whole content when there is no newline")
    func noNewline() throws {
        #expect(try firstLine(of: "{\"only\":\"line\"}") == "{\"only\":\"line\"}")
    }

    @Test("skips leading blank lines, matching lines(of:).first")
    func leadingBlankLines() throws {
        #expect(try firstLine(of: "\n\nreal\nrest\n") == "real")
    }

    @Test("nil for an empty file")
    func emptyFile() throws {
        #expect(try firstLine(of: "") == nil)
    }

    @Test("nil for a newline-only file")
    func newlineOnlyFile() throws {
        #expect(try firstLine(of: "\n\n\n") == nil)
    }

    @Test("nil for a missing file")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeone-nonexistent-\(UUID().uuidString).jsonl")
        #expect(FileHead.firstLine(of: url) == nil)
    }

    @Test("agrees with lines(of:).first on a realistic rollout head")
    func equivalenceWithLines() throws {
        let body = """
            {"type":"session_meta","payload":{"id":"x","cwd":"/Users/dev/proj"}}
            {"type":"turn_context","payload":{"model":"gpt-5.4"}}
            """
        try withTempSession(body) { url in
            #expect(FileHead.firstLine(of: url) == FileHead.lines(of: url).first)
        }
    }
}
