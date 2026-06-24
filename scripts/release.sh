#!/usr/bin/env bash
# VibeOne release packager — build the bundle and archive it for a GitHub Release.
#
# Phase-1 distribution is unsigned (ADR-004): this produces VibeOne-<version>.zip
# — the .app archived with `ditto`, which (unlike a plain `zip`) keeps the bundle
# structure, symlinks, and ad-hoc signature intact — plus a SHA-256 checksum, the
# only integrity signal an unsigned download has.
#
# It does NOT create the GitHub Release: tagging and publishing are outward-facing
# steps you run yourself. The script prints the exact commands when it's done.
#
# Usage:
#   scripts/release.sh [VERSION]        # default VERSION = 0.1.0
#
# Then follow the printed `git tag` / `gh release create` (or upload the artifacts
# on the Releases page in your browser).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

VERSION="${1:-${VIBEONE_VERSION:-0.1.0}}"
TAG="v$VERSION"
OUT_DIR=".build"
APP="$OUT_DIR/VibeOne.app"
ZIP="$OUT_DIR/VibeOne-$VERSION.zip"

# Build the .app at this version (delegates to the bundler).
VIBEONE_VERSION="$VERSION" "$REPO/scripts/bundle.sh" "$OUT_DIR"

echo "==> Archiving ${ZIP}…"
rm -f "$ZIP" "$ZIP.sha256"
# `ditto` is Apple's tool for archiving an .app: it preserves the signature and
# symlinks a plain `zip` would mangle. --keepParent puts VibeOne.app at the root.
ditto -c -k --keepParent "$APP" "$ZIP"

# Checksum so downloaders can verify an unsigned artifact.
( cd "$OUT_DIR" && shasum -a 256 "VibeOne-$VERSION.zip" > "VibeOne-$VERSION.zip.sha256" )

# Round-trip check: the archived copy must still pass codesign once expanded.
echo "==> Verifying the archived copy…"
VERIFY_DIR="$(mktemp -d)"
ditto -x -k "$ZIP" "$VERIFY_DIR"
codesign --verify --strict "$VERIFY_DIR/VibeOne.app"
rm -rf "$VERIFY_DIR"

echo
echo "==> Built $ZIP (v$VERSION)"
cat "$ZIP.sha256"
echo
echo "Publish the release (run yourself — these tag and push):"
echo "  git tag $TAG && git push origin $TAG"
echo "  gh release create $TAG \"$ZIP\" \"$ZIP.sha256\" --title \"$TAG\" --notes \"…\""
echo "Or upload the zip + checksum at https://github.com/kuk1song/vibeone/releases"
