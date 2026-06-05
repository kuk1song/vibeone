# VibeOne 🎵

> **One project, either agent.** A native macOS menu-bar app that switches a
> project seamlessly between **Claude Code and Codex** — memory, skills, MCP, and
> your live session all follow, so the two agents share one context.

**Status: early development.** The menu-bar shell and the session engine's Claude
side work and are tested; the Codex side, the one-click switch, and config sync
are in progress (see the roadmap).

## Why

Claude Code and Codex each keep their own memory files, skills, MCP config, and
conversation history. Switching between them mid-project means re-explaining
context and re-wiring config by hand. Existing tools do *either* config sync *or*
session handoff — never both, rarely bidirectionally. VibeOne fuses them into one
menu-bar switch.

## What works today

- ✅ **Menu-bar popover** (SwiftUI `MenuBarExtra`): a segmented Claude / Codex
  switch, live CLI-availability detection (`command -v claude/codex`), and a
  menu-bar glyph tinted by the active agent. No Dock icon, no window.
- ✅ **Session engine — Claude side**: read a Claude `.jsonl` transcript → an
  agent-neutral IR → write a fresh, resumable Claude session. Round-trip tested,
  including against real local data.

## Roadmap

- 🚧 Codex rollout read/write (`~/.codex/sessions/**/rollout-*.jsonl`)
- 🚧 One-click **switch**: locate the latest session → convert → write → resume
- 🚧 Config sync: memory (`CLAUDE.md` ⇄ `AGENTS.md`) · skills · MCP (JSON ⇄ TOML)
- 🚧 Safety: backup-before-write + atomic writes
- 🚧 Developer ID signing + notarization; GitHub Releases / Homebrew cask

## Requirements

- macOS 26+
- Swift 6.2 / Xcode 26 (to build)
- Zero third-party dependencies

## Build & run

```sh
swift run     # launch the menu-bar app (then look at the top-right of the menu bar)
swift test    # run the engine tests
swift build   # compile only
```

VibeOne is a menu-bar-only accessory: after `swift run` you'll see **nothing**
on screen except a new glyph in the menu bar — click it to open the popover. Quit
by stopping `swift run` (Ctrl-C).

## Architecture

One SwiftPM package, two targets:

- **`VibeOne`** — the SwiftUI menu-bar app. All design values (spacing, radius,
  color, type) live in `Sources/VibeOne/UI/DesignSystem.swift`; views use tokens,
  never raw numbers or hex.
- **`VibeOneEngine`** — agent-neutral session-handoff + config logic. Pure
  Foundation, no UI, fully unit-tested. Converts between each agent's native
  session format and a canonical IR.

It runs **fully local and offline** — it only reads and writes the agent files
already on your machine, never the network. A switch never mutates your original
session files; it always writes a new, resumable one.

## Contributing

Early and solo for now. To hack on it: branch from `main`, keep `swift build` +
`swift test` green (CI also runs `swift format` lint), and use
[Conventional Commits](https://www.conventionalcommits.org/).

## License

[MIT](LICENSE) © 2026 kuk1song
