import Dispatch
import Foundation

/// Registers an externally written rollout with Codex through the bundled
/// `codex app-server` stdio protocol.
///
/// The client deliberately implements only the official lifecycle needed by
/// VibeOne: `initialize` → `initialized` → `thread/resume`. It owns a fresh
/// short-lived app-server process for one registration, then closes stdin and
/// reaps it. No Codex database is read or written here.
public enum CodexAppServerClient {
    public struct Command: Equatable, Sendable {
        public var executableURL: URL
        public var arguments: [String]
        /// Optional per-process overrides. The caller supplies only keys it
        /// wants to replace; the current environment remains available.
        public var environment: [String: String]

        public init(
            executableURL: URL,
            arguments: [String] = ["app-server"],
            environment: [String: String] = [:]
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case couldNotStart(message: String)
        case couldNotWrite
        case timedOut
        case unexpectedEOF
        case invalidResponse
        case serverError(code: Int, message: String)
        case unexpectedThread(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .couldNotStart(let message):
                return "Codex app-server could not start: \(message)"
            case .couldNotWrite:
                return "Codex app-server closed its input unexpectedly"
            case .timedOut:
                return "Codex app-server did not respond in time"
            case .unexpectedEOF:
                return "Codex app-server closed before registration completed"
            case .invalidResponse:
                return "Codex app-server returned an invalid response"
            case .serverError(let code, let message):
                return "Codex app-server error \(code): \(message)"
            case .unexpectedThread(let expected, let actual):
                return
                    "Codex app-server resumed \(actual) instead of the requested thread \(expected)"
            }
        }
    }

    /// Perform one complete registration. `timeout` is a deadline for the whole
    /// handshake, not per response, so a wedged child cannot hold a switch open.
    public static func registerThread(
        _ threadId: String,
        command: Command,
        clientVersion: String,
        timeout: TimeInterval = 8
    ) throws {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(
                command.environment, uniquingKeysWith: { _, override in override })
        }

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // JSON-RPC errors arrive on stdout. Discard diagnostic chatter so an
        // unconsumed stderr pipe can never fill and deadlock the registration.
        process.standardError = FileHandle.nullDevice

        let reader = LineReader(handle: output.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            reader.stop()
            throw Failure.couldNotStart(message: error.localizedDescription)
        }

        defer {
            // EOF is the app-server's graceful shutdown signal. Give it a short
            // chance to exit, then terminate so every path remains bounded.
            try? input.fileHandleForWriting.close()
            if exited.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                process.terminate()
                _ = exited.wait(timeout: .now() + 1)
            }
            reader.stop()
            process.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(timeout)
        try send(
            [
                "id": 0,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "vibeone",
                        "title": "VibeOne",
                        "version": clientVersion,
                    ]
                ],
            ],
            to: input.fileHandleForWriting)
        _ = try response(id: 0, reader: reader, deadline: deadline)

        try send(
            ["method": "initialized", "params": [:]],
            to: input.fileHandleForWriting)
        try send(
            [
                "id": 1,
                "method": "thread/resume",
                "params": ["threadId": threadId],
            ],
            to: input.fileHandleForWriting)

        let result = try response(id: 1, reader: reader, deadline: deadline)
        guard
            let thread = result["thread"] as? [String: Any],
            let actualId = thread["id"] as? String
        else { throw Failure.invalidResponse }
        guard actualId == threadId else {
            throw Failure.unexpectedThread(expected: threadId, actual: actualId)
        }
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            throw Failure.couldNotWrite
        }
    }

    /// Ignore server notifications and unrelated messages; return only the
    /// matching JSON-RPC result, or turn its structured error into `Failure`.
    private static func response(
        id: Int,
        reader: LineReader,
        deadline: Date
    ) throws -> [String: Any] {
        while true {
            let data = try reader.nextLine(until: deadline)
            guard
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { throw Failure.invalidResponse }
            guard let responseId = object["id"] as? Int, responseId == id else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? 0
                let message = error["message"] as? String ?? "unknown error"
                throw Failure.serverError(code: code, message: message)
            }
            guard let result = object["result"] as? [String: Any] else {
                throw Failure.invalidResponse
            }
            return result
        }
    }
}

/// Turns `FileHandle`'s callback stream into deadline-aware JSONL reads. The
/// lock protects callback and caller access; the one-megabyte cap fails closed
/// if a broken peer emits an unbounded line.
private final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let condition = NSCondition()
    private var buffered = Data()
    private var lines: [Data] = []
    private var reachedEOF = false
    private var overflowed = false
    private let maximumBufferedBytes = 1_048_576

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            self?.receive(readable.availableData)
        }
    }

    func nextLine(until deadline: Date) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty, !reachedEOF, !overflowed {
            guard condition.wait(until: deadline) else {
                throw CodexAppServerClient.Failure.timedOut
            }
        }
        if overflowed { throw CodexAppServerClient.Failure.invalidResponse }
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        throw CodexAppServerClient.Failure.unexpectedEOF
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard !reachedEOF, !overflowed else { return }
        if data.isEmpty {
            if !buffered.isEmpty {
                lines.append(buffered)
                buffered.removeAll(keepingCapacity: false)
            }
            reachedEOF = true
            return
        }

        buffered.append(data)
        guard buffered.count <= maximumBufferedBytes else {
            overflowed = true
            return
        }
        while let newline = buffered.firstIndex(of: 0x0A) {
            var line = Data(buffered[..<newline])
            buffered.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
    }
}
