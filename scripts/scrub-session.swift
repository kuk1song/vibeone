#!/usr/bin/env swift
import Foundation

// Deterministic scrubber for Claude / Codex session JSONL (ADR-010).
//
// Goal: produce a PUBLIC-repo-safe golden-master fixture that keeps the REAL
// STRUCTURE of a session (line types, field names, nesting, event order, the
// Codex dual-stream) while removing ALL real content. Drift detection only needs
// structure, so we can scrub every string value except the handful of keys the
// readers switch on.
//
// Strategy: parse each line as JSON, walk it, and replace every string value
// EXCEPT an explicit structural allowlist (`type`, `role`, `model`,
// `model_provider`). UUID-like keys map deterministically (so parent-chains stay
// consistent); free text becomes "scrubbed text N". A final regex safety-net
// catches anything that could still carry a home path / email / token. Output is
// serialized with sorted keys so re-running is byte-stable.
//
// Usage:  swift scripts/scrub-session.swift <input.jsonl> <output.jsonl>

// Keys whose STRING value is a structural discriminator the readers depend on —
// kept verbatim. Everything else is scrubbed.
let keepVerbatim: Set<String> = ["type", "role", "model", "model_provider"]

// Keys that hold ids; mapped to deterministic placeholder UUIDs (same input →
// same output within a file, so references like parentUuid stay valid).
let idKeys: Set<String> = [
    "id", "uuid", "parentUuid", "parent_uuid", "sessionId", "session_id",
    "requestId", "request_id", "call_id", "tool_call_id", "conversation_id",
]

final class Scrubber {
    private var idMap: [String: String] = [:]
    private var textCounter = 0

    private func placeholderUUID(for original: String) -> String {
        if let mapped = idMap[original] { return mapped }
        let n = idMap.count + 1
        let mapped = String(format: "00000000-0000-4000-8000-%012d", n)
        idMap[original] = mapped
        return mapped
    }

    private func scrubString(key: String, value: String) -> String {
        if keepVerbatim.contains(key) { return value }
        if idKeys.contains(key) { return placeholderUUID(for: value) }
        switch key {
        case "cwd", "path", "rollout_path", "filepath", "file", "filename", "url":
            return "/Users/dev/project"
        case "timestamp", "created_at", "updated_at":
            return "2026-01-01T00:00:00.000Z"
        case "gitBranch", "git_branch", "branch":
            return "main"
        case "version", "cli_version", "cliVersion":
            return value  // tool version is not sensitive; keep for realism
        default:
            textCounter += 1
            return "scrubbed text \(textCounter)"
        }
    }

    private func scrub(_ value: Any, key: String) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = scrub(v, key: k) }
            return out
        case let arr as [Any]:
            return arr.map { scrub($0, key: key) }
        case let str as String:
            return scrubString(key: key, value: str)
        default:
            return value  // numbers / bools / null — not sensitive, structural
        }
    }

    /// Belt-and-suspenders: even after key-based scrubbing, ensure no home path /
    /// email / token can survive in the serialized line.
    private func safetyNet(_ line: String) -> String {
        var s = line
        let rules: [(String, String)] = [
            ("/Users/[^/\"\\\\]+", "/Users/dev"),
            ("/home/[^/\"\\\\]+", "/home/dev"),
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "dev@example.com"),
            ("sk-[A-Za-z0-9_-]{8,}", "REDACTED"),
            ("ghp_[A-Za-z0-9]{8,}", "REDACTED"),
            ("gho_[A-Za-z0-9]{8,}", "REDACTED"),
            ("xox[baprs]-[A-Za-z0-9-]{8,}", "REDACTED"),
            ("AKIA[0-9A-Z]{16}", "REDACTED"),
        ]
        for (pattern, repl) in rules {
            s = s.replacingOccurrences(
                of: pattern, with: repl, options: .regularExpression)
        }
        return s
    }

    func scrubLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let scrubbed = scrub(obj, key: "")
        guard
            let out = try? JSONSerialization.data(
                withJSONObject: scrubbed, options: [.sortedKeys, .withoutEscapingSlashes]),
            let str = String(data: out, encoding: .utf8)
        else { return nil }
        return safetyNet(str)
    }
}

// MARK: - main

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: swift scripts/scrub-session.swift <input.jsonl> <output.jsonl>\n".utf8))
    exit(2)
}
let input = args[1]
let output = args[2]

guard let raw = try? String(contentsOfFile: input, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read \(input)\n".utf8))
    exit(1)
}

let scrubber = Scrubber()
var outLines: [String] = []
var dropped = 0
for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
    if let scrubbed = scrubber.scrubLine(String(line)) {
        outLines.append(scrubbed)
    } else {
        dropped += 1
    }
}

try (outLines.joined(separator: "\n") + "\n").write(
    toFile: output, atomically: true, encoding: .utf8)
FileHandle.standardError.write(
    Data("scrubbed \(outLines.count) lines (dropped \(dropped) unparseable) -> \(output)\n".utf8))
