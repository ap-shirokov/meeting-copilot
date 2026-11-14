#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/Meeting Copilot.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$ROOT/dist"
xcrun swiftc -parse-as-library -O -swift-version 5 -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework AVFoundation \
    -framework ScreenCaptureKit -framework CoreMedia -framework AudioToolbox \
    Sources/main.swift -o "$CONTENTS/MacOS/MeetingCopilot"
cp scripts/Info.plist "$CONTENTS/Info.plist"
cp scripts/whisper_worker.py "$CONTENTS/Resources/whisper_worker.py"
cp scripts/litellm-config.yaml "$CONTENTS/Resources/litellm-config.yaml"
chmod +x "$CONTENTS/MacOS/MeetingCopilot"
# Local unsigned build: ad-hoc signing, no Apple Developer ID notarization.
codesign --force --deep --sign - "$APP"
DMG="$ROOT/dist/Meeting-Copilot-0.4.0.dmg"
rm -f "$DMG"
hdiutil create -volname 'Meeting Copilot' -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Created: $DMG"
