// International Code of Signals flags a-z (ported from Sources/Anchor/Flags.swift), drawn as inline SVG on a 150x100 grid.
const W = "#fff", K = "#000", R = "#B3122E", B = "#1F3F8F", Y = "#F2C230";
const X = 150, H = 100;

function art(f) {
  let s = "";
  const box = (x0, y0, x1, y1, c) =>
    (s += `<rect x="${x0 * X}" y="${y0 * H}" width="${(x1 - x0) * X + 0.5}" height="${(y1 - y0) * H + 0.5}" fill="${c}"/>`);
  const poly = (pts, c) => (s += `<polygon points="${pts.map(([x, y]) => `${x * X},${y * H}`).join(" ")}" fill="${c}"/>`);
  const hs = (cols) => cols.forEach((c, i) => box(0, i / cols.length, 1, (i + 1) / cols.length, c));
  const vs = (cols) => cols.forEach((c, i) => box(i / cols.length, 0, (i + 1) / cols.length, 1, c));
  const quarters = (a, b, c, d) => { box(0, 0, 0.5, 0.5, a); box(0.5, 0, 1, 0.5, b); box(0, 0.5, 0.5, 1, c); box(0.5, 0.5, 1, 1, d); };
  const saltire = (c) => (s += `<path d="M0 0L${X} ${H}M${X} 0L0 ${H}" stroke="${c}" stroke-width="${H * 0.24}" fill="none"/>`);
  const cross = (c) => { box(0.43, 0, 0.57, 1, c); box(0, 0.4, 1, 0.6, c); };
  switch (f) {
    case "a": box(0, 0, 0.5, 1, W); box(0.5, 0, 1, 1, B); break;
    case "b": box(0, 0, 1, 1, R); break;
    case "c": hs([B, W, R, W, B]); break;
    case "d": hs([Y, B, Y]); break;
    case "e": hs([B, R]); break;
    case "f": box(0, 0, 1, 1, W); poly([[0.5, 0], [1, 0.5], [0.5, 1], [0, 0.5]], R); break;
    case "g": vs([Y, B, Y, B, Y, B]); break;
    case "h": vs([W, R]); break;
    case "i": box(0, 0, 1, 1, Y); s += `<circle cx="${X / 2}" cy="${H / 2}" r="${H * 0.26}" fill="${K}"/>`; break;
    case "j": hs([B, W, B]); break;
    case "k": vs([Y, B]); break;
    case "l": quarters(Y, K, K, Y); break;
    case "m": box(0, 0, 1, 1, B); saltire(W); break;
    case "n":
      box(0, 0, 1, 1, W);
      for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) if ((r + c) % 2 === 0) box(c / 4, r / 4, (c + 1) / 4, (r + 1) / 4, B);
      break;
    case "o": box(0, 0, 1, 1, R); poly([[0, 0], [0, 1], [1, 1]], Y); break;
    case "p": box(0, 0, 1, 1, B); box(0.25, 0.25, 0.75, 0.75, W); break;
    case "q": box(0, 0, 1, 1, Y); break;
    case "r": box(0, 0, 1, 1, R); cross(Y); break;
    case "s": box(0, 0, 1, 1, W); box(0.25, 0.25, 0.75, 0.75, B); break;
    case "t": vs([R, W, B]); break;
    case "u": quarters(R, W, W, R); break;
    case "v": box(0, 0, 1, 1, W); saltire(R); break;
    case "w": box(0, 0, 1, 1, B); box(0.14, 0.14, 0.86, 0.86, W); box(0.3, 0.3, 0.7, 0.7, R); break;
    case "x": box(0, 0, 1, 1, W); cross(B); break;
    case "y":
      box(0, 0, 1, 1, Y);
      for (let k = 1; k < 8; k += 2) { const a = k * 0.25, b = a + 0.25; poly([[a, 0], [b, 0], [b - 1, 1], [a - 1, 1]], R); }
      break;
    case "z":
      poly([[0, 0], [1, 0], [0.5, 0.5]], Y); poly([[1, 0], [1, 1], [0.5, 0.5]], B);
      poly([[1, 1], [0, 1], [0.5, 0.5]], K); poly([[0, 1], [0, 0], [0.5, 0.5]], R);
      break;
    default: box(0, 0, 1, 1, W);
  }
  return s;
}

export const FLAGS = "abcdefghijklmnopqrstuvwxyz".split("");
const swallow = "0,0 150,0 108,50 150,100 0,100";

/** SVG markup for a flag letter; `size` is the height in px, width is 1.5x. */
export function flagSVG(letter, size = 14) {
  const f = String(letter || "a").toLowerCase();
  const tail = f === "a" || f === "b";
  const outline = tail ? `<polygon points="${swallow}"` : `<rect width="150" height="100"`;
  return `<svg class="flag" role="img" aria-label="Flag ${f.toUpperCase()}" width="${size * 1.5}" height="${size}" viewBox="0 0 150 100">` +
    (tail ? `<clipPath id="fc-${f}"><polygon points="${swallow}"/></clipPath><g clip-path="url(#fc-${f})">${art(f)}</g>` : art(f)) +
    `${outline} fill="none" stroke="rgba(0,0,0,.3)" stroke-width="3"/></svg>`;
}

/** The anchor mark (AnchorGlyph in the Swift app): eye, shank, stock, curved arms, flukes. */
export function anchorSVG(w, h, stroke = "currentColor", sw = 1.8, cls = "") {
  return `<svg class="${cls}" width="${w}" height="${h}" viewBox="-3 -3 28 36" fill="none" stroke="${stroke}" stroke-width="${(sw * 22) / w}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">` +
    `<circle cx="11" cy="3.08" r="3.08"/><path d="M11 6.16V26M4.4 9.36H17.6M0 16.12Q11 36.92 22 16.12M0 16.12L3.52 14.56M22 16.12L18.48 14.56"/></svg>`;
}
