import Foundation

/// A single-pass sequence of a file's newline-delimited records, yielded as raw
/// `Data` — the shape `JSONSerialization` consumes directly. Reads in bounded
/// chunks so peak memory is O(chunk + longest record), never O(file): a
/// long-running Claude transcript can reach hundreds of MB, and loading it as
/// one `String` multiplied that whole size through decode + split + parse.
///
/// Record semantics deliberately match the codecs' historical
/// `split(separator: "\n", omittingEmptySubsequences: true)`: empty records are
/// skipped and a trailing record with no final newline is still yielded.
/// Splitting on the LF *byte* is UTF-8-safe — no continuation byte is 0x0A, so
/// a multi-byte character can never straddle a record boundary.
struct FileLines: Sequence, IteratorProtocol {
    static let defaultChunkBytes = 1 << 20  // 1 MiB — a handful of reads per real file

    private let handle: FileHandle
    private let chunkBytes: Int
    private var buffer = Data()  // always rebased (startIndex 0)
    private var cursor = 0  // consumed prefix of `buffer`
    private var exhausted = false

    /// Throws when the file cannot be opened for reading; the store's `read`
    /// boundary surfaces that, mirroring the old whole-file load.
    init(url: URL, chunkBytes: Int = FileLines.defaultChunkBytes) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        self.chunkBytes = chunkBytes
    }

    mutating func next() -> Data? {
        while true {
            if let newline = buffer[cursor...].firstIndex(of: 0x0A) {
                let record = buffer[cursor..<newline]
                cursor = newline + 1
                if record.isEmpty { continue }
                return Data(record)
            }
            // No complete record buffered: drop the consumed prefix (keeps the
            // buffer bounded by chunk + partial record), then pull more bytes.
            if cursor > 0 {
                buffer = Data(buffer[cursor...])
                cursor = 0
            }
            if exhausted {
                guard !buffer.isEmpty else { return nil }
                let record = buffer
                buffer = Data()
                return record
            }
            if let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                exhausted = true
                try? handle.close()
            }
        }
    }
}
