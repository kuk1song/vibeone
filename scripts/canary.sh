#!/usr/bin/env bash
# VibeOne canary — local / self-hosted nightly drift sentinel (PR-E E4, ADR-010 ⑥).
#
# Runs the assertive `CanaryTests` suite against THIS machine's real ~/.claude and
# ~/.codex data: it demands sessions exist and still parse through the adapters.
# Unlike the opportunistic real-data tests (which skip when data is absent), a
# missing or unparseable store here is a RED failure — the signal that Claude Code
# or Codex moved or changed their on-disk format, caught before a user hits it.
#
# Run by hand:                 scripts/canary.sh
# Schedule it with launchd:    see scripts/com.vibeone.canary.plist
#
# Exits non-zero on any drift. Appends to $VIBEONE_CANARY_LOG.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${VIBEONE_CANARY_LOG:-$HOME/Library/Logs/vibeone-canary.log}"
mkdir -p "$(dirname "$LOG")"

cd "$REPO"

# pipefail makes the swift-test exit status survive the `tee`, so a drift fails
# the script (and, under launchd, leaves a non-zero exit in the log).
{
    echo "===== VibeOne canary @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
    echo "repo:  $REPO"
    echo "swift: $(swift --version | head -1)"
    VIBEONE_CANARY=1 swift test --filter CanaryTests
    echo "===== canary OK ====="
} 2>&1 | tee -a "$LOG"
