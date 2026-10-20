// Dev-only fake Tauri backend so the pages render in a normal browser. Loaded only when window.__TAURI__ is absent.
// Query params: ?scenario=six|many|fresh2|empty|nocli|signin|error|fresh|hot  &platform=windows|linux  &wayland=1
export function installMock() {
  const q = new URLSearchParams(location.search);
  const now = () => Math.floor(Date.now() / 1000);
  const iso = (secs) => new Date(Date.now() + secs * 1000).toISOString();
  const home = "/home/you";
  const scenario = q.get("scenario") || "";
  // ?scheme=light|dark forces the colour scheme (dev only): flips the prefers-color-scheme media rule.
  if (q.get("scheme")) { const force = () => {
    for (const sh of document.styleSheets) for (const r of sh.cssRules)
      if (r.media && /prefers-color-scheme: dark/.test(r.media.mediaText)) r.media.mediaText = q.get("scheme") === "dark" ? "all" : "not all";
  }; force(); addEventListener("load", force); setTimeout(force, 300); }

  const acct = (id, name, flag, email, plan, extra = {}) => ({ id, name, flag, dir: `${home}/.claude-anchor/accounts/${id}`, email, plan, pending: false, ...extra });
  let accounts = [
    acct("primary", "Work", "w", "you@work.example", "pro", { dir: `${home}/.claude` }),
    acct("client", "Client", "c", "you@client.example", "max"),
    acct("personal", "Personal", "p", "you@example.com", "pro"),
  ];
  if (scenario === "six" || scenario === "many" || scenario === "fresh2") {
    accounts.push(acct("studio", "Studio", "s", "you@studio.example", "pro"), acct("side", "Side project", "d", "you@example.com", "max"),
      acct("lab", "Lab", "l", undefined, undefined, { pending: true }));
    if (scenario === "many") accounts.push(acct("n1", "Archive", "g", "you@example.net", "pro"), acct("n2", "Travel", "h", "you@example.org", "pro"), acct("n3", "Spare", "k", "you@example.dev", "pro"));
  }
  if (scenario === "empty") accounts = [];
  const lim = (five, weekly, fiveReset = 5940, extra = {}) => ({
    fiveHour: five == null ? null : { percent: five, resetsAt: iso(fiveReset) },
    weekly: weekly == null ? null : { percent: weekly, resetsAt: iso(86400 * 3) },
    fetchedAt: now(), stale: false, error: null, needsSignIn: false, note: null, ...extra,
  });
  let limits = {
    primary: lim(scenario === "hot" ? 93 : 68, 31),
    client: lim(scenario === "fresh2" ? 0 : 22, 48, 11000),
    personal: lim(scenario === "fresh" ? 0 : 0, 12, 18000),
    studio: lim(scenario === "fresh2" ? 0 : 81, 60, 1320), side: lim(scenario === "fresh2" ? 0 : 45, 30, 9000), n1: lim(10, 5), n2: lim(55, 20), n3: lim(2, 2),
  };
  if (scenario === "error") limits.client = { ...lim(null, null), fiveHour: null, weekly: null, error: "Client's sign-in expired. Sign in again.", needsSignIn: true };

  const S = {
    config: {
      accounts, rules: [
        { path: `${home}/code/website`, accountID: "primary", allowOverflow: false },
        { path: `${home}/code/client-app`, accountID: "client", allowOverflow: true },
        { path: `${home}/notes`, accountID: "personal", allowOverflow: false },
      ],
      defaultID: "primary", overflowThreshold: 90, autoOverflow: true, bell: false, editorIntegration: false, removedNames: {},
      refreshSeconds: 300, notifyFresh: true, floatingButton: true, floatingSnap: true, floatingFade: q.get("fade") === "1", floatingAllSpaces: true,
    },
    limits, usageRows: [], groupBy: "account", rangeDays: 7,
    lastSession: scenario === "empty" ? null : { cwd: `${home}/code/website`, accountID: "primary", file: "x.jsonl" },
    overflowSuggestion: null,
    banner: scenario === "banner" ? "Work is at 92%. New sessions are using Personal." : null,
    signingIn: scenario === "signin" ? ["lab"] : [], cliInstalled: scenario !== "nocli", isRefreshing: false,
    lastRefreshed: scenario === "empty" ? null : now() - 20, loginItem: false, wayland: q.get("wayland") === "1",
    platform: q.get("platform") || "windows", home, version: "0.3.2",
  };
  if (scenario === "error") S.overflowSuggestion = "personal";

  const rowsFor = () => {
    const by = S.groupBy, k = S.rangeDays === 1 ? 0.15 : S.rangeDays === 7 ? 1 : 3.2;
    const sets = {
      account: S.config.accounts.filter((a) => !a.pending).map((a, i) => ({ id: a.id, label: a.name, accountID: a.id, tokens: [1200, 640, 212, 300, 90, 40][i % 6] * 1000, cost: [14.2, 7.9, 2.35, 3.1, 1, 0.5][i % 6] })),
      project: [["~/code/website", 1100, 13.1], ["~/code/client-app", 700, 8.4], ["~/notes", 212, 2.35], ["~/code/api", 120, 1.4], ["~/tmp", 30, 0.2]].map(([l, t, c]) => ({ id: l, label: l, tokens: t * 1000, cost: c })),
      model: [["Opus 5.5", 1500, 20.1], ["Sonnet 5.5", 480, 3.6], ["Haiku 4.5", 72, 0.75]].map(([l, t, c]) => ({ id: l, label: l, tokens: t * 1000, cost: c })),
    }[by];
    return sets.map((r) => ({ outputTokens: Math.round(r.tokens / 8), ...r, tokens: Math.round(r.tokens * k), cost: +(r.cost * k).toFixed(2) }));
  };
  // dev helpers: ?click=sel1|sel2 clicks elements in turn, ?scroll=N scrolls the content
  if (q.get("click") || q.get("scroll")) setTimeout(async () => {
    for (const sel of (q.get("click") || "").split("|").filter(Boolean)) { document.querySelector(sel)?.click(); await new Promise((r) => setTimeout(r, 400)); }
    if (q.get("scroll")) document.querySelector(".scroll").scrollTop = +q.get("scroll");
  }, 700);
  const listeners = [];
  const emit = () => { S.usageRows = rowsFor(); const c = JSON.parse(JSON.stringify(S)); listeners.forEach((f) => f({ payload: c })); return c; };
  const find = (id) => S.config.accounts.find((a) => a.id === id);
  const slug = (n) => n.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "acct";

  const cmds = {
    get_state: () => {},
    refresh: () => { S.isRefreshing = true; setTimeout(() => { S.isRefreshing = false; S.lastRefreshed = now(); emit(); }, 1500); },
    set_default: ({ id }) => { S.config.defaultID = id; S.banner = null; },
    add_account: ({ name, flag }) => {
      if (!name.trim()) throw "Give the account a name.";
      const id = slug(name); S.config.accounts.push(acct(id, name, flag, undefined, undefined, { pending: true })); S.signingIn.push(id);
      setTimeout(() => { const a = find(id); if (a) { a.pending = false; a.email = "you@example.com"; a.plan = "pro"; S.limits[id] = lim(5, 2); S.signingIn = S.signingIn.filter((x) => x !== id); emit(); } }, 3000);
    },
    sign_in: ({ id }) => { if (!S.signingIn.includes(id)) S.signingIn.push(id); setTimeout(() => { const a = find(id); if (a) { a.pending = false; a.email ||= "you@example.com"; a.plan ||= "pro"; S.limits[id] = lim(3, 1); } S.signingIn = S.signingIn.filter((x) => x !== id); emit(); }, 2500); },
    cancel_sign_in: ({ id }) => { S.signingIn = S.signingIn.filter((x) => x !== id); },
    sign_out_primary: () => { const a = find("primary"); if (a) { a.pending = true; a.email = undefined; a.plan = undefined; } },
    remove_account: ({ id, to }) => {
      const a = find(id); if (a) S.config.removedNames[id] = a.name;
      S.config.accounts = S.config.accounts.filter((x) => x.id !== id);
      S.config.rules.forEach((r) => { if (r.accountID === id) r.accountID = to; });
      if (S.config.defaultID === id) S.config.defaultID = to || S.config.accounts[0]?.id;
    },
    rename_account: ({ id, name }) => { if (!name.trim()) throw "Name can't be empty."; find(id).name = name.trim(); },
    set_flag: ({ id, flag }) => { find(id).flag = flag; },
    move_account: ({ from, to }) => { const [a] = S.config.accounts.splice(from, 1); S.config.accounts.splice(to, 0, a); },
    add_rule: ({ path, accountId }) => {
      const r = S.config.rules.find((x) => x.path === path);
      if (r) r.accountID = accountId; else S.config.rules.push({ path, accountID: accountId, allowOverflow: false });
    },
    remove_rule: ({ path }) => { S.config.rules = S.config.rules.filter((r) => r.path !== path); },
    set_rule_overflow: ({ path, on }) => { const r = S.config.rules.find((x) => x.path === path); if (r) r.allowOverflow = on; },
    pick_folder: () => `${home}/code/new-folder-${S.config.rules.length + 1}`,
    set_setting: ({ key, value }) => { S.config[key] = value; },
    set_editor_integration: ({ on }) => { S.config.editorIntegration = on; },
    set_login_item: ({ on }) => { S.loginItem = on; },
    set_usage_view: ({ groupBy, rangeDays }) => { S.groupBy = groupBy; S.rangeDays = rangeDays; },
    continue_session: ({ target }) => { if (!find(target)) throw "Unknown account."; },
    dismiss_banner: () => { S.banner = null; },
    open_url: ({ url }) => { window.open(url, "_blank", "noopener"); },
    toggle_pin: () => { S.pinned = !S.pinned; },
    open_main_near_button: () => { console.log("open_main_near_button"); },
    quit: () => { console.log("quit"); },
  };

  window.__TAURI__ = {
    core: {
      invoke: async (name, args = {}) => {
        const f = cmds[name];
        if (!f) throw `Unknown command ${name}`;
        await new Promise((r) => setTimeout(r, 30));
        const out = f(args);
        if (name === "pick_folder") return out;
        return emit();
      },
    },
    event: { listen: async (name, cb) => { if (name === "state") listeners.push(cb); return () => {}; } },
    window: { getCurrentWindow: () => ({ startDragging: async () => console.log("startDragging") }) },
    mock: true,
  };
}
