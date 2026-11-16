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
    Sources/main.swift Sources/MeetingAudioRecorder.swift -o "$CONTENTS/MacOS/MeetingCopilot"
# Render the app icon at 1024 px, then build a multi-resolution .icns.
mkdir -p "$ROOT/dist/AppIcon.iconset"
xcrun swift scripts/generate-icon.swift "$ROOT/dist/MeetingCopilotIcon.png"
ICONSET="$ROOT/dist/AppIcon.iconset"
for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" \
            "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" \
            "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" \
            "1024 icon_512x512@2x.png"; do
    read -r pixels filename <<< "$spec"
    sips -s format png -z "$pixels" "$pixels" "$ROOT/dist/MeetingCopilotIcon.png" --out "$ICONSET/$filename" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/MeetingCopilot.icns"
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
