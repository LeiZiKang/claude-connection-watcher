#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
app_binary="$project_root/dist/Claude Connection Watcher.app/Contents/MacOS/ClaudeConnectionWatcher"

plutil -lint "$project_root/Info.plist"
"$script_dir/build.sh"
"$app_binary" --self-test

echo "All tests passed. No user application was stopped."
