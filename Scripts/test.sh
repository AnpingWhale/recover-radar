#!/bin/bash
# CLT-only Swift 6.4 installations omit the bundled Testing macro search path.
# Keep this toolchain workaround out of the package's portable build settings.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
developer_dir="$(xcode-select -p)"
testing_plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
if [[ "$developer_dir" == */CommandLineTools && -f "$testing_plugins/libTestingMacros.dylib" ]]; then
  exec swift test --disable-xctest -Xswiftc -plugin-path -Xswiftc "$testing_plugins" "$@"
fi
exec swift test --disable-xctest "$@"
