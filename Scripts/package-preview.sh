#!/bin/bash
# Package only the standalone preview; never imply a signed Widget release.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
version="0.2.0-preview.1"
architecture="$(uname -m)"
./Scripts/build-preview.sh release
release_dir="$repo_root/build/releases"
staging_dir="$(mktemp -d "$repo_root/build/preview-package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$release_dir"
ditto "$repo_root/build/release/Recovery Radar Preview.app" "$staging_dir/Recovery Radar Preview.app"
cp LICENSE "$staging_dir/LICENSE.txt"
cat > "$staging_dir/请先阅读.txt" <<'NOTES'
Recovery Radar 0.2.0-preview.1

这是 macOS 14+ 的主应用预览，不包含可安装到桌面的 Widget 扩展。
将应用拖入 Applications，打开后选择“预览演示”或“小组件效果”。
演示数据为合成数据；真实账号登录尚待端到端验收。

该预览仅作 ad-hoc 签名，未经过 Developer ID 签名或 Apple 公证。
macOS 可能阻止打开；请勿关闭系统安全保护，也可自行从源码构建。
完整源码、正式工程签名及安装说明：
https://github.com/AnpingWhale/recover-radar

MIT License © 2026 AnpingWhale
NOTES
ln -s /Applications "$staging_dir/Applications"
artifact_name="RecoverRadar-$version-$architecture"
hdiutil create -volname "Recovery Radar Preview" -srcfolder "$staging_dir" \
  -format UDZO -ov "$release_dir/$artifact_name.dmg"
ditto -c -k --sequesterRsrc "$staging_dir" "$release_dir/$artifact_name.zip"
(cd "$release_dir" && shasum -a 256 "$artifact_name.dmg" "$artifact_name.zip" > SHA256SUMS.txt)
printf '\nPreview release files: %s\n' "$release_dir"
