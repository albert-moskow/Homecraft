#!/bin/bash
# Сборка .app без Xcode — только Command Line Tools.
set -e
cd "$(dirname "$0")"

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk}"
VERSION="${VERSION:-1.0.0}"
OUT="build/HomeCraft.app"

rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -O \
    -o "$OUT/Contents/MacOS/HomeCraft" src/*.swift

cp Info.plist "$OUT/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$OUT/Contents/Info.plist"

# иконка
if [ -f icon.png ]; then
  mkdir -p AppIcon.iconset
  for s in 16 32 64 128 256 512; do
    cp icon.png "AppIcon.iconset/icon_${s}x${s}.png"
  done
  iconutil -c icns AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$OUT/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --deep --sign - "$OUT"
echo "Готово: $OUT"
