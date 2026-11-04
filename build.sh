#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="${1:-build}"
mkdir -p "$build_dir/Fuzzy Display.app/Contents/MacOS"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc FuzzyDisplay.swift -module-cache-path "$build_dir/ModuleCache" -O -target "$arch-apple-macos13.0" -sdk "$sdk" -import-objc-header CGVirtualDisplayPrivate.h -framework Cocoa -framework CoreGraphics -o "$build_dir/FuzzyDisplay-$arch"
done
lipo -create "$build_dir/FuzzyDisplay-arm64" "$build_dir/FuzzyDisplay-x86_64" -output "$build_dir/Fuzzy Display.app/Contents/MacOS/FuzzyDisplay"
cp Info.plist "$build_dir/Fuzzy Display.app/Contents/Info.plist"
mkdir -p "$build_dir/Fuzzy Display.app/Contents/Resources"
cp LICENSE.md "$build_dir/Fuzzy Display.app/Contents/Resources/LICENSE.md"
codesign --force --sign - --identifier team.fuzzy.display "$build_dir/Fuzzy Display.app"
COPYFILE_DISABLE=1 tar -czf "$build_dir/FuzzyDisplay.tar.gz" -C "$build_dir" 'Fuzzy Display.app'
