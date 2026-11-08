//! Relay for Windows: a tray app around relay-core. The window is plain HTML/JS in ../ui, which calls the
//! commands below (see ../API.md for the contract).
use relay_core::backups;
use relay_core::claude_app::{self, QuitOptions};
use relay_core::executor::{self, Outcome};
use relay_core::index::{self, IndexSettings, Order, Role};
use relay_core::model::{SessionFolder, SessionRecord, Snapshot};
use relay_core::paths::Paths;
use relay_core::plans::{self, PullItem, SessionEdit, WriteIntent, WritePlan};
use relay_core::profiles::{self, LoginProfile, LOCKED};
use relay_core::scanner;
use relay_core::usage::{self, activity, auto_switch, AccountHistory, AccountUsage};
use relay_core::util::{local, now_ms, short};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_updater::UpdaterExt;

// MARK: State

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Settings {
    auto_switch_enabled: bool,
    auto_switch_threshold: i64,
    auto_switch_wait_for_idle: bool,
    force_quit: bool,
    switch_sync: bool,
    sync_accounts: Vec<String>,
    sync_source: Option<String>,
    include_tools: bool,
    include_subagents: bool,
    auto_update_check: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            auto_switch_enabled: false,
            auto_switch_threshold: 95,
            auto_switch_wait_for_idle: true,
            force_quit: true,
            switch_sync: false,
            sync_accounts: vec![],
            sync_source: None,
            include_tools: false,
            include_subagents: false,
            auto_update_check: true,
        }
    }
}

impl Settings {
    fn load(paths: &Paths) -> Settings {
        std::fs::read(paths.settings_file()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }
    fn save(&self, paths: &Paths) {
        let _ = paths.ensure_data_dirs();
        if let Ok(data) = serde_json::to_vec_pretty(self) {
            let _ = relay_core::util::write_atomic(&paths.settings_file(), &data, None);
        }
    }
    fn index(&self) -> IndexSettings {
        IndexSettings { include_tools: self.include_tools, include_subagents: self.include_subagents }
    }
    fn quit(&self) -> QuitOptions {
        QuitOptions { timeout: Duration::from_secs(30), force: self.force_quit }
    }
}

struct StoredPlan {
    intent: WriteIntent,
    keys: BTreeSet<String>,
    note: Option<String>,
    open_after: Option<String>,
}

struct Inner {
    paths: Paths,
    settings: Settings,
    snapshot: Snapshot,
    profiles: Vec<LoginProfile>,
    usage: HashMap<String, AccountUsage>,
    active_usage_current: bool,
    emails: HashMap<String, String>,
    claude_running: bool,
    switching: bool,
    steps: Vec<String>,
    auto_status: Option<String>,
    auto_waiting_since: Option<i64>,
    last_auto_switch: Option<i64>,
    no_candidate_notice: Option<i64>,
    awaiting_login: Option<String>,
    plans: HashMap<String, StoredPlan>,
    index_progress: index::Progress,
    index_stats: index::Stats,
    index_cancel: Arc<AtomicBool>,
    index_restart: bool,
    update: UpdateState,
    /// The version Tauri was built with (the release tag), which the updater compares against.
    app_version: String,
}

/// What the last update check found.
#[derive(Clone, Debug, Default)]
struct UpdateState {
    version: Option<String>,
    notes: Option<String>,
    checking: bool,
    error: Option<String>,
    /// The version a notification was already shown for.
    notified: Option<String>,
}

type Shared = Arc<Mutex<Inner>>;

fn lock(s: &Shared) -> std::sync::MutexGuard<'_, Inner> {
    s.lock().unwrap_or_else(|e| e.into_inner())
}

// MARK: Labels and DTOs

impl Inner {
    fn refresh(&mut self) {
        self.snapshot = scanner::scan(&self.paths);
        self.profiles = profiles::list(&self.paths);
        self.claude_running = claude_app::is_running();
    }

    fn active(&self) -> Option<String> {
        self.snapshot.active_account_id.clone()
    }

    fn label(&self, f: &SessionFolder) -> String {
        let mut s = if let Some(email) = self.emails.get(&f.account_id) {
            let siblings = self.snapshot.folders.iter().filter(|x| x.folder.account_id == f.account_id && !x.folder.is_backup_copy()).count();
            let mut s = email.clone();
            if siblings > 1 || f.is_backup_copy() {
                s += &format!(" / org {}", short(&f.org_id));
            }
            if f.is_backup_copy() {
                s += " (backup copy)";
            }
            s
        } else {
            f.short_label()
        };
        if Some(&f.account_id) == self.snapshot.active_account_id.as_ref() && !f.is_backup_copy() {
            s += " (signed in)";
        }
        s
    }

    fn account_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = vec![];
        let mut add = |id: &str| {
            if !ids.iter().any(|x| x == id) {
                ids.push(id.to_string());
            }
        };
        if let Some(a) = &self.snapshot.active_account_id {
            add(a);
        }
        for f in self.snapshot.folders.iter().filter(|f| !f.folder.is_backup_copy()) {
            add(&f.folder.account_id);
        }
        for p in &self.profiles {
            if let Some(a) = &p.account_id {
                add(a);
            }
        }
        ids
    }

    fn profile_of(&self, account: &str) -> Option<&LoginProfile> {
        self.profiles.iter().find(|p| p.account_id.as_deref() == Some(account))
    }

    fn title_of(&self, account: &str) -> String {
        self.emails.get(account).cloned()
            .or_else(|| self.profile_of(account).map(|p| p.name.clone()))
            .unwrap_or_else(|| format!("Account {}", short(account)))
    }

    fn sync_folder_ids(&self) -> Vec<String> {
        self.account_ids().iter().filter(|a| self.settings.sync_accounts.contains(a)).flat_map(|a| self.snapshot.folder_ids_of(a)).collect()
    }

    fn auto_pick(&self) -> Option<String> {
        let active = self.active();
        let candidates: Vec<auto_switch::Candidate> = self.profiles.iter()
            .filter(|p| !p.needs_login() && p.account_id.is_some() && p.account_id != active)
            .map(|p| auto_switch::Candidate { account_id: p.account_id.clone().unwrap(), usage: self.usage.get(p.account_id.as_ref().unwrap()).cloned() })
            .collect();
        auto_switch::pick(&candidates, self.settings.auto_switch_threshold, now_ms()).map(|c| c.account_id.clone())
    }

    fn account_entry(&self, id: &str) -> Value {
        let profile = self.profile_of(id);
        let active = self.active().as_deref() == Some(id);
        let (text, warning) = match profile {
            None => (if active { "Signed in, not saved yet".to_string() } else { "Not saved yet".to_string() }, false),
            Some(p) if p.problem.is_some() => (p.problem.clone().unwrap(), true),
            Some(p) if p.is_expired() => ("Saved login expired. Use Log In Again.".into(), true),
            Some(p) => {
                let mut t = format!("Saved {}", local(p.saved_at).format("%-d %b %Y %H:%M"));
                if let Some(e) = p.session_expires {
                    t += &format!(", valid until {}", local(e).format("%-d %b %Y"));
                }
                (t, false)
            }
        };
        let now = now_ms();
        let usage = self.usage.get(id).map(|u| json!({
            "fiveHour": u.five_hour_now(now),
            "fiveHourResetsAt": u.five_hour_reset(now),
            "week": u.seven_day_now(now),
            "weekResetsAt": u.week_reset(now),
            "sampledAt": u.sampled_at,
            "current": !active || self.active_usage_current,
        }));
        let email = self.emails.get(id).cloned();
        let nickname = profile.and_then(|p| (Some(&p.name) != email.as_ref()).then(|| p.name.clone()));
        let folder_ids = self.snapshot.folder_ids_of(id);
        let chats: HashSet<&String> = self.snapshot.folders.iter().filter(|f| folder_ids.contains(&f.folder.id()))
            .flat_map(|f| f.sessions.iter().map(|s| &s.session_id)).collect();
        json!({
            "id": id,
            "title": self.title_of(id),
            "email": email,
            "nickname": nickname,
            "isActive": active,
            "profile": profile.map(|p| json!({
                "id": p.id, "name": p.name, "savedAt": p.saved_at, "sessionExpires": p.session_expires,
                "problem": p.problem, "needsLogin": p.needs_login(),
            })),
            "status": { "text": text, "warning": warning },
            "usage": usage,
            "chatCount": chats.len(),
            "folderIds": folder_ids,
        })
    }

    fn state(&self) -> Value {
        let mut ids = self.account_ids();
        ids.sort_by(|a, b| {
            let (aa, ba) = (self.active().as_deref() == Some(a), self.active().as_deref() == Some(b));
            ba.cmp(&aa).then(self.title_of(a).to_lowercase().cmp(&self.title_of(b).to_lowercase()))
        });
        let p = &self.index_progress;
        let index_status = if p.running {
            format!("Indexing {} of {} files, {:.0}%", p.files_done, p.files_total, p.fraction() * 100.0)
        } else {
            format!("{} chats, {} messages indexed", self.index_stats.files, self.index_stats.messages)
        };
        json!({
            "appVersion": self.app_version,
            "platform": std::env::consts::OS,
            "claudeRunning": self.claude_running,
            "activeAccountId": self.active(),
            "switching": self.switching,
            "steps": self.steps,
            "accounts": ids.iter().map(|id| self.account_entry(id)).collect::<Vec<_>>(),
            "autoSwitch": {
                "enabled": self.settings.auto_switch_enabled,
                "threshold": self.settings.auto_switch_threshold,
                "waitForIdle": self.settings.auto_switch_wait_for_idle,
                "forceQuit": self.settings.force_quit,
                "status": self.auto_status,
                "nextAccountId": if self.settings.auto_switch_enabled { self.auto_pick() } else { None },
            },
            "switchSync": self.settings.switch_sync,
            "sync": { "accounts": self.settings.sync_accounts, "source": self.settings.sync_source },
            "index": {
                "running": p.running, "fraction": p.fraction(), "status": index_status,
                "includeTools": self.settings.include_tools, "includeSubagents": self.settings.include_subagents,
            },
            "paths": {
                "data": self.paths.data_dir, "backups": self.paths.backups_dir(), "claude": self.paths.claude_dir,
            },
            "update": {
                "current": self.app_version,
                "available": self.update.version.is_some(),
                "version": self.update.version,
                "notes": self.update.notes,
                "checking": self.update.checking,
                "error": self.update.error,
                "autoCheck": self.settings.auto_update_check,
            },
        })
    }

    fn session_dto(&self, s: &SessionRecord) -> Value {
        json!({
            "key": s.key(), "folderId": s.folder.id(), "accountId": s.folder.account_id, "sessionId": s.session_id,
            "cliSessionId": s.cli_session_id, "title": s.title, "titleSource": s.title_source, "cwd": s.cwd,
            "isArchived": s.is_archived, "isStarred": s.is_starred, "inArchivedIndex": s.in_archived_index,
            "lastActivity": s.last_activity_at.unwrap_or(s.file_mtime), "createdAt": s.created_at,
            "fileMTime": s.file_mtime, "fileSize": s.file_size, "file": s.file, "model": s.model,
            "problems": s.problems, "resumeCommand": s.resume_command(),
        })
    }

    fn plan_dto(&self, id: &str, plan: &WritePlan, note: Option<&String>, open_after: Option<&String>) -> Value {
        let folders: HashSet<String> = plan.changes.iter().map(|c| c.folder.id()).collect();
        let mut summary = format!("{} change(s) in {} folder(s)", plan.changes.len(), folders.len());
        if !plan.problems.is_empty() {
            summary += &format!(", {} problem(s) block applying", plan.problems.len());
        }
        if !plan.warnings.is_empty() {
            summary += &format!(", {} warning(s)", plan.warnings.len());
        }
        json!({
            "id": id,
            "title": plan.title,
            "summary": summary,
            "changes": plan.changes.iter().map(|c| json!({
                "folderId": c.folder.id(), "folderLabel": self.label(&c.folder), "kind": c.kind,
                "summary": c.summary, "detail": c.detail,
            })).collect::<Vec<_>>(),
            "problems": plan.problems.iter().map(|p| json!({ "path": p.path, "message": p.message })).collect::<Vec<_>>(),
            "warnings": plan.warnings,
            "canApply": plan.can_apply(),
            "note": note,
            "openAfter": open_after,
        })
    }

    fn store_plan(&mut self, intent: WriteIntent, note: Option<String>, open_after: Option<String>) -> Value {
        let plan = plans::plan(&intent, &self.paths);
        let id = uuid::Uuid::new_v4().to_string();
        let dto = self.plan_dto(&id, &plan, note.as_ref(), open_after.as_ref());
        self.plans.insert(id, StoredPlan { intent, keys: plan.keys(), note, open_after });
        dto
    }
}

// MARK: Notices, events, window

fn emit_state(app: &AppHandle, sessions: bool) {
    let _ = app.emit("relay://state", json!({ "sessions": sessions }));
    rebuild_tray(app);
}

fn window_in_front(app: &AppHandle) -> bool {
    app.get_webview_window("main").map(|w| w.is_visible().unwrap_or(false) && w.is_focused().unwrap_or(false)).unwrap_or(false)
}

/// In the window when it is in front, otherwise a Windows notification. `system` forces a notification.
fn notify(app: &AppHandle, title: &str, text: &str, warning: bool, system: bool) {
    if system || !window_in_front(app) {
        if app.notification().builder().title(title).body(text).show().is_ok() {
            return;
        }
    }
    let _ = app.emit("relay://toast", json!({ "title": title, "text": text, "warning": warning }));
}

/// For results the window shows itself: only a Windows notification, and only when the window is not in front.
fn notify_if_away(app: &AppHandle, title: &str, text: &str, warning: bool) {
    if !window_in_front(app) {
        notify(app, title, text, warning, true);
    }
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn set_steps(app: &AppHandle, shared: &Shared, steps: &[String]) {
    lock(shared).steps = steps.to_vec();
    let _ = app.emit("relay://steps", steps);
}

/// A step callback that collects the steps and sends them to the window.
fn stepper(app: &AppHandle, shared: &Shared) -> impl FnMut(&str) {
    let app = app.clone();
    let shared = shared.clone();
    let mut steps: Vec<String> = vec![];
    move |s: &str| {
        steps.push(s.to_string());
        set_steps(&app, &shared, &steps);
    }
}

fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> impl std::future::Future<Output = T> {
    async move { tauri::async_runtime::spawn_blocking(f).await.expect("worker thread") }
}

/// Open a chat once Claude has had a moment to start.
fn open_when_up(session_id: String) {
    thread::spawn(move || {
        for _ in 0..40 {
            if claude_app::is_running() {
                break;
            }
            thread::sleep(Duration::from_millis(500));
        }
        thread::sleep(Duration::from_secs(4));
        let _ = claude_app::open_url(&format!("claude://claude.ai/epitaxy/{session_id}"));
    });
}

// MARK: Commands: state and chats

#[tauri::command]
fn get_state(shared: State<Shared>) -> Value {
    let mut s = lock(&shared);
    s.claude_running = claude_app::is_running();
    s.state()
}

#[tauri::command]
fn list_sessions(shared: State<Shared>) -> Value {
    let mut s = lock(&shared);
    s.refresh();
    let folders: Vec<Value> = s.snapshot.folders.iter().map(|f| json!({
        "id": f.folder.id(), "accountId": f.folder.account_id, "orgId": f.folder.org_id,
        "label": s.label(&f.folder), "isBackupCopy": f.folder.is_backup_copy(), "count": f.sessions.len(),
    })).collect();
    let sessions: Vec<Value> = s.snapshot.all_sessions().map(|r| s.session_dto(r)).collect();
    json!({ "activeAccountId": s.active(), "folders": folders, "sessions": sessions })
}

#[tauri::command]
fn preview_edits(shared: State<Shared>, edits: Vec<SessionEdit>) -> Value {
    lock(&shared).store_plan(WriteIntent::Edits(edits), None, None)
}

#[tauri::command]
fn preview_pull(shared: State<Shared>, items: Vec<PullItem>, open_after: Option<String>, note: Option<String>) -> Result<Value, String> {
    let mut s = lock(&shared);
    s.refresh();
    let Some(active) = s.active() else { return Err("Claude is not signed in to an account.".into()) };
    let targets = s.snapshot.folder_ids_of(&active);
    Ok(s.store_plan(WriteIntent::Pull { items, targets }, note, open_after))
}

#[tauri::command]
fn preview_sync(shared: State<Shared>) -> Result<Value, String> {
    let mut s = lock(&shared);
    s.refresh();
    let picked: Vec<String> = s.account_ids().into_iter().filter(|a| s.settings.sync_accounts.contains(a)).collect();
    let intent = match s.settings.sync_source.clone().filter(|src| picked.contains(src)) {
        Some(src) => {
            let targets: Vec<String> = picked.iter().filter(|a| **a != src).flat_map(|a| s.snapshot.folder_ids_of(a)).collect();
            if targets.is_empty() {
                return Err("Tick at least one other account to copy to.".into());
            }
            WriteIntent::Copy { sources: s.snapshot.folder_ids_of(&src), targets }
        }
        None => {
            let ids = s.sync_folder_ids();
            if ids.len() < 2 {
                return Err("Tick at least two accounts.".into());
            }
            WriteIntent::Sync(ids)
        }
    };
    Ok(s.store_plan(intent, None, None))
}

#[tauri::command]
fn preview_restore(shared: State<Shared>, backup_id: String) -> Result<Value, String> {
    let mut s = lock(&shared);
    let b = backups::list(&s.paths).into_iter().find(|b| b.id == backup_id).ok_or("Backup not found.")?;
    Ok(s.store_plan(WriteIntent::RestoreBackup(b), None, None))
}

#[tauri::command]
fn discard_plan(shared: State<Shared>, plan_id: String) {
    lock(&shared).plans.remove(&plan_id);
}

#[tauri::command]
async fn apply_plan(app: AppHandle, shared: State<'_, Shared>, plan_id: String) -> Result<Value, String> {
    let shared = shared.inner().clone();
    let (intent, keys, note, open_after, paths, quit) = {
        let s = lock(&shared);
        if s.switching {
            return Err("A switch is running. Try again when it is done.".into());
        }
        let p = s.plans.get(&plan_id).ok_or("This preview is gone. Open it again.")?;
        (p.intent.clone(), p.keys.clone(), p.note.clone(), p.open_after.clone(), s.paths.clone(), s.settings.quit())
    };
    let mut step = stepper(&app, &shared);
    let outcome = blocking(move || executor::run(&intent, &keys, &paths, quit, &mut step)).await;
    let result = match outcome {
        Ok(Outcome::Applied { result, reopened }) => {
            lock(&shared).plans.remove(&plan_id);
            if let Some(sid) = open_after {
                open_when_up(sid);
            }
            Ok(json!({
                "status": "applied", "written": result.written, "moved": result.moved, "backupDir": result.backup.dir,
                "reopened": reopened, "warnings": result.log.iter().filter(|l| l.starts_with("WARNING")).collect::<Vec<_>>(),
            }))
        }
        Ok(Outcome::PlanChanged(plan)) => {
            let mut s = lock(&shared);
            let note = Some("Claude changed some files while quitting, so the plan changed. Claude is still closed. Review the new list and apply again.".to_string());
            let dto = s.plan_dto(&plan_id, &plan, note.as_ref(), open_after.as_ref());
            if let Some(p) = s.plans.get_mut(&plan_id) {
                p.keys = plan.keys();
                p.note = note.or(p.note.take());
            }
            Ok(json!({ "status": "planChanged", "plan": dto }))
        }
        Err(e) => Err(e.0),
    };
    let _ = note;
    lock(&shared).refresh();
    emit_state(&app, true);
    result
}

#[tauri::command]
fn open_chat(app: AppHandle, shared: State<Shared>, session_id: String) -> Result<(), String> {
    // The window says so itself when the chat is archived.
    let _ = (app, shared);
    claude_app::open_url(&format!("claude://claude.ai/epitaxy/{session_id}")).map_err(|e| e.0)
}

#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    let p = std::path::PathBuf::from(&path);
    if p.is_dir() {
        app.opener().open_path(path, None::<&str>).map_err(|e| e.to_string())
    } else {
        app.opener().reveal_item_in_dir(p).map_err(|e| e.to_string())
    }
}

// MARK: Commands: accounts

#[tauri::command]
async fn switch_account(app: AppHandle, shared: State<'_, Shared>, account_id: String) -> Result<Value, String> {
    let shared = shared.inner().clone();
    run_switch(&app, &shared, &account_id, None, None, None).await
}

/// The one way every switch runs, manual or automatic.
async fn run_switch(app: &AppHandle, shared: &Shared, account_id: &str, carry: Option<WriteIntent>, open_after: Option<String>, auto: Option<String>) -> Result<Value, String> {
    let (profile, sync, paths, quit, who) = {
        let mut s = lock(shared);
        if s.switching {
            return Err("A switch is already running.".into());
        }
        let p = s.profile_of(account_id).cloned().ok_or("This account has no saved login yet.")?;
        s.switching = true;
        s.steps.clear();
        let sync = s.settings.switch_sync.then(|| s.sync_folder_ids()).filter(|v| v.len() >= 2);
        (p, sync, s.paths.clone(), s.settings.quit(), s.title_of(account_id))
    };
    emit_state(app, false);
    let mut step = stepper(app, shared);
    let res = blocking(move || profiles::switch_to(&profile, sync.as_deref(), carry.as_ref(), &paths, quit, None, &mut step)).await;
    {
        let mut s = lock(shared);
        s.switching = false;
        s.refresh();
    }
    refresh_usage(app, shared, false);
    emit_state(app, true);
    match res {
        Ok(r) => {
            if r.switched {
                if let Some(sid) = open_after {
                    open_when_up(sid);
                }
            }
            let body = auto.iter().cloned().chain(r.notes.iter().cloned()).chain(r.warnings.iter().cloned()).collect::<Vec<_>>().join(" ");
            let title = if r.switched { format!("Switched to {who}") } else { format!("Could not switch to {who}") };
            if auto.is_some() {
                notify(app, &title, &body, !r.warnings.is_empty(), true);
            } else {
                notify_if_away(app, &title, &body, !r.warnings.is_empty());
            }
            Ok(json!({ "switched": r.switched, "notes": r.notes, "warnings": r.warnings }))
        }
        Err(e) => {
            if auto.is_some() {
                notify(app, &format!("Could not switch to {who}"), &e.0, true, true);
            }
            Err(e.0)
        }
    }
}

async fn fresh_login(app: &AppHandle, shared: &Shared, awaiting: Option<String>) -> Result<Value, String> {
    let (sync, paths, quit) = {
        let mut s = lock(shared);
        if s.switching {
            return Err("A switch is already running.".into());
        }
        s.switching = true;
        s.steps.clear();
        s.awaiting_login = awaiting.clone();
        let sync = s.settings.switch_sync.then(|| s.sync_folder_ids()).filter(|v| v.len() >= 2);
        (sync, s.paths.clone(), s.settings.quit())
    };
    emit_state(app, false);
    let mut step = stepper(app, shared);
    let res = blocking(move || profiles::prepare_fresh_login(&paths, sync.as_deref(), quit, &mut step)).await;
    {
        let mut s = lock(shared);
        s.switching = false;
        s.refresh();
    }
    emit_state(app, true);
    match res {
        Ok(r) => {
            let who = awaiting.map(|a| lock(shared).title_of(&a)).unwrap_or_else(|| "the account".into());
            notify_if_away(app, "Claude is signed out", &format!("Log in to {who} in Claude. Relay saves it by itself once you are in."), false);
            Ok(json!({ "notes": r.notes, "warnings": r.warnings }))
        }
        Err(e) => Err(e.0),
    }
}

#[tauri::command]
async fn log_in_and_save(app: AppHandle, shared: State<'_, Shared>, account_id: String) -> Result<Value, String> {
    let shared = shared.inner().clone();
    fresh_login(&app, &shared, Some(account_id)).await
}

#[tauri::command]
async fn add_account(app: AppHandle, shared: State<'_, Shared>) -> Result<Value, String> {
    let shared = shared.inner().clone();
    fresh_login(&app, &shared, None).await
}

#[tauri::command]
async fn save_login(app: AppHandle, shared: State<'_, Shared>, name: String, quit_claude: Option<bool>) -> Result<Value, String> {
    let shared = shared.inner().clone();
    let (paths, quit) = {
        let s = lock(&shared);
        (s.paths.clone(), s.settings.quit())
    };
    let name = if name.trim().is_empty() { "Account".to_string() } else { name.trim().to_string() };
    let res = blocking(move || -> Result<LoginProfile, String> {
        match profiles::save_current(&name, &paths) {
            Err(e) if e.0.starts_with(LOCKED) && quit_claude == Some(true) => {
                claude_app::quit(quit).map_err(|e| e.0)?;
                let saved = profiles::save_current(&name, &paths).map_err(|e| e.0);
                let _ = claude_app::open();
                saved
            }
            other => other.map_err(|e| e.0),
        }
    })
    .await?;
    let entry = {
        let mut s = lock(&shared);
        s.refresh();
        s.account_entry(res.account_id.as_deref().unwrap_or_default())
    };
    emit_state(&app, false);
    notify_if_away(&app, "Login saved", &format!("Saved the current Claude login as {}.", res.name), false);
    Ok(entry)
}

#[tauri::command]
fn rename_profile(app: AppHandle, shared: State<Shared>, profile_id: String, name: String) -> Result<(), String> {
    let mut s = lock(&shared);
    let p = s.profiles.iter().find(|p| p.id == profile_id).cloned().ok_or("Saved login not found.")?;
    profiles::rename_profile(&p, name.trim(), &s.paths).map_err(|e| e.0)?;
    s.refresh();
    drop(s);
    emit_state(&app, false);
    Ok(())
}

#[tauri::command]
fn forget_profile(app: AppHandle, shared: State<Shared>, profile_id: String) -> Result<(), String> {
    let mut s = lock(&shared);
    let p = s.profiles.iter().find(|p| p.id == profile_id).cloned().ok_or("Saved login not found.")?;
    profiles::delete(&p, &s.paths).map_err(|e| e.0)?;
    s.refresh();
    drop(s);
    emit_state(&app, false);
    Ok(())
}

/// Every field is optional; only the ones sent change. `syncSource: ""` means merge.
#[allow(clippy::too_many_arguments)]
#[tauri::command]
fn set_settings(
    app: AppHandle,
    shared: State<Shared>,
    auto_switch_enabled: Option<bool>,
    auto_switch_threshold: Option<i64>,
    auto_switch_wait_for_idle: Option<bool>,
    force_quit: Option<bool>,
    switch_sync: Option<bool>,
    sync_accounts: Option<Vec<String>>,
    sync_source: Option<String>,
    include_tools: Option<bool>,
    include_subagents: Option<bool>,
    auto_update_check: Option<bool>,
) -> Value {
    let mut s = lock(&shared);
    let before = s.settings.clone();
    let set = &mut s.settings;
    if let Some(v) = auto_switch_enabled { set.auto_switch_enabled = v; }
    if let Some(v) = auto_switch_threshold { set.auto_switch_threshold = v.clamp(50, 100); }
    if let Some(v) = auto_switch_wait_for_idle { set.auto_switch_wait_for_idle = v; }
    if let Some(v) = force_quit { set.force_quit = v; }
    if let Some(v) = switch_sync { set.switch_sync = v; }
    if let Some(v) = sync_accounts { set.sync_accounts = v; }
    if let Some(v) = sync_source { set.sync_source = (!v.is_empty()).then_some(v); }
    if let Some(v) = include_tools { set.include_tools = v; }
    if let Some(v) = include_subagents { set.include_subagents = v; }
    if let Some(v) = auto_update_check { set.auto_update_check = v; }
    s.settings.save(&s.paths);
    if s.settings.auto_switch_enabled != before.auto_switch_enabled {
        s.auto_status = None;
        s.auto_waiting_since = None;
        if s.settings.auto_switch_enabled {
            let _ = app.notification().request_permission();
        }
    }
    if s.settings.index() != before.index() {
        s.index_cancel.store(true, Ordering::SeqCst);
        s.index_restart = true;
    }
    let state = s.state();
    drop(s);
    rebuild_tray(&app);
    state
}

// MARK: Commands: search and backups

#[tauri::command]
async fn search(shared: State<'_, Shared>, query: String, role: Option<Role>, order: Option<Order>) -> Result<Value, String> {
    let shared = shared.inner().clone();
    let db = lock(&shared).paths.index_db();
    let started = std::time::Instant::now();
    let q = query.clone();
    let groups = blocking(move || index::search(&db, &q, role.unwrap_or(Role::Any), order.unwrap_or(Order::Relevance), 600)).await?;
    let s = lock(&shared);
    let map = s.snapshot.sessions_by_cli();
    let active = s.active();
    let have: HashSet<String> = active.as_deref().map(|a| s.snapshot.chat_ids_of(a)).unwrap_or_default();
    let out: Vec<Value> = groups.iter().map(|g| {
        let session = s.snapshot.preferred_session(&g.file.cli_session_id, &map).map(|r| json!({
            "folderId": r.folder.id(), "sessionId": r.session_id, "title": r.title, "inSignedIn": have.contains(&r.session_id),
        }));
        json!({
            "file": {
                "id": g.file.id, "cliSessionId": g.file.cli_session_id, "title": g.file.title, "firstPrompt": g.file.first_prompt,
                "cwd": g.file.cwd, "lastTimestamp": g.file.last_timestamp, "messages": g.file.messages, "isSubagent": g.file.is_subagent,
            },
            "hits": g.hits.iter().map(|h| json!({ "id": h.id, "role": h.role, "timestamp": h.timestamp, "snippet": h.snippet })).collect::<Vec<_>>(),
            "session": session,
        })
    }).collect();
    Ok(json!({ "groups": out, "elapsedMs": started.elapsed().as_millis() as u64 }))
}

#[tauri::command]
fn index_now(app: AppHandle, shared: State<Shared>) {
    start_indexing(&app, shared.inner());
}

#[tauri::command]
fn cancel_index(shared: State<Shared>) {
    lock(&shared).index_cancel.store(true, Ordering::SeqCst);
}

#[tauri::command]
fn list_backups(shared: State<Shared>) -> Value {
    let s = lock(&shared);
    let list: Vec<Value> = backups::list(&s.paths).iter().map(|b| json!({
        "id": b.id, "created": b.created, "title": b.title, "reason": b.reason,
        "folders": b.folders.iter().map(|f| format!("{}/{}", short(&f.account_id), short(&f.org_id))).collect::<Vec<_>>(),
        "files": b.files.len(), "changes": b.changes, "removed": b.removed.len(), "applied": b.applied, "dir": b.dir,
    })).collect();
    Value::Array(list)
}

#[tauri::command]
fn backup_now(shared: State<Shared>) -> Result<Value, String> {
    let mut s = lock(&shared);
    s.refresh();
    let folders: Vec<SessionFolder> = s.snapshot.folders.iter().map(|f| f.folder.clone()).filter(|f| !f.is_backup_copy()).collect();
    let mut b = backups::create(&folders, "manual", "Manual backup", vec![], &s.paths).map_err(|e| e.0)?;
    b.applied = true;
    let _ = backups::save(&b);
    Ok(json!({ "dir": b.dir, "files": b.files.len() }))
}

// MARK: Updates

/// Ask GitHub for the latest release. The update is only offered when its signature matches the public
/// key built into Relay; the updater checks that again before installing.
async fn run_update_check(app: &AppHandle, shared: &Shared, from_background: bool) -> Result<(), String> {
    {
        let mut s = lock(shared);
        if s.update.checking {
            return Ok(());
        }
        s.update.checking = true;
        s.update.error = None;
    }
    emit_state(app, false);
    let result = match app.updater() {
        Ok(u) => u.check().await.map_err(|e| e.to_string()),
        Err(e) => Err(e.to_string()),
    };
    let notify_version = {
        let mut s = lock(shared);
        s.update.checking = false;
        match &result {
            Ok(Some(u)) => {
                s.update.version = Some(u.version.clone());
                s.update.notes = u.body.clone();
            }
            Ok(None) => {
                s.update.version = None;
                s.update.notes = None;
            }
            // A failed background check stays quiet; a manual one shows why.
            Err(e) => {
                if !from_background {
                    s.update.error = Some(format!("Could not check for updates: {e}"));
                }
            }
        }
        let v = s.update.version.clone().filter(|v| s.update.notified.as_ref() != Some(v));
        if v.is_some() {
            s.update.notified = v.clone();
        }
        v
    };
    emit_state(app, false);
    if let Some(v) = notify_version.filter(|_| from_background) {
        notify(app, "Relay update available", &format!("Relay {v} is ready to install. Open Relay and click Install."), false, false);
    }
    result.map(|_| ())
}

#[tauri::command]
async fn check_update(app: AppHandle, shared: State<'_, Shared>) -> Result<Value, String> {
    let shared = shared.inner().clone();
    let _ = run_update_check(&app, &shared, false).await;
    let state = lock(&shared).state();
    Ok(state)
}

/// Download, check the signature, run the installer. On Windows Relay exits while the installer runs and is
/// started again when it is done.
#[tauri::command]
async fn install_update(app: AppHandle, shared: State<'_, Shared>) -> Result<(), String> {
    if lock(&shared).switching {
        return Err("A switch is running. Install the update when it is done.".into());
    }
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?
        .ok_or("Relay is already up to date.")?;
    let _ = app.emit("relay://toast", json!({ "title": "Updating Relay", "text": format!("Downloading Relay {}. Relay restarts when it is installed.", update.version), "warning": false }));
    update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
    app.restart();
}

// MARK: Background work

/// Keep the signed-in account's saved login current, flag ended ones, save a login that was asked for.
fn maintain_profiles(app: &AppHandle, shared: &Shared) {
    let (paths, awaiting, name) = {
        let s = lock(shared);
        if s.switching {
            return;
        }
        let name = s.awaiting_login.as_ref().map(|a| s.title_of(a));
        (s.paths.clone(), s.awaiting_login.clone(), name)
    };
    let mut refreshed = profiles::refresh_active(&paths, 300_000);
    if refreshed.is_none() {
        if let (Some(a), Some(n)) = (&awaiting, &name) {
            refreshed = profiles::save_new_if_settled(a, n, &paths);
        }
    }
    profiles::update_problems(&paths);
    let mut s = lock(shared);
    if s.switching {
        return;
    }
    s.profiles = profiles::list(&paths);
    if let Some(r) = refreshed {
        if s.awaiting_login.is_some() && (s.awaiting_login == r.account_id || s.awaiting_login.as_deref() == Some(&r.id)) {
            s.awaiting_login = None;
            let who = r.account_id.as_deref().map(|a| s.title_of(a)).unwrap_or(r.name.clone());
            drop(s);
            notify(app, "Login saved", &format!("Saved the login for {who}. You can switch to it from the tray icon now."), false, false);
        }
    }
}

/// Read usage, and when `evaluate` is set, let auto-switch act on it.
fn refresh_usage(app: &AppHandle, shared: &Shared, evaluate: bool) {
    let paths = lock(shared).paths.clone();
    AccountHistory::note_current(&paths);
    let events = usage::timeline_events(&paths);
    let map = usage::account_usage(&usage::read_samples(&paths), &events);
    let active = paths.active_account_id();
    let current = active.as_deref().and_then(|a| map.get(a)).map(|u| usage::is_current(u, &events)).unwrap_or(false);
    let emails = index::account_emails(&paths.index_db());
    {
        let mut s = lock(shared);
        s.usage = map;
        s.active_usage_current = current;
        if !emails.is_empty() {
            s.emails = emails;
        }
        s.claude_running = claude_app::is_running();
    }
    if evaluate {
        evaluate_auto_switch(app, shared);
    }
}

/// Recent chats of an account, newest first, one per chat.
fn recent_chats(snap: &Snapshot, account: &str, within_ms: i64) -> Vec<SessionRecord> {
    let cutoff = now_ms() - within_ms;
    let mut best: HashMap<String, SessionRecord> = HashMap::new();
    for f in snap.folders.iter().filter(|f| f.folder.account_id == account && !f.folder.is_backup_copy()) {
        for s in f.sessions.iter().filter(|s| s.activity() >= cutoff) {
            if best.get(&s.session_id).map(|c| c.activity() >= s.activity()).unwrap_or(false) {
                continue;
            }
            best.insert(s.session_id.clone(), s.clone());
        }
    }
    let mut out: Vec<SessionRecord> = best.into_values().collect();
    out.sort_by_key(|s| -s.activity());
    out
}

fn evaluate_auto_switch(app: &AppHandle, shared: &Shared) {
    let now = now_ms();
    let mut s = lock(shared);
    if !s.settings.auto_switch_enabled {
        s.auto_status = None;
        return;
    }
    let Some(active) = s.paths.active_account_id() else { return };
    let why = s.usage.get(&active).filter(|_| s.active_usage_current).and_then(|u| auto_switch::reason(u, s.settings.auto_switch_threshold, now));
    let Some(why) = why.filter(|_| !s.switching && s.claude_running) else {
        s.auto_status = None;
        s.auto_waiting_since = None;
        return;
    };
    let from = s.title_of(&active);
    if s.last_auto_switch.map(|t| now - t < 600_000).unwrap_or(false) {
        s.auto_status = Some(format!("{from}: {why}. Waiting a few minutes after the last automatic switch before trying again."));
        return;
    }
    let Some(target) = s.auto_pick() else {
        let threshold = s.settings.auto_switch_threshold;
        s.auto_status = Some(format!("{from}: {why}, and every other saved account is at {threshold}% or more. Staying on {from}."));
        if s.no_candidate_notice.map(|t| now - t > 3 * 3_600_000).unwrap_or(true) {
            s.no_candidate_notice = Some(now);
            drop(s);
            notify(app, "No account to switch to", &format!("{from}: {why}. Every other saved account is at {threshold}% or more too, so Claude stays on {from}."), true, true);
        }
        return;
    };
    let target_title = s.title_of(&target);
    // Read the chat lists again: the last scan can be old, and a new chat must count.
    s.snapshot = scanner::scan(&s.paths);
    if s.settings.auto_switch_wait_for_idle {
        let mine: HashSet<String> = s.snapshot.folders.iter().filter(|f| f.folder.account_id == active)
            .flat_map(|f| f.sessions.iter().filter_map(|x| x.cli_session_id.clone())).collect();
        let running = activity::busy_transcripts(&s.paths, &mine, 1_800_000, now);
        if !running.is_empty() {
            let n = running.len();
            let what = if n == 1 { "the running chat finishes".to_string() } else { format!("{n} running chats finish") };
            s.auto_status = Some(format!("{from}: {why}. Will switch to {target_title} once {what}."));
            if s.auto_waiting_since.is_none() {
                s.auto_waiting_since = Some(now);
                drop(s);
                notify(app, "Auto-switch is waiting", &format!("{from}: {why}. Switching to {target_title} once {what}."), false, true);
            }
            return;
        }
    }
    s.auto_status = None;
    s.auto_waiting_since = None;
    s.last_auto_switch = Some(now);
    // Chats worked on in the last day come along, and the newest one opens again.
    let recent = recent_chats(&s.snapshot, &active, 86_400_000);
    let targets = s.snapshot.folder_ids_of(&target);
    let carry = (!recent.is_empty() && !targets.is_empty()).then(|| WriteIntent::Pull {
        items: recent.iter().map(|r| PullItem { folder_id: r.folder.id(), session_id: r.session_id.clone() }).collect(),
        targets: targets.clone(),
    });
    let open_after = (!targets.is_empty()).then(|| recent.first().map(|r| r.session_id.clone())).flatten();
    drop(s);
    let app2 = app.clone();
    let shared2 = shared.clone();
    let reason = format!("{from} was switched away from because {why}.");
    tauri::async_runtime::block_on(async move {
        let _ = run_switch(&app2, &shared2, &target, carry, open_after, Some(reason)).await;
    });
}

fn start_indexing(app: &AppHandle, shared: &Shared) {
    let (paths, settings, cancel) = {
        let mut s = lock(shared);
        if s.index_progress.running {
            return;
        }
        s.index_progress = index::Progress { running: true, ..Default::default() };
        let cancel = Arc::new(AtomicBool::new(false));
        s.index_cancel = cancel.clone();
        (s.paths.clone(), s.settings.index(), cancel)
    };
    let app = app.clone();
    let shared = shared.clone();
    thread::spawn(move || {
        let _ = paths.ensure_data_dirs();
        let mut last = std::time::Instant::now();
        let mut report = |p: &index::Progress| {
            if last.elapsed() > Duration::from_millis(500) {
                last = std::time::Instant::now();
                lock(&shared).index_progress = index::Progress { running: true, ..p.clone() };
                let _ = app.emit("relay://state", json!({ "sessions": false }));
            }
        };
        let cancelled = || cancel.load(Ordering::SeqCst);
        let result = index::update(&paths.index_db(), &paths.projects_root, settings, &mut report, &cancelled);
        let restart = {
            let mut s = lock(&shared);
            s.index_progress = index::Progress::default();
            if result.is_ok() {
                s.index_stats = index::stats(&paths.index_db());
                let emails = index::account_emails(&paths.index_db());
                if !emails.is_empty() {
                    s.emails = emails;
                }
            }
            std::mem::take(&mut s.index_restart)
        };
        emit_state(&app, false);
        if restart {
            start_indexing(&app, &shared);
        }
    });
}

// MARK: Tray

fn rebuild_tray(app: &AppHandle) {
    let Some(tray) = app.tray_by_id("main") else { return };
    let Some(shared) = app.try_state::<Shared>() else { return };
    let menu = (|| -> tauri::Result<Menu<tauri::Wry>> {
        let s = lock(shared.inner());
        let m = Menu::new(app)?;
        m.append(&MenuItem::with_id(app, "open", "Open Relay", true, None::<&str>)?)?;
        m.append(&MenuItem::with_id(app, "search", "Search Chats", true, None::<&str>)?)?;
        m.append(&PredefinedMenuItem::separator(app)?)?;
        if s.switching {
            let last = s.steps.last().cloned().unwrap_or_else(|| "starting".into());
            m.append(&MenuItem::with_id(app, "status", format!("Switching: {last}"), false, None::<&str>)?)?;
        } else {
            m.append(&MenuItem::with_id(app, "header", "Claude account", false, None::<&str>)?)?;
            let now = now_ms();
            for id in s.account_ids() {
                let active = s.active().as_deref() == Some(id.as_str());
                let usage = s.usage.get(&id).map(|u| {
                    let mut t = format!("   5h {}%", u.five_hour_now(now));
                    if let Some(w) = u.seven_day_now(now) {
                        t += &format!(" \u{00B7} wk {w}%");
                    }
                    t
                }).unwrap_or_default();
                let p = s.profile_of(&id);
                let label = if active {
                    format!("\u{2713} {}{usage}", s.title_of(&id))
                } else if p.map(|p| !p.needs_login()).unwrap_or(false) {
                    format!("     {}{usage}", s.title_of(&id))
                } else {
                    format!("     {} ({})", s.title_of(&id), if p.is_none() { "log in to save" } else { "log in again" })
                };
                m.append(&MenuItem::with_id(app, format!("acct:{id}"), label, !active, None::<&str>)?)?;
            }
            if s.settings.auto_switch_enabled {
                let text = s.auto_status.clone().unwrap_or_else(|| format!("Auto-switch on at {}%", s.settings.auto_switch_threshold));
                m.append(&MenuItem::with_id(app, "auto", text, false, None::<&str>)?)?;
            }
            m.append(&MenuItem::with_id(app, "accounts", "Manage Accounts...", true, None::<&str>)?)?;
        }
        m.append(&PredefinedMenuItem::separator(app)?)?;
        if let Some(v) = &s.update.version {
            m.append(&MenuItem::with_id(app, "update", format!("Install Relay {v}..."), !s.switching, None::<&str>)?)?;
        } else {
            m.append(&MenuItem::with_id(app, "update-check", "Check for Updates", !s.update.checking, None::<&str>)?)?;
        }
        m.append(&MenuItem::with_id(app, "quit", "Quit Relay", true, None::<&str>)?)?;
        Ok(m)
    })();
    if let Ok(menu) = menu {
        let _ = tray.set_menu(Some(menu));
    }
}

fn on_menu(app: &AppHandle, id: &str) {
    match id {
        "open" => show_main(app),
        "search" | "accounts" => {
            show_main(app);
            let _ = app.emit("relay://navigate", if id == "search" { "search" } else { "accounts" });
        }
        "quit" => app.exit(0),
        "update" => {
            // Confirm and install from the window, where progress and errors show.
            show_main(app);
            let _ = app.emit("relay://navigate", "accounts");
        }
        "update-check" => {
            let app = app.clone();
            let Some(shared) = app.try_state::<Shared>().map(|s| s.inner().clone()) else { return };
            thread::spawn(move || {
                tauri::async_runtime::block_on(async {
                    let ok = run_update_check(&app, &shared, false).await.is_ok();
                    let (version, current) = { let s = lock(&shared); (s.update.version.clone(), s.app_version.clone()) };
                    match (ok, version) {
                        (true, Some(v)) => notify(&app, "Relay update available", &format!("Relay {v} is ready to install. Open Relay and click Install."), false, true),
                        (true, None) => notify(&app, "Relay is up to date", &format!("You have the latest version, {current}."), false, true),
                        (false, _) => notify(&app, "Could not check for updates", "GitHub could not be reached. Try again later.", true, true),
                    }
                });
            });
        }
        _ => {
            let Some(account) = id.strip_prefix("acct:").map(String::from) else { return };
            let app = app.clone();
            thread::spawn(move || confirm_and_activate(&app, &account));
        }
    }
}

/// From the tray: confirm with a Windows dialog, then switch, or log in for an account without a working login.
fn confirm_and_activate(app: &AppHandle, account: &str) {
    let Some(shared) = app.try_state::<Shared>().map(|s| s.inner().clone()) else { return };
    let (who, can_switch, merge) = {
        let s = lock(&shared);
        (s.title_of(account), s.profile_of(account).map(|p| !p.needs_login()).unwrap_or(false), s.settings.switch_sync && s.sync_folder_ids().len() >= 2)
    };
    let (title, mut text, button) = if can_switch {
        (format!("Switch Claude to {who}?"), format!("Claude will quit, which stops any running Code chats, then reopen signed in as {who}. The current login is saved first and backed up."), "Switch")
    } else {
        (format!("Log in to {who}?"), format!("The current login is saved first. Claude quits, which stops any running Code chats, and reopens signed out. Log in to {who} there. Relay saves that login by itself within a minute."), "Continue")
    };
    if merge {
        text += " Chats are merged between the accounts picked in Sync chats first.";
    }
    let ok = app.dialog().message(text).title(title).buttons(MessageDialogButtons::OkCancelCustom(button.into(), "Cancel".into())).blocking_show();
    if !ok {
        return;
    }
    let app2 = app.clone();
    let account = account.to_string();
    tauri::async_runtime::block_on(async move {
        let res = if can_switch { run_switch(&app2, &shared, &account, None, None, None).await } else { fresh_login(&app2, &shared, Some(account.clone())).await };
        if let Err(e) = res {
            notify(&app2, &format!("Could not switch to {who}"), &e, true, true);
        }
    });
}

// MARK: App

pub fn run() {
    let paths = Paths::standard();
    let _ = paths.ensure_data_dirs();
    let settings = Settings::load(&paths);
    let mut inner = Inner {
        snapshot: scanner::scan(&paths),
        profiles: profiles::list(&paths),
        usage: HashMap::new(),
        active_usage_current: false,
        emails: index::account_emails(&paths.index_db()),
        claude_running: claude_app::is_running(),
        switching: false,
        steps: vec![],
        auto_status: None,
        auto_waiting_since: None,
        last_auto_switch: None,
        no_candidate_notice: None,
        awaiting_login: None,
        plans: HashMap::new(),
        index_progress: index::Progress::default(),
        index_stats: index::stats(&paths.index_db()),
        index_cancel: Arc::new(AtomicBool::new(false)),
        index_restart: false,
        update: UpdateState::default(),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        settings,
        paths,
    };
    inner.refresh();
    let shared: Shared = Arc::new(Mutex::new(inner));

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main(app)))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![
            get_state, list_sessions, preview_edits, preview_pull, preview_sync, preview_restore, discard_plan, apply_plan,
            open_chat, reveal, switch_account, log_in_and_save, add_account, save_login, rename_profile, forget_profile,
            set_settings, search, index_now, cancel_index, list_backups, backup_now, check_update, install_update
        ])
        .on_window_event(|window, event| {
            // Closing the window keeps Relay running in the tray.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            lock(&shared).app_version = app.package_info().version.to_string();
            let icon = app.default_window_icon().cloned().expect("app icon");
            TrayIconBuilder::with_id("main")
                .icon(icon)
                .tooltip("Relay")
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| on_menu(app, event.id.as_ref()))
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show_main(tray.app_handle());
                    }
                })
                .build(app)?;
            rebuild_tray(&handle);

            // Every minute: keep logins fresh, read usage, let auto-switch act. RELAY_NO_BACKGROUND=1 turns
            // this off, for looking at the UI against real data without saving anything.
            if std::env::var_os("RELAY_NO_BACKGROUND").is_none() {
                let (app1, shared1) = (handle.clone(), shared.clone());
                thread::spawn(move || loop {
                    maintain_profiles(&app1, &shared1);
                    refresh_usage(&app1, &shared1, true);
                    emit_state(&app1, false);
                    thread::sleep(Duration::from_secs(60));
                });
                let (app2, shared2) = (handle.clone(), shared.clone());
                thread::spawn(move || loop {
                    start_indexing(&app2, &shared2);
                    thread::sleep(Duration::from_secs(600));
                });
                // Updates: a minute after start, then every 6 hours, while the setting is on.
                let (app3, shared3) = (handle.clone(), shared.clone());
                thread::spawn(move || {
                    thread::sleep(Duration::from_secs(60));
                    loop {
                        if lock(&shared3).settings.auto_update_check {
                            let (a, s) = (app3.clone(), shared3.clone());
                            tauri::async_runtime::block_on(async move {
                                let _ = run_update_check(&a, &s, true).await;
                            });
                        }
                        thread::sleep(Duration::from_secs(6 * 3600));
                    }
                });
            } else {
                let paths = lock(&shared).paths.clone();
                let events = usage::timeline_events(&paths);
                lock(&shared).usage = usage::account_usage(&usage::read_samples(&paths), &events);
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Relay");
}
