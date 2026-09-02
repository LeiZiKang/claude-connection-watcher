#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
app_path="$project_root/dist/Claude Connection Watcher.app"
app_binary="$app_path/Contents/MacOS/ClaudeConnectionWatcher"
release_dir="$project_root/release"
version="$(plutil -extract CFBundleShortVersionString raw "$project_root/Info.plist")"
base_name="Claude-Connection-Watcher-v${version}-macOS-universal"
submission_path=""
notary_log_path=""
validation_root=""
pending_archive_path=""
formal_archive_path=""
release_succeeded=false

cleanup() {
  if [ -n "$submission_path" ] && [[ "$submission_path" == "$release_dir"/.*-notary-submission.zip ]]; then
    rm -f "$submission_path"
  fi
  if [ -n "$validation_root" ] && [[ "$validation_root" == /private/tmp/CCWReleaseValidation.* ]]; then
    rm -rf "$validation_root"
  fi
  if [ -n "$pending_archive_path" ] && [[ "$pending_archive_path" == "$release_dir"/.*-pending.zip ]]; then
    rm -f "$pending_archive_path" "$pending_archive_path.sha256"
  fi
  if [ "$release_succeeded" != true ] &&
     [ -n "$formal_archive_path" ] &&
     [[ "$formal_archive_path" == "$release_dir"/Claude-Connection-Watcher-*.zip ]]; then
    rm -f "$formal_archive_path" "$formal_archive_path.sha256"
  fi
}
trap cleanup EXIT

write_checksum() {
  local archive_path="$1"
  local archive_name
  archive_name="$(basename "$archive_path")"
  (
    cd "$release_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
  )
}

verify_checksum() {
  local archive_path="$1"
  local archive_name
  archive_name="$(basename "$archive_path")"
  (
    cd "$release_dir"
    /usr/bin/shasum -a 256 -c "$archive_name.sha256"
  )
}

assert_universal_binary() {
  local binary_path="$1"
  local architecture_output architecture_count
  architecture_output="$(xcrun lipo -archs "$binary_path")"
  architecture_count="$(printf '%s\n' "$architecture_output" | /usr/bin/awk '{print NF}')"
  if [ "$architecture_count" -ne 2 ] ||
     [[ " $architecture_output " != *" arm64 "* ]] ||
     [[ " $architecture_output " != *" x86_64 "* ]]; then
    echo "Expected exactly arm64 and x86_64; found: $architecture_output" >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Usage:
  bash scripts/package-release.sh --preview
  CCW_SIGN_IDENTITY="Developer ID Application: ..." \
  CCW_NOTARY_PROFILE="keychain-profile-name" \
    bash scripts/package-release.sh --release

--preview creates an explicitly marked, ad-hoc-signed and unnotarized ZIP.
--release requires a Developer ID identity and a notarytool Keychain profile.

This script never reads, exports, or copies a signing private key. The signing
identity stays in the macOS Keychain, and notarytool resolves its credential
profile from the Keychain.
EOF
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
mode="$1"
case "$mode" in
  --preview|--release) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

mkdir -p "$release_dir"

if [ "$mode" = "--preview" ]; then
  CCW_ARCHITECTURES="arm64 x86_64" \
  CCW_SIGN_IDENTITY="" \
    "$script_dir/build.sh"
  archive_path="$release_dir/${base_name}-UNNOTARIZED-preview.zip"
  rm -f "$archive_path" "$archive_path.sha256"
  assert_universal_binary "$app_binary"
  codesign --verify --all-architectures --deep --strict "$app_path"
  /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$app_path" "$archive_path"
  write_checksum "$archive_path"
  verify_checksum "$archive_path"
  echo "Preview package created: $archive_path"
  echo "WARNING: This preview is ad-hoc signed and not notarized. Gatekeeper may block it."
  exit 0
fi

: "${CCW_SIGN_IDENTITY:?Set CCW_SIGN_IDENTITY to a Developer ID Application identity.}"
: "${CCW_NOTARY_PROFILE:?Set CCW_NOTARY_PROFILE to a notarytool Keychain profile name.}"

if [ -n "$(git -C "$project_root" status --porcelain)" ]; then
  echo "Refusing a formal release from a dirty Git working tree." >&2
  exit 1
fi
expected_tag="v$version"
if ! git -C "$project_root" tag --points-at HEAD --list "$expected_tag" | grep -Fxq "$expected_tag"; then
  echo "Refusing release: HEAD must have the exact tag $expected_tag." >&2
  exit 1
fi

CCW_ARCHITECTURES="arm64 x86_64" \
  "$script_dir/build.sh"

assert_universal_binary "$app_binary"
codesign --verify --all-architectures --deep --strict --verbose=2 "$app_path"

signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:' || {
  echo "The app is not signed with a Developer ID Application certificate." >&2
  exit 1
}
printf '%s\n' "$signature_details" | grep -q 'flags=.*runtime' || {
  echo "The hardened runtime flag is missing from the signature." >&2
  exit 1
}
printf '%s\n' "$signature_details" | grep -q '^Timestamp=' || {
  echo "The secure timestamp is missing from the signature." >&2
  exit 1
}

submission_path="$release_dir/.${base_name}-notary-submission.zip"
notary_log_path="$release_dir/.${base_name}-notary-log.json"
pending_archive_path="$release_dir/.${base_name}-pending.zip"
formal_archive_path="$release_dir/${base_name}.zip"
archive_path="$formal_archive_path"
rm -f \
  "$submission_path" \
  "$notary_log_path" \
  "$pending_archive_path" \
  "$pending_archive_path.sha256" \
  "$formal_archive_path" \
  "$formal_archive_path.sha256"
/usr/bin/ditto -c -k --keepParent "$app_path" "$submission_path"

notary_result="$(xcrun notarytool submit \
  "$submission_path" \
  --keychain-profile "$CCW_NOTARY_PROFILE" \
  --wait \
  --output-format json)"
notary_status="$(printf '%s' "$notary_result" | plutil -extract status raw -o - -)"
submission_id="$(printf '%s' "$notary_result" | plutil -extract id raw -o - -)"

xcrun notarytool log \
  "$submission_id" \
  "$notary_log_path" \
  --keychain-profile "$CCW_NOTARY_PROFILE"

log_status="$(plutil -extract status raw "$notary_log_path")"
log_status_code="$(plutil -extract statusCode raw "$notary_log_path")"
if [ "$notary_status" != "Accepted" ] ||
   [ "$log_status" != "Accepted" ] ||
   [ "$log_status_code" != "0" ]; then
  echo "Apple notarization was not accepted. Submission: $submission_id" >&2
  exit 1
fi

issues_plist="$(plutil -extract issues xml1 -o - "$notary_log_path" 2>/dev/null || true)"
issue_count="$(printf '%s\n' "$issues_plist" | grep -c '<dict>' || true)"
if [ "$issue_count" -gt 0 ]; then
  echo "Notary log contains $issue_count issue record(s); review: $notary_log_path" >&2
  exit 1
fi

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --all-architectures --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

# Repackage after stapling so the downloadable app contains its ticket.
/usr/bin/ditto -c -k --keepParent "$app_path" "$pending_archive_path"
rm -f "$submission_path"
submission_path=""

# Verify the exact downloadable archive after extracting it to a fresh location.
validation_root="$(/usr/bin/mktemp -d /private/tmp/CCWReleaseValidation.XXXXXX)"
/usr/bin/ditto -x -k "$pending_archive_path" "$validation_root"
validated_app="$validation_root/Claude Connection Watcher.app"
validated_binary="$validated_app/Contents/MacOS/ClaudeConnectionWatcher"
assert_universal_binary "$validated_binary"
codesign --verify --all-architectures --deep --strict --verbose=2 "$validated_app"
xcrun stapler validate "$validated_app"
spctl --assess --type execute --verbose=4 "$validated_app"

# Only expose a formal filename after every verification gate has passed.
mv "$pending_archive_path" "$formal_archive_path"
pending_archive_path=""
write_checksum "$formal_archive_path"
verify_checksum "$formal_archive_path"
release_succeeded=true

echo "Release package created: $archive_path"
echo "Checksum: $archive_path.sha256"
echo "Notary log (local review only): $notary_log_path"
echo "Upload both files to a draft GitHub Release after final review."
