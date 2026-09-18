#!/bin/zsh
set -e
set -o pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E "error|Build complete"
APP="build/VoidMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoidMac "$APP/Contents/MacOS/VoidMac"
cp Tools/Info.plist "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build/AppIcon.iconset
  swift Tools/MakeIcon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
Tools/make-cert.sh
security unlock-keychain -p voidmac "$HOME/Library/Keychains/voidmac.keychain-db" 2>/dev/null || true
codesign --force --sign "VoidMac Dev" --identifier cz.voidmac.app "$APP" 2>&1 | grep -vE "replacing existing signature|unable to build chain" || true
echo "Built $APP"
