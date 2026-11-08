// Fake Tauri backend with made-up data, used only when the page is opened in a normal browser
// (no window.__TAURI__). Lets the UI be previewed and screenshotted without Windows.
(function () {
  if (window.__TAURI__) return;

  const now = Date.now();
  const M = 60e3, H = 60 * M, D = 24 * H;
  const ACC = {
    work: "3f9a1c2e-5b7d-4aaa-8aaa-6e0c4d2b1f01",
    personal: "7b4d0e91-2c6a-4bbb-8bbb-91d3a7e5c402",
    side: "c58e2a73-9f14-4ccc-8ccc-2a6b8f0d7e03",
  };
  const ORG = {
    work: "0d6c8e4f-3a21-4ddd-8ddd-5c9e1b7a3d0a",
    personal: "94e2b7c5-6d38-4eee-8eee-8a4f2c6e1b0b",
    side: "e1a7d3f9-8b52-4fff-8fff-3d7b9e5c2a0c",
  };
  const EMAIL = { [ACC.work]: "work@example.com", [ACC.personal]: "personal@example.com", [ACC.side]: "side@example.com" };
  const DATA = "C:\\Users\\you\\AppData\\Roaming\\Relay";
  const SESSIONS_ROOT = "C:\\Users\\you\\AppData\\Roaming\\Claude\\claude-code-sessions";

  const folderList = [
    { accountId: ACC.work, orgId: ORG.work },
    { accountId: ACC.personal, orgId: ORG.personal },
    { accountId: ACC.side, orgId: ORG.side },
    { accountId: ACC.work, orgId: ORG.work + ".backup-1790000000" },
  ];

  const db = {
    active: ACC.work,
    claudeRunning: true,
    switching: false,
    steps: [],
    profiles: {
      [ACC.work]: { id: "work", name: "work@example.com", savedAt: now - 12 * M, sessionExpires: now + 28 * D, problem: null },
      [ACC.personal]: { id: "personal", name: "Personal", savedAt: now - 1.6 * D, sessionExpires: now + 26 * D, problem: null },
    },
    usage: {
      [ACC.work]: { fiveHour: 42, fiveHourResetsAt: now + 2.3 * H, week: 61, weekResetsAt: now + 3.2 * D, sampledAt: now - 7 * M, current: true },
      [ACC.personal]: { fiveHour: 0, fiveHourResetsAt: null, week: 18, weekResetsAt: now + 5 * D, sampledAt: now - 1.6 * D, current: false },
      [ACC.side]: { fiveHour: 0, fiveHourResetsAt: null, week: 97, weekResetsAt: now + 1.2 * D, sampledAt: now - 20 * H, current: false },
    },
    autoSwitch: { enabled: true, threshold: 95, waitForIdle: true, forceQuit: true, status: null },
    switchSync: false,
    sync: { accounts: [ACC.work, ACC.personal], source: null },
    index: { running: false, fraction: 0, includeTools: false, includeSubagents: false, files: 412, messages: 58310 },
    sessions: [],
    backups: [],
    plans: {},
  };

  const fid = (f) => f.accountId + "/" + f.orgId;
  const isBackup = (f) => f.orgId.includes(".backup");
  const short = (f) => f.accountId.slice(0, 8) + "/" + f.orgId.slice(0, 8) + (isBackup(f) ? " (backup copy)" : "");

  function label(f) {
    let s = EMAIL[f.accountId] || f.accountId.slice(0, 8);
    const siblings = folderList.filter((x) => x.accountId === f.accountId && !isBackup(x)).length;
    if (siblings > 1 || isBackup(f)) s += " / org " + f.orgId.slice(0, 8);
    if (isBackup(f)) s += " (backup copy)";
    if (f.accountId === db.active && !isBackup(f)) s += " (signed in)";
    return s;
  }

  // About 40 chats spread over the accounts, with overlaps.
  const chats = [
    ["Fix the login redirect loop", "C:\\code\\shop\\web"],
    ["Add dark mode to settings", "C:\\code\\shop\\web"],
    ["Migrate payments to the new API", "C:\\code\\shop\\api"],
    ["Write tests for the cart service", "C:\\code\\shop\\api"],
    ["עיצוב חדש - Website redesign", "C:\\code\\studio\\site"],
    ["Speed up the image pipeline", "C:\\code\\studio\\media"],
    ["Rename the user table columns", "C:\\code\\shop\\db"],
    ["Investigate flaky CI on Windows", "C:\\code\\tools\\ci"],
    ["Draft the onboarding emails", "C:\\code\\marketing\\emails"],
    ["Port the CLI to Rust", "C:\\code\\tools\\cli"],
    ["Sentry alert triage", "C:\\code\\shop\\api"],
    ["Refactor the search screen", "C:\\code\\shop\\web"],
    ["Add CSV export to reports", "C:\\code\\finance\\reports"],
    ["Quarterly report charts", "C:\\code\\finance\\reports"],
    ["Upgrade to the latest React", "C:\\code\\shop\\web"],
    ["Clean up feature flags", "C:\\code\\shop\\web"],
    ["Docker compose for local dev", "C:\\code\\tools\\infra"],
    ["Localize the checkout page", "C:\\code\\shop\\web"],
    ["Fix timezone bug in invoices", "C:\\code\\finance\\billing"],
    ["Set up the staging deploy", "C:\\code\\tools\\infra"],
    ["Review the auth middleware", "C:\\code\\shop\\api"],
    ["Mobile layout for the dashboard", "C:\\code\\studio\\dashboard"],
    ["Write the release notes", "C:\\code\\tools\\cli"],
    ["Profile slow SQL queries", "C:\\code\\shop\\db"],
    ["Add retries to the webhook sender", "C:\\code\\shop\\api"],
    ["Accessibility pass on forms", "C:\\code\\shop\\web"],
    ["Generate API client from OpenAPI", "C:\\code\\tools\\sdk"],
    ["Plan the database backup job", "C:\\code\\tools\\infra"],
    ["Debug the PDF renderer", "C:\\code\\finance\\billing"],
    ["Prototype the AI summary feature", "C:\\code\\studio\\labs"],
    ["Update the privacy policy page", "C:\\code\\marketing\\site"],
    ["Split the monolith config", "C:\\code\\shop\\api"],
    ["Fix the broken password reset", "C:\\code\\shop\\web"],
    ["Add rate limiting", "C:\\code\\shop\\api"],
    ["Clean up old S3 buckets", "C:\\code\\tools\\infra"],
    ["Move logs to structured JSON", "C:\\code\\shop\\api"],
    ["Design tokens for the theme", "C:\\code\\studio\\design"],
    ["Investigate memory leak in worker", "C:\\code\\shop\\worker"],
    ["Side project landing page", "C:\\code\\side\\landing"],
    ["Weekend game jam ideas", "C:\\code\\side\\jam"],
  ];

  const pad = (n, w) => String(n).padStart(w, "0");
  chats.forEach(([title, cwd], i) => {
    const sid = "local_5e55" + pad(i, 4) + "-0000-4000-8000-0000000000" + pad(i, 2);
    const cli = "c0ffee00-" + pad(i, 4) + "-4000-8000-" + pad(i * 7, 12);
    const last = now - Math.round((i * i * 0.35 + i * 2 + 0.3) * H);
    let where;
    if (title === "Quarterly report charts") where = ["personal"];
    else if (title === "Weekend game jam ideas") where = ["side"];
    else if (title === "Side project landing page") where = ["side", "personal"];
    else if (i % 5 === 0) where = ["work"];
    else if (i % 5 === 1) where = ["work", "personal"];
    else where = ["work", "personal", "side"];
    const archived = i % 7 === 3;
    const starred = !archived && i % 9 === 2;
    for (const k of where) {
      const f = folderList.find((x) => x.accountId === ACC[k] && !isBackup(x));
      addSession(f, sid, cli, title, cwd, archived, starred, last);
    }
    if (i === 6 || i === 11) addSession(folderList[3], sid, cli, title, cwd, archived, false, last - 2 * D);
  });

  function addSession(f, sid, cli, title, cwd, archived, starred, last) {
    db.sessions.push({
      key: fid(f) + "|" + sid,
      folderId: fid(f),
      accountId: f.accountId,
      sessionId: sid,
      cliSessionId: cli,
      title,
      titleSource: null,
      cwd,
      isArchived: archived,
      isStarred: starred,
      inArchivedIndex: archived,
      lastActivity: last,
      createdAt: last - 3 * H,
      fileMTime: last,
      fileSize: 1800 + title.length * 13,
      file: SESSIONS_ROOT + "\\" + f.accountId + "\\" + f.orgId + "\\" + sid + ".json",
      model: "claude-opus-5-5",
      problems: [],
      resumeCommand: 'cd "' + cwd + '" && claude --resume ' + cli,
    });
  }

  db.backups = [
    {
      id: "2026-11-08_101500-sync", created: now - 5 * H, title: "Sync 2 account folders", reason: "sync",
      folders: [short(folderList[0]), short(folderList[1])], files: 74,
      changes: ['3f9a1c2e/0d6c8e4f: "Add CSV export to reports": add from 3f9a1c2e/0d6c8e4f',
        '3f9a1c2e/0d6c8e4f: Archived list: add 1 (6 total)'],
      removed: 0, applied: true, dir: DATA + "\\backups\\2026-11-08_101500-sync",
    },
    {
      id: "2026-11-07_183000-manual", created: now - 1.2 * D, title: "Manual backup", reason: "manual",
      folders: [short(folderList[0]), short(folderList[1]), short(folderList[2])], files: 118,
      changes: [], removed: 0, applied: true, dir: DATA + "\\backups\\2026-11-07_183000-manual",
    },
  ];

  // ---------- events ----------
  const listeners = {};
  let eventId = 1;
  function emit(event, payload) {
    for (const cb of listeners[event] || []) cb({ event, id: eventId++, payload });
  }
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  async function runSteps(steps, gap = 450) {
    db.steps = [];
    for (const s of steps) {
      db.steps = db.steps.concat([s]);
      emit("relay://steps", db.steps.slice());
      await sleep(gap);
    }
  }

  // ---------- state ----------
  function liveFolders(acc) { return folderList.filter((f) => f.accountId === acc && !isBackup(f)); }
  function chatCount(acc) {
    const ids = new Set(liveFolders(acc).map(fid));
    return new Set(db.sessions.filter((s) => ids.has(s.folderId)).map((s) => s.sessionId)).size;
  }
  const fmtDay = (ms) => new Date(ms).toLocaleDateString(undefined, { day: "numeric", month: "short" });
  const fmtTime = (ms) => new Date(ms).toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

  function accountEntries() {
    const ids = [ACC.work, ACC.personal, ACC.side];
    return ids.map((id) => {
      const p = db.profiles[id] || null;
      const isActive = id === db.active;
      let status;
      if (!p) status = { text: isActive ? "Signed in, not saved yet" : "Not saved yet", warning: false };
      else if (p.problem) status = { text: p.problem, warning: true };
      else status = { text: "Saved " + fmtTime(p.savedAt) + ", valid until " + fmtDay(p.sessionExpires), warning: false };
      return {
        id, title: EMAIL[id], email: EMAIL[id],
        nickname: p && p.name !== EMAIL[id] ? p.name : null,
        isActive,
        profile: p ? Object.assign({}, p, { needsLogin: !!p.problem }) : null,
        status,
        usage: db.usage[id] ? Object.assign({}, db.usage[id]) : null,
        chatCount: chatCount(id),
        folderIds: liveFolders(id).map(fid),
      };
    }).sort((a, b) => (a.isActive !== b.isActive ? (a.isActive ? -1 : 1) : a.title.localeCompare(b.title)));
  }

  function nextAccountId() {
    const t = db.autoSwitch.threshold;
    const cands = accountEntries().filter((e) => !e.isActive && e.profile && !e.profile.needsLogin);
    const ok = cands.filter((e) => !e.usage || ((e.usage.week || 0) < t && e.usage.fiveHour < t));
    ok.sort((a, b) => {
      if (!a.usage !== !b.usage) return a.usage ? -1 : 1;
      if (!a.usage) return 0;
      return (a.usage.week || 0) - (b.usage.week || 0) || a.usage.fiveHour - b.usage.fiveHour;
    });
    return ok.length ? ok[0].id : null;
  }

  const update = { available: true, version: "0.5.0", notes: "Relay updates itself now.", checking: false, error: null, autoCheck: true };

  function appState() {
    const idx = db.index;
    return {
      appVersion: "0.4.0",
      platform: "windows",
      claudeRunning: db.claudeRunning,
      activeAccountId: db.active,
      switching: db.switching,
      steps: db.steps.slice(),
      accounts: accountEntries(),
      autoSwitch: Object.assign({}, db.autoSwitch, { nextAccountId: nextAccountId() }),
      switchSync: db.switchSync,
      sync: { accounts: db.sync.accounts.slice(), source: db.sync.source },
      index: {
        running: idx.running,
        fraction: idx.fraction,
        status: idx.running
          ? "Indexing " + Math.round(idx.fraction * 64) + " of 64 files, " + Math.round(idx.fraction * 100) + "%"
          : idx.files.toLocaleString() + " chats, " + idx.messages.toLocaleString() + " messages indexed",
        includeTools: idx.includeTools,
        includeSubagents: idx.includeSubagents,
      },
      paths: { data: DATA, backups: DATA + "\\backups", claude: "C:\\Users\\you\\AppData\\Roaming\\Claude" },
      update: Object.assign({ current: "0.4.0" }, update),
    };
  }

  function sessionsPayload() {
    return {
      activeAccountId: db.active,
      folders: folderList.map((f) => ({
        id: fid(f), accountId: f.accountId, orgId: f.orgId, label: label(f), isBackupCopy: isBackup(f),
        count: db.sessions.filter((s) => s.folderId === fid(f)).length,
      })),
      sessions: db.sessions.map((s) => Object.assign({}, s, { problems: s.problems.slice() })),
    };
  }

  // ---------- plans ----------
  const q = (t) => '"\u2068' + t + '\u2069"';
  let planSeq = 1;
  function makePlan(title, changes, extra) {
    const id = "plan-" + planSeq++;
    const folders = new Set(changes.map((c) => c.folderId));
    const plan = Object.assign({
      id, title,
      summary: changes.length + " change(s) in " + folders.size + " folder(s)",
      changes, problems: [], warnings: [], canApply: changes.length > 0, note: null, openAfter: null,
    }, extra || {});
    if (plan.problems.length) plan.canApply = false;
    plan.summary = changes.length + " change(s) in " + folders.size + " folder(s)"
      + (plan.problems.length ? ", " + plan.problems.length + " problem(s) block applying" : "")
      + (plan.warnings.length ? ", " + plan.warnings.length + " warning(s)" : "");
    db.plans[id] = { plan, apply: (extra && extra._apply) || (() => {}) };
    delete plan._apply;
    return JSON.parse(JSON.stringify(plan));
  }
  const folderLabel = (id) => label(folderList.find((f) => fid(f) === id));

  function previewEdits({ edits }) {
    const changes = [];
    const idxDelta = {};
    for (const e of edits) {
      const s = db.sessions.find((x) => x.folderId === e.folderId && x.sessionId === e.sessionId);
      if (!s) continue;
      const what = [];
      if (e.title != null && e.title !== s.title) what.push("rename to " + q(e.title));
      if (e.isArchived != null && e.isArchived !== s.isArchived) {
        what.push(e.isArchived ? "archive" : "restore from archive");
        idxDelta[s.folderId] = (idxDelta[s.folderId] || 0) + (e.isArchived ? 1 : -1);
      }
      if (e.isStarred != null && e.isStarred !== s.isStarred) what.push(e.isStarred ? "pin" : "unpin");
      if (!what.length) continue;
      changes.push({ folderId: s.folderId, folderLabel: folderLabel(s.folderId), kind: "edit", summary: q(s.title) + ": " + what.join(", "), detail: s.sessionId + ".json" });
    }
    for (const [f, d] of Object.entries(idxDelta)) {
      changes.push({ folderId: f, folderLabel: folderLabel(f), kind: "archivedIndex", summary: "Archived list: " + (d > 0 ? "add " + d : "remove " + -d), detail: null });
    }
    const n = new Set(edits.map((e) => e.sessionId)).size;
    return makePlan("Change " + n + " chat" + (n === 1 ? "" : "s"), changes, {
      _apply: () => {
        for (const e of edits) {
          const s = db.sessions.find((x) => x.folderId === e.folderId && x.sessionId === e.sessionId);
          if (!s) continue;
          if (e.title != null) { s.title = e.title; s.titleSource = "user"; }
          if (e.isArchived != null) { s.isArchived = e.isArchived; s.inArchivedIndex = e.isArchived; }
          if (e.isStarred != null) s.isStarred = e.isStarred;
        }
      },
    });
  }

  function previewPull({ items, openAfter, note }) {
    const targets = liveFolders(db.active).map(fid);
    const best = {};
    for (const it of items) {
      const s = db.sessions.find((x) => x.folderId === it.folderId && x.sessionId === it.sessionId);
      if (!s || targets.includes(s.folderId)) continue;
      if (!best[s.sessionId] || best[s.sessionId].fileMTime < s.fileMTime) best[s.sessionId] = s;
    }
    const changes = [];
    for (const t of targets) {
      for (const s of Object.values(best)) {
        if (db.sessions.some((x) => x.folderId === t && x.sessionId === s.sessionId)) continue;
        const src = folderList.find((f) => fid(f) === s.folderId);
        changes.push({ folderId: t, folderLabel: folderLabel(t), kind: "add", summary: q(s.title) + ": add from " + short(src),
          detail: (s.isArchived ? "archived" : "active") + ", last change " + fmtTime(s.fileMTime) });
        if (s.isArchived) changes.push({ folderId: t, folderLabel: folderLabel(t), kind: "archivedIndex", summary: "Archived list: add 1", detail: null });
      }
    }
    const n = Object.keys(best).length;
    return makePlan("Add " + n + " chat" + (n === 1 ? "" : "s") + " to the signed-in account", changes, {
      note: note || null,
      openAfter: openAfter || null,
      _apply: () => {
        for (const t of targets) {
          const f = folderList.find((x) => fid(x) === t);
          for (const s of Object.values(best)) {
            if (db.sessions.some((x) => x.folderId === t && x.sessionId === s.sessionId)) continue;
            addSession(f, s.sessionId, s.cliSessionId, s.title, s.cwd, s.isArchived, s.isStarred, s.lastActivity);
          }
        }
      },
    });
  }

  function previewSync() {
    const picked = db.sync.accounts;
    if (picked.length < 2) throw "Tick at least two accounts in Sync chats.";
    const folders = picked.flatMap((a) => liveFolders(a).map(fid));
    const all = new Map();
    for (const s of db.sessions.filter((x) => folders.includes(x.folderId))) if (!all.has(s.sessionId)) all.set(s.sessionId, s);
    const changes = [];
    const src = db.sync.source;
    const targets = src ? folders.filter((f) => !f.startsWith(src)) : folders;
    for (const t of targets) {
      for (const s of all.values()) {
        if (src && s.accountId !== src) continue;
        if (db.sessions.some((x) => x.folderId === t && x.sessionId === s.sessionId)) continue;
        const from = folderList.find((f) => fid(f) === s.folderId);
        changes.push({ folderId: t, folderLabel: folderLabel(t), kind: "add", summary: q(s.title) + ": add from " + short(from),
          detail: (s.isArchived ? "archived" : "active") + ", last change " + fmtTime(s.fileMTime) });
      }
    }
    return makePlan(src ? "Copy chats into " + targets.length + " folder" + (targets.length === 1 ? "" : "s") : "Sync " + folders.length + " account folders", changes, {
      warnings: changes.length ? ['"Prototype the AI summary feature" is 132 KB (connector config). A copy this big once failed to show in the sidebar.'] : [],
      _apply: () => {
        for (const c of changes) {
          const t = folderList.find((f) => fid(f) === c.folderId);
          const title = c.summary.split(":")[0].replace(/["\u2068\u2069]/g, "");
          const s = [...all.values()].find((x) => x.title === title);
          if (s) addSession(t, s.sessionId, s.cliSessionId, s.title, s.cwd, s.isArchived, s.isStarred, s.lastActivity);
        }
      },
    });
  }

  function previewRestore({ backupId }) {
    const b = db.backups.find((x) => x.id === backupId);
    if (!b) throw "Backup not found.";
    const f0 = fid(folderList[0]);
    const changes = [
      { folderId: f0, folderLabel: folderLabel(f0), kind: "putBack", summary: "Revert " + q("Add CSV export to reports"), detail: "local_5e550012-0000-4000-8000-000000000012.json" },
      { folderId: f0, folderLabel: folderLabel(f0), kind: "moveOut", summary: "Move out " + q("Weekend game jam ideas") + " (not in the backup)", detail: "local_5e550039-0000-4000-8000-000000000039.json" },
      { folderId: f0, folderLabel: folderLabel(f0), kind: "archivedIndex", summary: "Archived list: remove 1 (5 total)", detail: null },
    ];
    return makePlan("Restore backup " + b.id, changes);
  }

  async function applyPlan({ planId }) {
    const entry = db.plans[planId];
    if (!entry) throw "That preview is gone. Preview again.";
    const running = db.claudeRunning;
    const steps = [];
    if (running) steps.push("Quitting Claude");
    steps.push("Re-reading files", "Backing up " + new Set(entry.plan.changes.map((c) => c.folderId)).size + " folder(s)",
      "Backup: " + DATA + "\\backups\\2026-11-08_161200-" + "apply", "Wrote " + entry.plan.changes.length + " file(s), moved 0 to the backup");
    if (running) steps.push("Reopening Claude");
    steps.push("Done");
    if (running) { db.claudeRunning = false; emit("relay://state", { sessions: false }); }
    await runSteps(steps, 380);
    entry.apply();
    db.claudeRunning = running;
    delete db.plans[planId];
    db.backups.unshift({
      id: "2026-11-08_161200-apply", created: Date.now(), title: entry.plan.title, reason: "apply",
      folders: [...new Set(entry.plan.changes.map((c) => c.folderId))].map((id) => short(folderList.find((f) => fid(f) === id))),
      files: 60, changes: entry.plan.changes.map((c) => c.summary), removed: 0, applied: true,
      dir: DATA + "\\backups\\2026-11-08_161200-apply",
    });
    emit("relay://state", { sessions: true });
    return { status: "applied", written: entry.plan.changes.length, moved: 0, backupDir: DATA + "\\backups\\2026-11-08_161200-apply", reopened: running, warnings: [] };
  }

  // ---------- accounts ----------
  async function switchAccount({ accountId }) {
    const p = db.profiles[accountId];
    if (!p) throw "That account has no saved login. Use Log In and Save.";
    db.switching = true;
    emit("relay://state", { sessions: false });
    const from = db.profiles[db.active];
    await runSteps(["Quitting Claude", "Saving the current login (" + (from ? from.name : "account") + ")", "Restoring the login for " + p.name,
      "Reopening Claude", "Checking that Claude accepted the login", "Done"], 550);
    db.active = accountId;
    db.switching = false;
    db.usage[accountId] = Object.assign({}, db.usage[accountId] || { fiveHour: 0, week: 0, fiveHourResetsAt: null, weekResetsAt: null }, { sampledAt: Date.now(), current: true });
    emit("relay://state", { sessions: true });
    return { switched: true, notes: ["Switched to " + p.name + "."], warnings: [] };
  }

  async function logInAndSave({ accountId }) {
    db.switching = true;
    emit("relay://state", { sessions: false });
    await runSteps(["Quitting Claude", "Saving the current login", "Moving the login files aside", "Reopening Claude", "Done"], 500);
    db.switching = false;
    emit("relay://state", { sessions: false });
    return { notes: ["Claude is signed out. Log in to " + (EMAIL[accountId] || "the account") + " there. Relay saves it by itself once you are in."], warnings: [] };
  }

  async function addAccount() {
    db.switching = true;
    emit("relay://state", { sessions: false });
    await runSteps(["Quitting Claude", "Saving the current login", "Moving the login files aside", "Reopening Claude", "Done"], 500);
    db.switching = false;
    emit("relay://state", { sessions: false });
    return { notes: ["Claude is signed out. Log in to the account there. Relay saves it by itself once you are in."], warnings: [] };
  }

  let lockedOnce = false;
  async function saveLogin({ name, quitClaude }) {
    if (!lockedOnce && !quitClaude) {
      lockedOnce = true;
      throw "LOCKED: Claude keeps its login files locked while it runs.";
    }
    if (quitClaude) await runSteps(["Quitting Claude", "Saving the current login", "Reopening Claude", "Done"], 400);
    db.profiles[db.active] = { id: (name || "account").replace(/[^a-z0-9]/gi, "-").toLowerCase(), name, savedAt: Date.now(), sessionExpires: Date.now() + 30 * D, problem: null };
    emit("relay://state", { sessions: false });
    return accountEntries().find((e) => e.id === db.active);
  }

  function findProfile(profileId) {
    return Object.entries(db.profiles).find(([, p]) => p.id === profileId);
  }

  // ---------- search ----------
  function search({ query, role, order }) {
    const words = String(query || "").toLowerCase().replace(/"/g, " ").split(/\s+/).filter((w) => w.length > 0);
    if (!words.length) return { elapsedMs: 0, groups: [] };
    const seen = new Map();
    for (const s of db.sessions) if (!seen.has(s.cliSessionId)) seen.set(s.cliSessionId, s);
    const mark = (text) => {
      let out = text;
      for (const w of words) {
        const re = new RegExp("(" + w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\w*)", "ig");
        out = out.replace(re, "\u0002$1\u0003");
      }
      return out;
    };
    const lines = [
      ["user", "Can you look at why {t} keeps failing after the last deploy?"],
      ["assistant", "I found the cause of {t}: the config is read before the environment is loaded. Here is a fix."],
      ["user", "Thanks. Now write tests for {t} so it does not come back."],
      ["assistant", "Added three tests that cover {t}, including the Windows path case."],
    ];
    const groups = [];
    let id = 1;
    for (const s of seen.values()) {
      const hay = (s.title + " " + s.cwd).toLowerCase();
      if (!words.every((w) => hay.includes(w) || "deploy tests fix config windows".includes(w))) continue;
      const hits = lines
        .filter(([r]) => role === "any" || r === role)
        .map(([r, text], k) => ({ id: id++, role: r, timestamp: new Date(s.lastActivity - k * 9 * M).toISOString(), snippet: mark(text.replace("{t}", s.title.toLowerCase())) }))
        .filter((h) => h.snippet.includes("\u0002"));
      if (!hits.length) continue;
      const copies = db.sessions.filter((x) => x.sessionId === s.sessionId);
      const inSigned = copies.some((x) => x.accountId === db.active && !x.folderId.includes(".backup"));
      const pick = copies.find((x) => x.accountId === db.active && !x.folderId.includes(".backup")) || copies[0];
      groups.push({
        file: { id: groups.length + 1, cliSessionId: s.cliSessionId, title: s.title, firstPrompt: "Can you look at " + s.title.toLowerCase() + "?",
          cwd: s.cwd, lastTimestamp: new Date(s.lastActivity).toISOString(), messages: 20 + (s.title.length % 30), isSubagent: false },
        hits,
        session: { folderId: pick.folderId, sessionId: pick.sessionId, title: pick.title, inSignedIn: inSigned },
      });
    }
    // One transcript with no sidebar entry.
    if (words.some((w) => "deploy".startsWith(w) || w.startsWith("deploy"))) {
      groups.push({
        file: { id: 999, cliSessionId: "0ddba11-0000-4000-8000-000000000999", title: null, firstPrompt: "deploy script keeps timing out on the build agent",
          cwd: "C:\\code\\tools\\ci", lastTimestamp: new Date(now - 9 * D).toISOString(), messages: 12, isSubagent: false },
        hits: [{ id: id++, role: "user", timestamp: new Date(now - 9 * D).toISOString(), snippet: mark("the deploy script keeps timing out on the build agent") }],
        session: null,
      });
    }
    if (order === "newest") groups.sort((a, b) => String(b.file.lastTimestamp).localeCompare(String(a.file.lastTimestamp)));
    return { elapsedMs: 8 + groups.length, groups };
  }

  async function indexNow() {
    if (db.index.running) return null;
    db.index.running = true;
    for (let k = 1; k <= 10 && db.index.running; k++) {
      db.index.fraction = k / 10;
      emit("relay://state", { sessions: false });
      await sleep(250);
    }
    db.index.running = false;
    db.index.fraction = 0;
    db.index.messages += 214;
    emit("relay://state", { sessions: false });
    return null;
  }

  // ---------- dispatcher ----------
  const handlers = {
    get_state: () => appState(),
    list_sessions: () => sessionsPayload(),
    preview_edits: previewEdits,
    preview_pull: previewPull,
    preview_sync: previewSync,
    preview_restore: previewRestore,
    discard_plan: ({ planId }) => { delete db.plans[planId]; return null; },
    apply_plan: applyPlan,
    open_chat: ({ sessionId }) => { console.log("[mock] open_chat", sessionId); return null; },
    reveal: ({ path }) => { console.log("[mock] reveal", path); return null; },
    switch_account: switchAccount,
    log_in_and_save: logInAndSave,
    add_account: addAccount,
    save_login: saveLogin,
    rename_profile: ({ profileId, name }) => {
      const e = findProfile(profileId);
      if (e) e[1].name = name;
      emit("relay://state", { sessions: false });
      return null;
    },
    forget_profile: ({ profileId }) => {
      const e = findProfile(profileId);
      if (e) delete db.profiles[e[0]];
      emit("relay://state", { sessions: false });
      return null;
    },
    set_settings: (a) => {
      const as = db.autoSwitch;
      if ("autoSwitchEnabled" in a) as.enabled = !!a.autoSwitchEnabled;
      if ("autoSwitchThreshold" in a) as.threshold = Number(a.autoSwitchThreshold);
      if ("autoSwitchWaitForIdle" in a) as.waitForIdle = !!a.autoSwitchWaitForIdle;
      if ("forceQuit" in a) as.forceQuit = !!a.forceQuit;
      if ("switchSync" in a) db.switchSync = !!a.switchSync;
      if ("syncAccounts" in a) db.sync.accounts = a.syncAccounts.slice();
      if ("syncSource" in a) db.sync.source = a.syncSource ? a.syncSource : null;
      if ("includeTools" in a) db.index.includeTools = !!a.includeTools;
      if ("includeSubagents" in a) db.index.includeSubagents = !!a.includeSubagents;
      if ("autoUpdateCheck" in a) update.autoCheck = !!a.autoUpdateCheck;
      return appState();
    },
    check_update: () => { update.checking = false; return appState(); },
    install_update: () => {
      emit("relay://toast", { title: "Updating Relay", text: "Downloading Relay " + update.version + ". Relay restarts when it is installed.", warning: false });
      return null;
    },
    search,
    index_now: () => { indexNow(); return null; },
    cancel_index: () => { db.index.running = false; return null; },
    list_backups: () => JSON.parse(JSON.stringify(db.backups)),
    backup_now: () => {
      const b = { id: "2026-11-08_162000-manual", created: Date.now(), title: "Manual backup", reason: "manual",
        folders: folderList.slice(0, 3).map(short), files: 121, changes: [], removed: 0, applied: true, dir: DATA + "\\backups\\2026-11-08_162000-manual" };
      db.backups.unshift(b);
      return { dir: b.dir, files: b.files };
    },
  };

  window.__TAURI__ = {
    core: {
      invoke(cmd, args) {
        const h = handlers[cmd];
        if (!h) return Promise.reject("Unknown command " + cmd);
        return new Promise((resolve, reject) => {
          setTimeout(() => {
            try {
              Promise.resolve(h(args || {})).then((v) => resolve(v === undefined ? null : JSON.parse(JSON.stringify(v))), reject);
            } catch (e) {
              reject(e);
            }
          }, 30);
        });
      },
    },
    event: {
      listen(event, cb) {
        (listeners[event] = listeners[event] || []).push(cb);
        return Promise.resolve(() => { listeners[event] = (listeners[event] || []).filter((x) => x !== cb); });
      },
    },
    __mock: { emit, db },
  };
})();
