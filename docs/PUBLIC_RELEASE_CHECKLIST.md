# Public Release Credential-Safety Checklist

Complete this checklist before publishing source code, tags, releases, binary attachments, screenshots, or diagnostic logs. Public maintainer names, GitHub usernames, repository URLs, ordinary bundle identifiers, and normal Git timestamps do not need to be anonymized.

## Secrets and service credentials

- Search for API keys, OAuth tokens, session cookies, passwords, webhook secrets, access tokens, refresh tokens, and credential-bearing URLs.
- Search for cloud, GitHub, Slack, proxy, VPN, VPS, database, analytics, and error-reporting credentials.
- Verify that `.env`, local configuration, generated profiles, debug logs, fixtures, and shell history were not added to Git.
- Inspect the complete reachable Git history, not only the current working tree, for credentials that were later deleted.

## Apple Developer material

- Do not commit Apple private keys or exports such as `.p8`, `.p12`, `.key`, or password-protected certificate archives.
- Do not commit provisioning profiles (`.mobileprovision` or `.provisionprofile`), exported Keychains, signing passwords, App Store Connect API keys, issuer IDs, or private key IDs.
- Inspect `Info.plist`, entitlements, embedded provisioning profiles, update feeds, and code-signing metadata before releasing an app bundle.
- Confirm whether the build is ad-hoc signed or Developer ID signed. Never upload a signing private key to the repository or CI without a deliberate encrypted-secret design.
- Treat a public bundle identifier, Team ID, certificate subject, maintainer name, or GitHub username as attribution/metadata—not as an authentication secret. Still publish them deliberately.

## Build and release artifacts

- Rebuild from the reviewed checkout; do not reuse an older bundle that may contain stale resources.
- Inspect compiled binaries and packaged resources for embedded tokens, credentials, private endpoints, local configuration, or provisioning profiles.
- Confirm generated apps, caches, local diagnostics, and signing exports are excluded by `.gitignore`.
- Run self-tests (which may stop their own disposable child processes but never user applications) and verify the repository is clean before tagging.

## Final checks

- Confirm the third-party/non-affiliation notice is visible.
- Confirm documented privacy behavior and limitations match the code.
- Review GitHub Actions configuration and logs to ensure secrets cannot be printed or exposed to untrusted pull requests.
- Prefer a private draft repository or draft release for the first external review.
- Publish only after source, history, CI configuration, and release artifacts have no unexplained credential finding.
