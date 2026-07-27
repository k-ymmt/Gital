---
name: release
description: Release a new Gital version via Homebrew — bump version, build/notarize, publish the GitHub release, and update the tap cask. Use when the user asks to release, publish, or ship a new version.
disable-model-invocation: true
argument-hint: "[version]"
arguments: version
allowed-tools: |
  Bash(./Scripts/run-tests.sh)
  Bash(Scripts/release.sh)
  Bash(git add *)
  Bash(git commit *)
  Bash(git push *)
  Bash(git pull *)
  Bash(gh release create *)
  Bash(gh repo clone *)
  Bash(brew fetch *)
  Bash(security find-generic-password *)
---

# Gital release

Publishes a signed + notarized build to GitHub Releases and updates the Homebrew cask in `k-ymmt/homebrew-tap`. Users install with `brew install --cask k-ymmt/tap/gital`.

The new version is `$version` (e.g. `/release 1.1`). If it is empty, ask the user which version to release — do not guess.

## Preconditions (verify before starting)

- Working tree is clean (`git status`). If not, stop and ask.
- notarytool keychain profile `gital-notary` exists. Quick check: `security find-generic-password -s "com.apple.gke.notary.tool"` succeeds. If missing, ask the user to run: `! xcrun notarytool store-credentials gital-notary --apple-id <apple-id> --team-id 8HUWJ2ZRK2`

## Steps

1. **Bump version** (skip if the requested version already matches): update every `MARKETING_VERSION` in `Gital.xcodeproj/project.pbxproj` to `$version` and increment every `CURRENT_PROJECT_VERSION` by 1.
2. **Test**: `./Scripts/run-tests.sh` must pass. Stop on failure.
3. **Commit & push** the version bump to `main`.
4. **Build**: `Scripts/release.sh` — archives, signs with Developer ID, notarizes (waits for Apple; a few minutes), staples, zips. It prints the artifact path and SHA256 at the end; capture both. Stop if notarization status is not `Accepted`.
5. **GitHub release**: `gh release create v$version build/release/Gital-$version.zip --repo k-ymmt/Gital --title "Gital $version" --notes "<short release notes from recent commits>"`
6. **Update the tap cask**: work in `/opt/homebrew/Library/Taps/k-ymmt/homebrew-tap` if it exists (run `git pull` first); otherwise `gh repo clone k-ymmt/homebrew-tap` into the scratchpad. In `Casks/gital.rb`, set `version "$version"` and `sha256 "<sha256 from step 4>"`, then commit and push.
7. **Verify**: ensure the local tap clone at `/opt/homebrew/Library/Taps/k-ymmt/homebrew-tap` is up to date (`git pull`), then run `brew fetch --cask k-ymmt/tap/gital`. Success looks like `✔︎ Cask gital ($version)` — this proves the release URL and sha256 match. Do not run `brew audit` (blocked by outdated CLT on this machine).

## Report

State the released version, the release URL (`https://github.com/k-ymmt/Gital/releases/tag/v$version`), the sha256, and that `brew fetch` verified the cask.
