#!/usr/bin/env bash
# Build the app and zip it into dist/ClaudeAnchor-<version>.zip with a .sha256 next to it.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="ClaudeAnchor-${VERSION}.zip"
mkdir -p dist
rm -f "dist/$ZIP" "dist/$ZIP.sha256"
ditto -c -k --keepParent "build.noindex/Claude Anchor.app" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
echo "packaged dist/$ZIP"
cat "dist/$ZIP.sha256"
