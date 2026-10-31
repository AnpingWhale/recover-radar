#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
swift build
products_dir="$(swift build --show-bin-path)"
mkdir -p build
xcrun swiftc -swift-version 6 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -I "$products_dir" -I "$products_dir/Modules" -L "$products_dir" \
  -lRecoveryUI -lRecoveryCore Scripts/render-widget-previews.swift \
  -o build/render-widget-previews
./build/render-widget-previews
