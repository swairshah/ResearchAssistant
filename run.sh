#!/bin/zsh
set -euo pipefail

swift build

APP_DIR=".build/ResearchReader.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy the built executable and its resource bundle
cp .build/arm64-apple-macosx/debug/ResearchReader "$MACOS/ResearchReader"
cp -R .build/arm64-apple-macosx/debug/ResearchReader_ResearchReader.bundle "$RESOURCES/"

# Generate .icns from the PNG icon
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
SOURCE_PNG="Sources/ResearchReader/Resources/icon.png"
sips -z 16 16     "$SOURCE_PNG" --out "$ICONSET/icon_16x16.png"      > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET/icon_16x16@2x.png"   > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET/icon_32x32.png"      > /dev/null
sips -z 64 64     "$SOURCE_PNG" --out "$ICONSET/icon_32x32@2x.png"   > /dev/null
sips -z 128 128   "$SOURCE_PNG" --out "$ICONSET/icon_128x128.png"    > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET/icon_256x256.png"    > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET/icon_512x512.png"    > /dev/null
sips -z 1024 1024 "$SOURCE_PNG" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

# Write Info.plist
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ResearchReader</string>
    <key>CFBundleIdentifier</key>
    <string>com.swair.research-reader</string>
    <key>CFBundleName</key>
    <string>ResearchReader</string>
    <key>CFBundleDisplayName</key>
    <string>Research Reader</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Research Reader uses the microphone for voice input to the AI assistant.</string>
</dict>
</plist>
PLIST

open "$APP_DIR"
