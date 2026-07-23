import Foundation
import Testing

@testable import VibeOneEngine

@Suite("Codex app-server registration")
struct CodexAppServerClientTests {
    private static let threadId = "11111111-2222-3333-4444-555555555555"
    private static let liveCanaryEnabled =
        ProcessInfo.processInfo.environment["VIBEONE_APP_SERVER_CANARY"] == "1"

    private struct FakeServer {
        let directory: URL
        let executable: URL
        let trace: URL
        let mode: String

        init(mode: String) throws {
            let fm = FileManager.default
            self.mode = mode
            directory = fm.temporaryDirectory.appendingPathComponent(
                "vibeone-app-server-\(ProcessInfo.processInfo.globallyUniqueString)")
            executable = directory.appendingPathComponent("fake-app-server")
            trace = directory.appendingPathComponent("requests.jsonl")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            let script = """
                #!/bin/zsh
                trace="$1"
                expected="$2"
                mode="$3"

                IFS= read -r initialize || exit 10
                print -r -- "$initialize" >> "$trace"
                if [[ "$mode" == "eof-before-initialize" ]]; then
                  exit 0
                fi
                if [[ "$mode" == "stall" ]]; then
                  sleep 10
                  exit 0
                fi

                print -r -- '{"method":"server/ready","params":{}}'
                print -r -- '{"id":0,"result":{"codexHome":"/tmp","platformFamily":"unix","platformOs":"macos","userAgent":"fake"}}'

                IFS= read -r initialized || exit 11
                print -r -- "$initialized" >> "$trace"
                IFS= read -r resume || exit 12
                print -r -- "$resume" >> "$trace"

                if [[ "$mode" == "server-error" ]]; then
                  print -r -- '{"id":1,"error":{"code":-32001,"message":"thread not found"}}'
                elif [[ "$mode" == "wrong-thread" ]]; then
                  print -r -- '{"id":1,"result":{"thread":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}}}'
                else
                  print -r -- '{"id":1,"result":{"thread":{"id":"\(CodexAppServerClientTests.threadId)"}}}'
                fi

                # The client must close stdin and reap this process after the response.
                IFS= read -r _
                print -r -- "exited" > "$trace.exit"
                """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        var command: CodexAppServerClient.Command {
            CodexAppServerClient.Command(
                executableURL: executable,
                arguments: [trace.path, CodexAppServerClientTests.threadId, mode])
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("performs the official initialize → initialized → thread/resume handshake")
    func successfulHandshake() throws {
        let fake = try FakeServer(mode: "success")
        defer { fake.cleanup() }

        try CodexAppServerClient.registerThread(
            Self.threadId,
            command: fake.command,
            clientVersion: "test-0.2.0",
            timeout: 3)

        let requestLines = try String(contentsOf: fake.trace, encoding: .utf8)
            .split(separator: "\n")
        #expect(requestLines.count == 3)

        let initialize = try jsonObject(String(requestLines[0]))
        #expect(initialize["id"] as? Int == 0)
        #expect(initialize["method"] as? String == "initialize")
        let initializeParams = try #require(initialize["params"] as? [String: Any])
        let clientInfo = try #require(initializeParams["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "vibeone")
        #expect(clientInfo["title"] as? String == "VibeOne")
        #expect(clientInfo["version"] as? String == "test-0.2.0")

        let initialized = try jsonObject(String(requestLines[1]))
        #expect(initialized["id"] == nil)
        #expect(initialized["method"] as? String == "initialized")

        let resume = try jsonObject(String(requestLines[2]))
        #expect(resume["id"] as? Int == 1)
        #expect(resume["method"] as? String == "thread/resume")
        let resumeParams = try #require(resume["params"] as? [String: Any])
        #expect(resumeParams["threadId"] as? String == Self.threadId)

        #expect(
            FileManager.default.fileExists(atPath: fake.trace.path + ".exit"),
            "the app-server process should observe stdin closing and exit before return")
    }

    @Test("surfaces a structured thread/resume error")
    func serverError() throws {
        let fake = try FakeServer(mode: "server-error")
        defer { fake.cleanup() }

        #expect(
            throws: CodexAppServerClient.Failure.serverError(
                code: -32001, message: "thread not found"
            )
        ) {
            try CodexAppServerClient.registerThread(
                Self.threadId,
                command: fake.command,
                clientVersion: "test",
                timeout: 3)
        }
    }

    @Test("rejects a success response for a different thread")
    func wrongThread() throws {
        let fake = try FakeServer(mode: "wrong-thread")
        defer { fake.cleanup() }

        #expect(
            throws: CodexAppServerClient.Failure.unexpectedThread(
                expected: Self.threadId,
                actual: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )
        ) {
            try CodexAppServerClient.registerThread(
                Self.threadId,
                command: fake.command,
                clientVersion: "test",
                timeout: 3)
        }
    }

    @Test("fails explicitly when app-server closes before initialize")
    func earlyEOF() throws {
        let fake = try FakeServer(mode: "eof-before-initialize")
        defer { fake.cleanup() }

        #expect(throws: CodexAppServerClient.Failure.unexpectedEOF) {
            try CodexAppServerClient.registerThread(
                Self.threadId,
                command: fake.command,
                clientVersion: "test",
                timeout: 3)
        }
    }

    @Test("times out instead of hanging on a silent app-server")
    func timeout() throws {
        let fake = try FakeServer(mode: "stall")
        defer { fake.cleanup() }

        #expect(throws: CodexAppServerClient.Failure.timedOut) {
            try CodexAppServerClient.registerThread(
                Self.threadId,
                command: fake.command,
                clientVersion: "test",
                timeout: 0.1)
        }
    }

    /// Current-host integration without touching the user's real Codex state:
    /// both the rollout and app-server index live below one disposable
    /// `CODEX_HOME`. Opt-in because CI does not have ChatGPT.app installed.
    @Test(
        "current bundled app-server accepts a VibeOne rollout",
        .enabled(if: Self.liveCanaryEnabled))
    func currentBundledAppServer() throws {
        let binary = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(
            FileManager.default.isExecutableFile(atPath: binary.path),
            "current-host canary requires the bundled Codex executable")

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vibeone-live-app-server-\(ProcessInfo.processInfo.globallyUniqueString)")
        let codexHome = sandbox.appendingPathComponent("codex-home")
        let workspace = sandbox.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let id = UUID().uuidString.lowercased()
        let rollout =
            codexHome
            .appendingPathComponent("sessions/2026/07/23", isDirectory: true)
            .appendingPathComponent("rollout-2026-07-23T00-00-00-\(id).jsonl")
        try FileManager.default.createDirectory(
            at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = CanonicalSession(
            sourceAgent: "claude",
            workspace: workspace.path,
            messages: [
                CanonicalMessage(role: .user, text: "isolated app-server canary"),
                CanonicalMessage(role: .assistant, text: "acknowledged"),
            ])
        try CodexSession.write(
            session,
            options: .init(sessionId: id, cwd: workspace.path)
        ).write(to: rollout, atomically: true, encoding: .utf8)

        try CodexAppServerClient.registerThread(
            id,
            command: .init(
                executableURL: binary,
                environment: ["CODEX_HOME": codexHome.path]),
            clientVersion: "canary",
            timeout: 8)

        #expect(
            FileManager.default.fileExists(
                atPath: codexHome.appendingPathComponent("state_5.sqlite").path),
            "thread/resume should create the isolated index")
    }

    private func jsonObject(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
