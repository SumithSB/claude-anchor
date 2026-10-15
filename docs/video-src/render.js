// Renders index.html deterministically: calls seek(t) for every frame and screenshots it.
// Usage: node render.js [outDir] [fps] [duration] [onlyTimesCSV]
// Needs the `playwright` npm library (no browser download; uses PLAYWRIGHT_BROWSERS_PATH or CHROMIUM_PATH).
const path = require('path');
const fs = require('fs');
let pw;
try { pw = require('playwright'); } catch (e) { pw = require('/opt/node-tools/node_modules/playwright'); }

const out = path.resolve(process.argv[2] || 'frames');
const fps = Number(process.argv[3] || 30);
const dur = Number(process.argv[4] || 26);
const only = process.argv[5] ? process.argv[5].split(',').map(Number) : null;
fs.mkdirSync(out, { recursive: true });

(async () => {
  const browser = await pw.chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined, args: ['--force-device-scale-factor=1', '--font-render-hinting=none'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });
  page.on('pageerror', e => console.error('PAGEERROR', e.message)); page.on('console', m => { if (m.type()==='error') console.error('CONSOLE', m.text()); });
  await page.goto('file://' + path.resolve(__dirname, 'index.html'));
  await page.waitForFunction('window.READY === true');
  const cues = await page.evaluate(() => window.CUES ? window.CUES() : null);   // sound cue times for audio.py
  if (cues) fs.writeFileSync(path.join(out, 'cues.json'), JSON.stringify(cues, null, 1));
  const times = only || Array.from({ length: Math.round(dur * fps) }, (_, i) => i / fps);
  for (let i = 0; i < times.length; i++) {
    const t = times[i];
    await page.evaluate(t => window.seek(t), t);
    const name = only ? `t${t}.png` : `f${String(i).padStart(4, '0')}.png`;
    await page.screenshot({ path: path.join(out, name), type: 'png' });
  }
  await browser.close();
})();
