// Harbor switcher: berths per account, a chain and an anchor that sails to the default berth.
// Port of Sources/Anchor/Harbor.swift. Pointer events for the drag, rAF tweens for the sail (no images).
import { flagSVG, anchorSVG } from "./flags.js";

const HEIGHT = 230, DY = 132, BERTH_TOP = 144, WATER_Y = 66;
const reduce = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const easeOut = (t) => 1 - (1 - t) ** 3;
const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
const spring = (t) => 1 - Math.exp(-7 * t) * Math.cos(12 * t);

export function layoutFor(n, W) {
  const fullMax = Math.max(1, Math.floor(W / 86)), compactMax = Math.floor(W / 54);
  let L;
  if (n <= fullMax) {
    const ghost = n <= fullMax - 2, slots = n + (ghost ? 1 : 0), pitch = W / Math.max(slots, 1);
    L = { mode: "full", sp: pitch, w: Math.min(100, pitch - 12), ghost, pad: 0, contentW: W };
  } else if (n <= compactMax) {
    const pitch = W / n;
    L = { mode: "compact", sp: pitch, w: pitch - 6, ghost: false, pad: 0, contentW: W };
  } else L = { mode: "scroll", sp: 82, w: 72, ghost: true, pad: 12, contentW: 24 + 82 * (n + 1) };
  return { ...L, n, W, maxPan: Math.max(0, L.contentW - W), x: (i) => L.pad + L.sp * (i + 0.5) };
}

/** Utilization colour and the countdown text are supplied by the host through `helpers`. */
export function createHarbor({ W = 308, getState, helpers, onPick, onAdd }) {
  const el = document.createElement("div");
  el.className = "harbor";
  el.tabIndex = 0;
  el.setAttribute("role", "group");
  el.setAttribute("aria-label", "Default account");

  const wave = (base, amp, bottom) => {
    let x = 0, k = 0, d = `M0 ${base}`;
    while (x < W + 174) { d += `Q${x + 21.75} ${base + (k % 2 ? amp : -amp)} ${x + 43.5} ${base}`; x += 43.5; k++; }
    return bottom ? `${d}L${x} ${bottom}L0 ${bottom}Z` : d;
  };
  el.innerHTML =
    `<svg class="sea" width="${W}" height="${HEIGHT}" aria-hidden="true">` +
    `<g class="waves1"><path d="${wave(WATER_Y, 7, HEIGHT)}" fill="var(--sea)"/></g>` +
    `<g class="waves2"><path d="${wave(WATER_Y + 8, 5)}" fill="none" stroke="var(--foam)" stroke-width="1.2"/></g>` +
    `<path d="M0 190Q${W / 4} 178 ${W / 2} 186Q${W * 0.75} 194 ${W} 182L${W} ${HEIGHT}L0 ${HEIGHT}Z" fill="var(--seabed)"/></svg>` +
    `<div class="quay"></div>` +
    `<div class="fadeL"></div><div class="fadeR"></div>` +
    `<svg class="chain" width="${W}" height="${HEIGHT}" aria-hidden="true"><path class="c1" fill="none" stroke="rgba(0,0,0,.22)" stroke-width="5" stroke-linecap="round"/><path class="c2" fill="none" stroke="var(--chain)" stroke-width="3" stroke-linecap="round" stroke-dasharray="5 3"/></svg>` +
    `<div class="hull"></div>` +
    `<button class="qarrow ql" aria-label="Show earlier accounts" style="left:6px"></button>` +
    `<button class="qarrow qr" aria-label="Show more accounts" style="left:${W - 32}px"></button>` +
    `<div class="dotsrow" aria-hidden="true"></div>` +
    `<div class="anchor" aria-hidden="true">${anchorSVG(22, 26, "currentColor", 2.4)}</div>`;
  const $ = (s) => el.querySelector(s);
  const quay = $(".quay"), anchor = $(".anchor"), c1 = $(".c1"), c2 = $(".c2"), fadeL = $(".fadeL"), fadeR = $(".fadeR");
  const ql = $(".ql"), qr = $(".qr"), dotsRow = $(".dotsrow");
  ql.innerHTML = qr.innerHTML = "";
  ql.insertAdjacentHTML("beforeend", `<svg class="ic" viewBox="0 0 24 24"><path d="m15 18-6-6 6-6"/></svg>`);
  qr.insertAdjacentHTML("beforeend", `<svg class="ic" viewBox="0 0 24 24"><path d="m9 18 6-6-6-6"/></svg>`);

  let pos = null, dragging = false, grab = { x: 0, y: 0 }, dragVX = 0, hotIdx = null, panOverride = null;
  let motionId = 0, panId = 0, edgeDir = 0, edgeTimer = null, selfCommit = null, lastDefault = null, lastKey = "";

  const berths = () => getState().config.accounts.filter((a) => !a.pending);
  const activeIdx = () => Math.max(0, berths().findIndex((a) => a.id === getState().config.defaultID));
  const lay = () => layoutFor(berths().length, W);
  const clampPan = (p, L) => Math.max(0, Math.min(L.maxPan, p));
  const curPan = (L) => (L.mode === "scroll" ? clampPan(panOverride ?? L.x(activeIdx()) - L.W / 2, L) : 0);
  const rest = (L) => ({ x: L.x(activeIdx()), y: DY });

  function draw() {
    const L = lay(), pan = curPan(L), pt = pos || rest(L), vx = pt.x - pan;
    quay.style.transform = `translateX(${-pan}px)`;
    const tipx = vx, tipy = pt.y - 16, hx = W / 2;
    const sag = Math.max(8, 46 - Math.abs(tipx - hx) * 0.12 - (dragging ? 20 : 0));
    const d = `M${hx} 10Q${(hx + tipx) / 2} ${(10 + tipy) / 2 + sag} ${tipx} ${tipy}`;
    c1.setAttribute("d", d); c2.setAttribute("d", d);
    const tilt = Math.atan2(vx - hx, Math.max(20, pt.y - 10)) * -40 / Math.PI;
    anchor.style.transform = `translate(${vx - 20}px,${pt.y - 20}px) rotate(${tilt}deg) scale(${dragging ? 1.12 : 1})`;
    anchor.classList.toggle("dragging", dragging);
    anchor.classList.toggle("locked", L.n < 2);
    anchor.hidden = L.n === 0;
    const sc = L.mode === "scroll";
    const canL = sc && pan > 2, canR = sc && pan < L.maxPan - 2;
    fadeL.style.opacity = canL ? 1 : 0; fadeR.style.opacity = canR ? 1 : 0;
    ql.hidden = !canL; qr.hidden = !canR;
    if (sc) {
      const pages = Math.max(1, Math.ceil(L.contentW / L.W)), cur = Math.round((pan / Math.max(1, L.maxPan)) * (pages - 1));
      dotsRow.innerHTML = Array.from({ length: pages }, (_, p) => `<i class="${p === cur ? "on" : ""}"></i>`).join("");
    } else dotsRow.innerHTML = "";
    quay.querySelectorAll(".berth[data-i]").forEach((b) => {
      const i = +b.dataset.i, on = i === activeIdx() && !dragging, hot = i === hotIdx;
      b.classList.toggle("lit", on || hot); b.classList.toggle("hot", hot);
    });
  }

  function buildBerths() {
    const L = lay(), list = berths(), roomy = L.mode === "full", S = getState();
    const key = JSON.stringify([L.mode, L.n, list.map((a) => [a.id, a.name, a.flag, S.limits[a.id]?.fiveHour?.percent, S.limits[a.id]?.fiveHour?.resetsAt, helpers.isFresh(a.id), helpers.countdown(a.id)]), S.config.defaultID, dragging]);
    if (key === lastKey) return;
    lastKey = key;
    let html = "";
    list.forEach((a, i) => {
      const pct = S.limits[a.id]?.fiveHour?.percent, fresh = helpers.isFresh(a.id), on = i === activeIdx() && !dragging;
      const cd = fresh ? null : helpers.countdown(a.id);
      let st, color;
      if (fresh) { st = roomy ? (on ? "Anchored · full 5h" : "Full 5h window") : "Full"; color = "var(--fresh)"; }
      else if (pct == null) { st = "—"; color = "var(--text2)"; }
      else {
        const n = Math.round(pct);
        if (on) { st = roomy ? `Anchored · ${n}%` : `${n}%`; color = "var(--accent-text)"; }
        else { st = (roomy ? "5h " : "") + `${n}%`; color = helpers.color(pct); }
      }
      const sub = cd ? (roomy ? `resets in ${cd}` : `↻ ${cd}`) : fresh ? (roomy ? "ready now" : "") : "\u00a0";
      let label = `Anchor at ${a.name}, `;
      label += fresh ? "fresh 5-hour window" : pct != null ? `5-hour limit ${Math.round(pct)} percent used${cd ? `, resets in ${cd}` : ""}` : "5-hour limit unknown";
      const nm = roomy ? a.name : a.name.split(" ")[0];
      html += `<button class="berth ${roomy ? "" : "compact"}" data-i="${i}" title="${esc(a.name)}" aria-label="${esc(label)}" aria-current="${i === activeIdx()}" style="left:${L.x(i) - L.w / 2}px;width:${L.w}px">` +
        `${flagSVG(a.flag, roomy ? 13 : 11)}<span class="nm trunc">${esc(nm)}</span><span class="st" style="color:${color}${st.length > 15 ? ";font-size:9px" : ""}">${esc(st)}</span><span class="sub" style="color:${fresh ? "var(--fresh)" : "var(--text2)"}">${esc(sub || "\u00a0")}</span>` +
        (fresh ? `<span class="badge" aria-hidden="true">${roomy ? "FRESH" : ""}</span>` : "") + `</button>`;
    });
    if (L.ghost) {
      html += `<button class="berth ghost" data-add title="Add account" aria-label="Add account" style="left:${L.x(L.n) - L.w / 2}px;width:${L.w}px"><svg class="ic" viewBox="0 0 24 24"><path d="M5 12h14M12 5v14"/></svg>Add</button>`;
    }
    quay.innerHTML = html;
  }

  // ---- motion
  function tween(from, to, dur, ease, my) {
    return new Promise((res) => {
      if (reduce()) { pos = { ...to }; draw(); return res(); }
      const t0 = performance.now();
      const f = () => {
        if (my !== motionId) return res();
        const k = Math.max(0, Math.min(1, (performance.now() - t0) / dur)), e = ease(k);
        pos = { x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e };
        draw();
        if (k < 1) requestAnimationFrame(f); else { pos = { ...to }; draw(); res(); }
      };
      requestAnimationFrame(f);
    });
  }
  function panTo(target, L) {
    if (L.mode !== "scroll") return;
    const to = clampPan(target, L), from = curPan(L), my = ++panId;
    if (reduce()) { panOverride = to; draw(); return; }
    const t0 = performance.now();
    const f = () => {
      if (my !== panId) return;
      const k = Math.max(0, Math.min(1, (performance.now() - t0) / 380));
      panOverride = from + (to - from) * easeInOut(k); draw();
      if (k < 1) requestAnimationFrame(f);
    };
    requestAnimationFrame(f);
  }
  function splash(x) {
    if (reduce()) return;
    const pan = curPan(lay());
    for (const [r, delay] of [[48, 0], [34, 250]]) {
      const d = document.createElement("div");
      d.className = "ripple";
      d.style.cssText = `left:${x - pan - r}px;top:${WATER_Y - r * 0.26}px;width:${r * 2}px;height:${r * 0.52}px;animation-delay:${delay}ms;opacity:0`;
      el.insertBefore(d, quay.nextSibling);
      setTimeout(() => d.remove(), 1300);
    }
  }
  function commit(i) {
    const a = berths()[i];
    if (!a || a.id === getState().config.defaultID) return;
    selfCommit = a.id;
    onPick(a.id);
  }
  async function sail(start, i, commitIt) {
    const L = lay();
    if (!berths()[i]) return;
    const my = ++motionId, bx = L.x(i);
    panTo(bx - L.W / 2, L);
    if (reduce()) { pos = { x: bx, y: DY }; if (commitIt) commit(i); pos = null; draw(); return; }
    const lift = DY - 90;
    pos = start;
    await tween(start, { x: start.x, y: lift }, 200, easeOut, my); if (my !== motionId) return;
    await tween({ x: start.x, y: lift }, { x: bx, y: lift }, 300, easeInOut, my); if (my !== motionId) return;
    splash(bx);
    if (commitIt) commit(i);
    await tween({ x: bx, y: lift }, { x: bx, y: DY }, 450, spring, my); if (my !== motionId) return;
    await sleep(500); if (my !== motionId) return;
    pos = null; draw();
  }
  async function glideHome() {
    const my = ++motionId;
    await tween(pos || rest(lay()), rest(lay()), 350, easeOut, my);
    if (my === motionId) { pos = null; draw(); }
  }
  async function dock(i) {
    const L = lay(), bx = L.x(i), my = ++motionId;
    if (L.mode === "scroll") { const v = bx - curPan(L); if (v < 60 || v > L.W - 60) panTo(bx - L.W / 2, L); }
    splash(bx); commit(i);
    await tween(pos, { x: bx, y: DY }, 350, spring, my); if (my !== motionId) return;
    await sleep(600); if (my !== motionId) return;
    pos = null; draw();
  }
  const step = (d) => { const j = activeIdx() + d; if (berths()[j] && !dragging) sail(pos || rest(lay()), j, true); };
  const pick = (i) => { if (i !== activeIdx() && !dragging) sail(pos || rest(lay()), i, true); };

  // ---- drag
  const hotAt = (p, L) => {
    if (p.y < 76) return null;
    let hot = null, best = L.sp * 0.55 + 6;
    for (let i = 0; i < L.n; i++) { const d = Math.abs(p.x - L.x(i)); if (d < best) { best = d; hot = i; } }
    return hot;
  };
  const setHot = (h) => { if (h !== hotIdx) { hotIdx = h; draw(); } };
  const setEdge = (dir) => {
    if (dir === edgeDir) return;
    edgeDir = dir; clearInterval(edgeTimer);
    if (!dir) return;
    edgeTimer = setInterval(() => {
      if (!dragging || !edgeDir) return clearInterval(edgeTimer);
      const L = lay(); panId++;
      panOverride = clampPan(curPan(L) + edgeDir * 5, L);
      pos = { x: dragVX + panOverride, y: pos.y };
      hotIdx = hotAt(pos, L); draw();
    }, 16);
  };
  anchor.addEventListener("pointerdown", (e) => {
    const L = lay();
    if (L.n < 2 || e.button > 0) return;
    e.preventDefault();
    anchor.setPointerCapture(e.pointerId);
    motionId++; panId++;
    const r = el.getBoundingClientRect(), pan = curPan(L), cur = pos || rest(L);
    grab = { x: cur.x - pan - (e.clientX - r.left), y: cur.y - (e.clientY - r.top) };
    if (L.mode === "scroll") panOverride = pan;
    pos = cur; dragging = true; lastKey = ""; buildBerths(); draw();
  });
  anchor.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const L = lay(), r = el.getBoundingClientRect(), pan = curPan(L);
    dragVX = Math.min(W - 18, Math.max(18, e.clientX - r.left + grab.x));
    const y = Math.min(DY + 34, Math.max(34, e.clientY - r.top + grab.y));
    pos = { x: dragVX + pan, y };
    hotIdx = hotAt(pos, L); draw();
    if (L.mode === "scroll") setEdge(dragVX < 44 ? -1 : dragVX > W - 44 ? 1 : 0);
  });
  const end = () => {
    if (!dragging) return;
    setEdge(0); dragging = false;
    const hot = hotIdx; hotIdx = null; lastKey = ""; buildBerths(); draw();
    if (hot != null) dock(hot); else glideHome();
  };
  anchor.addEventListener("pointerup", end);
  anchor.addEventListener("pointercancel", end);

  quay.addEventListener("click", (e) => {
    const b = e.target.closest(".berth");
    if (!b) return;
    if (b.dataset.add !== undefined) onAdd && onAdd(); else pick(+b.dataset.i);
  });
  ql.addEventListener("click", () => { const L = lay(); panTo(curPan(L) - 82 * Math.max(2, Math.floor(L.W / 82) - 1), L); });
  qr.addEventListener("click", () => { const L = lay(); panTo(curPan(L) + 82 * Math.max(2, Math.floor(L.W / 82) - 1), L); });
  el.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft") { step(-1); e.preventDefault(); }
    else if (e.key === "ArrowRight") { step(1); e.preventDefault(); }
  });
  el.addEventListener("wheel", (e) => {
    const L = lay();
    if (L.mode !== "scroll" || dragging) return;
    e.preventDefault(); panId++;
    panOverride = clampPan(curPan(L) + (Math.abs(e.deltaX) >= Math.abs(e.deltaY) ? e.deltaX : e.deltaY), L); draw();
  }, { passive: false });

  /** Call after every state change. */
  function update() {
    const S = getState(), L = lay(), list = berths();
    const now = S.config.defaultID, was = lastDefault;
    lastDefault = now;
    el.setAttribute("aria-valuetext", list.length ? `${list[activeIdx()]?.name}, ${activeIdx() + 1} of ${list.length}` : "None");
    if (L.mode === "scroll" && panOverride == null) panOverride = curPan(L);
    buildBerths();
    if (was != null && was !== now) {
      if (selfCommit === now) selfCommit = null;
      else if (!dragging && !pos) {
        const from = list.findIndex((a) => a.id === was), to = list.findIndex((a) => a.id === now);
        if (from >= 0 && to >= 0) { sail({ x: L.x(from), y: DY }, to, false); return; }
      }
    }
    draw();
  }
  return { el, update };
}
