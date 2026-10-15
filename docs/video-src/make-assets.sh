#!/bin/sh
# Renders the real SwiftUI views (demo data only) into docs/video-src/assets/.
# Builds a scratch copy of the app so the repo's sources stay untouched:
#  - adds TourShots.swift and a `--tour-assets <dir>` entry point
set -e
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
work=${TMPDIR:-/tmp}/anchor-tour-build; rm -rf "$work"; mkdir -p "$work"
cp -R "$repo/Package.swift" "$repo/Sources" "$work/"
cp "$here/TourShots.swift" "$work/Sources/Anchor/"
sed -i '' 's/        let a = CommandLine.arguments/&\
        if let i = a.firstIndex(of: "--tour-assets"), a.indices.contains(i + 1) { MainActor.assumeIsolated { TourShots.run(dir: a[i + 1]) }; exit(0) }/' "$work/Sources/Anchor/AnchorApp.swift"
(cd "$work" && swift build)
rm -rf "$here/assets"; "$work/.build/debug/Anchor" --tour-assets "$here/assets"
ls -l "$here/assets"
