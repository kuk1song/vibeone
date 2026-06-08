import Foundation

/// Read/write the Claude side of MCP config: the `mcpServers` object in a JSON
/// file (`<workspace>/.mcp.json` for project scope — see `ConfigLocation`).
/// Format verified against Claude Code's MCP docs.
public enum ClaudeMCP {

    // MARK: - Read

    /// Parse the `mcpServers` object out of a Claude MCP JSON document. A missing
    /// or malformed file yields no servers (tolerant — never throws). Entries with
    /// a `command` are stdio; entries with a `url` are remote (`type` ∈
    /// `http`/`streamable-http`/`sse`, defaulting to http).
    public static func read(json: String) -> [MCPServer] {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return servers(from: obj["mcpServers"] as? [String: Any] ?? [:])
    }

    /// Build servers from a decoded `mcpServers` map, sorted by name for
    /// determinism. Reused for both `.mcp.json` and `~/.claude.json` shapes.
    static func servers(from map: [String: Any]) -> [MCPServer] {
        map.compactMap { name, raw -> MCPServer? in
            guard let entry = raw as? [String: Any] else { return nil }
            if let command = entry["command"] as? String {
                return MCPServer(
                    name: name,
                    transport: .stdio(
                        command: command,
                        args: stringArray(entry["args"]),
                        env: stringMap(entry["env"])))
            }
            if let url = entry["url"] as? String {
                let kind: MCPServer.RemoteKind =
                    (entry["type"] as? String) == "sse" ? .sse : .http
                return MCPServer(
                    name: name,
                    transport: .remote(url: url, kind: kind, headers: stringMap(entry["headers"])))
            }
            return nil
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Write

    /// Additively merge `servers` into an existing Claude MCP JSON document and
    /// re-render it. Servers whose name already exists are left untouched (merge,
    /// never overwrite — ARCHITECTURE §5); all unrelated JSON keys are preserved.
    /// `existingJSON` empty/blank starts from `{}`.
    public static func merged(_ servers: [MCPServer], intoJSON existingJSON: String) -> String {
        var root =
            (existingJSON.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        var map = root["mcpServers"] as? [String: Any] ?? [:]

        for server in servers where map[server.name] == nil {
            map[server.name] = jsonEntry(server)
        }
        root["mcpServers"] = map

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys, .prettyPrinted]),
            let str = String(data: data, encoding: .utf8)
        else { return existingJSON }
        return str + "\n"
    }

    /// The JSON object for one server (the value under its name in `mcpServers`).
    static func jsonEntry(_ server: MCPServer) -> [String: Any] {
        switch server.transport {
        case .stdio(let command, let args, let env):
            var entry: [String: Any] = ["command": command]
            if !args.isEmpty { entry["args"] = args }
            if !env.isEmpty { entry["env"] = env }
            return entry
        case .remote(let url, let kind, let headers):
            var entry: [String: Any] = ["type": kind.rawValue, "url": url]
            if !headers.isEmpty { entry["headers"] = headers }
            return entry
        }
    }

    // MARK: -

    private static func stringArray(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func stringMap(_ any: Any?) -> [String: String] {
        guard let dict = any as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }
}
