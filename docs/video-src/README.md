# v0.3 tour video

`index.html` composes the tour from real SwiftUI renders of the app (demo data only: Work / Client /
Personal, `you@work.example`) in `assets/`. Motion, captions, the cursor and the fake desktop are HTML/CSS;
every piece of app UI is a PNG rendered by the app itself. A global `seek(t)` drives it, and `render.js`
screenshots it frame by frame with Playwright.

Output: `../tour.mp4` (1280x720, 30 fps, H.264, 25.6 s, silent), `../tour.gif` (800 px, 12 fps), `../tour.jpg` (poster, t = 21 s).

Scenes: 0 glance (menu opens, scrolls) · 3.8 dark mode · 5.4 fresh window · 7.8 switch to Personal ·
10.6 refresh · 12.6 Accounts / Folder rules / Settings · 15.4 pop-out · 18.0 floating button + glance card · 23.2 end card.

## 1. Re-render the UI assets (only when the UI changes)

```sh
docs/video-src/make-assets.sh        # needs Xcode / swift; writes docs/video-src/assets/*.png at 2x
```

It builds a scratch copy of the app (in `$TMPDIR`) with `TourShots.swift` added and a `--tour-assets`
entry point, so the repo sources are untouched. Snapshot models (`live == false`) never read real
usage or call the API, so the renders contain demo data only.

## 2. Render frames and encode

```sh
cd docs/video-src
npm i --no-save playwright           # library only; no browser download
export CHROMIUM_PATH=".../Google Chrome for Testing"   # or PLAYWRIGHT_BROWSERS_PATH
node render.js /tmp/tour-frames 30 25.6            # 768 PNGs, 1280x720
node render.js /tmp/tour-check 30 1 2.2,6.6,9.6,14.4,21   # optional: a few check frames (t<sec>.png)

ffmpeg -y -framerate 30 -i /tmp/tour-frames/f%04d.png -c:v libx264 -preset slow -crf 20 \
  -pix_fmt yuv420p -movflags +faststart -an ../tour.mp4
ffmpeg -y -i ../tour.mp4 -vf "fps=12,scale=800:-1:flags=lanczos,palettegen=max_colors=96:stats_mode=diff" /tmp/pal.png
ffmpeg -y -i ../tour.mp4 -i /tmp/pal.png \
  -lavfi "fps=12,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" ../tour.gif
ffmpeg -y -i /tmp/tour-frames/f0630.png -q:v 3 ../tour.jpg
```
