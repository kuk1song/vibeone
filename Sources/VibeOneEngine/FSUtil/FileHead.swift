import Foundation

/// Bounded reads of a file's head — for cheaply peeking at a session's header
/// (its `cwd`/id) when *enumerating* many transcripts, without loading a
/// possibly-multi-MB file in full. The fields we need sit in the first few lines
/// (Claude stamps `cwd` by line ~3; Codex's `session_meta` is line 1), so a
/// small bounded prefix always suffices.
enum FileHead {

    /// Default prefix window. Comfortably covers the largest header seen on real
    /// data (a ~27 KB Codex `session_meta`); a header past this is treated as
    /// unreadable rather than read unboundedly.
    static let defaultMaxBytes = 256 * 1024

    /// The complete lines contained in the first `maxBytes` of `url`. The trailing
    /// partial line (if the window cut mid-line) is dropped, so a multi-byte UTF-8
    /// character is never split across the boundary. Returns `[]` if the file is
    /// missing, empty, or not decodable as UTF-8.
    static func lines(of url: URL, maxBytes: Int = defaultMaxBytes) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return [] }
        // Keep only through the last newline so the final line is always complete;
        // if there's no newline at all, the window holds a single (whole) line.
        let complete = data.lastIndex(of: 0x0A).map { data[...$0] } ?? data
        guard let text = String(data: complete, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
