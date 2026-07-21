#!/bin/bash
# Builds a distributable, unsigned PhraseCounterApp.app bundle.
#
# Why this exists: the primary, documented way to run this project is
# compiling from source (see README's Setup section) — deliberately, since
# this tool reads djay's live UI and database, and "read the source you're
# about to run" is a real trust property an unsigned prebuilt binary can't
# offer the same way. This script exists as an ADDITIONAL convenience
# option for people who'd rather download-and-run than install Xcode
# Command Line Tools and compile — not a replacement for the source path.
#
# Since there's no Apple Developer ID to sign/notarize this app, macOS
# Gatekeeper will still block the first launch either way (same as any
# unsigned software) — see the README section this script's output is
# documented under for the right-click-to-open workaround.
set -e

cd "$(dirname "$0")/PhraseCounterApp"

echo "Building release binary..."
swift build -c release

BIN_PATH=".build/release/PhraseCounterApp"
if [ ! -f "$BIN_PATH" ]; then
  # Fall back to the arch-qualified path some toolchains use instead.
  BIN_PATH=$(find .build -type f -path "*release/PhraseCounterApp" | head -1)
fi
if [ ! -f "$BIN_PATH" ]; then
  echo "Could not find the built binary." >&2
  exit 1
fi

APP_DIR="../dist/PhraseCounterApp.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/PhraseCounterApp"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PhraseCounterApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.yanchau.djay-phrase-tool</string>
    <key>CFBundleName</key>
    <string>PhraseCounterApp</string>
    <key>CFBundleDisplayName</key>
    <string>djay Phrase Counter</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Re-signing (ad-hoc) so Gatekeeper sees a valid, consistent bundle signature..."
# Without this, the hand-assembled bundle carries a stale linker-only signature
# that only covers the raw binary, not the bundle as a whole (Info.plist etc.) —
# Gatekeeper then reports the .app as "damaged" instead of the normal
# unidentified-developer warning. This does NOT make the app trusted/notarized,
# it just makes the signature internally consistent.
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
du -sh "$APP_DIR"

ZIP_PATH="../dist/PhraseCounterApp-macOS.zip"
rm -f "$ZIP_PATH"
echo "Zipping with ditto (NOT the zip command — zip mangles .app bundle metadata and signatures, which is a common cause of the 'file is damaged' Gatekeeper error)..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
echo "Zipped: $ZIP_PATH"
