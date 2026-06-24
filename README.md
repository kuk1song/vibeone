# VibeOne 🎵

> A native macOS menu-bar app for switching a project between Claude Code and
> Codex without a break — your live session, memory, skills, and MCP all follow
> the project.

🚧 Early development.

## What it does

VibeOne lives in your menu bar. Pick a project's session and switch the agent
behind it: it hands off the in-flight conversation to the other agent, keeps
their shared context in sync, and opens the target so you can keep working.

- **Session handoff** — continue the same conversation in the other agent.
- **Config sync** — memory, skills, and MCP servers follow the project.
- **Menu-bar native** — SwiftUI, no Dock icon, zero third-party dependencies.

## Requirements

- macOS 26 or later
- Claude Code and/or Codex installed

## Install

### Download

1. Download the latest `VibeOne-*.zip` from the
   [Releases](https://github.com/kuk1song/vibeone/releases) page and unzip it.
2. Move **VibeOne.app** into your **Applications** folder.
3. VibeOne isn't notarized yet, so macOS blocks it the first time. Approve it
   once:
   - Double-click VibeOne — macOS refuses to open it.
   - Open **System Settings → Privacy & Security**, scroll down, and click
     **Open Anyway** next to the VibeOne message; confirm with Touch ID or your
     password.
   - Prefer the terminal? `xattr -dr com.apple.quarantine /Applications/VibeOne.app`
     clears the quarantine flag so it opens normally.

   You only do this once. Look for the VibeOne face in your menu bar.

### Build from source

```sh
git clone https://github.com/kuk1song/vibeone.git
cd vibeone
./scripts/bundle.sh        # assembles .build/VibeOne.app
open .build/VibeOne.app
```

During development you can also just run `swift run`.

## Why does macOS warn me?

VibeOne ships as an unsigned, ad-hoc build for now — that's why macOS asks you
to approve it the first time. Signed, notarized builds are planned so downloads
open without the extra step.

## License

[MIT](LICENSE)
