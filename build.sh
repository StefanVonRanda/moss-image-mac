#!/bin/zsh
# Builds MossImage.app next to this script. Run: ~/moss-mlx/app/build.sh
#   --release  also bundles the engine payload (scripts/engine-payload.sh) into Contents/Resources/engine
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -vE "^\[|Compiling|Build complete" || true
APP=MossImage.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/MossImage "$APP/Contents/MacOS/MossImage"
if [[ "${1:-}" == --release ]]; then
  scripts/engine-payload.sh >/dev/null
  mkdir -p "$APP/Contents/Resources/engine"
  cp .build/engine/uv .build/engine/*.whl .build/engine/requirements.lock "$APP/Contents/Resources/engine/"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MOSS Image</string>
  <key>CFBundleDisplayName</key><string>MOSS Image</string>
  <key>CFBundleIdentifier</key><string>dk.vonranda.mossimage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MossImage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $(pwd)/$APP"
