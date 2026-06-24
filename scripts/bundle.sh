#!/usr/bin/env bash
# VibeOne bundler — assemble a double-clickable VibeOne.app from `swift build`.
#
# A bare SwiftPM executable is just a Mach-O binary: it has no Info.plist, so it
# can't be a menu-bar-only ("LSUIElement") app, can't be double-clicked from
# Finder, and can't launch at login. This wraps the release binary in the minimal
# `.app` bundle layout macOS expects:
#
#   VibeOne.app/Contents/
#     Info.plist          identity + LSUIElement (menu-bar-only, no Dock icon)
#     MacOS/VibeOne       the release binary
#     Resources/          (reserved for an .icns later)
#
# v0 ships UNSIGNED (ad-hoc) — `swift build` ad-hoc-signs the binary so it runs
# locally, and we re-sign the whole bundle so the signature also seals Info.plist.
# Developer ID signing + notarization come later, only when frictionless download
# distribution is needed (see local_notes/DECISIONS.md ADR-004). No third-party
# tools: just the toolchain plus codesign / plutil that ship with macOS.
#
# Usage:
#   scripts/bundle.sh [OUT_DIR]          # default OUT_DIR = .build (gitignored)
#   VIBEONE_VERSION=0.2.0 scripts/bundle.sh
#
# Then: open .build/VibeOne.app   (or drag it into /Applications to dogfood).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

APP_NAME="VibeOne"
BUNDLE_ID="io.github.kuk1song.vibeone"

# Marketing version (human-facing) and build number (monotonic, for future
# updates/notarization). No git tags yet → default the version; derive the build
# from the commit count so it always increases.
VERSION="${VIBEONE_VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

OUT_DIR="${1:-.build}"
APP="$OUT_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME (release)…"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "error: release binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP (v$VERSION build $BUILD)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHumanReadableCopyright</key>
	<string>MIT License</string>
</dict>
</plist>
PLIST

# Fail loudly if the generated plist is malformed.
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc sign the whole bundle (identity "-"): seals Info.plist + MacOS together.
# No nested frameworks/helpers, so no --deep needed. This is NOT Developer ID —
# downloaded copies still hit Gatekeeper until phase 2 (ADR-004).
echo "==> Ad-hoc signing…"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
echo "    open \"$APP\"                     # run it now"
echo "    cp -R \"$APP\" /Applications/       # install for login launch"
