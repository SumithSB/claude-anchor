# v0.3 tour video (design mock)

`index.html` is a self-contained HTML/CSS/JS re-creation of the v0.3 UI (popover, harbor switcher,
fresh-window card, refresh, pop-out window, floating button) driven by a global `seek(t)`; it is a
design preview, not a recording of the real app. `render.js` screenshots it frame by frame with Playwright.

```sh
npm i --no-save playwright            # library only; set PLAYWRIGHT_BROWSERS_PATH to an existing Chromium
node render.js frames 30 26           # 780 PNGs, 1280x720, 30 fps, 26 s
ffmpeg -framerate 30 -i frames/f%04d.png -c:v libx264 -crf 22 -pix_fmt yuv420p -movflags +faststart ../brag-v0.3.mp4
ffmpeg -i ../brag-v0.3.mp4 -vf "fps=12,scale=800:-1:flags=lanczos,palettegen=max_colors=128:stats_mode=diff" pal.png
ffmpeg -i ../brag-v0.3.mp4 -i pal.png -lavfi "fps=12,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" ../brag-v0.3.gif
```
