#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
final_app_path="$project_root/dist/Claude Connection Watcher.app"
thin_root="$project_root/dist/.thin"
architecture_list="${CCW_ARCHITECTURES:-$(uname -m)}"
staging_root="$(/usr/bin/mktemp -d /private/tmp/ClaudeConnectionWatcher.XXXXXX)"
app_path="$staging_root/Claude Connection Watcher.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"

cleanup() {
  if [[ "$staging_root" == /private/tmp/ClaudeConnectionWatcher.* ]]; then
    rm -rf "$staging_root"
  fi
}
trap cleanup EXIT

if [ -n "${CCW_SDK_PATH:-}" ]; then
  sdk_path="$CCW_SDK_PATH"
elif [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
  # This older SDK also avoids a known CLT compiler/SDK version skew.
  sdk_path="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
fi

read -r -a architectures <<< "$architecture_list"
[ "${#architectures[@]}" -gt 0 ] || {
  echo "CCW_ARCHITECTURES did not contain an architecture." >&2
  exit 2
}

for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Unsupported macOS architecture: $architecture" >&2; exit 2 ;;
  esac
done

rm -rf "$thin_root"
mkdir -p "$macos_path" "$thin_root"

declare -a thin_binaries=()
for architecture in "${architectures[@]}"; do
  architecture_root="$thin_root/$architecture"
  binary_path="$architecture_root/ClaudeConnectionWatcher"
  mkdir -p \
    "$architecture_root/ModuleCache" \
    "$architecture_root/SDKModuleCache"

  xcrun swiftc \
    -swift-version 5 \
    -target "$architecture-apple-macosx13.0" \
    -sdk "$sdk_path" \
    -module-cache-path "$architecture_root/ModuleCache" \
    -sdk-module-cache-path "$architecture_root/SDKModuleCache" \
    -framework AppKit \
    "$project_root/Sources/main.swift" \
    -o "$binary_path"

  strip -x "$binary_path"
  thin_binaries+=("$binary_path")
done

app_binary="$macos_path/ClaudeConnectionWatcher"
if [ "${#thin_binaries[@]}" -eq 1 ]; then
  cp "${thin_binaries[0]}" "$app_binary"
else
  xcrun lipo -create "${thin_binaries[@]}" -output "$app_binary"
fi

cp "$project_root/Info.plist" "$contents_path/Info.plist"
chmod 755 "$app_binary"
plutil -lint "$contents_path/Info.plist"

# Clear Finder/resource-fork metadata in isolated staging before signing.
xattr -cr "$app_path"

if [ -n "${CCW_SIGN_IDENTITY:-}" ]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$CCW_SIGN_IDENTITY" \
    "$app_path"
  signing_mode="Developer ID"
else
  codesign --force --sign - "$app_path"
  signing_mode="ad-hoc"
fi

codesign --verify --all-architectures --deep --strict "$app_path"

if [ -e "$final_app_path" ]; then
  rm -rf "$final_app_path"
fi
/usr/bin/ditto --norsrc --noextattr "$app_path" "$final_app_path"
codesign --verify --all-architectures --deep --strict "$final_app_path"

final_binary="$final_app_path/Contents/MacOS/ClaudeConnectionWatcher"
architectures_built="$(xcrun lipo -archs "$final_binary")"

echo "Built: $final_app_path"
echo "Architectures: $architectures_built"
echo "Signing: $signing_mode"
echo "The app was not launched and no process was stopped."
