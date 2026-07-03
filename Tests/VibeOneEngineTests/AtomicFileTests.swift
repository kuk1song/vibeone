import XCTest

@testable import VibeOneEngine

final class AtomicFileTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeone-fsutil-\(unique)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWriteCreatesFileAndIntermediateDirectories() throws {
        let url = root.appendingPathComponent("nested/deep/session.jsonl")
        try AtomicFile.write("hello\n", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello\n")
    }

    func testWriteOverwritesAtomicallyLeavingNoTempFiles() throws {
        let url = root.appendingPathComponent("session.jsonl")
        try AtomicFile.write("first", to: url)
        try AtomicFile.write("second", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second")

        // No stray ".session.jsonl.tmp-*" left behind in the directory.
        let leftovers = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "atomic write must clean up its temp file")
    }

    func testBackupCopiesExistingFileAndReturnsURL() throws {
        let url = root.appendingPathComponent("config.toml")
        try AtomicFile.write("original", to: url)

        let backup = try XCTUnwrap(try AtomicFile.backup(url, timestamp: "20260606T000000"))
        XCTAssertEqual(backup.lastPathComponent, "config.toml.bak.20260606T000000")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path), "backup must not move the original")
    }

    /// Two writes inside one timestamp tick must yield two backups: the earlier
    /// pre-write state is never replaced by the later one.
    func testBackupNeverOverwritesAnEarlierBackupWithTheSameTimestamp() throws {
        let url = root.appendingPathComponent("config.toml")
        try AtomicFile.write("v1", to: url)

        let first = try XCTUnwrap(try AtomicFile.backup(url, timestamp: "same-tick"))
        try AtomicFile.write("v2", to: url)
        let second = try XCTUnwrap(try AtomicFile.backup(url, timestamp: "same-tick"))

        XCTAssertNotEqual(first, second, "a colliding backup must pick a distinct name")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "v1")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "v2")
    }

    func testBackupReturnsNilWhenSourceMissing() throws {
        let url = root.appendingPathComponent("does-not-exist.toml")
        XCTAssertNil(try AtomicFile.backup(url, timestamp: "20260606T000000"))
    }

    /// Backup-then-write is the real call site (engine writes config/sessions):
    /// the backup keeps the pre-write content, the target gets the new content.
    func testBackupThenWritePreservesOldAndAppliesNew() throws {
        let url = root.appendingPathComponent("session.jsonl")
        try AtomicFile.write("v1", to: url)

        let backup = try XCTUnwrap(try AtomicFile.backup(url, timestamp: "ts"))
        try AtomicFile.write("v2", to: url)

        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "v1")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "v2")
    }
}
