# Releasing Claude Connection Watcher

GitHub's automatically generated source archives contain source code, not an installable macOS application. Distribute the packaged ZIP and checksum as assets attached to a GitHub Release.

## Security boundary

- Keep the Developer ID private key in the macOS Keychain.
- Keep App Store Connect `.p8` files, certificate exports, passwords, and provisioning profiles outside this repository.
- Do not copy a `.p12` or `.p8` into GitHub Actions for the initial release workflow.
- Store notarization credentials with `xcrun notarytool store-credentials`; the release script accepts only the resulting Keychain profile name.
- A Developer ID certificate subject and Team ID are public signing metadata. The corresponding private key is the credential that must remain secret.

## Optional local preview

To test packaging without using Apple Developer credentials:

```bash
bash scripts/package-release.sh --preview
```

This creates an ad-hoc-signed, unnotarized Universal 2 ZIP under `release/`. Its filename clearly contains `UNNOTARIZED-preview`; do not publish it as a normal stable release.

## Configure notarization once

1. Install a valid **Developer ID Application** certificate in your login Keychain.
2. Create a notarytool Keychain profile interactively:

   ```bash
   xcrun notarytool store-credentials "ccw-notary"
   ```

3. Follow Apple's prompts. Do not place the resulting credentials or any exported private key in this repository.

## Build the public package

Before running the formal release command, commit every change and create the exact version tag matching `Info.plist` (for example, `v0.1.0`). The script refuses a dirty working tree or an untagged/mismatched `HEAD`.

Use the public name of the Developer ID identity shown by Keychain Access or `security find-identity`:

```bash
CCW_SIGN_IDENTITY="Developer ID Application: PUBLIC CERTIFICATE NAME (TEAMID)" \
CCW_NOTARY_PROFILE="ccw-notary" \
  bash scripts/package-release.sh --release
```

The script:

1. Builds `arm64` and `x86_64` executables and combines them into a Universal 2 app.
2. Signs the app with Hardened Runtime and a secure timestamp.
3. Rejects signatures that are not Developer ID Application signatures.
4. Submits a temporary ZIP through `notarytool` using the Keychain profile.
5. Requires structured `Accepted`/status-code results and rejects issue records in the downloaded notary log.
6. Staples and validates the notarization ticket.
7. Runs `codesign` and Gatekeeper assessment checks.
8. Packages under a hidden pending filename, extracts it into a fresh temporary directory, and repeats architecture, signature, stapler, and Gatekeeper checks.
9. Only after every gate succeeds, exposes the formal ZIP filename and writes a basename-only SHA-256 checksum.

The ignored `release/` directory also retains the Apple notary log for local review. Do not upload that log as a release asset.

Expected assets:

```text
release/Claude-Connection-Watcher-vVERSION-macOS-universal.zip
release/Claude-Connection-Watcher-vVERSION-macOS-universal.zip.sha256
```

## Publish on GitHub

1. Ensure the repository is clean and the release commit is pushed.
2. Create a version tag such as `v0.1.0`.
3. Create a **draft** GitHub Release for that tag.
4. Upload the ZIP and `.sha256` file as release assets.
5. Download the draft asset and test it on another Mac or a fresh user account.
6. Confirm Gatekeeper accepts it and the checksum matches.
7. Publish the draft release.

Never attach the contents of the local `release/` directory to Git itself. The directory is ignored and is only a staging area for GitHub Release assets.

## Homebrew tap

Maintain `Casks/claude-connection-watcher.rb` in the separate public `LeiZiKang/homebrew-tap` repository. After publishing a release, update the cask's version and SHA-256 to match the exact downloadable ZIP. Do not use `:no_check` or attach signing credentials to the tap.

Validate the cask with `brew style`, load its metadata with `brew info --cask`, and verify the published download with `brew fetch --cask`. A local install test must preserve any existing manual installation and preferences. Publish the release asset before publishing a cask that references it.
