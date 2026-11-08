// Relay for Windows UI. Talks to the Rust side through window.__TAURI__ (see ../API.md).
"use strict";

const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args || {});
const listen = (event, cb) => window.__TAURI__.event.listen(event, cb);

// ---------------------------------------------------------------- helpers

const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ESC[c]);
/** A title inside a sentence, isolated so right-to-left text does not turn the sentence around. */
const quoted = (t) => '"⁨' + t + '⁩"';
const iso = (t) => "⁨" + t + "⁩";
const errText = (e) => (typeof e === "string" ? e : e && e.message ? e.message : String(e));
const plural = (n, word, many) => n + " " + (n === 1 ? word : many || word + "s");

function fmtDate(ms) {
  if (ms == null) return "";
  return new Date(ms).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}
/** "15:14" today, "Sat 23:19" within a week either way, otherwise "7 Nov". */
function when(ms) {
  const d = new Date(ms), now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  if (Math.abs(ms - Date.now()) < 6.5 * 864e5) return d.toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit" });
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short" });
}
function project(cwd) {
  const parts = String(cwd || "").split(/[\\/]+/).filter(Boolean);
  return parts.slice(-2).join("/");
}
function highlight(snippet) {
  return esc(String(snippet || "").replace(/\n/g, " ")).replace(/\u0002/g, "<mark>").replace(/\u0003/g, "</mark>");
}
async function copyText(text, what) {
  try {
    await navigator.clipboard.writeText(text);
    toast({ text: (what || "Text") + " copied." });
  } catch (e) {
    toast({ text: "Could not copy: " + errText(e), warning: true });
  }
}
function resumeCommandFor(file) {
  return (file.cwd ? 'cd "' + file.cwd + '" && ' : "") + "claude --resume " + file.cliSessionId;
}

const ICONS = {
  sessions: '<path d="M8 6h12M8 12h12M8 18h12"/><circle cx="4" cy="6" r="1"/><circle cx="4" cy="12" r="1"/><circle cx="4" cy="18" r="1"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
  accounts: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.6-3.6 3.3-5.5 6.5-5.5s5.9 1.9 6.5 5.5"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8M18 14.8c2 .8 3.2 2.5 3.5 5.2"/>',
  sync: '<path d="M20 11a8 8 0 0 0-14.5-4.5L4 8"/><path d="M4 4v4h4"/><path d="M4 13a8 8 0 0 0 14.5 4.5L20 16"/><path d="M20 20v-4h-4"/>',
  backups: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9"/><path d="M10 13h4"/>',
  add: '<path d="M12 4v11"/><path d="m7.5 10.5 4.5 4.5 4.5-4.5"/><path d="M4 19h16"/>',
  restore: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
  archive: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9"/><path d="M10 13h4"/>',
  pin: '<path d="M9 3h6l-1 6 4 4H6l4-4z"/><path d="M12 13v8"/>',
  pinFill: '<path d="M9 3h6l-1 6 4 4H6l4-4z" fill="currentColor"/><path d="M12 13v8"/>',
  rename: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="m13.5 6.5 4 4"/>',
  reload: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  details: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  warn: '<path d="M12 4 2.8 20h18.4z"/><path d="M12 10v4.5M12 17.3v.2"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.6v.2"/>',
  ok: '<circle cx="12" cy="12" r="9"/><path d="m8 12.3 2.8 2.8L16.5 9.5"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  chevron: '<path d="m9 6 6 6-6 6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  open: '<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
};
const icon = (name, cls) => '<svg class="i ' + (cls || "") + '" viewBox="0 0 24 24" aria-hidden="true">' + ICONS[name] + "</svg>";

// ---------------------------------------------------------------- state

const S = {
  view: "sessions",
  app: null,
  sess: null,
  loadError: null,
  steps: [],
  stepsFor: null, // "plan" or "account": which progress the last steps belong to
  pending: new Map(), // record key -> edit
  // sessions
  filter: "all",
  folder: "all-live",
  query: "",
  sort: { key: "lastActivity", dir: -1 },
  selected: new Set(),
  anchor: null,
  details: false,
  // search
  search: { query: "", role: "any", order: "relevance", orphans: false, groups: [], selected: null, elapsed: 0, error: null, ran: false },
  // backups
  backups: [],
  openBackup: null,
  modal: null,
};

const VIEWS = [
  ["sessions", "Sessions", "sessions"],
  ["search", "Search", "search"],
  ["accounts", "Accounts", "accounts"],
  ["sync", "Sync chats", "sync"],
  ["backups", "Backups", "backups"],
];

const $view = document.getElementById("view");
const $modal = document.getElementById("modalRoot");
const $toast = document.getElementById("toastRoot");

// ---------------------------------------------------------------- toast

function toast({ title, text, warning }) {
  const norm = (x) => String(x || "").replace(/[.\s]+$/, "").trim();
  if (title && norm(title) === norm(text)) title = null;
  const el = document.createElement("div");
  el.className = "toast" + (warning ? " warning" : "");
  el.setAttribute("role", "status");
  el.innerHTML = '<span class="t-icon">' + icon(warning ? "warn" : "ok") + '</span><div class="grow" dir="auto">'
    + (title ? '<div class="t-title">' + esc(title) + "</div>" : "")
    + '<div class="' + (title ? "t-text" : "") + '">' + esc(text) + "</div></div>"
    + '<button class="icon-btn" style="height:22px;min-width:22px;padding:0" aria-label="Dismiss">' + icon("x") + "</button>";
  const close = () => el.remove();
  el.querySelector("button").onclick = close;
  $toast.appendChild(el);
  while ($toast.children.length > 3) $toast.firstChild.remove();
  setTimeout(close, warning ? 10000 : 6000);
}

// ---------------------------------------------------------------- data

async function loadState() {
  try {
    S.app = await invoke("get_state");
    if (S.app.steps && S.app.steps.length) S.steps = S.app.steps;
  } catch (e) {
    S.loadError = errText(e);
  }
}
async function loadSessions() {
  try {
    S.sess = await invoke("list_sessions");
    S.loadError = null;
    // Drop pending edits whose chat vanished.
    const keys = new Set(S.sess.sessions.map((s) => s.key));
    for (const k of [...S.pending.keys()]) if (!keys.has(k)) S.pending.delete(k);
  } catch (e) {
    S.loadError = errText(e);
  }
}
async function loadBackups() {
  try { S.backups = await invoke("list_backups"); } catch (e) { toast({ title: "Could not list backups", text: errText(e), warning: true }); }
}

async function refresh(sessionsToo) {
  await Promise.all([loadState(), sessionsToo ? loadSessions() : null]);
  if (S.view === "backups") await loadBackups();
  renderNav();
  renderView();
  if (S.modal && S.modal.type === "plan") renderModal();
}

function activeAccount() {
  return S.app && S.app.accounts.find((a) => a.isActive);
}
function accountTitle(id) {
  const a = S.app && S.app.accounts.find((x) => x.id === id);
  return a ? a.title : id ? id.slice(0, 8) : "";
}

// ---------------------------------------------------------------- nav

function renderNav() {
  const items = document.getElementById("navItems");
  items.innerHTML = VIEWS.map(([id, label, ic]) => {
    let badge = "";
    if (id === "sessions" && S.pending.size) badge = '<span class="badge accent">' + pendingChatCount() + "</span>";
    if (id === "accounts" && S.app && S.app.switching) badge = '<span class="spinner"></span>';
    return '<button class="nav-item' + (S.view === id ? " active" : "") + '" data-nav="' + id + '"' + (S.view === id ? ' aria-current="page"' : "") + ">"
      + icon(ic) + "<span>" + label + "</span>" + badge + "</button>";
  }).join("");
  const f = document.getElementById("navFooter");
  if (!S.app) { f.innerHTML = ""; return; }
  const idx = S.app.index;
  let html = '<div class="row"><span class="dot' + (S.app.claudeRunning ? " on" : "") + '"></span>'
    + (S.app.claudeRunning ? "Claude is running" : "Claude is not running") + "</div>";
  if (S.app.switching) html += '<div class="row"><span class="dot busy"></span><span>Switching: ' + esc(S.steps[S.steps.length - 1] || "starting") + "</span></div>";
  if (idx.running) html += '<div class="progress" style="width:100%"><div style="width:' + Math.round(idx.fraction * 100) + '%"></div></div>';
  html += '<div class="faint">' + esc(idx.status) + "</div>";
  f.innerHTML = html;
}

document.getElementById("navItems").addEventListener("click", (e) => {
  const b = e.target.closest("[data-nav]");
  if (b) go(b.dataset.nav);
});

async function go(view) {
  if (!VIEWS.some((v) => v[0] === view)) return;
  S.view = view;
  if (view === "backups") await loadBackups();
  renderNav();
  renderView();
  if (view === "search") setTimeout(() => { const i = document.getElementById("searchInput"); if (i) i.focus(); }, 0);
}

// ---------------------------------------------------------------- view rendering

function renderView() {
  const active = document.activeElement;
  const focusId = active && active.id && $view.contains(active) ? active.id : null;
  const sel = focusId && typeof active.selectionStart === "number" ? [active.selectionStart, active.selectionEnd] : null;
  const scrolls = {};
  $view.querySelectorAll("[data-keep-scroll]").forEach((el) => { scrolls[el.dataset.keepScroll] = el.scrollTop; });
  const openMenus = [...$view.querySelectorAll("details[data-keep-open][open]")].map((d) => d.dataset.keepOpen);

  if (!S.app || (!S.sess && S.view === "sessions")) {
    $view.innerHTML = S.loadError
      ? '<div class="placeholder">' + icon("warn") + "<div>Could not read Claude's files.</div><div class=\"err\">" + esc(S.loadError) + "</div></div>"
      : '<div class="placeholder"><div class="spinner"></div><div>Reading your chats</div></div>';
    return;
  }
  const html = { sessions: viewSessions, search: viewSearch, accounts: viewAccounts, sync: viewSync, backups: viewBackups }[S.view]();
  $view.innerHTML = html;

  $view.querySelectorAll("[data-keep-scroll]").forEach((el) => { if (scrolls[el.dataset.keepScroll]) el.scrollTop = scrolls[el.dataset.keepScroll]; });
  openMenus.forEach((k) => { const d = $view.querySelector('details[data-keep-open="' + k + '"]'); if (d) d.open = true; });
  if (focusId) {
    const el = document.getElementById(focusId);
    if (el) {
      el.focus();
      if (sel && typeof el.setSelectionRange === "function") try { el.setSelectionRange(sel[0], sel[1]); } catch (e) { /* not a text field */ }
    }
  }
}

// ---------------------------------------------------------------- sessions

function folderMap() {
  const m = {};
  for (const f of S.sess.folders) m[f.id] = f;
  return m;
}

/** Chats grouped into rows, with the filters applied and sorted. */
function sessionRows() {
  const folders = folderMap();
  const active = S.sess.activeAccountId;
  const live = (r) => !(folders[r.folderId] || {}).isBackupCopy;
  const have = new Set(S.sess.sessions.filter((s) => s.accountId === active && live(s)).map((s) => s.sessionId));
  const canTake = !!active && S.sess.folders.some((f) => f.accountId === active && !f.isBackupCopy);
  const byChat = new Map();
  for (const s of S.sess.sessions) {
    const f = folders[s.folderId];
    if (!f) continue;
    if (S.folder === "all-live" && f.isBackupCopy) continue;
    if (S.folder !== "all-live" && S.folder !== "all" && s.folderId !== S.folder) continue;
    let list = byChat.get(s.sessionId);
    if (!list) byChat.set(s.sessionId, (list = []));
    list.push(s);
  }
  const q = S.query.trim().toLowerCase();
  const rows = [];
  for (const [sid, copies] of byChat) {
    const primary = copies.find((c) => c.accountId === active && live(c))
      || copies.reduce((a, b) => ((b.lastActivity || b.fileMTime) > (a.lastActivity || a.fileMTime) ? b : a));
    const labels = copies.map((c) => (folders[c.folderId] || {}).label || c.folderId).sort();
    const accountKeys = new Set(copies.map((c) => ((folders[c.folderId] || {}).isBackupCopy ? c.folderId : c.accountId)));
    const edit = S.pending.get(primary.key);
    const inSignedIn = have.has(sid);
    const row = {
      id: sid,
      rec: primary,
      copies,
      labels,
      accountCount: accountKeys.size,
      title: edit && edit.title != null ? edit.title : primary.title,
      isArchived: edit && edit.isArchived != null ? edit.isArchived : primary.isArchived,
      isStarred: edit && edit.isStarred != null ? edit.isStarred : primary.isStarred,
      hasPending: copies.some((c) => S.pending.has(c.key)),
      inSignedIn,
      pullable: !inSignedIn && canTake,
      lastActivity: Math.max(...copies.map((c) => c.lastActivity || c.fileMTime || 0)),
      project: project(primary.cwd),
      problems: [...new Set(copies.flatMap((c) => c.problems || []))],
    };
    row.accountsText = row.accountCount === 1 ? labels[0] : row.accountCount + " accounts";
    switch (S.filter) {
      case "active": if (row.isArchived) continue; break;
      case "archived": if (!row.isArchived) continue; break;
      case "pinned": if (!row.isStarred) continue; break;
      case "elsewhere": if (!row.pullable) continue; break;
      case "pending": if (!row.hasPending) continue; break;
    }
    if (q) {
      const hay = (row.title + " " + primary.cwd + " " + sid + " " + (primary.cliSessionId || "") + " " + labels.join(" ")).toLowerCase();
      if (!hay.includes(q)) continue;
    }
    rows.push(row);
  }
  const { key, dir } = S.sort;
  const val = (r) => {
    switch (key) {
      case "title": return r.title.toLowerCase();
      case "project": return r.project.toLowerCase();
      case "here": return r.inSignedIn ? 0 : r.pullable ? 1 : 2;
      case "accounts": return r.accountsText.toLowerCase();
      case "archived": return r.isArchived ? 1 : 0;
      case "pinned": return r.isStarred ? 1 : 0;
      default: return r.lastActivity;
    }
  };
  rows.sort((a, b) => {
    const x = val(a), y = val(b);
    if (x < y) return -dir;
    if (x > y) return dir;
    return b.lastActivity - a.lastActivity;
  });
  return rows;
}

/** Copies a change goes to: the live ones, or the backup copies for a chat that only exists there. */
function editTargets(rows) {
  const folders = folderMap();
  return rows.flatMap((r) => {
    const live = r.copies.filter((c) => !(folders[c.folderId] || {}).isBackupCopy);
    return live.length ? live : r.copies;
  });
}

function pendingChatCount() {
  return new Set([...S.pending.values()].map((e) => e.sessionId)).size;
}

/** Queue a change for these copies. Changes that end up matching the file are dropped. */
function queue(records, change) {
  for (const r of records) {
    const e = Object.assign({ folderId: r.folderId, sessionId: r.sessionId }, S.pending.get(r.key) || {});
    if (change.title) {
      const t = change.title(r);
      if (t != null) e.title = t;
    }
    if (change.archived !== undefined) {
      e.isArchived = change.archived;
      if (change.archived && (e.isStarred != null ? e.isStarred : r.isStarred)) e.isStarred = false;
    }
    if (change.starred !== undefined) {
      e.isStarred = change.starred;
      if (change.starred && (e.isArchived != null ? e.isArchived : r.isArchived)) e.isArchived = false;
    }
    if (e.title === r.title) delete e.title;
    if (e.isArchived === r.isArchived && r.isArchived === r.inArchivedIndex) delete e.isArchived;
    if (e.isStarred === r.isStarred) delete e.isStarred;
    if (e.title == null && e.isArchived == null && e.isStarred == null) S.pending.delete(r.key);
    else S.pending.set(r.key, e);
  }
  renderNav();
  renderView();
}

const FILTERS = [["all", "All"], ["active", "Active"], ["archived", "Archived"], ["pinned", "Pinned"], ["elsewhere", "Not in this account"], ["pending", "Changed"]];
const COLS = [
  ["title", "Title", "c-title"],
  ["project", "Project", "c-proj"],
  ["here", "Signed-in account", "c-here"],
  ["accounts", "Accounts", "c-accts"],
  ["archived", "Archived", "c-arch"],
  ["pinned", "Pinned", "c-pin"],
  ["lastActivity", "Last activity", "c-date"],
];

function viewSessions() {
  const rows = sessionRows();
  S._rows = rows;
  const visible = new Set(rows.map((r) => r.id));
  for (const id of [...S.selected]) if (!visible.has(id)) S.selected.delete(id);
  const sel = rows.filter((r) => S.selected.has(r.id));
  const anyArchived = sel.some((r) => r.isArchived);
  const anyPull = sel.some((r) => r.pullable);
  const allSelected = rows.length > 0 && sel.length === rows.length;

  let html = '<header class="view-head"><h1>Sessions</h1><div class="grow"></div><div class="toolbar">'
    + tb("pull-selected", "add", "Add to This Account", "Copy the selected chats into the signed-in account so Claude can open them", !anyPull, true)
    + '<span class="sep"></span>'
    + tb("restore", "restore", "Restore", "Restore the selected archived chats", !anyArchived)
    + tb("archive", "archive", "Archive", "Archive the selected chats in every account that has them", !sel.length)
    + tb("pin", "pin", sel.length && sel.every((r) => r.isStarred) ? "Unpin" : "Pin", "Pin or unpin the selected chats", !sel.length)
    + tb("rename", "rename", "Rename", "Rename the selected chats", !sel.length)
    + '<span class="sep"></span>'
    + tb("reload", "reload", "", "Read the session files again", false)
    + '<button class="icon-btn' + (S.details ? " on" : "") + '" data-action="toggle-details" title="Show details of the selected chat" aria-label="Details" aria-pressed="' + S.details + '">' + icon("details") + "</button>"
    + "</div>"
    + '<div class="search-box">' + icon("search") + '<input id="sessFilter" type="search" placeholder="Filter by title, project, account or id" aria-label="Filter chats" value="' + esc(S.query) + '"></div>'
    + "</header>";

  html += '<div class="filters"><div class="segmented" role="tablist" aria-label="Show">'
    + FILTERS.map(([k, l]) => '<button role="tab" aria-selected="' + (S.filter === k) + '" class="' + (S.filter === k ? "on" : "") + '" data-filter="' + k + '"'
      + (k === "elsewhere" ? ' title="Chats the signed-in account does not have, so Claude cannot open them yet"' : "") + ">" + l + "</button>").join("")
    + "</div>"
    + '<select id="folderSel" aria-label="Account folder" title="Pick one account folder to see and change only its copies">'
    + opt("all-live", "All accounts", S.folder) + opt("all", "All, including backup copies", S.folder)
    + '<option disabled>──────────</option>'
    + S.sess.folders.map((f) => opt(f.id, f.label + " (" + f.count + ")", S.folder)).join("")
    + "</select>"
    + '<span class="count">' + plural(rows.length, "chat") + (sel.length ? ", " + sel.length + " selected" : "") + "</span></div>";

  html += '<div class="sess-body"><div class="table-wrap" data-keep-scroll="sessions"><table class="grid" role="grid" aria-multiselectable="true"><thead><tr>'
    + '<th class="c-check"><input type="checkbox" class="cb" data-action="select-all" aria-label="Select all"' + (allSelected ? " checked" : "") + "></th>"
    + COLS.map(([k, l, c]) => '<th class="sortable ' + c + '" data-sort="' + k + '" aria-sort="' + (S.sort.key === k ? (S.sort.dir > 0 ? "ascending" : "descending") : "none") + '">'
      + (k === "here" ? '<span class="lbl-long">' + l + '</span><span class="lbl-short" title="' + l + '">Here</span>' : l) + (S.sort.key === k ? '<span class="arrow">' + (S.sort.dir > 0 ? "▲" : "▼") + "</span>" : "") + "</th>").join("")
    + "</tr></thead><tbody>";
  if (!rows.length) {
    html += '<tr><td colspan="8"><div class="empty">' + (S.query || S.filter !== "all" ? "No chats match." : "No chats found yet.") + "</div></td></tr>";
  }
  const parts = [];
  for (const r of rows) {
    const s = S.selected.has(r.id);
    parts.push('<tr data-id="' + esc(r.id) + '"' + (s ? ' class="sel" aria-selected="true"' : "") + ">"
      + '<td class="c-check"><input type="checkbox" class="cb" data-check' + (s ? " checked" : "") + ' aria-label="Select"></td>'
      + '<td class="c-title"><div class="t-title">' + (r.hasPending ? '<span class="pdot" title="Changed, not applied yet"></span>' : "")
      + '<span class="txt' + (r.hasPending ? " pending" : "") + '" dir="auto" title="' + esc(r.title) + '">' + esc(r.title) + "</span>"
      + (r.problems.length ? '<span class="warn" title="' + esc(r.problems.join("\n")) + '">' + icon("warn") + "</span>" : "") + "</div></td>"
      + '<td class="c-proj muted" title="' + esc(r.rec.cwd) + '">' + esc(r.project) + "</td>"
      + '<td class="c-here">' + (r.inSignedIn
        ? '<span class="here" title="The signed-in account has this chat, so Claude can open it"><span class="dot"></span><span class="lbl-long">Here</span></span>'
        : r.pullable ? '<button class="btn sm" data-action="pull-row" title="Copy this chat into the signed-in account so Claude can open it"><span class="lbl-long">Add to This Account</span><span class="lbl-short">Add</span></button>' : "")
      + "</td>"
      + '<td class="c-accts muted" title="' + esc(r.labels.join("\n")) + '">' + esc(r.accountsText) + "</td>"
      + '<td class="c-arch">' + (r.isArchived ? '<span class="cell-icon" title="Archived">' + icon("archive") + "</span>" : "") + "</td>"
      + '<td class="c-pin">' + (r.isStarred ? '<span class="cell-icon pin" title="Pinned">' + icon("pinFill") + "</span>" : "") + "</td>"
      + '<td class="c-date muted">' + esc(fmtDate(r.lastActivity)) + "</td></tr>");
  }
  html += parts.join("") + "</tbody></table></div>";
  if (S.details) html += detailsPanel(sel.length === 1 ? sel[0] : null);
  html += "</div>";

  if (S.pending.size) {
    const n = pendingChatCount();
    html += '<div class="pending-bar">' + icon("edit") + '<span class="grow">' + plural(n, "chat") + " changed, not written yet.</span>"
      + '<button class="btn" data-action="discard">Discard</button><button class="btn primary" data-action="review">Review and Apply...</button></div>';
  }
  return html;
}

function tb(action, ic, label, help, disabled, primaryish) {
  return '<button class="icon-btn" data-action="' + action + '" title="' + esc(help) + '" aria-label="' + esc(label || help) + '"' + (disabled ? " disabled" : "") + ">"
    + icon(ic) + (label && primaryish ? "<span>" + esc(label) + "</span>" : "") + "</button>";
}
function opt(value, label, current) {
  return '<option value="' + esc(value) + '"' + (value === current ? " selected" : "") + ">" + esc(label) + "</option>";
}

function detailsPanel(row) {
  if (!row) return '<aside class="details"><div class="placeholder" style="padding:10px">Select one chat to see its details.</div></aside>';
  const r = row.rec, folders = folderMap();
  let h = '<aside class="details" data-id="' + esc(row.id) + '"><h3 dir="auto">' + esc(row.title) + "</h3>"
    + '<div class="row wrap">'
    + (row.inSignedIn || !row.pullable
      ? '<button class="btn primary sm" data-action="open-row">' + icon("open") + "Open in Claude</button>"
      : '<button class="btn primary sm" data-action="open-row">' + icon("add") + "Add and Open</button>")
    + (r.resumeCommand ? '<button class="btn sm" data-action="copy-resume">' + icon("copy") + "Copy Resume</button>" : "")
    + "</div>";
  h += '<div class="group"><div class="group-title">' + (row.copies.length === 1 ? "Account" : "In " + row.accountCount + " accounts") + "</div>";
  for (const c of row.copies) {
    h += '<div class="row small"><span class="grow" dir="auto">' + esc((folders[c.folderId] || {}).label || c.folderId) + "</span>"
      + (c.isArchived ? '<span class="cell-icon" title="Archived in this account">' + icon("archive") + "</span>" : "")
      + (c.isStarred ? '<span class="cell-icon pin" title="Pinned in this account">' + icon("pinFill") + "</span>" : "") + "</div>";
  }
  h += "</div>";
  h += '<div class="group"><div class="group-title">Shown copy</div><div class="kv">'
    + kv("Project", r.cwd)
    + '<div class="k">File</div><div class="v"><button class="link" data-action="reveal" data-path="' + esc(r.file) + '">' + esc(r.file.split(/[\\/]/).pop()) + "</button></div>"
    + kv("Size", Math.max(1, Math.round(r.fileSize / 1024)) + " KB")
    + kv("Archived", r.isArchived ? "yes" : "no")
    + kv("In archived list", r.inArchivedIndex ? "yes" : "no")
    + kv("Pinned", r.isStarred ? "yes" : "no")
    + kv("Title source", r.titleSource || "-")
    + (r.model ? kv("Model", r.model) : "")
    + "</div></div>";
  h += '<div class="group"><div class="group-title">IDs</div><div class="kv">' + kv("Session", r.sessionId) + kv("CLI session", r.cliSessionId || "missing") + "</div></div>";
  h += '<div class="group"><div class="group-title">Dates</div><div class="kv">'
    + (r.createdAt ? kv("Created", fmtDate(r.createdAt)) : "") + kv("Last activity", fmtDate(row.lastActivity)) + kv("File modified", fmtDate(r.fileMTime)) + "</div></div>";
  if (row.problems.length) h += '<div class="group"><div class="group-title">Schema guard</div>' + row.problems.map((p) => '<div class="warn small">' + esc(p) + "</div>").join("") + "</div>";
  return h + "</aside>";
}
function kv(k, v) {
  return '<div class="k">' + esc(k) + '</div><div class="v" dir="auto">' + esc(v) + "</div>";
}

function rowById(id) {
  return (S._rows || []).find((r) => r.id === id);
}

function noteForPull(row) {
  const folders = folderMap();
  const who = (activeAccount() || {}).title || "the signed-in account";
  const where = (folders[row.rec.folderId] || {}).label || "another account";
  return quoted(row.title) + " is in " + where + ". Claude is signed in to " + who + ", so it cannot open it until it is added to " + who + ".";
}

async function openRow(row) {
  if (!row) return;
  if (!row.inSignedIn && row.pullable) {
    await preview("preview_pull", { items: row.copies.map((c) => ({ folderId: c.folderId, sessionId: c.sessionId })), openAfter: row.id, note: noteForPull(row) });
    return;
  }
  try {
    await invoke("open_chat", { sessionId: row.id });
    if (row.isArchived) toast({ text: quoted(row.title) + " is archived. It opens, but stays out of Claude's sidebar until you restore it." });
  } catch (e) {
    toast({ title: "Could not open the chat", text: errText(e), warning: true });
  }
}

$view.addEventListener("input", (e) => {
  if (e.target.id === "sessFilter") {
    S.query = e.target.value;
    renderView();
  } else if (e.target.id === "searchInput") {
    S.search.query = e.target.value;
    scheduleSearch();
  }
});

$view.addEventListener("change", (e) => {
  const t = e.target;
  if (t.id === "folderSel") { S.folder = t.value; S.selected.clear(); renderView(); return; }
  if (t.id === "roleSel") { S.search.role = t.value; runSearch(); return; }
  if (t.id === "orderSel") { S.search.order = t.value; runSearch(); return; }
  if (t.id === "orphansCb") { S.search.orphans = t.checked; renderView(); return; }
  if (t.dataset.setting) { changeSetting(t); return; }
  if (t.dataset.syncAccount) { toggleSyncAccount(t.dataset.syncAccount, t.checked); return; }
  if (t.name === "syncHow") { setSettings({ syncSource: t.value }); return; }
});

$view.addEventListener("click", (e) => {
  const t = e.target;
  const action = t.closest("[data-action]");
  const navTo = t.closest("[data-go]");
  if (navTo) { go(navTo.dataset.go); return; }
  if (S.view === "sessions") {
    if (handleSessionsClick(e, t, action)) return;
  }
  if (!action) return;
  const a = action.dataset.action;
  switch (a) {
    // search
    case "pick-result": S.search.selected = Number(action.dataset.id); renderView(); break;
    case "index-now": invoke("index_now").catch((err) => toast({ title: "Could not update the index", text: errText(err), warning: true })); break;
    case "index-stop": invoke("cancel_index").catch(() => {}); break;
    case "result-open": resultOpen(); break;
    case "result-copy": { const g = selectedGroup(); if (g) copyText(resumeCommandFor(g.file), "Resume command"); break; }
    // accounts
    case "acct-activate": activate(action.dataset.id); break;
    case "acct-save": saveLogin(action.dataset.id); break;
    case "acct-rename": renameProfile(action.dataset.id); break;
    case "acct-forget": forgetProfile(action.dataset.id); break;
    case "add-account": addAccount(); break;
    // sync
    case "sync-preview": preview("preview_sync", {}); break;
    // backups
    case "backup-now": backupNow(); break;
    case "backup-folder": reveal(S.app.paths.backups); break;
    case "backup-show": reveal(action.dataset.path); break;
    case "backup-toggle": S.openBackup = S.openBackup === action.dataset.id ? null : action.dataset.id; renderView(); break;
    case "backup-restore": preview("preview_restore", { backupId: action.dataset.id }); break;
    case "reveal": reveal(action.dataset.path); break;
  }
});

function handleSessionsClick(e, t, action) {
  const th = t.closest("th[data-sort]");
  if (th) {
    const k = th.dataset.sort;
    S.sort = S.sort.key === k ? { key: k, dir: -S.sort.dir } : { key: k, dir: k === "lastActivity" ? -1 : 1 };
    renderView();
    return true;
  }
  const filter = t.closest("[data-filter]");
  if (filter) { S.filter = filter.dataset.filter; renderView(); return true; }
  const tr = t.closest("tbody tr[data-id]");
  const rows = S._rows || [];
  const sel = rows.filter((r) => S.selected.has(r.id));
  if (action) {
    const a = action.dataset.action;
    switch (a) {
      case "pull-row": {
        const row = rowById(tr.dataset.id);
        if (row) preview("preview_pull", { items: row.copies.map((c) => ({ folderId: c.folderId, sessionId: c.sessionId })) });
        return true;
      }
      case "select-all":
        if (action.checked) rows.forEach((r) => S.selected.add(r.id)); else S.selected.clear();
        renderView();
        return true;
      case "pull-selected":
        preview("preview_pull", { items: sel.filter((r) => r.pullable).flatMap((r) => r.copies.map((c) => ({ folderId: c.folderId, sessionId: c.sessionId }))) });
        return true;
      case "restore": queue(editTargets(sel), { archived: false }); return true;
      case "archive": queue(editTargets(sel), { archived: true }); return true;
      case "pin": queue(editTargets(sel), { starred: sel.some((r) => !r.isStarred) }); return true;
      case "rename": openRename(sel); return true;
      case "reload": refresh(true); return true;
      case "toggle-details": S.details = !S.details; renderView(); return true;
      case "discard": S.pending.clear(); renderNav(); renderView(); return true;
      case "review": preview("preview_edits", { edits: [...S.pending.values()] }, { fromEdits: true }); return true;
      case "open-row": { const id = t.closest("[data-id]").dataset.id; openRow(rowById(id)); return true; }
      case "copy-resume": { const row = rowById(t.closest("[data-id]").dataset.id); if (row && row.rec.resumeCommand) copyText(row.rec.resumeCommand, "Resume command"); return true; }
      case "reveal": reveal(action.dataset.path); return true;
    }
  }
  if (tr) {
    const id = tr.dataset.id;
    const isCheck = t.matches("input[data-check]");
    if (e.shiftKey && S.anchor) {
      const ids = rows.map((r) => r.id);
      const a = ids.indexOf(S.anchor), b = ids.indexOf(id);
      if (a >= 0 && b >= 0) {
        if (!(e.ctrlKey || e.metaKey || isCheck)) S.selected.clear();
        for (let i = Math.min(a, b); i <= Math.max(a, b); i++) S.selected.add(ids[i]);
      }
    } else if (e.ctrlKey || e.metaKey || isCheck) {
      if (S.selected.has(id)) S.selected.delete(id); else S.selected.add(id);
      S.anchor = id;
    } else {
      S.selected.clear();
      S.selected.add(id);
      S.anchor = id;
    }
    renderView();
    return true;
  }
  return false;
}

$view.addEventListener("dblclick", (e) => {
  if (S.view === "sessions") {
    const tr = e.target.closest("tbody tr[data-id]");
    if (tr && !e.target.closest("button, input")) openRow(rowById(tr.dataset.id));
  } else if (S.view === "search") {
    if (e.target.closest(".result")) resultOpen();
  }
});

// ---------------------------------------------------------------- rename

function openRename(rows) {
  if (!rows.length) return;
  S.modal = { type: "rename", rows, single: rows[0].title, find: "", replace: "", prefix: "" };
  renderModal();
  setTimeout(() => { const i = $modal.querySelector("input"); if (i) { i.focus(); i.select(); } }, 0);
}
function renameNew(m, row) {
  if (m.rows.length === 1) return m.single;
  let t = row.title;
  if (m.find) t = t.split(m.find).join(m.replace);
  if (m.prefix && !t.startsWith(m.prefix)) t = m.prefix + t;
  return t;
}
function modalRename(m) {
  let body = '<div class="dialog-body"><h2>' + (m.rows.length === 1 ? "Rename chat" : "Rename " + m.rows.length + " chats") + "</h2>";
  if (m.rows.length === 1) {
    body += '<input type="text" dir="auto" data-modal-field="single" value="' + esc(m.single) + '" aria-label="Title">';
  } else {
    body += '<div class="form-grid"><label>Find</label><input type="text" data-modal-field="find" placeholder="text to replace" value="' + esc(m.find) + '">'
      + '<label>Replace with</label><input type="text" data-modal-field="replace" value="' + esc(m.replace) + '">'
      + '<label>Add prefix</label><input type="text" data-modal-field="prefix" placeholder="optional" value="' + esc(m.prefix) + '"></div>'
      + '<div class="rename-list" data-rename-preview>' + renamePreview(m) + "</div>";
  }
  body += '<p class="small">Titles are written when you apply pending changes, to every account\'s copy of the chat. Renamed chats get titleSource "user" so Claude keeps the name.</p></div>';
  return '<div class="dialog mid" role="dialog" aria-modal="true" aria-label="Rename">' + body
    + '<div class="dialog-foot"><button class="btn" data-modal="cancel">Cancel</button><button class="btn primary" data-modal="ok" data-default>Rename</button></div></div>';
}
function renamePreview(m) {
  return m.rows.map((r) => {
    const t = renameNew(m, r);
    return '<div dir="auto">' + esc(t) + (t !== r.title ? '<div class="faint small">was: ' + esc(r.title) + "</div>" : "") + "</div>";
  }).join("");
}
function applyRename(m) {
  const titles = {};
  for (const r of m.rows) {
    const t = renameNew(m, r).trim();
    if (t) titles[r.id] = t;
  }
  queue(editTargets(m.rows), { title: (rec) => titles[rec.sessionId] });
}

// ---------------------------------------------------------------- plans

async function preview(cmd, args, extra) {
  try {
    const plan = await invoke(cmd, args);
    S.modal = Object.assign({ type: "plan", plan, state: "preview", result: null, error: null, steps: [] }, extra || {});
    renderModal();
  } catch (e) {
    toast({ title: "Could not prepare the preview", text: errText(e), warning: true });
  }
}

const KIND = {
  edit: ["edit", "edit", "k-accent"],
  update: ["sync", "update", "k-accent"],
  add: ["plus", "add", "k-green"],
  putBack: ["restore", "put back", "k-green"],
  removeDeleted: ["trash", "move out deleted", "k-orange"],
  moveOut: ["trash", "move out", "k-orange"],
  addMarker: ["minus", "deleted marker", "k-orange"],
  archivedIndex: ["archive", "archived list", "k-accent"],
};
const KIND_ORDER = ["edit", "update", "add", "putBack", "removeDeleted", "moveOut", "addMarker", "archivedIndex"];

function modalPlan(m) {
  const p = m.plan;
  const running = S.app && S.app.claudeRunning;
  let html = '<div class="dialog wide' + (m.state === "preview" ? "" : " compact") + '" role="dialog" aria-modal="true" aria-label="' + esc(p.title) + '">'
    + '<div class="plan-head"><h2 dir="auto">' + esc(p.title) + '</h2><div class="muted">' + esc(p.summary) + "</div>"
    + (m.note || p.note ? '<div class="warn" dir="auto">' + esc(m.note || p.note) + "</div>" : "") + "</div>";

  if (m.state === "preview") {
    html += '<div class="plan-list">';
    if (p.problems.length) {
      html += '<div class="plan-section"><h4 class="err">Schema guard: nothing will be written until these are fixed</h4></div>'
        + p.problems.map((x) => '<div class="problem">' + esc(x.message) + '<div class="p-path">' + esc(x.path) + "</div></div>").join("");
    }
    if (p.warnings.length) html += '<div class="plan-section"><h4>Warnings</h4></div>' + p.warnings.map((w) => '<div class="warning-box" dir="auto">' + esc(w) + "</div>").join("");
    if (!p.changes.length && !p.problems.length) html += '<div class="empty">Nothing to change. Everything already matches.</div>';
    const groups = new Map();
    for (const c of p.changes) {
      if (!groups.has(c.folderId)) groups.set(c.folderId, []);
      groups.get(c.folderId).push(c);
    }
    for (const [, list] of [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      list.sort((a, b) => (KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind)) || a.summary.localeCompare(b.summary));
      const counts = {};
      list.forEach((c) => { counts[c.kind] = (counts[c.kind] || 0) + 1; });
      const totals = KIND_ORDER.filter((k) => counts[k]).map((k) => (KIND[k] || [0, k])[1] + ": " + counts[k]).join(", ");
      html += '<div class="plan-section"><h4 dir="auto">' + esc(list[0].folderLabel) + ' <span class="faint" style="font-weight:400">' + esc(totals) + "</span></h4>";
      for (const c of list) {
        const k = KIND[c.kind] || ["info", c.kind, "k-accent"];
        html += '<div class="change"><span class="c-icon ' + k[2] + '" title="' + esc(k[1]) + '">' + icon(k[0]) + '</span><div class="grow"><div class="c-sum" dir="auto">'
          + esc(c.summary) + "</div>" + (c.detail ? '<div class="c-det" title="' + esc(c.detail) + '">' + esc(c.detail) + "</div>" : "") + "</div></div>";
      }
      html += "</div>";
    }
    html += "</div>";
    const applyLabel = (running ? "Quit Claude, Back Up and " : "Back Up and ") + (p.openAfter ? "Add" : "Apply");
    html += '<div class="dialog-foot"><div class="left">'
      + (p.openAfter ? '<button class="btn" data-modal="open-anyway" title="Claude most likely shows an empty or missing chat">Open Without Adding</button>' : "")
      + '</div><button class="btn" data-modal="cancel">Cancel</button><button class="btn primary" data-modal="apply" data-default' + (p.canApply ? "" : " disabled") + ">"
      + esc(applyLabel) + "</button></div>";
  } else if (m.state === "applying") {
    html += '<div class="result-box">' + stepsList(m.steps, true) + "</div>"
      + '<div class="dialog-foot"><span class="muted grow">Working. Do not reopen Claude yet.</span></div>';
  } else if (m.state === "done") {
    const r = m.result;
    html += '<div class="result-box"><div class="big-status ok">' + icon("ok") + "Done. Wrote " + plural(r.written, "file") + ", moved " + r.moved + " to the backup.</div>"
      + (r.reopened ? "<div>Claude was reopened.</div>" : (running ? "" : '<div class="muted">Claude was not running, so it was not started.</div>'))
      + (p.openAfter ? "<div>Opening the chat in Claude.</div>" : "")
      + '<div class="row small"><span class="muted grow" style="word-break:break-all">Backup: ' + esc(r.backupDir) + '</span><button class="btn sm" data-modal="show-backup">Show</button></div>'
      + (r.warnings || []).map((w) => '<div class="warning-box" style="margin:0">' + esc(w) + "</div>").join("")
      + "</div>"
      + '<div class="dialog-foot"><button class="btn primary" data-modal="close" data-default>Close</button></div>';
  } else if (m.state === "failed") {
    html += '<div class="result-box"><div class="big-status err">' + icon("warn") + '<span dir="auto">' + esc(m.error) + "</span></div>" + stepsList(m.steps, false) + "</div>"
      + '<div class="dialog-foot"><button class="btn primary" data-modal="close" data-default>Close</button></div>';
  }
  return html + "</div>";
}

function stepsList(steps, running) {
  if (!steps.length) return running ? '<div class="step current"><span class="spinner"></span>Starting</div>' : "";
  return '<div class="stack">' + steps.map((s, i) => {
    const cur = running && i === steps.length - 1;
    return '<div class="step' + (cur ? " current" : "") + '">' + (cur ? '<span class="spinner"></span>' : icon("check")) + '<span dir="auto">' + esc(s) + "</span></div>";
  }).join("") + "</div>";
}

async function applyPlan() {
  const m = S.modal;
  if (!m || m.type !== "plan") return;
  m.state = "applying";
  m.steps = [];
  S.steps = [];
  renderModal();
  try {
    const r = await invoke("apply_plan", { planId: m.plan.id });
    if (S.modal !== m) return;
    if (r.status === "planChanged") {
      m.plan = r.plan;
      m.state = "preview";
      m.note = "Claude changed some files while quitting, so the plan changed. Claude is still closed. Review the new list and apply again.";
    } else {
      m.state = "done";
      m.result = r;
      if (m.fromEdits) S.pending.clear();
    }
  } catch (e) {
    if (S.modal !== m) return;
    m.state = "failed";
    m.error = errText(e);
  }
  renderModal();
  refresh(true);
}

// ---------------------------------------------------------------- dialogs

function confirmDialog({ title, text, ok, danger }) {
  return new Promise((resolve) => {
    if (S.modal && S.modal.resolve) S.modal.resolve(false);
    S.modal = { type: "confirm", title, text, ok: ok || "OK", danger, resolve };
    renderModal();
  });
}
function promptDialog({ title, text, value, ok }) {
  return new Promise((resolve) => {
    if (S.modal && S.modal.resolve) S.modal.resolve(null);
    S.modal = { type: "prompt", title, text, value: value || "", ok: ok || "Save", resolve };
    renderModal();
    setTimeout(() => { const i = $modal.querySelector("input"); if (i) { i.focus(); i.select(); } }, 0);
  });
}

let modalSeq = 0;
function renderModal() {
  const m = S.modal;
  if (!m) { $modal.innerHTML = ""; delete $modal.dataset.uid; return; }
  let inner = "";
  if (m.type === "plan") inner = modalPlan(m);
  else if (m.type === "rename") inner = modalRename(m);
  else if (m.type === "confirm") {
    inner = '<div class="dialog" role="alertdialog" aria-modal="true" aria-label="' + esc(m.title) + '"><div class="dialog-body"><h2 dir="auto">' + esc(m.title) + '</h2><p dir="auto">' + esc(m.text) + "</p></div>"
      + '<div class="dialog-foot"><button class="btn" data-modal="cancel">Cancel</button><button class="btn primary' + '" data-modal="ok" data-default>' + esc(m.ok) + "</button></div></div>";
  } else if (m.type === "prompt") {
    inner = '<div class="dialog" role="dialog" aria-modal="true" aria-label="' + esc(m.title) + '"><div class="dialog-body"><h2>' + esc(m.title) + "</h2>"
      + (m.text ? '<p dir="auto">' + esc(m.text) + "</p>" : "") + '<input type="text" dir="auto" data-modal-field="value" value="' + esc(m.value) + '"></div>'
      + '<div class="dialog-foot"><button class="btn" data-modal="cancel">Cancel</button><button class="btn primary" data-modal="ok" data-default>' + esc(m.ok) + "</button></div></div>";
  }
  const scroll = $modal.querySelector(".plan-list");
  const top = scroll ? scroll.scrollTop : 0;
  // Animate only when a dialog first opens, not on every progress update.
  if (!m._uid) m._uid = ++modalSeq;
  const again = $modal.dataset.uid === String(m._uid);
  $modal.dataset.uid = String(m._uid);
  $modal.innerHTML = '<div class="backdrop' + (again ? " static" : "") + '">' + inner + "</div>";
  const s2 = $modal.querySelector(".plan-list");
  if (s2) s2.scrollTop = top;
}

function closeModal(result) {
  const m = S.modal;
  if (!m) return;
  if (m.type === "plan" && m.state === "applying") return;
  if (m.type === "plan" && m.state === "preview") invoke("discard_plan", { planId: m.plan.id }).catch(() => {});
  S.modal = null;
  renderModal();
  if (m.resolve) m.resolve(result);
}

$modal.addEventListener("input", (e) => {
  const f = e.target.dataset.modalField;
  if (!f || !S.modal) return;
  S.modal[f] = e.target.value;
  if (S.modal.type === "rename") {
    const list = $modal.querySelector("[data-rename-preview]");
    if (list) list.innerHTML = renamePreview(S.modal);
  }
});

$modal.addEventListener("click", (e) => {
  const b = e.target.closest("[data-modal]");
  if (!b) return;
  const m = S.modal;
  if (!m) return;
  switch (b.dataset.modal) {
    case "cancel": closeModal(m.type === "prompt" ? null : false); break;
    case "close": closeModal(); break;
    case "ok":
      if (m.type === "rename") { S.modal = null; renderModal(); applyRename(m); }
      else if (m.type === "prompt") { S.modal = null; renderModal(); m.resolve(m.value); }
      else { S.modal = null; renderModal(); m.resolve(true); }
      break;
    case "apply": applyPlan(); break;
    case "open-anyway": {
      const id = m.plan.openAfter;
      closeModal();
      invoke("open_chat", { sessionId: id }).catch((err) => toast({ title: "Could not open the chat", text: errText(err), warning: true }));
      break;
    }
    case "show-backup": if (m.result) reveal(m.result.backupDir); break;
  }
});

// A click outside an open menu closes it.
document.addEventListener("click", (e) => {
  document.querySelectorAll("details.menu[open]").forEach((d) => { if (!d.contains(e.target)) d.open = false; });
});

document.addEventListener("keydown", (e) => {
  if (S.modal) {
    if (e.key === "Escape") { e.preventDefault(); closeModal(S.modal.type === "prompt" ? null : false); }
    else if (e.key === "Enter" && e.target.tagName !== "TEXTAREA" && e.target.tagName !== "BUTTON") {
      const d = $modal.querySelector("[data-default]:not(:disabled)");
      if (d) { e.preventDefault(); d.click(); }
    }
    return;
  }
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f") {
    const el = document.getElementById(S.view === "search" ? "searchInput" : "sessFilter");
    if (el) { e.preventDefault(); el.focus(); el.select(); }
  } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "a" && S.view === "sessions" && !/INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) {
    e.preventDefault();
    (S._rows || []).forEach((r) => S.selected.add(r.id));
    renderView();
  } else if (e.key === "Enter" && S.view === "sessions" && !/INPUT|TEXTAREA|SELECT|BUTTON/.test(e.target.tagName) && S.selected.size === 1) {
    openRow(rowById([...S.selected][0]));
  }
});

// ---------------------------------------------------------------- search

let searchTimer = null, searchSeq = 0;
function scheduleSearch() {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(runSearch, 180);
}
async function runSearch() {
  const s = S.search, seq = ++searchSeq;
  if (!s.query.trim()) {
    s.groups = []; s.selected = null; s.error = null; s.ran = false;
    renderView();
    return;
  }
  try {
    const r = await invoke("search", { query: s.query, role: s.role, order: s.order });
    if (seq !== searchSeq) return;
    s.groups = r.groups;
    s.elapsed = r.elapsedMs;
    s.error = null;
    s.ran = true;
    if (s.selected != null && !s.groups.some((g) => g.file.id === s.selected)) s.selected = null;
  } catch (e) {
    if (seq !== searchSeq) return;
    s.error = "Search failed: " + errText(e);
  }
  renderView();
}
function selectedGroup() {
  return S.search.groups.find((g) => g.file.id === S.search.selected);
}
function groupTitle(g) {
  return g.file.title || g.file.firstPrompt || g.file.cliSessionId;
}

function viewSearch() {
  const s = S.search, idx = S.app.index;
  const shown = s.orphans ? s.groups.filter((g) => !g.session) : s.groups;
  let html = '<header class="view-head"><h1>Search</h1></header>'
    + '<div class="search-top"><div class="search-box">' + icon("search")
    + '<input id="searchInput" type="search" placeholder="Search your chats. Words must all match, &quot;quotes&quot; for a phrase." aria-label="Search your chats" value="' + esc(s.query) + '"></div>'
    + '<select id="roleSel" aria-label="Who said it">' + opt("any", "Everyone", s.role) + opt("user", "Me", s.role) + opt("assistant", "Claude", s.role)
    + (idx.includeTools ? opt("tool", "Tools", s.role) : "") + "</select>"
    + '<select id="orderSel" aria-label="Order">' + opt("relevance", "Best match", s.order) + opt("newest", "Newest", s.order) + "</select>"
    + '<label class="row small" title="Only chats that have no sidebar entry in any account"><input type="checkbox" class="cb" id="orphansCb"' + (s.orphans ? " checked" : "") + ">No sidebar entry</label></div>";

  html += '<div class="index-bar">' + (idx.running ? '<div class="progress"><div style="width:' + Math.round(idx.fraction * 100) + '%"></div></div>' : "")
    + "<span>" + esc(idx.status) + '</span><span class="grow"></span>'
    + '<details class="menu" data-keep-open="indexopts"><summary class="btn sm">' + icon("sliders") + "Index options</summary><div class=\"menu-pop\">"
    + '<label><input type="checkbox" class="cb" data-setting="includeTools"' + (idx.includeTools ? " checked" : "") + ">Include tool calls and output</label>"
    + '<label><input type="checkbox" class="cb" data-setting="includeSubagents"' + (idx.includeSubagents ? " checked" : "") + ">Include subagent and workflow chats</label>"
    + '<div class="faint small">Changing these rebuilds the index. With both on, the first build reads every transcript and can take minutes, and the index gets much larger.</div>'
    + "</div></details>"
    + (idx.running ? '<button class="btn sm" data-action="index-stop">' + icon("stop") + "Stop</button>" : '<button class="btn sm" data-action="index-now">' + icon("reload") + "Update Now</button>")
    + "</div>";

  html += '<div class="split"><div class="results" data-keep-scroll="results">';
  if (s.error) html += '<div class="empty err">' + esc(s.error) + "</div>";
  else if (s.query.trim() && s.ran && !shown.length) html += '<div class="empty">No matches.</div>';
  for (const g of shown) {
    const f = g.file;
    html += '<div class="result' + (s.selected === f.id ? " sel" : "") + '" data-action="pick-result" data-id="' + f.id + '">'
      + '<div class="r-title" dir="auto">' + esc(groupTitle(g)) + "</div>"
      + '<div class="r-meta"><span>' + esc(project(f.cwd)) + "</span><span>" + esc(f.lastTimestamp ? fmtDate(Date.parse(f.lastTimestamp)) : "") + "</span><span>" + plural(g.hits.length, "match", "matches") + "</span>"
      + (g.session ? (g.session.inSignedIn ? "" : '<span class="warn">other account</span>') : '<span class="faint">no sidebar entry</span>') + "</div>"
      + '<div class="r-snip" dir="auto">' + highlight(g.hits[0] && g.hits[0].snippet) + "</div></div>";
  }
  html += '</div><div class="detail" data-keep-scroll="detail">';
  const g = selectedGroup();
  if (g) {
    const f = g.file;
    html += '<h3 dir="auto">' + esc(groupTitle(g)) + "</h3>"
      + '<div class="kv">' + kv("Project", f.cwd || "-") + kv("Last message", f.lastTimestamp ? fmtDate(Date.parse(f.lastTimestamp)) : "-") + kv("Messages", f.messages) + kv("CLI session", f.cliSessionId) + "</div>"
      + '<div class="row wrap">'
      + (g.session
        ? '<button class="btn primary sm" data-action="result-open">' + (g.session.inSignedIn ? icon("open") + "Open in Claude" : icon("add") + "Add and Open") + "</button>"
        : '<span class="muted small">No sidebar entry in any account. Resume it from a terminal:</span>')
      + '<button class="btn sm" data-action="result-copy">' + icon("copy") + "Copy Resume Command</button></div>"
      + g.hits.map((h) => '<div class="hit"><div class="h-meta"><span>' + esc({ user: "You", assistant: "Claude", tool: "Tool" }[h.role] || h.role) + "</span><span>"
        + esc(h.timestamp ? fmtDate(Date.parse(h.timestamp)) : "") + '</span></div><div class="h-text" dir="auto">' + highlight(h.snippet) + "</div></div>").join("");
  } else {
    html += '<div class="placeholder">' + icon("search") + "<div>" + (s.groups.length ? plural(shown.length, "chat") + ", " + Math.round(s.elapsed) + " ms" : "Type to search your chats.") + "</div></div>";
  }
  return html + "</div></div>";
}

async function resultOpen() {
  const g = selectedGroup();
  if (!g || !g.session) return;
  if (g.session.inSignedIn) {
    try { await invoke("open_chat", { sessionId: g.session.sessionId }); } catch (e) { toast({ title: "Could not open the chat", text: errText(e), warning: true }); }
    return;
  }
  const who = (activeAccount() || {}).title || "the signed-in account";
  const label = ((S.sess && S.sess.folders.find((f) => f.id === g.session.folderId)) || {}).label || "another account";
  const items = S.sess
    ? S.sess.sessions.filter((x) => x.sessionId === g.session.sessionId).map((x) => ({ folderId: x.folderId, sessionId: x.sessionId }))
    : [{ folderId: g.session.folderId, sessionId: g.session.sessionId }];
  await preview("preview_pull", {
    items, openAfter: g.session.sessionId,
    note: quoted(g.session.title) + " is in " + label + ". Claude is signed in to " + who + ", so it cannot open it until it is added to " + who + ".",
  });
}

// ---------------------------------------------------------------- accounts

function usageLine(a) {
  const u = a.usage;
  if (!u) {
    return '<div class="usage faint">' + (a.isActive ? "No usage recorded yet. Claude records it about every 30 minutes." : "No usage known. Claude records it while this account is signed in.") + "</div>";
  }
  const age = Date.now() - u.sampledAt;
  const asOf = age < 120e3 ? "just now" : age < 3600e3 ? Math.floor(age / 60e3) + " min ago" : "as of " + when(u.sampledAt);
  return '<div class="usage" title="From Claude\'s own usage records. Updated about every 30 minutes while this account is signed in; for other accounts it is the last known figure, and a limit counts as reset once its window has passed.">'
    + meter("5-hour", u.fiveHour, u.fiveHourResetsAt)
    + (u.week != null ? meter("Week", u.week, u.weekResetsAt) : "")
    + '<span class="faint">' + esc(asOf) + "</span></div>";
}
function meter(label, pct, resets) {
  const p = Math.max(0, Math.min(100, pct || 0));
  const fill = p >= 90 ? "fill-red" : p >= 70 ? "fill-orange" : "fill-green";
  return '<span class="meter"><span class="m-label">' + label + '</span><span class="m-bar" role="meter" aria-label="' + label + '" aria-valuenow="' + p + '" aria-valuemin="0" aria-valuemax="100"><div class="' + fill + '" style="width:' + p + '%"></div></span>'
    + '<span class="m-pct">' + p + "%</span>" + (resets && resets > Date.now() ? '<span class="m-detail">resets by ' + esc(when(resets)) + "</span>" : "") + "</span>";
}

function accountCard(a) {
  const st = S.app;
  const busy = st.switching;
  const next = st.autoSwitch.nextAccountId === a.id;
  let actions = "";
  if (a.profile) actions += '<button class="btn" data-action="acct-rename" data-id="' + esc(a.id) + '">Rename</button>'
    + '<button class="btn" data-action="acct-forget" data-id="' + esc(a.id) + '" title="Delete Relay\'s saved copy of this login">Forget</button>';
  if (a.isActive) {
    if (!a.profile) actions += '<button class="btn primary" data-action="acct-save" data-id="' + esc(a.id) + '"' + (busy ? " disabled" : "") + ">Save</button>";
  } else if (a.profile && !a.profile.needsLogin) {
    actions += '<button class="btn primary" data-action="acct-activate" data-id="' + esc(a.id) + '"' + (busy ? " disabled" : "") + ">Switch</button>";
  } else {
    actions += '<button class="btn" data-action="acct-activate" data-id="' + esc(a.id) + '"' + (busy ? " disabled" : "") + ">" + (a.profile ? "Log In Again" : "Log In and Save") + "</button>";
  }
  return '<div class="acct"><div class="acct-top"><div class="grow"><div class="acct-title"><span dir="auto">' + esc(a.title) + "</span>"
    + (a.nickname ? '<span class="nick" dir="auto">' + esc(a.nickname) + "</span>" : "")
    + (a.isActive ? '<span class="badge green">signed in</span>' : "")
    + (next ? '<span class="badge blue" title="Auto-switch would move to this account">next</span>' : "") + "</div>"
    + '<div class="acct-status' + (a.status.warning ? " warning" : "") + '" dir="auto">' + esc(a.status.text) + "</div></div>"
    + '<div class="acct-actions">' + actions + "</div></div>" + usageLine(a) + "</div>";
}

function viewAccounts() {
  const st = S.app, as = st.autoSwitch;
  const next = as.nextAccountId && st.accounts.find((a) => a.id === as.nextAccountId);
  const picked = st.sync.accounts.filter((id) => st.accounts.some((a) => a.id === id)).length;
  let html = '<header class="view-head"><h1>Accounts</h1></header><div class="view-scroll" data-keep-scroll="accounts"><div class="page">'
    + '<div class="card card-pad stack"><p>Every account used on this PC is listed here, with how much of its 5-hour and weekly limit is used. Switch between saved ones from here or from the tray icon, without logging in again. For an account that is not saved yet, click Log In and Save once.</p>'
    + '<p class="muted small">Don\'t use Log out inside Claude, and don\'t sign in to a saved account by hand: both end its saved login. The signed-in account\'s saved copy refreshes by itself.</p></div>'
    + '<div class="section-title"><h2>Accounts</h2><span class="grow"></span><button class="btn" data-action="add-account"' + (st.switching ? " disabled" : "")
    + ' title="For an account never used on this PC: reopens Claude signed out so you can log in to it">' + icon("plus") + "Add Another Account...</button></div>"
    + '<div class="card acct-list">' + (st.accounts.length ? st.accounts.map(accountCard).join("") : '<div class="empty">No accounts found yet.</div>') + "</div>";

  if (st.switching || (S.stepsFor === "account" && S.steps.length)) {
    html += '<div class="section-title"><h2>' + (st.switching ? "Switching" : "Last switch") + '</h2></div><div class="card">' + '<div class="steps">' + stepsList(S.steps, st.switching) + "</div></div>";
  }

  html += '<div class="section-title"><h2>Auto-switch</h2></div><div class="card">'
    + setting("Switch to the least used account when this one runs low", null, "autoSwitchEnabled", as.enabled, false)
    + '<div class="setting"><div class="label">Switch at<div class="sub">Of the 5-hour or the weekly limit, whichever is reached first</div></div>'
    + '<select data-setting="autoSwitchThreshold" aria-label="Switch at"' + (as.enabled ? "" : " disabled") + ">"
    + [80, 85, 90, 95, 98, 100].map((t) => '<option value="' + t + '"' + (t === as.threshold ? " selected" : "") + ">" + t + "%</option>").join("") + "</select></div>"
    + setting("Wait until running chats finish", null, "autoSwitchWaitForIdle", as.waitForIdle, !as.enabled)
    + setting("If Claude does not close, force it to quit", "Claude can keep running in the tray when its window closes. Without this, Relay gives up instead of switching.", "forceQuit", as.forceQuit, false)
    + '<div class="caption">' + esc(autoSwitchExplanation(as)) + "</div>"
    + (as.status
      ? '<div class="status-line">' + icon("clock") + '<span dir="auto">' + esc(as.status) + "</span></div>"
      : as.enabled && next ? '<div class="status-line calm">Next account when needed: ' + esc(next.title) + "</div>" : "")
    + "</div>";

  html += '<div class="section-title"><h2>When switching</h2></div><div class="card">'
    + setting("Merge chats between the accounts picked in Sync chats", null, "switchSync", st.switchSync, false)
    + '<div class="caption">' + (picked >= 2 ? picked + " accounts are picked. Each merge is backed up first." : 'Pick at least two accounts in <button class="link" data-go="sync">Sync chats</button> for this to do anything.') + "</div></div>";

  html += '<p class="note">Saved logins stay on this PC in ' + esc(st.paths.data) + ". They are copies of Claude's own encrypted login data, work only for your Windows user on this PC, and never leave it.</p>";
  return html + "</div></div>";
}

function autoSwitchExplanation(as) {
  let t = "Checks every minute while Claude runs. When the signed-in account reaches " + as.threshold + "% of its 5-hour or weekly limit, it picks the saved account with the lowest weekly use that is under "
    + as.threshold + "% on both. Claude quits and reopens on that account, the chats you worked on in the last day are copied over (backed up first), and the newest one opens again.";
  t += as.waitForIdle
    ? ' It waits until no chat is writing, so no reply is cut off. If a chat hits the limit first, it stops there; send "continue" in it after the switch.'
    : ' A chat that is still replying stops when Claude quits; send "continue" in it after the switch.';
  return t;
}

function setting(label, sub, key, on, disabled) {
  return '<div class="setting"><div class="label">' + esc(label) + (sub ? '<div class="sub">' + esc(sub) + "</div>" : "") + "</div>"
    + '<label class="switch"><input type="checkbox" role="switch" data-setting="' + key + '" aria-label="' + esc(label) + '"' + (on ? " checked" : "") + (disabled ? " disabled" : "") + "></label></div>";
}

async function setSettings(patch) {
  try {
    S.app = await invoke("set_settings", patch);
    renderNav();
    renderView();
  } catch (e) {
    toast({ title: "Could not change the setting", text: errText(e), warning: true });
    refresh(false);
  }
}
function changeSetting(el) {
  const key = el.dataset.setting;
  const value = el.type === "checkbox" ? el.checked : key === "autoSwitchThreshold" ? Number(el.value) : el.value;
  if ((key === "includeTools" || key === "includeSubagents") && S.view === "search") {
    const d = el.closest("details");
    if (d) d.open = true;
  }
  setSettings({ [key]: value });
}

function accountById(id) {
  return S.app.accounts.find((a) => a.id === id);
}

async function activate(id) {
  const a = accountById(id);
  if (!a || S.app.switching) return;
  const merge = S.app.switchSync && S.app.sync.accounts.length >= 2;
  if (a.profile && !a.profile.needsLogin) {
    const ok = await confirmDialog({
      title: "Switch Claude to " + a.title + "?",
      text: "Claude will quit, which stops any running Code chats, then reopen signed in as " + a.title + ". The current login is saved first and backed up."
        + (merge ? " Chats are merged between the accounts picked in Sync chats first." : ""),
      ok: "Switch",
    });
    if (!ok) return;
    runAccountAction("switch_account", { accountId: id }, "Switched to " + a.title, "Could not switch to " + a.title);
  } else {
    const ok = await confirmDialog({
      title: "Log in to " + a.title + "?",
      text: "The current login is saved first. Claude quits, which stops any running Code chats, and reopens signed out. Log in to " + a.title
        + " there. Relay saves that login by itself within a minute, and from then on you can switch to it from the tray icon."
        + (merge ? " Chats are merged between the accounts picked in Sync chats first." : ""),
      ok: "Continue",
    });
    if (!ok) return;
    runAccountAction("log_in_and_save", { accountId: id }, "Claude is signed out", "Could not log in to " + a.title);
  }
}

async function addAccount() {
  if (S.app.switching) return;
  const ok = await confirmDialog({
    title: "Add another account?",
    text: "The current login is saved first. Claude will quit, which stops any running Code chats, and reopen signed out. Log in to the other account there. Relay saves it by itself once you are in.\n\nDo not use Log out inside Claude for this: logging out can end that login on the server, and then its saved copy stops working.",
    ok: "Continue",
  });
  if (!ok) return;
  runAccountAction("add_account", {}, "Claude is signed out", "Could not add an account");
}

async function runAccountAction(cmd, args, okTitle, failTitle) {
  S.steps = [];
  S.stepsFor = "account";
  if (S.view !== "accounts") go("accounts"); else renderView();
  try {
    const r = await invoke(cmd, args);
    const warnings = r.warnings || [];
    const switched = cmd !== "switch_account" || r.switched;
    const text = (r.notes || []).concat(warnings).join(" ");
    toast({ title: switched ? okTitle : failTitle, text: text || okTitle, warning: !!warnings.length || !switched });
  } catch (e) {
    toast({ title: failTitle, text: errText(e), warning: true });
  }
  refresh(true);
}

async function saveLogin(id) {
  const a = accountById(id);
  if (!a) return;
  const name = a.email || a.title;
  try {
    await invoke("save_login", { name });
    toast({ title: "Login saved", text: "Saved the current Claude login as " + name + "." });
  } catch (e) {
    const msg = errText(e);
    if (msg.startsWith("LOCKED:")) {
      const ok = await confirmDialog({
        title: "Quit Claude, save and reopen it?",
        text: msg.slice(7).trim() + " Relay can quit Claude, save the login and reopen Claude. Quitting stops any running Code chats.",
        ok: "Quit, Save and Reopen",
      });
      if (!ok) return;
      S.steps = [];
      try {
        await invoke("save_login", { name, quitClaude: true });
        toast({ title: "Login saved", text: "Saved the current Claude login as " + name + "." });
      } catch (e2) {
        toast({ title: "Could not save the login", text: errText(e2), warning: true });
      }
    } else {
      toast({ title: "Could not save the login", text: msg, warning: true });
    }
  }
  refresh(false);
}

async function renameProfile(id) {
  const a = accountById(id);
  if (!a || !a.profile) return;
  const name = await promptDialog({ title: "Name for this account", value: a.profile.name, ok: "Save" });
  if (name == null || !name.trim()) return;
  try {
    await invoke("rename_profile", { profileId: a.profile.id, name: name.trim() });
  } catch (e) {
    toast({ title: "Could not rename", text: errText(e), warning: true });
  }
  refresh(false);
}

async function forgetProfile(id) {
  const a = accountById(id);
  if (!a || !a.profile) return;
  const ok = await confirmDialog({
    title: "Forget the saved login for " + a.title + "?",
    text: "Only Relay's saved copy is removed. Claude, the account and your chats are not touched. You can log in and save it again later.",
    ok: "Forget",
  });
  if (!ok) return;
  try {
    await invoke("forget_profile", { profileId: a.profile.id });
  } catch (e) {
    toast({ title: "Could not forget the login", text: errText(e), warning: true });
  }
  refresh(false);
}

// ---------------------------------------------------------------- sync

function syncAccounts() {
  return S.app.accounts.filter((a) => a.folderIds && a.folderIds.length);
}
function toggleSyncAccount(id, on) {
  const set = new Set(S.app.sync.accounts);
  if (on) set.add(id); else set.delete(id);
  const patch = { syncAccounts: [...set] };
  if (!on && S.app.sync.source === id) patch.syncSource = "";
  setSettings(patch);
}

function viewSync() {
  const st = S.app;
  const accounts = syncAccounts();
  const picked = accounts.filter((a) => st.sync.accounts.includes(a.id));
  const src = st.sync.source && picked.find((a) => a.id === st.sync.source);
  const explanation = src
    ? "Copies the chats of " + src.title + " into the other picked accounts. Their own chats stay and nothing is deleted. If an account already has a newer copy of a chat, it keeps its copy."
    : "Every picked account ends up with all of their chats. When two accounts have the same chat, the newest copy wins. A chat deleted in one account stays deleted in all of them.";
  let html = '<header class="view-head"><h1>Sync chats</h1></header><div class="view-scroll" data-keep-scroll="sync"><div class="page">'
    + '<div class="card card-pad"><p class="muted">Give your accounts the same chats. Tick the accounts, choose how, then preview. Nothing is written until you apply, Claude is closed while it happens, and everything is backed up first.</p></div>'
    + '<div class="section-title"><h2>Accounts</h2></div><div class="card">';
  html += accounts.length ? accounts.map((a) => {
    const lists = a.folderIds.length;
    return '<label class="check-row"><input type="checkbox" class="cb" data-sync-account="' + esc(a.id) + '"' + (st.sync.accounts.includes(a.id) ? " checked" : "") + '><div class="grow">'
      + '<div class="row"><span dir="auto">' + esc(a.title) + "</span>" + (a.isActive ? '<span class="badge green">signed in</span>' : "") + "</div>"
      + '<div class="sub">' + plural(a.chatCount, "chat") + (lists > 1 ? ", in " + lists + " chat lists (one per organization), all included" : "") + "</div></div></label>";
  }).join("") : '<div class="empty">No account has chats on this PC yet.</div>';
  html += "</div>";
  html += '<div class="section-title"><h2>How</h2></div><div class="card">'
    + '<label class="check-row"><input type="radio" name="syncHow" value=""' + (src ? "" : " checked") + '><div class="grow">Merge: every picked account gets every chat</div></label>'
    + picked.map((a) => '<label class="check-row"><input type="radio" name="syncHow" value="' + esc(a.id) + '"' + (src && src.id === a.id ? " checked" : "") + '><div class="grow" dir="auto">Copy from '
      + esc(a.title) + " to the others" + (a.isActive ? " (signed in now)" : "") + "</div></label>").join("")
    + '<div class="caption">' + esc(explanation) + "</div></div>";
  html += '<div class="card"><div class="setting"><div class="label muted">' + (picked.length < 2 ? "Tick at least two accounts." : picked.length + " accounts picked") + "</div>"
    + '<button class="btn primary" data-action="sync-preview"' + (picked.length < 2 ? " disabled" : "") + ">Preview...</button></div></div>";
  if (S.sess) {
    html += '<div class="card"><details class="disclosure" data-keep-open="folders"><summary>' + icon("chevron") + "Folders on disk</summary><div class=\"folders\">"
      + S.sess.folders.map((f) => {
        const included = picked.some((a) => a.folderIds.includes(f.id));
        return '<div><div dir="auto">' + esc(f.label) + '</div><div class="faint small">' + plural(f.count, "chat")
          + (f.isBackupCopy ? ", hand-made backup copy, never synced" : "") + (included ? ", included" : "") + '</div><div class="f-id">' + esc(f.id) + "</div></div>";
      }).join("") + "</div></details></div>";
  }
  return html + "</div></div>";
}

// ---------------------------------------------------------------- backups

function viewBackups() {
  let html = '<header class="view-head"><h1>Backups</h1><div class="grow"></div>'
    + '<button class="btn" data-action="backup-now" title="Save a copy of every account folder\'s session files without changing anything">' + icon("archive") + "Back Up Now</button>"
    + '<button class="btn" data-action="backup-folder">' + icon("folder") + "Open Folder</button></header>"
    + '<div class="view-scroll" data-keep-scroll="backups"><div class="page">'
    + '<div class="card card-pad"><p class="muted">Every write makes a backup here first. Restoring one quits Claude, backs up the current state, puts the session files back as they were and reopens Claude. backlog, waiting-input and scheduled-tasks.json are never touched.</p></div>'
    + '<div class="card">';
  if (!S.backups.length) html += '<div class="empty">No backups yet.</div>';
  for (const b of S.backups) {
    const open = S.openBackup === b.id;
    html += '<div class="backup"><div class="grow"><div class="row"><button class="link b-title" data-action="backup-toggle" data-id="' + esc(b.id) + '" aria-expanded="' + open + '">' + esc(b.title) + "</button></div>"
      + '<div class="b-meta">' + esc(fmtDate(b.created)) + ", " + esc(b.folders.join(", ")) + "</div>"
      + '<div class="b-meta">' + plural(b.files, "file") + " saved, " + plural(b.changes.length, "planned change") + ", " + b.removed + " moved out" + (b.applied ? "" : ", not applied") + "</div>";
    if (open) {
      html += b.changes.length ? "<ul>" + b.changes.slice(0, 12).map((c) => '<li dir="auto">' + esc(c) + "</li>").join("") + "</ul>"
        + (b.changes.length > 12 ? '<div class="faint small">and ' + (b.changes.length - 12) + " more</div>" : "") : '<div class="faint small" style="margin-top:6px">No planned changes, a copy only.</div>';
    }
    html += '</div><button class="btn sm" data-action="backup-show" data-path="' + esc(b.dir) + '">Show</button>'
      + '<button class="btn sm" data-action="backup-restore" data-id="' + esc(b.id) + '">Preview Restore...</button></div>';
  }
  return html + "</div></div></div>";
}

async function backupNow() {
  try {
    const r = await invoke("backup_now");
    toast({ title: "Backed up", text: "Saved " + plural(r.files, "file") + " to " + r.dir.split(/[\\/]/).pop() + "." });
    await loadBackups();
    renderView();
  } catch (e) {
    toast({ title: "Backup failed", text: errText(e), warning: true });
  }
}

async function reveal(path) {
  try { await invoke("reveal", { path }); } catch (e) { toast({ title: "Could not show the file", text: errText(e), warning: true }); }
}

// ---------------------------------------------------------------- events and start

async function start() {
  await Promise.all([loadState(), loadSessions()]);
  renderNav();
  renderView();
  listen("relay://state", (ev) => refresh(!!(ev.payload && ev.payload.sessions)));
  listen("relay://steps", (ev) => {
    S.steps = Array.isArray(ev.payload) ? ev.payload : [];
    S.stepsFor = S.modal && S.modal.type === "plan" && S.modal.state === "applying" ? "plan" : "account";
    if (S.modal && S.modal.type === "plan" && S.modal.state === "applying") {
      S.modal.steps = S.steps;
      renderModal();
    }
    renderNav();
    if (S.view === "accounts") renderView();
  });
  listen("relay://toast", (ev) => { if (ev.payload) toast(ev.payload); });
  listen("relay://navigate", (ev) => { if (typeof ev.payload === "string") go(ev.payload); });
}

start();
