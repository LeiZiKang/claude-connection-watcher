#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
app_path="$project_root/dist/Claude Connection Watcher.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
module_cache_path="$project_root/dist/.ModuleCache"
sdk_module_cache_path="$project_root/dist/.SDKModuleCache"
architecture="$(uname -m)"

case "$architecture" in
  arm64|x86_64) ;;
  *) echo "Unsupported macOS architecture: $architecture" >&2; exit 1 ;;
esac

if [ -n "${CCW_SDK_PATH:-}" ]; then
  sdk_path="$CCW_SDK_PATH"
elif [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
  # This older SDK also avoids a known CLT compiler/SDK version skew.
  sdk_path="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
fi

if [ -e "$app_path" ]; then
  rm -rf "$app_path"
fi

mkdir -p "$macos_path" "$module_cache_path" "$sdk_module_cache_path"

xcrun swiftc \
  -swift-version 5 \
  -target "$architecture-apple-macosx13.0" \
  -sdk "$sdk_path" \
  -module-cache-path "$module_cache_path" \
  -sdk-module-cache-path "$sdk_module_cache_path" \
  -framework AppKit \
  "$project_root/Sources/main.swift" \
  -o "$macos_path/ClaudeConnectionWatcher"

strip -x "$macos_path/ClaudeConnectionWatcher"
cp "$project_root/Info.plist" "$contents_path/Info.plist"
chmod 755 "$macos_path/ClaudeConnectionWatcher"

plutil -lint "$contents_path/Info.plist"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

echo "Built: $app_path"
echo "The app was not launched and no process was stopped."
