import Foundation
import Testing

@testable import VibeOneEngine

/// `FileLines` must yield exactly the records `String.split(separator: "\n",
/// omittingEmptySubsequences: true)` would — the codecs' historical contract —
/// while reading in bounded chunks. Tiny `chunkBytes` values force every
/// boundary condition (record split across chunks, record longer than a chunk,
/// multi-byte UTF-8 straddling a chunk edge) that a real multi-hundred-MB
/// transcript would only hit by chance.
@Suite("FileLines streaming record reader")
struct FileLinesTests {

    /// Write `contents` to a temp file and collect every record as a String.
    private func records(
        of contents: String, chunkBytes: Int = FileLines.defaultChunkBytes
    ) throws -> [String] {
        var out: [String] = []
        try withTempSession(contents) { url in
            out = try FileLines(url: url, chunkBytes: chunkBytes).map {
                String(decoding: $0, as: UTF8.self)
            }
        }
        return out
    }

    @Test("yields each newline-delimited record")
    func basicRecords() throws {
        #expect(try records(of: "alpha\nbeta\ngamma\n") == ["alpha", "beta", "gamma"])
    }

    @Test("a trailing record without a final newline is still yielded")
    func trailingRecordWithoutNewline() throws {
        #expect(try records(of: "alpha\nbeta") == ["alpha", "beta"])
    }

    @Test("empty records are skipped, matching split(omittingEmptySubsequences:)")
    func emptyRecordsSkipped() throws {
        #expect(try records(of: "\n\nalpha\n\n\nbeta\n\n") == ["alpha", "beta"])
    }

    @Test("records split across chunk boundaries reassemble intact")
    func recordsAcrossChunks() throws {
        #expect(
            try records(of: "alpha\nbeta\ngamma\n", chunkBytes: 4) == ["alpha", "beta", "gamma"])
    }

    @Test("a record longer than one chunk accumulates until its newline")
    func recordLongerThanChunk() throws {
        let long = String(repeating: "x", count: 100)
        #expect(try records(of: "\(long)\nend\n", chunkBytes: 8) == [long, "end"])
    }

    @Test("multi-byte UTF-8 straddling a chunk edge survives byte-exact")
    func multiByteAcrossChunks() throws {
        // 1-byte chunks force every UTF-8 continuation byte onto its own read.
        #expect(try records(of: "面🎵条\nok\n", chunkBytes: 1) == ["面🎵条", "ok"])
    }

    @Test("an empty file yields nothing")
    func emptyFile() throws {
        #expect(try records(of: "") == [])
    }

    @Test("opening a missing file throws")
    func missingFileThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeone-nonexistent-\(UUID().uuidString).jsonl")
        #expect(throws: (any Error).self) { try FileLines(url: url) }
    }

    @Test("byte-identical to split-on-newline over a realistic JSONL body")
    func equivalenceWithSplit() throws {
        let body = """
            {"type":"session_meta","payload":{"id":"x","cwd":"/Users/dev/proj"}}

            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"你好 🎵"}]}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            """
        let expected = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(try records(of: body, chunkBytes: 7) == expected)
    }
}
