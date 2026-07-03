import Foundation

/// Crash-safe file writes for the engine: never expose a half-written session or
/// config, and never overwrite without a recoverable backup (ARCHITECTURE §5).
public enum AtomicFile {

    /// Write `contents` to `url` atomically: data is written to a temp file in the
    /// same directory, flushed to disk (`fsync`), then renamed over the target — a
    /// reader sees either the old file or the complete new one, never a partial
    /// write. Intermediate directories are created as needed.
    ///
    /// The temp file shares the target's directory so the final step is a rename
    /// within one filesystem (atomic); a cross-device move would not be.
    public static func write(_ contents: String, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let temp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(ProcessInfo.processInfo.globallyUniqueString)")
        fm.createFile(atPath: temp.path, contents: nil)

        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.synchronize()  // fsync: durable on disk before the rename
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temp)
            throw error
        }

        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Copy an existing file to a sibling `<name>.bak.<timestamp>` before it is
    /// overwritten. Returns the backup URL, or `nil` if `url` doesn't exist (a
    /// brand-new target needs no backup). `timestamp` should be filesystem-safe
    /// (the caller owns its format).
    ///
    /// An existing backup is never deleted — it holds a pre-write state that would
    /// otherwise be unrecoverable. If two writes land inside one timestamp tick,
    /// the second backup gets a unique suffix instead of replacing the first.
    @discardableResult
    public static func backup(_ url: URL, timestamp: String) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        var backup = url.appendingPathExtension("bak.\(timestamp)")
        if fm.fileExists(atPath: backup.path) {
            let unique = ProcessInfo.processInfo.globallyUniqueString.prefix(8)
            backup = url.appendingPathExtension("bak.\(timestamp)-\(unique)")
        }
        try fm.copyItem(at: url, to: backup)
        return backup
    }
}
