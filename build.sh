#!/bin/bash
# Сборка .app без Xcode — только Command Line Tools.
set -e
cd "$(dirname "$0")"

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
OUT="build/HomeCraft.app"

rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -O \
    -o "$OUT/Contents/MacOS/HomeCraft" src/*.swift

cp Info.plist "$OUT/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$OUT/Contents/Info.plist"

# Настоящий iconset: каждый PNG рисуется в своём размере, включая Retina.
swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -O \
    -o build/MakeIcon tools/MakeIcon.swift
mkdir -p build/icon-source
build/MakeIcon build/icon-source
iconutil -c icns build/icon-source/AppIcon.iconset \
    -o "$OUT/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$OUT"
echo "Готово: $OUT"
