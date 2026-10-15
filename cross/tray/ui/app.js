// Claude Anchor tray UI. Port of Sources/Anchor/Views.swift + Flags.swift (AccountsPane). Vanilla JS, no framework.
import { flagSVG, anchorSVG, FLAGS } from "./flags.js";
import { createHarbor } from "./harbor.js";

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const REPO = "https://github.com/SumithSB/claude-anchor";
const CLI_DOCS = "https://docs.anthropic.com/en/docs/claude-code/setup";

let state = null;
let view = "home"; // home | accounts | rules | settings
const ui = { showAll: false, picked: null, doneId: null, rename: null, adding: false, newName: "", newFlag: "a", localPin: false, pinned: null };
let pendingRender = false;

const $ = (s, r = document) => r.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const nowS = () => Date.now() / 1000;

// ---------- icons
const P = {
  pin: '<path d="M12 17v5M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>',
  back: '<path d="m15 18-6-6 6-6"/>',
  users: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
  folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  gear: '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
  power: '<path d="M12 2v10M18.4 6.6a9 9 0 1 1-12.77.04"/>',
  plus: '<path d="M5 12h14M12 5v14"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  check: '<circle cx="12" cy="12" r="10" fill="currentColor" stroke="none"/><path d="m8 12 3 3 5-6" stroke="var(--paper)" stroke-width="2.4"/>',
  warn: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4M12 17h.01"/>',
  arrow: '<path d="M5 12h14m-7-7 7 7-7 7"/>',
  dots: '<circle cx="12" cy="12" r="10"/><circle cx="8" cy="12" r=".8" fill="currentColor"/><circle cx="12" cy="12" r=".8" fill="currentColor"/><circle cx="16" cy="12" r=".8" fill="currentColor"/>',
};
const ic = (n, size) => `<svg class="ic" viewBox="0 0 24 24"${size ? ` style="width:${size}px;height:${size}px"` : ""} aria-hidden="true">${P[n]}</svg>`;
const flag = (l, s) => flagSVG(l, s);

// ---------- model helpers
const accounts = () => state.config.accounts;
const account = (id) => accounts().find((a) => a.id === id);
const active = () => account(state.config.defaultID) || accounts()[0];
const isPrimary = (a) => a.id === "primary";
const isFresh = (id) => {
  const l = state.limits[id];
  if (!l || l.error || l.stale) return false;
  return l.fiveHour ? l.fiveHour.percent < 1 : !!l.weekly;
};
const freshAccounts = () => accounts().filter((a) => !a.pending && a.id !== state.config.defaultID && isFresh(a.id));
const activeIsFresh = () => !!active() && isFresh(active().id);
const peak = (l) => Math.max(l?.fiveHour?.percent ?? 0, l?.weekly?.percent ?? 0);
const levelColor = (p) => (p >= 90 ? "var(--limit)" : p >= 75 ? "var(--amber)" : "var(--fresh)");
const level = (p) => (p >= 90 ? "crit" : p >= 75 ? "warn" : "ok");
const trashWord = () => (state.platform === "windows" ? "Recycle Bin" : "Trash");
const abbreviate = (p) => {
  const h = state.home || "";
  if (!h) return p;
  const win = state.platform === "windows";
  return (win ? p.toLowerCase().startsWith(h.toLowerCase()) : p.startsWith(h)) ? "~" + p.slice(h.length) : p;
};
const compact = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1000 ? Math.round(n / 1000) + "k" : String(n));
const usd = (c) => "$" + c.toFixed(2);
const resetAt = (w) => (w?.resetsAt ? Date.parse(w.resetsAt) : NaN);

function resetText(w) {
  const t = resetAt(w);
  if (isNaN(t)) return "";
  const s = (t - Date.now()) / 1000;
  if (s <= 0) return "Resets now";
  if (s < 86400) { const m = Math.floor(s / 60); return m >= 60 ? `Resets in ${Math.floor(m / 60)}h ${m % 60}m` : `Resets in ${m}m`; }
  return "Resets " + new Date(t).toLocaleDateString(undefined, { weekday: "short" });
}
function countdown(id) {
  const w = state.limits[id]?.fiveHour, t = resetAt(w);
  if (!w || w.percent < 75 || isNaN(t)) return null;
  const secs = (t - Date.now()) / 1000;
  if (secs <= 0) return null;
  const mins = Math.ceil(secs / 60), h = Math.floor(mins / 60), m = mins % 60;
  return h === 0 ? `${m}m` : m === 0 ? `${h}h` : `${h}h ${m}m`;
}
function lastRefreshedText() {
  if (state.isRefreshing) return "Updating…";
  if (state.lastRefreshed == null) return "Not updated yet";
  const s = Math.max(0, Math.floor(nowS() - state.lastRefreshed));
  if (s < 60) return "Updated just now";
  if (s < 3600) return `Updated ${Math.floor(s / 60)} min ago`;
  return `Updated ${Math.floor(s / 3600)} h ago`;
}
const isOutdated = () => (state.lastRefreshed == null ? false : nowS() - state.lastRefreshed > Math.max(600, 3 * state.config.refreshSeconds));
const continueTargets = () => {
  const from = state.lastSession?.accountID || state.config.defaultID;
  return accounts().filter((a) => !a.pending && a.id !== from).sort((a, b) => {
    const la = state.limits[a.id], lb = state.limits[b.id];
    const ea = !!la?.error, eb = !!lb?.error;
    if (ea !== eb) return ea ? 1 : -1;
    const fa = isFresh(a.id), fb = isFresh(b.id);
    if (fa !== fb) return fa ? -1 : 1;
    return peak(la) - peak(lb);
  });
};

// ---------- backend
async function call(name, args) {
  try {
    const r = await invoke(name, args || {});
    if (r && typeof r === "object" && r.config) setState(r);
    return r;
  } catch (e) {
    toast(String(e?.message || e));
    return undefined;
  }
}
let toastTimer;
function toast(msg) {
  document.querySelectorAll(".toast").forEach((t) => t.remove());
  const t = document.createElement("div");
  t.className = "toast"; t.setAttribute("role", "alert"); t.textContent = msg;
  document.body.append(t);
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.remove(), 5000);
}

// ---------- building blocks
const caption = (t) => `<div class="caption" role="heading" aria-level="2">${esc(t)}</div>`;
const sw = (checked, key, label, disabled) => `<input type="checkbox" role="switch" class="sw" data-c="${key}" aria-label="${esc(label)}" ${checked ? "checked" : ""} ${disabled ? "disabled" : ""}>`;
const prow = (label, trailing, sub) => `<div class="prow"><div class="lab">${esc(label)}${sub ? `<small>${esc(sub)}</small>` : ""}</div>${trailing}</div>`;
const section = (title, body, footer) => `<section class="section">${title ? caption(title) : ""}<div class="group">${body}</div>${footer ? `<div class="foot">${esc(footer)}</div>` : ""}</section>`;
const seg = (label, opts, cur, k, fill) =>
  `<div class="seg ${fill ? "fill" : ""}" role="radiogroup" aria-label="${label}">${opts.map(([l, v]) => `<button role="radio" aria-checked="${cur === v}" data-a="usage" data-k="${k}" data-v="${v}">${l}</button>`).join("")}</div>`;
const ibtn = (icon, label, act, extra = "") => `<button class="ibtn ${extra}" data-a="${act}" aria-label="${esc(label)}" title="${esc(label)}">${ic(icon, 13)}</button>`;

// ---------- ring
function ring(title, w, stale) {
  const p = Math.min(100, Math.max(0, w?.percent ?? 0)), C = 2 * Math.PI * 34.5, lv = level(p);
  const rs = resetText(w) + (stale ? " (cached)" : "");
  return `<div class="ring" role="img" aria-label="${title} limit, ${Math.round(p)} percent used. ${esc(rs)}">
    <div class="box"><svg viewBox="0 0 76 76" width="76" height="76" aria-hidden="true"><defs><linearGradient id="gr-${lv}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="var(--g-${lv}-a)"/><stop offset="1" stop-color="var(--g-${lv}-b)"/></linearGradient></defs>
      <circle cx="38" cy="38" r="34.5" fill="none" stroke="var(--track)" stroke-width="7"/>
      ${p > 0 ? `<circle class="arc" cx="38" cy="38" r="34.5" fill="none" stroke="url(#gr-${lv})" stroke-width="7" stroke-linecap="round" stroke-dasharray="${C}" stroke-dashoffset="${C * (1 - p / 100)}" transform="rotate(-90 38 38)"/>` : ""}</svg>
      <div class="pct ${p >= 90 ? "crit" : ""}"><span>${Math.round(p)}<small>%</small></span></div></div>
    <div><div class="lbl">${title}</div><div class="rs">${esc(rs)}</div></div></div>`;
}

// ---------- home
function headerHTML() {
  const n = accounts().length, old = isOutdated();
  const pinned = state.pinned ?? ui.localPin;
  return `<div class="head pane-head" style="padding:0" data-tauri-drag-region>
    <div class="mark" data-tauri-drag-region>${anchorSVG(14, 16, "currentColor", 1.8)}</div>
    <div class="titles" data-tauri-drag-region><div class="t1 trunc" data-tauri-drag-region>Claude Anchor</div>
      <div class="t2 trunc" data-tauri-drag-region>Routing ${n} ${n === 1 ? "account" : "accounts"}</div>
      <div class="t3 trunc ${old ? "old" : ""}" data-tauri-drag-region>${lastRefreshedText()}</div></div>
    <button class="ibtn" data-a="pin" aria-pressed="${pinned}" aria-label="Keep window open" title="${pinned ? "Unpin window" : "Keep window open"}">${ic("pin", 13)}</button>
    <button class="ibtn ${state.isRefreshing ? "spin" : ""}" data-a="refresh" aria-label="Refresh limits" title="Refresh limits" ${state.isRefreshing ? "disabled" : ""}>${ic("refresh", 13)}</button></div>`;
}
const emptyState = (title, detail, label, act, extra = "") =>
  `<div class="empty"><div style="opacity:.6;color:var(--text2)">${anchorSVG(22, 24, "currentColor", 1.6)}</div><div class="h">${esc(title)}</div><div class="s">${esc(detail)}</div><button class="btn" data-a="${act}" ${extra}>${esc(label)}</button></div>`;

function alertHTML() {
  const b = state.banner;
  if (!b) return "";
  const target = freshAccounts()[0];
  let btn = "";
  if (target) btn = `<button class="btn" data-a="anchorAt" data-id="${esc(target.id)}">Anchor at ${esc(target.name)}</button>`;
  else if (state.overflowSuggestion && account(state.overflowSuggestion)) {
    const t = account(state.overflowSuggestion);
    btn = `<button class="btn" data-a="continueOn" data-id="${esc(t.id)}">Continue this conversation on ${esc(t.name)}</button>`;
  }
  return `<div class="tinted amber" role="status"><span style="color:var(--amber);margin-top:1px">${ic("warn", 14)}</span>
    <div class="body"><div style="font-size:12.5px">${esc(b)}</div>${btn}</div>
    <button class="xbtn" data-a="dismiss" aria-label="Dismiss message" title="Dismiss">${ic("x", 10)}</button></div>`;
}
function freshHTML() {
  const fresh = freshAccounts(), a = active();
  if (!fresh.length && activeIsFresh() && a)
    return `<div class="tinted fresh"><span style="color:var(--fresh)">${ic("check", 16)}</span><div><div class="h">${esc(a.name)} has a full 5-hour window</div><div class="s">Your limit just reset. You're good to go.</div></div></div>`;
  if (!fresh.length) return "";
  const title = fresh.length === 1 ? `${fresh[0].name} has a full 5-hour window` : `${fresh.length} accounts have a full 5-hour window`;
  return `<div class="tinted fresh"><span style="color:var(--fresh)">${ic("check", 16)}</span><div class="body" style="gap:8px"><div><div class="h">${esc(title)}</div><div class="s">Anchor there to start on a clean slate.</div></div>
    <div style="display:flex;flex-direction:column;gap:6px;align-items:flex-start">${fresh.slice(0, 2).map((f) => `<button class="btn fresh" data-a="anchorAt" data-id="${esc(f.id)}">${flag(f.flag, 10)}<span class="trunc">Anchor at ${esc(f.name)}</span></button>`).join("")}
    ${fresh.length > 2 ? `<span class="muted" style="font-size:11.5px">+${fresh.length - 2} more</span>` : ""}</div></div></div>`;
}
function signingRows() {
  const a = active();
  return state.signingIn.filter((id) => account(id) && !(a && a.id === id && a.pending)).map((id) =>
    `<div class="tinted amber" role="status"><span class="spinner" style="margin-top:3px"></span><div class="body"><div style="font-size:12.5px">Finish signing in to ${esc(account(id).name)} in your browser.</div></div><button class="btn small ghost" data-a="cancelSignIn" data-id="${esc(id)}">Cancel</button></div>`).join("");
}
function accountCard() {
  const a = active();
  if (!a) return "";
  const l = state.limits[a.id];
  let body;
  if (a.pending) {
    const first = accounts().every((x) => x.pending);
    body = `<div style="display:flex;flex-direction:column;gap:6px"><div style="font-weight:600">${first ? "Sign in to get started" : `${esc(a.name)} isn't signed in`}</div>
      <div class="muted">Anchor reads your Claude Code sign-in to show limits and usage.</div>
      ${state.signingIn.includes(a.id) ? `<div class="row"><span class="spinner"></span><span class="muted">Finish signing in in your browser</span><button class="btn small ghost" data-a="cancelSignIn" data-id="${esc(a.id)}">Cancel</button></div>` : `<div><button class="btn small ghost" data-a="signIn" data-id="${esc(a.id)}">Sign in with browser</button></div>`}</div>`;
  } else if (l) {
    if (l.error) body = `<div class="row"><span class="muted sp" style="display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">${esc(l.error)}</span>${l.needsSignIn ? `<button class="btn small ghost" data-a="signIn" data-id="${esc(a.id)}">Sign in again</button>` : ""}</div>`;
    else body = `<div class="rings">${ring("5-hour", l.fiveHour, l.stale)}${ring("Weekly", l.weekly, l.stale)}</div>${l.note ? `<div class="muted" style="margin-top:8px">${esc(l.note)}</div>` : ""}`;
  } else body = `<div class="row"><span class="spinner"></span><span class="muted">Checking limits…</span></div>`;
  return `<div class="card" style="display:flex;flex-direction:column;gap:12px">
    <div class="row" style="gap:10px">${flag(a.flag, 18)}<div class="sp" style="line-height:1.25"><div class="trunc" style="font-size:13.5px;font-weight:600">${esc(a.name)}</div>${a.email ? `<div class="trunc muted" style="font-size:11.5px">${esc(a.email)}</div>` : ""}</div>${a.plan && !a.pending ? `<span class="pill">${esc(cap(a.plan))}</span>` : ""}</div>
    <hr class="hr">${body}</div>`;
}
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

function usageCard() {
  const rows = state.usageRows || [];
  const total = rows.reduce((s, r) => s + r.tokens, 0), cost = rows.reduce((s, r) => s + r.cost, 0), top = Math.max(1, ...rows.map((r) => r.tokens));
  const shown = ui.showAll ? rows : rows.slice(0, 4);
  return `<div class="card" style="display:flex;flex-direction:column;gap:10px">
    <div class="row">${caption("Usage")}<div class="sp"></div>${seg("Range", [["Today", 1], ["7 days", 7], ["30 days", 30]], state.rangeDays, "rangeDays")}</div>
    <div class="row" style="align-items:baseline;gap:6px" role="group" aria-label="Total usage: ${compact(total)} tokens, about ${usd(cost)}"><span class="big">${compact(total)}</span><span class="muted trunc" style="font-size:12px">tokens · ≈${usd(cost)}</span></div>
    ${seg("Group by", [["Account", "account"], ["Project", "project"], ["Model", "model"]], state.groupBy, "groupBy", true)}
    ${rows.length ? `<div style="display:flex;flex-direction:column;gap:9px">${shown.map((r) => {
      const a = r.accountID && account(r.accountID);
      return `<div class="urow" role="group" aria-label="${esc(r.label)}: ${compact(r.tokens)} tokens, about ${usd(r.cost)}"><div class="top">${a ? flag(a.flag, 11) : ""}<span class="trunc sp" title="${esc(r.label)}">${esc(r.label)}</span><span class="num">${compact(r.tokens)}</span><span class="num cost" title="What this usage would cost at API prices. Your plan is a flat fee.">≈${usd(r.cost)}</span></div><div class="bar"><i style="width:max(3px,${(r.tokens / top) * 100}%)"></i></div></div>`;
    }).join("")}</div>
    ${rows.length > 4 ? `<button class="link" style="text-align:center;height:24px;width:100%" data-a="showAll">${ui.showAll ? "Show fewer" : `Show all ${rows.length}`}</button>` : ""}
    <div class="muted" style="font-size:11px">≈ is the API price of this usage, not your bill.</div>` : `<div class="muted" style="min-height:40px">No Claude Code usage yet in this range.</div>`}</div>`;
}

function continueCard() {
  const s = state.lastSession;
  if (!s) return "";
  const src = account(s.accountID), targets = continueTargets(), sel = targets.find((t) => t.id === ui.picked) || targets[0];
  const tag = (t) => (isFresh(t.id) ? "Fresh" : state.limits[t.id]?.fiveHour ? `${Math.round(state.limits[t.id].fiveHour.percent)}% used` : "");
  let body;
  if (ui.doneId && account(ui.doneId)) {
    const t = account(ui.doneId);
    body = `<div class="tinted fresh" style="padding:10px;border-radius:10px"><span style="color:var(--fresh)">${ic("check", 15)}</span><div class="sp"><div style="font-size:12.5px;font-weight:600">Reopened on ${esc(t.name)} in a terminal.</div><div class="s">Full history carried over. The old one stays on ${esc(src?.name || "the original account")}.</div></div><button class="btn small ghost" data-a="doneContinue">Done</button></div>`;
  } else if (!targets.length) body = `<div class="muted" style="font-size:12px">Add a second account to continue a conversation there when this one runs out.</div>`;
  else body = `<select class="sel block" data-c="continuePick" aria-label="Continue on">${targets.map((t) => `<option value="${esc(t.id)}" ${t.id === sel.id ? "selected" : ""}>${esc(tag(t) ? `${t.name} · ${tag(t)}` : t.name)}</option>`).join("")}</select>
    <button class="btn block" data-a="continue" ${s.file ? "" : "disabled"} title="Opens in a new terminal with the full history." aria-label="Continue on ${esc(sel.name)}">${src ? flag(src.flag, 10) : ""}<span style="font-weight:700">→</span>${flag(sel.flag, 10)}<span class="trunc">Continue on ${esc(sel.name)}</span></button>`;
  return `<div class="card" style="display:flex;flex-direction:column;gap:10px">${caption("Last conversation")}
    <div class="row">${ic("folder", 13)}<span class="trunc sp" style="font-size:12.5px;font-weight:500" title="${esc(s.cwd)}">${esc(abbreviate(s.cwd))}</span>${src ? `${flag(src.flag, 11)}<span class="trunc muted" style="max-width:110px;font-size:12px">on ${esc(src.name)}</span>` : ""}</div>${body}</div>`;
}

function homeHTML() {
  let mid;
  if (!state.cliInstalled) mid = emptyState("Claude Code isn't installed.", "Install it, then reopen this menu.", "Open install guide", "openCli") + alertHTML();
  else if (!accounts().length) mid = emptyState("Add an account to start", "Each account keeps its own limits and usage.", "Add account", "goAdd") + alertHTML();
  else mid = `<div id="harborHost"></div>${signingRows()}${state.banner ? alertHTML() : freshHTML()}${accountCard()}${usageCard()}${continueCard()}`;
  return `<div class="scroll"><div class="stack">${headerHTML()}${mid}</div></div>
    <div class="navwrap"><nav class="nav" aria-label="Sections">
      <button data-a="nav" data-v="accounts">${ic("users")}Accounts</button><button data-a="nav" data-v="rules" aria-label="Folder rules">${ic("folder")}Rules</button><button data-a="nav" data-v="settings">${ic("gear")}Settings</button>
      <button class="q" data-a="quit" aria-label="Quit Claude Anchor" title="Quit Claude Anchor">${ic("power")}</button></nav></div>`;
}

// ---------- panes
const paneHead = (title) => `<div class="head pane-head" data-tauri-drag-region><button class="ibtn" data-a="back" aria-label="Back" title="Back">${ic("back", 13)}</button><h1 class="pane-title" data-tauri-drag-region>${esc(title)}</h1></div>`;
const paneWrap = (title, body) => `<div class="pane" style="display:contents">${paneHead(title)}<div class="scroll"><div class="stack">${body}</div></div></div>`;
const dotsBtn = (label, id) => `<button class="dots" data-a="rowmenu" data-id="${esc(id)}" aria-haspopup="menu" aria-label="${esc(label)}" title="${esc(label)}">${ic("dots", 18)}</button>`;

function accountsPane() {
  const list = accounts();
  const rows = list.map((a, i) => {
    const editing = ui.rename?.id === a.id;
    let sub = "";
    if (state.signingIn.includes(a.id)) sub = `<div class="em"><span class="spinner"></span><span class="trunc">Finish signing in in your browser</span><button class="btn small ghost" data-a="cancelSignIn" data-id="${esc(a.id)}">Cancel</button></div>`;
    else if (a.pending) sub = `<div class="em">Not signed in<button class="btn small ghost" data-a="signIn" data-id="${esc(a.id)}">Sign in</button></div>`;
    else if (a.email) sub = `<div class="em"><span class="trunc">${esc(a.email)}</span></div>`;
    return `<div class="arow">${flag(a.flag, 16)}<div class="col">${editing
      ? `<input class="inp" data-c="renameInput" aria-label="Account name" value="${esc(ui.rename.draft)}" maxlength="40">`
      : `<div class="nm trunc" data-a="startRename" data-id="${esc(a.id)}" title="Double-click to rename">${esc(a.name)}</div>`}${sub}</div>
      ${a.plan && !a.pending ? `<span class="pill">${esc(cap(a.plan))}</span>` : ""}${dotsBtn(`Options for ${a.name}`, a.id)}</div>`;
  }).join("");
  const add = ui.adding ? "" : `<button class="addrow" data-a="goAdd">${ic("plus", 14)}Add account</button>`;
  const form = ui.adding ? section("New account", `<div style="padding:10px 0;display:flex;flex-direction:column;gap:10px">
      <div class="row"><input class="inp" id="newName" data-c="newName" aria-label="Account name" placeholder="Account name" value="${esc(ui.newName)}" maxlength="40"><button class="ibtn" style="width:auto;padding:0 6px" data-a="pickNewFlag" aria-label="Flag ${ui.newFlag.toUpperCase()}, change" title="Change flag">${flag(ui.newFlag, 16)}</button></div>
      <div class="row"><button class="btn small ghost" data-a="cancelAdd">Cancel</button><div class="sp"></div><button class="btn small" data-a="submitAdd" ${ui.newName.trim() ? "" : "disabled"}>Sign in with browser</button></div></div>`) : "";
  return paneWrap("Accounts", section("Signed in", rows + add, "New sessions start on the default account. Use ⋯ to rename, change the flag or reorder") + form);
}

function rulesPane() {
  const a0 = active(), thr = state.config.overflowThreshold;
  const rows = state.config.rules.map((r) => {
    const acct = account(r.accountID), l = state.limits[r.accountID], pct = l?.fiveHour?.percent ?? 0;
    const near = pct >= thr && !l?.error, fb = a0, uses = r.allowOverflow && fb && fb.id !== r.accountID;
    let st = "";
    if (near && acct) {
      const t = `${acct.name} at ${Math.round(pct)}%`, txt = uses ? `${t} · now using ${fb.name}` : `${t} · new sessions will wait`, tint = uses ? "var(--amber)" : "var(--limit)";
      st = `<div class="status" style="color:${tint};background:color-mix(in srgb,${tint} 10%,transparent)"><i style="background:${tint}"></i><span>${esc(txt)}</span></div>`;
    }
    return `<div class="rrow"><div class="row">${ic("folder", 13)}<span class="path trunc sp" title="${esc(r.path)}">${esc(abbreviate(r.path))}</span>${dotsBtn(`Options for ${abbreviate(r.path)}`, r.path)}</div>
      <div class="row">${acct ? flag(acct.flag, 11) : ""}<select class="sel inline" data-c="ruleAcct" data-path="${esc(r.path)}" aria-label="Account for ${esc(abbreviate(r.path))}">${!acct ? `<option selected>Choose account</option>` : ""}${accounts().map((a) => `<option value="${esc(a.id)}" ${a.id === r.accountID ? "selected" : ""}>${esc(a.name)}</option>`).join("")}</select>
      <div class="sp"></div><span class="muted" style="font-size:12px">Overflow</span><input type="checkbox" role="switch" class="sw" data-c="ruleOverflow" data-path="${esc(r.path)}" aria-label="Allow overflow for ${esc(abbreviate(r.path))}" ${r.allowOverflow ? "checked" : ""}></div>${st}</div>`;
  }).join("");
  const body = section("Folders", rows + `<button class="addrow" data-a="addFolder">${ic("plus", 14)}Add folder</button>`, "New Claude sessions in a folder, in a terminal or an editor, use its account. Overflow lets a folder use the default account when its own is near its limit.") +
    (a0 ? section("Default", prow("Every other folder", `${flag(a0.flag, 11)}<span class="trunc" style="font-weight:500;max-width:150px">${esc(a0.name)}</span>`)) : "");
  return paneWrap("Folder rules", body);
}

function settingsPane() {
  const c = state.config, wl = state.wayland, p = accounts().find(isPrimary);
  const opts = [[30, "Live every 30 s"], [60, "Every 1 min"], [300, "Every 5 min"], [900, "Every 15 min"], [0, "Manual only"]];
  const kbd = `<span class="kbd" aria-hidden="true">Ctrl+Alt+A</span>`;
  const body =
    section("General",
      prow("Launch at login", sw(state.loginItem, "login", "Launch at login")) +
      prow("Bell sound", sw(c.bell, "set:bell", "Bell sound")) +
      prow("Auto-switch near limit", sw(c.autoOverflow, "set:autoOverflow", "Auto-switch near limit")) +
      (c.autoOverflow ? prow("Switch at", `<select class="sel" data-c="threshold" aria-label="Auto-switch threshold">${[70, 75, 80, 85, 90, 95].map((v) => `<option value="${v}" ${Math.round(c.overflowThreshold) === v ? "selected" : ""}>${v}%</option>`).join("")}${[70, 75, 80, 85, 90, 95].includes(Math.round(c.overflowThreshold)) ? "" : `<option selected>${Math.round(c.overflowThreshold)}%</option>`}</select>`) : "") +
      prow("Use in VS Code and Cursor", sw(!!c.editorIntegration, "editor", "Use in VS Code and Cursor"))) +
    section("Limits",
      prow("Refresh limits", `<select class="sel" data-c="refresh" aria-label="Refresh limits">${opts.map(([v, l]) => `<option value="${v}" ${c.refreshSeconds === v ? "selected" : ""}>${l}</option>`).join("")}</select>`) +
      prow("Notify when a window resets", sw(c.notifyFresh, "set:notifyFresh", "Notify when a window resets")),
      "Live uses more of Anthropic's API. Use Refresh in the header any time.") +
    section("Floating button",
      prow("Show floating button", (wl ? "" : kbd) + sw(c.floatingButton && !wl, "set:floatingButton", "Show floating button", wl)) +
      prow("Snap to screen edges", sw(c.floatingSnap, "set:floatingSnap", "Snap to screen edges", wl)) +
      prow("Fade when idle", sw(c.floatingFade, "set:floatingFade", "Fade when idle", wl)),
      wl ? "Not available on Wayland." : "") +
    (p && !p.pending ? section("Account", `<div class="prow"><button class="link" style="color:var(--limit)" data-a="signOut">Sign out of Claude Code</button></div>`) : "") +
    section("About",
      prow("Version", `<span class="muted">${esc(state.version)}</span>`) +
      `<div class="prow"><button class="link" data-a="url" data-url="${REPO}#readme">Documentation</button></div><div class="prow"><button class="link" data-a="url" data-url="${REPO}/issues">Report an issue</button></div>`);
  return paneWrap("Settings", body);
}

// ---------- popups and modals
let popupEl = null, popupOwner = null;
function closePopup() { popupEl?.remove(); popupEl = null; document.removeEventListener("pointerdown", outside, true); }
function outside(e) { if (popupEl && !popupEl.contains(e.target)) closePopup(); }
function popup(anchorEl, content) {
  closePopup();
  const m = document.createElement("div");
  m.className = "menu"; m.setAttribute("role", "menu"); m.append(content);
  document.body.append(m);
  const r = anchorEl.getBoundingClientRect();
  m.style.left = Math.max(8, Math.min(r.right - m.offsetWidth, 340 - m.offsetWidth - 8)) + "px";
  let top = r.bottom + 4;
  if (top + m.offsetHeight > 632) top = Math.max(8, r.top - m.offsetHeight - 4);
  m.style.top = top + "px";
  popupEl = m; popupOwner = anchorEl;
  setTimeout(() => document.addEventListener("pointerdown", outside, true));
  m.querySelector("button")?.focus();
  m.addEventListener("keydown", (e) => {
    const bs = [...m.querySelectorAll("button")], i = bs.indexOf(document.activeElement);
    if (e.key === "ArrowDown") { bs[(i + 1) % bs.length].focus(); e.preventDefault(); }
    else if (e.key === "ArrowUp") { bs[(i - 1 + bs.length) % bs.length].focus(); e.preventDefault(); }
  });
}
function menu(anchorEl, items) {
  const box = document.createElement("div");
  for (const it of items) {
    if (it === "-") { box.append(document.createElement("hr")); continue; }
    const b = document.createElement("button");
    b.setAttribute("role", "menuitem"); b.textContent = it.label; if (it.danger) b.className = "danger";
    b.addEventListener("click", () => { closePopup(); it.run(); });
    box.append(b);
  }
  popup(anchorEl, box);
}
function flagPicker(anchorEl, current, used, pick) {
  const g = document.createElement("div");
  g.className = "flaggrid";
  g.innerHTML = FLAGS.map((f) => `<button data-f="${f}" role="menuitemradio" aria-label="Flag ${f.toUpperCase()}" aria-pressed="${f === current}" class="${used.has(f) && f !== current ? "used" : ""}">${flagSVG(f, 20)}</button>`).join("");
  g.addEventListener("click", (e) => { const b = e.target.closest("[data-f]"); if (b) { closePopup(); pick(b.dataset.f); } });
  popup(anchorEl, g);
}
function modal(html, wire) {
  const s = document.createElement("div");
  s.className = "scrim"; s.innerHTML = `<div class="modal" role="dialog" aria-modal="true">${html}</div>`;
  document.body.append(s);
  const close = () => { s.remove(); };
  s.addEventListener("pointerdown", (e) => { if (e.target === s) close(); });
  s.addEventListener("keydown", (e) => { if (e.key === "Escape") { close(); e.stopPropagation(); } });
  wire(s, close);
  (s.querySelector("select,input,button") || s).focus();
  return close;
}
function removeDialog(a) {
  const others = accounts().filter((x) => x.id !== a.id);
  const def = others.find((o) => o.id === state.config.defaultID) || others[0];
  modal(`<h2>Remove ${esc(a.name)}</h2><p>Its config folder moves to the ${trashWord()}. Usage already logged stays in your history.</p>
    ${others.length ? `<label class="muted" style="font-size:11.5px" for="mv">Move its folders to</label><select id="mv" class="sel block">${others.map((o) => `<option value="${esc(o.id)}" ${o === def ? "selected" : ""}>${esc(o.name)}</option>`).join("")}</select>` : ""}
    <div class="acts"><button class="btn ghost" data-x="cancel">Cancel</button><button class="btn danger" data-x="ok">Remove ${esc(a.name)}</button></div>`,
  (s, close) => s.addEventListener("click", (e) => {
    const x = e.target.closest("[data-x]")?.dataset.x;
    if (x === "cancel") close();
    if (x === "ok") { close(); call("remove_account", { id: a.id, to: s.querySelector("#mv")?.value || "" }); }
  }));
}
function signOutDialog() {
  modal(`<h2>Sign out of Claude Code?</h2><p>This signs the primary account out. Other accounts stay signed in.</p><div class="acts"><button class="btn ghost" data-x="cancel">Cancel</button><button class="btn danger" data-x="ok">Sign out</button></div>`,
    (s, close) => s.addEventListener("click", (e) => {
      const x = e.target.closest("[data-x]")?.dataset.x;
      if (x === "cancel") close();
      if (x === "ok") { close(); call("sign_out_primary"); }
    }));
}

// ---------- rendering
let harbor = null;
function ensureHarbor() {
  if (harbor) return harbor;
  harbor = createHarbor({
    getState: () => state,
    helpers: { isFresh, countdown, color: levelColor },
    onPick: (id) => { state.config.defaultID = id; call("set_default", { id }); },
    onAdd: () => { ui.adding = true; ui.newName = ""; ui.newFlag = nextFlag(); go("accounts"); },
  });
  return harbor;
}
const nextFlag = () => { const used = new Set(accounts().map((a) => a.flag)); return FLAGS.find((f) => !used.has(f)) || "a"; };
function go(v) { view = v; closePopup(); render(true); }

function render(resetScroll) {
  if (!state) return;
  const app = $("#app"), keep = $(".scroll")?.scrollTop || 0, hadFocus = document.activeElement?.dataset?.a;
  pendingRender = false;
  app.innerHTML = view === "accounts" ? accountsPane() : view === "rules" ? rulesPane() : view === "settings" ? settingsPane() : homeHTML();
  if (view === "home") {
    const host = $("#harborHost");
    if (host) { const h = ensureHarbor(); host.replaceWith(h.el); h.update(); }
  }
  if (!resetScroll && $(".scroll")) $(".scroll").scrollTop = keep;
  if (hadFocus && !resetScroll) $(`[data-a="${hadFocus}"]`)?.focus?.();
  if (view === "accounts" && ui.rename) { const i = $('[data-c="renameInput"]'); i?.focus(); i?.select(); }
}
function setState(s) {
  state = s;
  const t = document.activeElement;
  if (t && (t.tagName === "INPUT" && t.type === "text" || t.classList?.contains("inp"))) { pendingRender = true; harbor?.update(); return; }
  render();
}
document.addEventListener("focusout", () => setTimeout(() => { if (pendingRender && !document.activeElement?.classList?.contains("inp")) render(); }, 0));

// ---------- events
const A = {
  back: () => go("home"),
  nav: (d) => { ui.adding = false; ui.rename = null; go(d.v); },
  refresh: () => call("refresh"),
  pin: async () => { ui.localPin = !ui.localPin; const r = await call("toggle_pin"); if (!r) ui.localPin = !ui.localPin; render(); },
  quit: () => call("quit"),
  dismiss: () => call("dismiss_banner"),
  openCli: () => call("open_url", { url: CLI_DOCS }),
  url: (d) => call("open_url", { url: d.url }),
  anchorAt: (d) => call("set_default", { id: d.id }),
  signIn: (d) => call("sign_in", { id: d.id }),
  cancelSignIn: (d) => call("cancel_sign_in", { id: d.id }),
  usage: (d) => {
    const v = d.k === "rangeDays" ? +d.v : d.v;
    call("set_usage_view", { groupBy: d.k === "groupBy" ? v : state.groupBy, rangeDays: d.k === "rangeDays" ? v : state.rangeDays });
  },
  showAll: () => { ui.showAll = !ui.showAll; render(); },
  continue: async () => {
    const sel = continueTargets().find((t) => t.id === ui.picked) || continueTargets()[0];
    if (!sel) return;
    const r = await call("continue_session", { target: sel.id });
    if (r) { ui.doneId = sel.id; render(); }
  },
  continueOn: (d) => call("continue_session", { target: d.id }),
  doneContinue: () => { ui.doneId = null; render(); },
  goAdd: () => { ui.adding = true; ui.newName = ""; ui.newFlag = nextFlag(); go("accounts"); setTimeout(() => $("#newName")?.focus(), 0); },
  cancelAdd: () => { ui.adding = false; render(); },
  submitAdd: async () => { const n = ui.newName.trim(); if (!n) return; ui.adding = false; await call("add_account", { name: n, flag: ui.newFlag }); render(); },
  pickNewFlag: (d, el) => flagPicker(el, ui.newFlag, new Set(accounts().map((a) => a.flag)), (f) => { ui.newFlag = f; render(); }),
  startRename: (d) => { const a = account(d.id); ui.rename = { id: a.id, draft: a.name }; render(); },
  addFolder: async () => {
    const path = await call("pick_folder");
    const id = active()?.id || accounts()[0]?.id;
    if (path && id) call("add_rule", { path, accountId: id });
  },
  signOut: () => signOutDialog(),
  rowmenu: (d, el) => {
    if (view === "rules") return menu(el, [{ label: "Remove rule", danger: true, run: () => call("remove_rule", { path: d.id }) }]);
    const i = accounts().findIndex((a) => a.id === d.id), a = accounts()[i];
    menu(el, [
      { label: "Rename", run: () => A.startRename({ id: a.id }) },
      { label: "Change flag", run: () => flagPicker(el.isConnected ? el : popupOwner, a.flag, new Set(accounts().map((x) => x.flag)), (f) => call("set_flag", { id: a.id, flag: f })) },
      { label: "Sign in again", run: () => call("sign_in", { id: a.id }) },
      ...(i > 0 ? [{ label: "Move up", run: () => call("move_account", { from: i, to: i - 1 }) }] : []),
      ...(i < accounts().length - 1 ? [{ label: "Move down", run: () => call("move_account", { from: i, to: i + 1 }) }] : []),
      "-",
      isPrimary(a) ? { label: "Sign out", run: signOutDialog } : { label: `Remove ${a.name}`, danger: true, run: () => removeDialog(a) },
    ]);
  },
};
document.addEventListener("click", (e) => {
  const el = e.target.closest("[data-a]");
  if (el && A[el.dataset.a] && !el.disabled) A[el.dataset.a](el.dataset, el);
});
document.addEventListener("dblclick", (e) => { const el = e.target.closest('[data-a="startRename"]'); if (el) A.startRename(el.dataset); });
document.addEventListener("change", async (e) => {
  const t = e.target, k = t.dataset.c;
  if (!k) return;
  if (k.startsWith("set:")) call("set_setting", { key: k.slice(4), value: t.checked });
  else if (k === "login") call("set_login_item", { on: t.checked });
  else if (k === "editor") call("set_editor_integration", { on: t.checked });
  else if (k === "refresh") call("set_setting", { key: "refreshSeconds", value: +t.value });
  else if (k === "threshold") call("set_setting", { key: "overflowThreshold", value: +t.value });
  else if (k === "continuePick") { ui.picked = t.value; render(); }
  else if (k === "ruleAcct") {
    const r = state.config.rules.find((x) => x.path === t.dataset.path);
    await call("add_rule", { path: t.dataset.path, accountId: t.value });
    if (r?.allowOverflow) call("set_rule_overflow", { path: t.dataset.path, on: true });
  } else if (k === "ruleOverflow") call("set_rule_overflow", { path: t.dataset.path, on: t.checked });
  else if (k === "renameInput") commitRename(t.value);
});
function commitRename(v) {
  const r = ui.rename; ui.rename = null;
  if (r && v.trim() && v.trim() !== account(r.id)?.name) call("rename_account", { id: r.id, name: v.trim() }).then(() => render());
  else render();
}
document.addEventListener("input", (e) => {
  const t = e.target;
  if (t.dataset.c === "newName") { ui.newName = t.value; const b = $('[data-a="submitAdd"]'); if (b) b.disabled = !t.value.trim(); }
  else if (t.dataset.c === "renameInput" && ui.rename) ui.rename.draft = t.value;
});
document.addEventListener("keydown", (e) => {
  const t = e.target;
  if (e.key === "Enter" && t.dataset.c === "renameInput") { e.preventDefault(); commitRename(t.value); }
  else if (e.key === "Enter" && t.dataset.c === "newName") { e.preventDefault(); A.submitAdd(); }
  else if (e.key === "Escape") {
    if (popupEl) { const o = popupOwner; closePopup(); o?.isConnected && o.focus(); }
    else if (t.dataset.c === "renameInput") { ui.rename = null; render(); }
    else if (document.querySelector(".scrim")) return;
    else if (view !== "home") go("home");
  }
});
document.addEventListener("contextmenu", (e) => { if (!window.__TAURI__.mock && !/INPUT|TEXTAREA/.test(e.target.tagName)) e.preventDefault(); });

// refresh relative times ("Updated 2 min ago", countdowns)
setInterval(() => { if (state && !pendingRender && !document.querySelector(".scrim") && !popupEl && !document.activeElement?.classList?.contains("inp")) render(); }, 30000);

listen("state", (e) => setState(e.payload));
invoke("get_state").then(setState).catch((e) => { $("#app").innerHTML = `<div class="empty"><div class="h">Couldn't load</div><div class="s">${esc(e)}</div></div>`; });
