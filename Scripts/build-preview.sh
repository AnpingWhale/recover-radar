#!/bin/bash
# A runnable, ad-hoc signed development app for Macs with Command Line Tools.
# This intentionally does not install a Widget or simulate App Group access.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
configuration="${1:-debug}"
case "$configuration" in
  debug) output_dir="$repo_root/build"; optimization="-Onone" ;;
  release) output_dir="$repo_root/build/release"; optimization="-O" ;;
  *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 2 ;;
esac
swift build -c "$configuration"
products_dir="$(swift build -c "$configuration" --show-bin-path)"
preview_app="$output_dir/Recovery Radar Preview.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources"
xcrun swiftc -swift-version 6 -parse-as-library "$optimization" \
  -target "$(uname -m)-apple-macos14.0" \
  -I "$products_dir" -I "$products_dir/Modules" -L "$products_dir" \
  Apps/RecoverRadar/*.swift \
  -lRecoveryUI -lCOROSIntegration -lRecoveryCore \
  -o "$preview_app/Contents/MacOS/RecoverRadar"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RecoverRadar</string>
<key>CFBundleIdentifier</key><string>org.example.RecoverRadar.Preview</string>
<key>CFBundleName</key><string>Recovery Radar Preview</string>
<key>CFBundleDisplayName</key><string>Recovery Radar Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>RecoverRadarPreviewMode</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>org.example.RecoverRadar.Preview</string>
<key>CFBundleURLSchemes</key><array><string>recoverradar</string></array>
</dict></array>
</dict></plist>
PLIST
cp LICENSE "$preview_app/Contents/Resources/LICENSE"
codesign --force --sign - "$preview_app"
codesign --verify --strict "$preview_app"
printf '\nDevelopment preview: %s\n' "$preview_app"
