import Foundation

/// Read/write the Codex side of MCP config: `[mcp_servers.<id>]` tables inside
/// `~/.codex/config.toml` (table syntax + keys verified against Codex's config
/// reference). MCP shares this file with unrelated config, so writes are
/// surgical and never reserialize the whole document.
///
/// **Read** is a tolerant subset parser (the common stdio/remote keys; anything
/// unrecognized is skipped, never fatal). **Write is append-only**: existing
/// server blocks and all non-MCP content are preserved verbatim — only servers
/// absent from the file are appended. That keeps non-managed entries and
/// advanced keys (timeouts, tool allowlists, …) byte-for-byte intact.
public enum CodexMCP {

    private static let tablePrefix = "mcp_servers"

    // MARK: - Read

    /// Parse `[mcp_servers.<id>]` tables into servers, sorted by name. Handles the
    /// common forms Codex emits: `command`/`url` strings, single-line `args`
    /// arrays, and `env` as either an inline table (`{ K = "v" }`) or an
    /// `[mcp_servers.<id>.env]` sub-table.
    public static func read(toml: String) -> [MCPServer] {
        // Accumulate per-server fields keyed by server name, in first-seen order.
        var order: [String] = []
        var fields: [String: [String: String]] = [:]  // name -> (command/url/argsRaw)
        var envs: [String: [String: String]] = [:]  // name -> env map (from sub-table)

        var currentServer: String?
        var inEnvSubtable = false

        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                // A new table header ends any previous server context.
                currentServer = nil
                inEnvSubtable = false
                guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    continue
                }
                let inner = String(line.dropFirst().dropLast())
                let segs = splitSegments(inner)
                guard segs.count >= 2, segs[0] == tablePrefix else { continue }
                let name = segs[1]
                if fields[name] == nil {
                    order.append(name)
                    fields[name] = [:]
                }
                currentServer = name
                inEnvSubtable = segs.count == 3 && segs[2] == "env"
                continue
            }

            guard let server = currentServer,
                let eq = line.firstIndex(of: "=")
            else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let valueText = String(line[line.index(after: eq)...]).trimmingCharacters(
                in: .whitespaces)

            if inEnvSubtable {
                if let v = parseString(valueText) {
                    envs[server, default: [:]][unquoteKey(key)] = v
                }
                continue
            }

            switch key {
            case "command", "url":
                if let v = parseString(valueText) { fields[server]?[key] = v }
            case "args":
                fields[server]?["args"] = valueText  // parsed lazily below
            case "env":
                for (k, v) in parseInlineTable(valueText) { envs[server, default: [:]][k] = v }
            default:
                continue  // cwd / timeouts / tool lists — not modeled (preserved on write)
            }
        }

        return order.compactMap { name in
            buildServer(name: name, fields: fields[name] ?? [:], env: envs[name] ?? [:])
        }
        .sorted { $0.name < $1.name }
    }

    private static func buildServer(
        name: String, fields: [String: String], env: [String: String]
    ) -> MCPServer? {
        if let command = fields["command"] {
            let args = fields["args"].map(parseStringArray) ?? []
            return MCPServer(name: name, transport: .stdio(command: command, args: args, env: env))
        }
        if let url = fields["url"] {
            return MCPServer(name: name, transport: .remote(url: url, kind: .http, headers: env))
        }
        return nil
    }

    // MARK: - Write (append-only)

    /// Append `servers` that aren't already present as `[mcp_servers.<id>]` tables
    /// in `existingTOML`, returning the new document. Existing content (including
    /// non-MCP tables and already-present servers) is preserved verbatim.
    public static func merged(_ servers: [MCPServer], intoTOML existingTOML: String) -> String {
        let present = existingServerNames(in: existingTOML)
        let toAdd = servers.filter { !present.contains($0.name) }
        guard !toAdd.isEmpty else { return existingTOML }

        var out = existingTOML
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        for server in toAdd.sorted(by: { $0.name < $1.name }) {
            out += "\n" + render(server)
        }
        return out
    }

    /// Names that already have any `[mcp_servers.<id>]` (or `.<id>.env`) table.
    static func existingServerNames(in toml: String) -> Set<String> {
        var names: Set<String> = []
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") else { continue }
            let segs = splitSegments(String(line.dropFirst().dropLast()))
            if segs.count >= 2, segs[0] == tablePrefix { names.insert(segs[1]) }
        }
        return names
    }

    /// Render one server as a `[mcp_servers.<id>]` table block (trailing newline).
    static func render(_ server: MCPServer) -> String {
        var lines = ["[\(tablePrefix).\(formatKey(server.name))]"]
        switch server.transport {
        case .stdio(let command, let args, let env):
            lines.append("command = \(quote(command))")
            if !args.isEmpty {
                lines.append("args = [\(args.map(quote).joined(separator: ", "))]")
            }
            appendEnv(env, to: &lines)
        case .remote(let url, _, let headers):
            lines.append("url = \(quote(url))")
            appendEnv(headers, to: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendEnv(_ env: [String: String], to lines: inout [String]) {
        guard !env.isEmpty else { return }
        let pairs = env.sorted { $0.key < $1.key }
            .map { "\(formatKey($0.key)) = \(quote($0.value))" }
        lines.append("env = { \(pairs.joined(separator: ", ")) }")
    }

    // MARK: - TOML scalar helpers

    /// Drop a `#` comment that is outside a double-quoted string.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        var result = ""
        for ch in line {
            if escaped {
                result.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inString {
                result.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { inString.toggle() }
            if ch == "#" && !inString { break }
            result.append(ch)
        }
        return result
    }

    /// Split a dotted table path into segments, respecting quoted segments
    /// (`a."b.c".d` → ["a", "b.c", "d"]).
    static func splitSegments(_ path: String) -> [String] {
        var segs: [String] = []
        var current = ""
        var inQuote = false
        for ch in path {
            if ch == "\"" {
                inQuote.toggle()
                continue
            }
            if ch == "." && !inQuote {
                segs.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        segs.append(current.trimmingCharacters(in: .whitespaces))
        return segs
    }

    /// Parse a basic TOML string value (`"..."`) with the common escapes.
    private static func parseString(_ text: String) -> String? {
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return nil }
        let body = text.dropFirst().dropLast()
        var result = ""
        var escaped = false
        for ch in body {
            if escaped {
                switch ch {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: result.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Parse a single-line array of strings (`["a", "b"]`).
    private static func parseStringArray(_ text: String) -> [String] {
        guard text.hasPrefix("["), text.hasSuffix("]") else { return [] }
        return splitTopLevel(String(text.dropFirst().dropLast()), by: ",")
            .compactMap { parseString($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Parse a single-line inline table of strings (`{ K = "v", K2 = "v2" }`).
    private static func parseInlineTable(_ text: String) -> [String: String] {
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return [:] }
        var map: [String: String] = [:]
        for pair in splitTopLevel(String(text.dropFirst().dropLast()), by: ",") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = unquoteKey(String(pair[..<eq]).trimmingCharacters(in: .whitespaces))
            if let v = parseString(
                String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            {
                map[key] = v
            }
        }
        return map
    }

    /// Split on `separator` at the top level, ignoring separators inside quotes.
    private static func splitTopLevel(_ text: String, by separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { inQuote.toggle() }
            if ch == separator && !inQuote {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    private static func unquoteKey(_ key: String) -> String {
        guard key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 else { return key }
        return String(key.dropFirst().dropLast())
    }

    /// A TOML key/segment: bare if it matches `[A-Za-z0-9_-]+`, else quoted.
    static func formatKey(_ key: String) -> String {
        let bareSafe =
            !key.isEmpty
            && key.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
            }
        return bareSafe ? key : quote(key)
    }

    /// A TOML basic string: wrap in quotes, escaping `\` and `"`.
    static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
