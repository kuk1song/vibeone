import os

/// Unified system logging for the app (ADR-013). `os.Logger` is first-party
/// (zero dependencies, privacy-aware, near-free when nobody's listening) — the
/// standard way to get an observable trace out of a menu-bar app that has no
/// console of its own. The engine stays log-free and pure; observation lives
/// here, at the orchestration layer.
///
/// Watch it live:
///   log stream --predicate 'subsystem == "com.vibeone.app"' --level debug
/// or filter by subsystem in Console.app.
enum Log {
    private static let subsystem = "com.vibeone.app"

    /// The ▶ switch: handoff + open.
    static let switching = Logger(subsystem: subsystem, category: "switch")
    /// Config sync (memory · MCP · skills), auto and manual.
    static let sync = Logger(subsystem: subsystem, category: "sync")
}
