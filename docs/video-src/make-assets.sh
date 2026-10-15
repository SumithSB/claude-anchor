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
h="$work/Sources/Anchor/Harbor.swift"   # tour hooks (see the Tour enum in TourShots.swift)
sed -i '' \
  -e 's/let t = reduceMotion ? 0 : tl.date/let t = reduceMotion || Tour.active ? 0 : tl.date/' \
  -e 's/\.stroke(Color\.black\.opacity(0\.22), style/.stroke(Color.black.opacity(Tour.hide ? 0 : 0.22), style/' \
  -e 's/\.stroke(Clay\.chain, style/.stroke(Tour.hide ? Color.clear : Clay.chain, style/' \
  -e 's/if !list\.isEmpty { anchorView/if !list.isEmpty \&\& !Tour.hide { anchorView/' \
  -e 's/let on = i == activeIdx \&\& !dragging$/let on = i == activeIdx \&\& !dragging \&\& !Tour.drag/' \
  -e 's/let hot = i == hotIdx$/let hot = i == hotIdx || i == Tour.hot/' "$h"
[ "$(grep -c 'Tour\.' "$h")" -ge 6 ] || { echo "Harbor.swift changed; update the tour patches in make-assets.sh" >&2; exit 1; }
(cd "$work" && swift build)
rm -rf "$here/assets"; "$work/.build/debug/Anchor" --tour-assets "$here/assets"
ls -l "$here/assets"
