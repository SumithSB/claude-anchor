# v0.3 tour video

`index.html` composes the tour from real SwiftUI renders of the app (demo data only: Work / Client /
Personal, `you@work.example`) in `assets/`. Captions, the cursor, the fake desktop and the dragged
anchor + chain are HTML/SVG; the rest of the app UI is PNGs rendered by the app itself. For the
drag scene the harbor is rendered without its anchor and chain, and `index.html` redraws them from
`Harbor.swift`'s geometry (chain curve and sag, dash, tilt, 1.12x lift, spring settle, splash rings).
A global `seek(t)` drives everything; `render.js` screenshots it frame by frame with Playwright and
writes the sound cue times to `cues.json`, which `audio.py` turns into the soundtrack.

Output: `../tour.mp4` (1280x720, 30 fps, H.264 + AAC 160k stereo, 26.2 s, -16 LUFS),
`../tour.gif` (800 px, 12 fps, silent), `../tour.jpg` (poster, t = 21.8 s).

Scenes: 0 glance (menu opens, scrolls) · 3.6 dark mode · 5.0 fresh window · 7.4 drag the anchor to Personal ·
11.4 refresh · 13.4 Accounts / Folder rules / Settings · 16.2 pop-out · 18.8 floating button + glance card · 24.0 end card.

## 1. Re-render the UI assets (only when the UI changes)

```sh
docs/video-src/make-assets.sh        # needs Xcode / swift; writes docs/video-src/assets/*.png at 2x
```

It builds a scratch copy of the app (in `$TMPDIR`), so the repo sources are untouched. In that copy it:
- adds `TourShots.swift` and a `--tour-assets <dir>` entry point;
- patches `Harbor.swift` with the `Tour` hooks (frozen waves so all renders match; anchor and chain
  hidden; "mid-drag" berth states). It fails loudly if those lines change upstream;
- makes `refreshIfStale()` return early for snapshot models (`live == false`). Without that, the
  popover's `onAppear` starts a real rescan and limits fetch that replaces the demo data with this
  machine's usage. Once the repo has that guard the patch is skipped.

## 2. Render frames, synthesise audio, encode

```sh
cd docs/video-src
npm i --no-save playwright           # library only; no browser download
export CHROMIUM_PATH=".../Google Chrome for Testing"   # or PLAYWRIGHT_BROWSERS_PATH
node render.js /tmp/tour-frames 30 26.2            # 786 PNGs (1280x720) + cues.json
node render.js /tmp/tour-check 30 1 8.6,9.3,10.05,21.8   # optional: check frames (t<sec>.png)

python3 audio.py /tmp/tour-frames/cues.json /tmp/tour-audio.wav   # stdlib only; calls ffmpeg for loudnorm

ffmpeg -y -framerate 30 -i /tmp/tour-frames/f%04d.png -i /tmp/tour-audio.wav -map 0:v -map 1:a \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -shortest -movflags +faststart ../tour.mp4
ffmpeg -y -i ../tour.mp4 -vf "fps=12,scale=800:-1:flags=lanczos,palettegen=max_colors=96:stats_mode=diff" /tmp/pal.png
ffmpeg -y -i ../tour.mp4 -i /tmp/pal.png \
  -lavfi "fps=12,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -an ../tour.gif
ffmpeg -y -i /tmp/tour-frames/f0654.png -q:v 3 ../tour.jpg

ffmpeg -hide_banner -nostats -i ../tour.mp4 -af ebur128=peak=true -f null - 2>&1 | tail -12   # expect I ≈ -16 LUFS
```

Sound (`audio.py`, all synthesised): a soft D-major pad that lifts to a G chord on the end card, UI
clicks, a chain-link rattle over an airy whoosh while the anchor is dragged, a wooden thud with a faint
metal ring when it lands, two-note chimes for fresh windows, quiet whooshes when panels open, faint
ticks while refresh spins, and a closing three-note chime. Normalised with two-pass linear loudnorm
(-16 LUFS, -1.5 dBTP).
