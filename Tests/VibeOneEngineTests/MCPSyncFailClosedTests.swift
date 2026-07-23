import Foundation
import Testing

@testable import VibeOneEngine

/// Destructive-path guards added after the second real-data MCP review. This
/// suite uses an isolated workspace/home per test because Swift Testing runs
/// cases in parallel.
struct MCPSyncFailClosedTests {

    private struct Sandbox {
        let workspace: URL
        let home: URL
        let fm = FileManager.default

        init() throws {
            let unique = ProcessInfo.processInfo.globallyUniqueString
            workspace = fm.temporaryDirectory.appendingPathComponent("vibeone-mcp-ws-\(unique)")
            home = fm.temporaryDirectory.appendingPathComponent("vibeone-mcp-home-\(unique)")
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        }

        var claudeMCP: URL { workspace.appendingPathComponent(".mcp.json") }
        var codexConfig: URL { workspace.appendingPathComponent(".codex/config.toml") }

        func cleanup() {
            try? fm.removeItem(at: workspace)
            try? fm.removeItem(at: home)
        }

        func writeClaude(_ contents: String) throws {
            try contents.write(to: claudeMCP, atomically: true, encoding: .utf8)
        }

        func writeClaude(_ contents: Data) throws {
            try contents.write(to: claudeMCP)
        }

        func writeCodex(_ contents: String) throws {
            try fm.createDirectory(
                at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: codexConfig, atomically: true, encoding: .utf8)
        }

        func writeCodex(_ contents: Data) throws {
            try fm.createDirectory(
                at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: codexConfig)
        }
    }

    private func expectFailure(
        _ expected: MCPSync.Failure,
        applying sandbox: Sandbox
    ) {
        do {
            _ = try MCPSync.apply(
                workspace: sandbox.workspace.path, home: sandbox.home, timestamp: { "TS" })
            Issue.record("expected \(expected), but apply succeeded")
        } catch let error as MCPSync.Failure {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// `mcpServers` must be an object. Replacing any other JSON type would
    /// discard user data just as surely as rebuilding malformed JSON.
    @Test(arguments: [
        #"{"mcpServers":[]}"#,
        #"{"mcpServers":"keep me"}"#,
        #"{"mcpServers":null}"#,
    ])
    func nonObjectClaudeMCPServersFailsClosed(broken: String) throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        try s.writeClaude(broken)
        try s.writeCodex("[mcp_servers.fs]\ncommand = \"a\"\n")

        expectFailure(.malformedClaudeConfig(path: s.claudeMCP.path), applying: s)

        #expect(
            try String(contentsOf: s.claudeMCP, encoding: .utf8) == broken,
            "the structurally invalid value must survive byte-for-byte")
    }

    /// A raw key can occupy a name even when its value is not translatable.
    /// Additive sync must not overwrite it, claim it was added, or reformat the
    /// unchanged file.
    @Test func occupiedUnrepresentableClaudeServerIsNotClaimedOrRewritten() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        let original = #"{"mcpServers":{"fs":"user-owned-unrepresentable-value"}}"#
        try s.writeClaude(original)
        try s.writeCodex("[mcp_servers.fs]\ncommand = \"a\"\n")

        let outcome = try MCPSync.apply(
            workspace: s.workspace.path, home: s.home, timestamp: { "TS" })

        #expect(outcome.addedToClaude == [])
        #expect(outcome.backups == [])
        #expect(
            try String(contentsOf: s.claudeMCP, encoding: .utf8) == original,
            "no actual addition means no rewrite")
    }

    /// When one requested name is occupied and another is absent, report only
    /// the server that was actually inserted.
    @Test func outcomeReportsOnlyServersActuallyAddedToClaude() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        let original =
            #"{"mcpServers":{"occupied":"user-owned-unrepresentable-value"},"otherKey":42}"#
        try s.writeClaude(original)
        try s.writeCodex(
            """
            [mcp_servers.occupied]
            command = "a"

            [mcp_servers.fresh]
            command = "b"
            """)

        let outcome = try MCPSync.apply(
            workspace: s.workspace.path, home: s.home, timestamp: { "TS" })

        #expect(outcome.addedToClaude == ["fresh"])
        #expect(outcome.backups.count == 1)
        let data = try Data(contentsOf: s.claudeMCP)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["occupied"] as? String == "user-owned-unrepresentable-value")
        #expect(servers["fresh"] is [String: Any])
        #expect(root["otherKey"] as? Int == 42)
    }

    /// Invalid UTF-8 must never be mistaken for an empty Claude target and
    /// overwritten when Codex has content to add.
    @Test func nonUTF8ClaudeTargetFailsClosed() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        let original = Data([0xFF, 0xFE, 0x00, 0x61])
        try s.writeClaude(original)
        try s.writeCodex("[mcp_servers.fs]\ncommand = \"a\"\n")

        expectFailure(.nonUTF8Config(path: s.claudeMCP.path), applying: s)

        #expect(try Data(contentsOf: s.claudeMCP) == original)
    }

    /// The same fail-closed rule applies to the Codex project target.
    @Test func nonUTF8CodexTargetFailsClosed() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        let original = Data([0xFF, 0xFE, 0x00, 0x62])
        try s.writeCodex(original)
        try s.writeClaude(#"{"mcpServers":{"fs":{"command":"a"}}}"#)

        expectFailure(.nonUTF8Config(path: s.codexConfig.path), applying: s)

        #expect(try Data(contentsOf: s.codexConfig) == original)
    }

    /// Unsafe files are errors only on a destructive path. With no
    /// representable server to add in either direction, apply stays a quiet
    /// no-op and leaves both targets untouched.
    @Test func unsafeTargetsStayQuietWhenNothingNeedsWriting() throws {
        let s = try Sandbox()
        defer { s.cleanup() }
        let claude = #"{"mcpServers":[]}"#
        let codex = Data([0xFF, 0xFE, 0x00, 0x62])
        try s.writeClaude(claude)
        try s.writeCodex(codex)

        let outcome = try MCPSync.apply(
            workspace: s.workspace.path, home: s.home, timestamp: { "TS" })

        #expect(outcome.addedToClaude == [])
        #expect(outcome.addedToCodex == [])
        #expect(outcome.backups == [])
        #expect(try String(contentsOf: s.claudeMCP, encoding: .utf8) == claude)
        #expect(try Data(contentsOf: s.codexConfig) == codex)
    }
}
