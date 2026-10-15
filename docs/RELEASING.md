# Releasing

This is the release process for maintainers. Each step is run by hand. The app is packaged on a Mac.

Notes on signing:

- The app is **ad-hoc signed and not notarized**. The installer and the Homebrew cask clear the download quarantine. A zip downloaded by hand needs System Settings > Privacy & Security > Open Anyway.
- **Notarization is required before submitting to the official `homebrew/cask`.** This release process does not notarize. The tap in step 7 is the only Homebrew channel for now.

Replace `X.Y.Z` with the new version (for example `0.3.1`) everywhere below.

## 1. Bump the version

Edit `Resources/Info.plist` on a branch:

- `CFBundleShortVersionString`: the version, `X.Y.Z`.
- `CFBundleVersion`: the build number. Increase it by one on every release. 0.4.0 is build `7`.

```sh
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString X.Y.Z' Resources/Info.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion N' Resources/Info.plist
```

## 2. Update the changelog

In `CHANGELOG.md`, add a `## [X.Y.Z] - YYYY-MM-DD` section above the previous release. Copy the entries from the work since the last release, grouped under Added, Changed, Fixed and Removed as they apply.

## 3. Merge to main

Open a pull request with the version bump and the changelog, get it reviewed, and merge it to `main`. Make sure CI passes.

## 4. Package on a Mac

On a Mac with the Swift toolchain (`xcode-select --install`), from a clean checkout of `main`:

```sh
scripts/package.sh
```

This builds the app and writes two files:

- `dist/ClaudeAnchor-X.Y.Z.zip`
- `dist/ClaudeAnchor-X.Y.Z.zip.sha256`

The script prints the checksum file. Keep its SHA-256 value for step 7.

Check the package before publishing:

```sh
ditto -x -k dist/ClaudeAnchor-X.Y.Z.zip /tmp/anchor-check
```

Open the unzipped app and confirm it launches. Use a scratch directory, not your real `~/.claude-anchor`, if you are testing on a machine with live accounts. Then remove the check folder.

## 5. Tag the release

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

## 6. Create the GitHub release

On github.com/SumithSB/claude-anchor, create a release from the `vX.Y.Z` tag:

- Title: `Claude Anchor X.Y.Z`.
- Notes: the changelog section for this version.
- Attach both files: `dist/ClaudeAnchor-X.Y.Z.zip` and `dist/ClaudeAnchor-X.Y.Z.zip.sha256`.

The installer finds the release by the `.zip.sha256` asset name, so keep that name exactly. It downloads the zip, checks it against the `.sha256` file, and falls back to a source build if no release is found.

## 7. Update the Homebrew tap

In github.com/SumithSB/homebrew-tap, edit `Casks/claude-anchor.rb`:

- `version "X.Y.Z"`
- `sha256` set to the first field of `ClaudeAnchor-X.Y.Z.zip.sha256`.

Commit and push the change to the tap.

## 8. Verify

On a Mac that has the previous version installed:

```sh
brew update && brew upgrade --cask claude-anchor
brew info --cask claude-anchor
```

Check that `brew info` shows `X.Y.Z`, and that the app relaunches. Your settings and accounts in `~/.claude-anchor` should be unchanged.

To check the checksum on the file GitHub serves:

```sh
curl -fsSLO https://github.com/SumithSB/claude-anchor/releases/download/vX.Y.Z/ClaudeAnchor-X.Y.Z.zip
shasum -a 256 ClaudeAnchor-X.Y.Z.zip
```

The output must match the value in the cask.

## Troubleshooting

- **`brew upgrade` says the cask is already current.** Run `brew update` first, then check that the tap has the new `version` line.
- **Checksum mismatch in Homebrew.** The `sha256` in the cask does not match the zip. Rebuild or re-download the zip from the release, then update the cask.
- **The installer builds from source instead of downloading.** The release is missing the `.zip.sha256` asset, or the names don't match the version.

## Windows and Linux artifacts

These are built by CI, not by hand. Pushing the `vX.Y.Z` tag runs `.github/workflows/release-cross.yml` (or run it from the Actions tab with the existing tag as input). The tag sets the version in `cross/*/Cargo.toml` and `cross/tray/tauri.conf.json` for the build, so those files do not need a bump for the release to be named correctly.

It uploads to the release for the tag (creating it, not as a draft, if it does not exist yet; if you create the release by hand in step 6, do it before pushing the tag or just attach the macOS files to the one CI made):

- Windows: `Claude Anchor_X.Y.Z_x64-setup.exe` (NSIS, per-user), `Claude Anchor_X.Y.Z_x64_en-US.msi`, `anchor-X.Y.Z-windows-x86_64.zip` (the `anchor.exe` CLI).
- Linux: `Claude Anchor_X.Y.Z_amd64.AppImage`, `.deb`, `anchor-X.Y.Z-linux-x86_64.tar.gz` (the `anchor` CLI).
- A `.sha256` next to each of those, in the same `<hash>  <file>` format as the macOS one.

`install.sh` (Linux) and `install.ps1` find assets by suffix (`.AppImage`, `-setup.exe`, `linux-x86_64.tar.gz`, `windows-x86_64.zip`, each plus `.sha256`) and the macOS path only looks at `ClaudeAnchor-*.zip`, so keep those names. GitHub turns spaces in asset names into dots. Windows builds are unsigned, so SmartScreen warns on first run.

Verify on a clean machine or VM, with a throwaway home: run `install.sh` on Linux and `install.ps1` on Windows, then `anchor which` in a routed folder.
