//! Saved Claude desktop logins and switching between them.
//!
//! A saved login lives in <Relay>/profiles/<id>/:
//!   Cookies       copy of Claude's cookie database (values stay encrypted with Claude's own key)
//!   auth.json     the login keys copied from Claude's config.json (encrypted blobs, never shown or logged)
//!   profile.json  this metadata
use crate::claude_app::{self, QuitOptions};
use crate::executor;
use crate::json_patch;
use crate::log::{self, LoginKind};
use crate::paths::Paths;
use crate::plans::{self, WriteIntent};
use crate::usage::AccountHistory;
use crate::util::{err, now_ms, restrict, stamp, write_atomic, Error, Result};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;

/// Keys in config.json that make up the login. Everything else in config.json is left alone.
pub const CONFIG_KEYS: [&str; 3] = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"];

/// Error text prefix when Claude keeps its cookie database locked while it runs (Windows).
pub const LOCKED: &str = "LOCKED:";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginProfile {
    pub id: String,
    pub name: String,
    pub account_id: Option<String>,
    pub saved_at: i64,
    /// When the claude.ai session cookie expires, from the cookie's expiry column, never its value.
    pub session_expires: Option<i64>,
    /// Set when this saved login is known not to work any more.
    pub problem: Option<String>,
}

impl LoginProfile {
    pub fn is_expired(&self) -> bool {
        self.session_expires.map(|e| e < now_ms()).unwrap_or(false)
    }
    pub fn needs_login(&self) -> bool {
        self.problem.is_some() || self.is_expired()
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SwitchResult {
    pub notes: Vec<String>,
    pub warnings: Vec<String>,
    pub login_backup: Option<PathBuf>,
    pub sync_backup: Option<PathBuf>,
    pub carry_backup: Option<PathBuf>,
    pub reopened: bool,
    /// True when Claude ended up on the target account.
    pub switched: bool,
}

fn dir(p: &LoginProfile, paths: &Paths) -> PathBuf {
    paths.profiles_dir().join(&p.id)
}

pub fn list(paths: &Paths) -> Vec<LoginProfile> {
    let Ok(rd) = fs::read_dir(paths.profiles_dir()) else { return vec![] };
    let mut out: Vec<LoginProfile> = rd
        .filter_map(|e| e.ok())
        .filter_map(|e| serde_json::from_slice(&fs::read(e.path().join("profile.json")).ok()?).ok())
        .collect();
    out.sort_by_key(|p| p.name.to_lowercase());
    out
}

pub fn profile_for(account: Option<&str>, paths: &Paths) -> Option<LoginProfile> {
    let account = account?;
    list(paths).into_iter().find(|p| p.account_id.as_deref() == Some(account))
}

fn slug(name: &str) -> String {
    let s: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' }).take(40).collect();
    if s.is_empty() { "account".into() } else { s }
}

fn unique_id(base: &str, paths: &Paths) -> String {
    let mut id = base.to_string();
    let mut n = 2;
    while paths.profiles_dir().join(&id).exists() {
        id = format!("{base}-{n}");
        n += 1;
    }
    id
}

fn read_config(paths: &Paths) -> Result<(Vec<u8>, Map<String, Value>)> {
    let data = fs::read(paths.claude_config()).map_err(|e| Error(format!("Could not read Claude's config.json: {e}")))?;
    match serde_json::from_slice::<Value>(&data) {
        Ok(Value::Object(m)) => Ok((data, m)),
        _ => err("Claude's config.json is not a JSON object."),
    }
}

// MARK: Save

/// Save Claude's current login under `name`. Re-saving the same account updates its profile.
pub fn save_current(name: &str, paths: &Paths) -> Result<LoginProfile> {
    paths.ensure_data_dirs()?;
    let account = paths.active_account_id();
    if account.is_none() || !is_signed_in(paths) {
        return err("Claude does not look signed in. Log in first, then save.");
    }
    let mut profile = profile_for(account.as_deref(), paths).unwrap_or_else(|| LoginProfile {
        id: unique_id(&slug(name), paths),
        name: name.into(),
        account_id: account.clone(),
        saved_at: now_ms(),
        session_expires: None,
        problem: None,
    });
    profile.name = name.into();
    write_snapshot(&mut profile, paths)?;
    Ok(profile)
}

fn write_snapshot(profile: &mut LoginProfile, paths: &Paths) -> Result<()> {
    let d = dir(profile, paths);
    fs::create_dir_all(&d)?;
    restrict(&d);
    let (_, config) = read_config(paths)?;
    let mut auth = Map::new();
    for k in CONFIG_KEYS {
        if let Some(v) = config.get(k) {
            auth.insert(k.into(), v.clone());
        }
    }
    if !auth.contains_key("oauth:tokenCacheV2") && !auth.contains_key("oauth:tokenCache") {
        return err("No saved login found in Claude's config.json. Log in to Claude first, then save.");
    }
    let tmp = d.join(".Cookies.tmp");
    let _ = fs::remove_file(&tmp);
    if let Err(e) = sqlite_backup(&paths.cookies(), &tmp) {
        let _ = fs::remove_file(&tmp);
        if claude_app::is_running() {
            return err(format!("{LOCKED} Claude keeps its login files locked while it runs ({e})."));
        }
        return Err(e);
    }
    write_atomic(&d.join("auth.json"), &serde_json::to_vec(&Value::Object(auth.clone()))?, None)?;
    restrict(&tmp);
    fs::rename(&tmp, d.join("Cookies")).map_err(|e| Error(format!("Could not store the cookie snapshot: {e}")))?;
    if let Some(a) = auth.get("lastKnownAccountUuid").and_then(|v| v.as_str()) {
        profile.account_id = Some(a.into());
    }
    profile.saved_at = now_ms();
    profile.session_expires = session_expiry(&d.join("Cookies"));
    profile.problem = None;
    save_meta(profile, paths)
}

/// Consistent copy of a live SQLite database.
fn sqlite_backup(src: &Path, dst: &Path) -> Result<()> {
    let from = Connection::open_with_flags(src, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    from.busy_timeout(Duration::from_secs(5))?;
    let mut to = Connection::open(dst)?;
    let backup = rusqlite::backup::Backup::new(&from, &mut to)?;
    backup.run_to_completion(1000, Duration::from_millis(100), None)?;
    Ok(())
}

fn cookie_query(cookies: &Path, sql: &str) -> Option<Option<i64>> {
    let c = Connection::open_with_flags(cookies, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()?;
    let _ = c.busy_timeout(Duration::from_secs(2));
    c.query_row(sql, [], |r| r.get::<_, Option<i64>>(0)).ok()
}

/// Latest expiry of the claude.ai session cookies. Reads names and expiry only, never values.
pub fn session_expiry(cookies: &Path) -> Option<i64> {
    let micros = cookie_query(cookies, "SELECT max(expires_utc) FROM cookies WHERE host_key LIKE '%claude.ai' AND name IN ('sessionKey','sessionKeyV3')")??;
    // Chromium time: microseconds since 1601-01-01.
    (micros > 0).then(|| micros / 1000 - 11_644_473_600_000)
}

/// Some(true/false) when the database could be read, None when it could not (locked while Claude runs).
pub fn has_session_cookie(cookies: &Path) -> Option<bool> {
    let n = cookie_query(cookies, "SELECT count(*) FROM cookies WHERE host_key LIKE '%claude.ai' AND name IN ('sessionKey','sessionKeyV3')")?;
    Some(n.unwrap_or(0) > 0)
}

pub fn rename_profile(p: &LoginProfile, name: &str, paths: &Paths) -> Result<()> {
    let mut p = p.clone();
    p.name = name.into();
    save_meta(&p, paths)
}

pub fn delete(p: &LoginProfile, paths: &Paths) -> Result<()> {
    fs::remove_dir_all(dir(p, paths))?;
    Ok(())
}

pub fn save_meta(p: &LoginProfile, paths: &Paths) -> Result<()> {
    write_atomic(&dir(p, paths).join("profile.json"), &serde_json::to_vec_pretty(p)?, None)
}

// MARK: Signed-in state

/// True when Claude's files and its log say an account is signed in right now.
pub fn is_signed_in(paths: &Paths) -> bool {
    let Ok((_, config)) = read_config(paths) else { return false };
    if !config.get("lastKnownAccountUuid").map(|v| v.is_string()).unwrap_or(false) {
        return false;
    }
    if !config.contains_key("oauth:tokenCacheV2") && !config.contains_key("oauth:tokenCache") {
        return false;
    }
    if has_session_cookie(&paths.cookies()) == Some(false) {
        return false;
    }
    log::last_state_is_signed_out(paths) != Some(true)
}

fn settled(paths: &Paths) -> bool {
    // Right after a sign-in Claude is still setting up its tokens.
    log::login_events(paths, None, 1 << 20).last().map(|e| now_ms() - e.date >= 20_000).unwrap_or(true)
}

/// Saved logins only stay valid while that account is not signed in again by hand, so the signed-in
/// account's copy is refreshed regularly. Fails quietly while Claude keeps the files locked.
pub fn refresh_active(paths: &Paths, min_interval_ms: i64) -> Option<LoginProfile> {
    let id = paths.active_account_id()?;
    let mut p = profile_for(Some(&id), paths)?;
    if !is_signed_in(paths) || (p.problem.is_none() && now_ms() - p.saved_at < min_interval_ms) || !settled(paths) {
        return None;
    }
    write_snapshot(&mut p, paths).ok()?;
    Some(p)
}

/// Save the signed-in account under `name` if it has no saved login yet, once Claude has settled.
pub fn save_new_if_settled(account: &str, name: &str, paths: &Paths) -> Option<LoginProfile> {
    if paths.active_account_id().as_deref() != Some(account) || profile_for(Some(account), paths).is_some() || !is_signed_in(paths) || !settled(paths) {
        return None;
    }
    save_current(name, paths).ok()
}

/// Flag saved logins that Claude's log shows were signed out after they were saved.
pub fn update_problems(paths: &Paths) {
    let events = log::login_events(paths, None, 2 << 20);
    if events.is_empty() {
        return;
    }
    for mut p in list(paths).into_iter().filter(|p| p.problem.is_none()) {
        let Some(acc) = p.account_id.clone() else { continue };
        let ended = events.iter().find(|e| e.date > p.saved_at + 1000 && matches!(&e.kind, LoginKind::SignedOut { from: Some(f) } if *f == acc));
        if let Some(e) = ended {
            p.problem = Some(format!("Signed out inside Claude on {}, which ended this saved login. Use Log In Again.", crate::util::local(e.date).format("%-d %b %H:%M")));
            let _ = save_meta(&p, paths);
        }
    }
}

// MARK: Shared steps

fn login_backup_dir(paths: &Paths, suffix: &str) -> Result<PathBuf> {
    paths.ensure_data_dirs()?;
    let base = format!("{}-{suffix}", stamp(now_ms()));
    let mut d = paths.backups_dir().join(&base);
    let mut n = 2;
    while d.exists() {
        d = paths.backups_dir().join(format!("{base}-{n}"));
        n += 1;
    }
    fs::create_dir_all(&d)?;
    restrict(&d);
    Ok(d)
}

const SWAP_SUFFIXES: [&str; 3] = ["switch-login", "switch-back", "add-account"];

/// When Relay swapped Claude's login files, from the names of its login backups.
pub fn login_swap_dates(paths: &Paths) -> Vec<i64> {
    let Ok(rd) = fs::read_dir(paths.backups_dir()) else { return vec![] };
    let mut out: Vec<i64> = rd
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.len() > 18 && SWAP_SUFFIXES.iter().any(|s| n[18..].starts_with(s)))
        .filter_map(|n| crate::util::parse_stamp(&n[..17]))
        .collect();
    out.sort();
    out
}

fn write_config(data: &[u8], paths: &Paths) -> Result<()> {
    write_atomic(&paths.claude_config(), data, None).map_err(|e| Error(format!("Could not update Claude's config.json: {}", e.0)))
}

/// Save the account being left, so its refreshed tokens are kept. A signed-out state is never saved.
fn save_outgoing(paths: &Paths, result: &mut SwitchResult, step: &mut dyn FnMut(&str)) -> Result<Option<LoginProfile>> {
    let Some(current) = paths.active_account_id() else { return Ok(None) };
    if !is_signed_in(paths) {
        result.notes.push("Claude was signed out, so there was no login to save first.".into());
        return Ok(None);
    }
    if let Some(mut cur) = profile_for(Some(&current), paths) {
        step(&format!("Saving the current login ({})", cur.name));
        write_snapshot(&mut cur, paths)?;
        return Ok(Some(cur));
    }
    step("Saving the current login");
    let p = save_current(&format!("Account {}", crate::util::short(&current)), paths)?;
    result.notes.push(format!("The current account had no saved login, so it was saved as {}.", p.name));
    Ok(Some(p))
}

/// Merge chats between folders while Claude is closed. Problems skip it with a warning.
fn merge_chats(ids: Option<&[String]>, paths: &Paths, result: &mut SwitchResult, step: &mut dyn FnMut(&str)) -> Result<()> {
    let Some(ids) = ids.filter(|i| i.len() >= 2) else { return Ok(()) };
    step("Merging chats between accounts");
    let plan = plans::plan(&WriteIntent::Sync(ids.to_vec()), paths);
    if !plan.problems.is_empty() {
        result.warnings.push(format!("Chat merge skipped: {}", problem_list(&plan)));
    } else if !plan.changes.is_empty() {
        let r = executor::apply(&plan, paths, &mut |_| {})?;
        result.sync_backup = Some(r.backup.dir.clone());
        result.notes.push(format!("Merged chats: {} written, {} moved to the backup.", r.written, r.moved));
    }
    Ok(())
}

/// Bring chats along to the account being switched to, while Claude is closed.
fn carry_chats(intent: Option<&WriteIntent>, paths: &Paths, result: &mut SwitchResult, step: &mut dyn FnMut(&str)) -> Result<()> {
    let Some(intent) = intent else { return Ok(()) };
    let plan = plans::plan(intent, paths);
    if !plan.problems.is_empty() {
        result.warnings.push(format!("Chats were not brought along: {}", problem_list(&plan)));
    } else if !plan.changes.is_empty() {
        step("Bringing chats along");
        let r = executor::apply(&plan, paths, &mut |_| {})?;
        result.carry_backup = Some(r.backup.dir.clone());
        let chats = plan.changes.iter().filter(|c| matches!(c.kind, plans::ChangeKind::Add | plans::ChangeKind::Update))
            .map(|c| c.target.clone()).collect::<std::collections::HashSet<_>>().len();
        result.notes.push(format!("Brought {chats} chat{} along.", if chats == 1 { "" } else { "s" }));
    }
    Ok(())
}

fn problem_list(plan: &plans::WritePlan) -> String {
    plan.problems.iter()
        .map(|p| format!("{}: {}", p.path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(), p.message))
        .collect::<Vec<_>>().join("; ")
}

/// Put a profile's login files in place, after backing up the current ones. Claude must not be running.
fn restore_files(profile: &LoginProfile, paths: &Paths, suffix: &str) -> Result<PathBuf> {
    let d = dir(profile, paths);
    let auth: Map<String, Value> = match fs::read(d.join("auth.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()) {
        Some(Value::Object(m)) if d.join("Cookies").exists() => m,
        _ => return err(format!("The saved login for {} is incomplete. Use Log In Again for it.", profile.name)),
    };
    let backup = login_backup_dir(paths, suffix)?;
    let cookies = paths.cookies();
    let journal = cookies.with_file_name("Cookies-journal");
    for src in [cookies.clone(), journal.clone(), paths.claude_config()] {
        if src.exists() {
            fs::copy(&src, backup.join(src.file_name().unwrap()))?;
        }
    }
    let mut sets: Vec<(&str, Value)> = vec![];
    let mut removes: Vec<&str> = vec![];
    for k in CONFIG_KEYS {
        match auth.get(k) {
            Some(v) => sets.push((k, v.clone())),
            None => removes.push(k),
        }
    }
    let (config_data, _) = read_config(paths)?;
    let new_config = json_patch::remove(&json_patch::patch(&config_data, &sets)?, &removes)?;

    let tmp = cookies.with_file_name(".Cookies.relay-tmp");
    let _ = fs::remove_file(&tmp);
    fs::copy(d.join("Cookies"), &tmp)?;
    restrict(&tmp);
    // A leftover journal could roll the swapped database back, so it goes first.
    if journal.exists() {
        fs::remove_file(&journal)?;
    }
    fs::rename(&tmp, &cookies).map_err(|e| Error(format!("Could not put the cookie database in place ({e}). The previous files are in {}.", backup.display())))?;
    write_config(&new_config, paths)?;
    // Claude does not always log a sign-in when it opens on a swapped login, so note it here.
    AccountHistory::record(profile.account_id.as_deref(), now_ms() + 1, paths);
    Ok(backup)
}

// MARK: Add another account / log in again

/// Reopen Claude signed out without logging out, so saved logins stay valid on the server.
pub fn prepare_fresh_login(paths: &Paths, sync: Option<&[String]>, quit: QuitOptions, step: &mut dyn FnMut(&str)) -> Result<SwitchResult> {
    let mut result = SwitchResult::default();
    let mut quit_by_us = false;
    if paths.is_live_claude_dir() && claude_app::is_running() {
        step("Quitting Claude");
        claude_app::quit(quit)?;
        quit_by_us = true;
    }
    let inner = (|| -> Result<()> {
        save_outgoing(paths, &mut result, step)?;
        merge_chats(sync, paths, &mut result, step)?;
        step("Moving the login files aside");
        let backup = login_backup_dir(paths, "add-account")?;
        result.login_backup = Some(backup.clone());
        let (config_data, _) = read_config(paths)?;
        fs::copy(paths.claude_config(), backup.join("config.json"))?;
        let cookies = paths.cookies();
        for src in [cookies.clone(), cookies.with_file_name("Cookies-journal")] {
            if src.exists() {
                let dst = backup.join(src.file_name().unwrap());
                if fs::rename(&src, &dst).is_err() {
                    fs::copy(&src, &dst)?;
                    fs::remove_file(&src)?;
                }
            }
        }
        write_config(&json_patch::remove(&config_data, &CONFIG_KEYS)?, paths)?;
        AccountHistory::record(None, now_ms(), paths);
        result.notes.push("Claude is signed out. Log in to the account there. Relay saves it by itself once you are in.".into());
        Ok(())
    })();
    if let Err(e) = inner {
        if quit_by_us {
            let _ = claude_app::open();
        }
        return Err(e);
    }
    if quit_by_us {
        step("Reopening Claude");
        result.reopened = claude_app::open().is_ok();
    }
    step("Done");
    Ok(result)
}

// MARK: Switch

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Acceptance {
    Accepted,
    Rejected,
}

/// After Claude reopens with a restored login. Rejected when the log shows a sign-out that is not followed by
/// this account signing in; accepted when the log shows this account signed in, or when enough time passes
/// without a sign-out and the login files still point to this account.
pub fn wait_for_acceptance(target: &LoginProfile, since: i64, paths: &Paths, timeout_s: u64, quiet_s: u64) -> Acceptance {
    let mut sign_out_seen_at: Option<u64> = None;
    let signed_in = |e: &log::LoginEvent| matches!(&e.kind, LoginKind::SignedIn { account, .. } if Some(account.as_str()) == target.account_id.as_deref());
    for second in 1..=timeout_s {
        sleep(Duration::from_secs(1));
        let events = log::login_events(paths, Some(since), 1 << 20);
        if let Some(last_out) = events.iter().rposition(|e| e.is_sign_out()) {
            if events[last_out + 1..].iter().any(signed_in) {
                return Acceptance::Accepted;
            }
            let seen = *sign_out_seen_at.get_or_insert(second);
            if second - seen >= 5 {
                return Acceptance::Rejected;
            }
            continue;
        }
        if events.iter().any(signed_in) {
            return Acceptance::Accepted;
        }
        if second >= quiet_s && paths.active_account_id() == target.account_id && has_session_cookie(&paths.cookies()) != Some(false) {
            return Acceptance::Accepted;
        }
    }
    if sign_out_seen_at.is_none() && paths.active_account_id() == target.account_id { Acceptance::Accepted } else { Acceptance::Rejected }
}

/// Quit Claude, save the current login, optionally merge or bring chats along, back up and swap the login
/// files, reopen Claude and check it accepted the login. If Claude rejects it, the previous login goes back.
/// `verifier` replaces the check against the live Claude (tests).
pub fn switch_to(
    target: &LoginProfile,
    sync: Option<&[String]>,
    carry: Option<&WriteIntent>,
    paths: &Paths,
    quit: QuitOptions,
    verifier: Option<&dyn Fn(&LoginProfile) -> Acceptance>,
    step: &mut dyn FnMut(&str),
) -> Result<SwitchResult> {
    let mut result = SwitchResult::default();
    if target.is_expired() {
        return err(format!("The saved login for {} expired. Use Log In Again for it.", target.name));
    }
    if let Some(problem) = &target.problem {
        return err(format!("{}: {problem}", target.name));
    }
    let live = paths.is_live_claude_dir();
    let mut quit_by_us = false;
    if live && claude_app::is_running() {
        step("Quitting Claude");
        claude_app::quit(quit)?;
        quit_by_us = true;
    }
    let mut outgoing = None;
    let inner = (|| -> Result<()> {
        outgoing = save_outgoing(paths, &mut result, step)?;
        merge_chats(sync, paths, &mut result, step)?;
        carry_chats(carry, paths, &mut result, step)?;
        step(&format!("Restoring the login for {}", target.name));
        result.login_backup = Some(restore_files(target, paths, "switch-login")?);
        Ok(())
    })();
    if let Err(e) = inner {
        if quit_by_us {
            let _ = claude_app::open();
        }
        return Err(e);
    }

    let opened_at = now_ms() - 1000;
    if live {
        step("Reopening Claude");
        result.reopened = claude_app::open().is_ok();
    }
    let verdict = if let Some(v) = verifier {
        v(target)
    } else if live {
        step("Checking that Claude accepted the login");
        wait_for_acceptance(target, opened_at, paths, 40, 15)
    } else {
        Acceptance::Accepted
    };
    if verdict == Acceptance::Accepted {
        result.switched = true;
        result.notes.push(format!("Switched to {}.", target.name));
        step("Done");
        return Ok(result);
    }

    // Rejected: flag the profile and go back to the account we came from.
    let mut broken = target.clone();
    broken.problem = Some("Claude did not accept this saved login. It was most likely ended by Log out in Claude, or by signing in to this account again by hand. Use Log In Again.".into());
    let _ = save_meta(&broken, paths);
    let Some(back) = outgoing else {
        result.warnings.push(format!("Claude did not accept the saved login for {} and is now signed out. Use Log In Again for {}, or log in to any account in Claude.", target.name, target.name));
        step("Done");
        return Ok(result);
    };
    step(&format!("Claude did not accept it. Switching back to {}", back.name));
    if live && claude_app::is_running() {
        claude_app::quit(quit)?;
    }
    restore_files(&back, paths, "switch-back")?;
    if live {
        let _ = claude_app::open();
    }
    result.warnings.push(format!(
        "Claude did not accept the saved login for {}, so you are back on {}. That saved login was most likely ended by Log out in Claude or by signing in to it again by hand. Use Log In Again for {} once, and switching works from then on.",
        target.name, back.name, target.name
    ));
    step("Done");
    Ok(result)
}
