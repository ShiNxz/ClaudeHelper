//! Applies a plan: backup first, allowlisted paths only, atomic writes, then a check of what was written.
use crate::backups::{self, BackupInfo};
use crate::claude_app::{self, QuitOptions};
use crate::paths::Paths;
use crate::plans::{self, FileOp, WriteIntent, WritePlan};
use crate::schema;
use crate::util::{err, write_atomic, Result};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

/// The real path of the nearest existing ancestor plus the rest, so a file that does not exist yet still
/// gets a stable path and links compare equal.
fn canonical(path: &Path) -> PathBuf {
    let mut cur = path.to_path_buf();
    let mut rest: Vec<std::ffi::OsString> = vec![];
    while !cur.exists() {
        match (cur.file_name(), cur.parent()) {
            (Some(name), Some(parent)) => {
                rest.insert(0, name.to_os_string());
                cur = parent.to_path_buf();
            }
            _ => return path.to_path_buf(),
        }
    }
    let mut out = fs::canonicalize(&cur).unwrap_or(cur);
    for r in rest {
        out.push(r);
    }
    out
}

/// Defense in depth: the only paths Relay may ever create, replace or move are
/// <claude-code-sessions>/<account>/<org>/<local_*.json | archived-sessions.idx | deleted_*>.
pub fn is_allowed_target(target: &Path, paths: &Paths) -> bool {
    if target.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
        return false;
    }
    let root: Vec<String> = canonical(&paths.sessions_root).components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
    let comps: Vec<String> = canonical(target).components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
    if comps.len() != root.len() + 3 || comps[..root.len()] != root[..] {
        return false;
    }
    schema::is_managed_name(comps.last().unwrap())
}

#[derive(Debug, Clone)]
pub struct ApplyResult {
    pub backup: BackupInfo,
    pub written: usize,
    pub moved: usize,
    pub log: Vec<String>,
}

pub fn apply(plan: &WritePlan, paths: &Paths, say: &mut dyn FnMut(&str)) -> Result<ApplyResult> {
    if !plan.problems.is_empty() {
        return err(format!("Refusing to write: {} schema problem(s).", plan.problems.len()));
    }
    if plan.changes.is_empty() {
        return err("Nothing to apply.");
    }
    if let Some(c) = plan.changes.iter().find(|c| !is_allowed_target(&c.target, paths)) {
        return err(format!("Refusing to touch {}: outside the session files Relay manages.", c.target.display()));
    }
    if paths.is_live_sessions_root() && claude_app::is_running() {
        return err("Claude is running. Quit it first or it will overwrite these files.");
    }
    say(&format!("Backing up {} folder(s)", plan.folders.len()));
    let changes: Vec<String> = plan.changes.iter().map(|c| format!("{}: {}", c.folder.short_label(), c.summary)).collect();
    let mut backup = backups::create(&plan.folders, &plan.reason, &plan.title, changes, paths)?;
    say(&format!("Backup: {}", backup.dir.display()));

    let mut log = vec![];
    let (mut written, mut moved) = (0, 0);
    for c in &plan.changes {
        match &c.op {
            FileOp::Write { data, mtime } => {
                write_atomic(&c.target, data, *mtime).map_err(|e| crate::util::Error(format!("{} Backup at {}", e.0, backup.dir.display())))?;
                written += 1;
                log.push(format!("wrote {}", c.target.display()));
            }
            FileOp::MoveToBackup => {
                if !c.target.exists() {
                    continue;
                }
                let rel = format!("{}/{}/{}", c.folder.account_id, c.folder.org_id, c.target.file_name().unwrap().to_string_lossy());
                let dest = backup.removed_dir().join(&c.folder.account_id).join(&c.folder.org_id).join(c.target.file_name().unwrap());
                fs::create_dir_all(dest.parent().unwrap())?;
                if fs::rename(&c.target, &dest).is_err() {
                    fs::copy(&c.target, &dest)?;
                    fs::remove_file(&c.target)?;
                }
                backup.removed.push(rel);
                moved += 1;
                log.push(format!("moved {} -> {}", c.target.display(), dest.display()));
            }
        }
    }
    // Every written file must still pass the schema guard.
    for c in &plan.changes {
        let FileOp::Write { .. } = c.op else { continue };
        let Ok(data) = fs::read(&c.target) else { continue };
        let name = c.target.file_name().unwrap().to_string_lossy().to_string();
        if name.starts_with("local_") {
            let v: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
            let problems = schema::session_problems(&v, &c.target);
            if !problems.is_empty() {
                log.push(format!("WARNING after write: {name}: {}", problems.join("; ")));
            }
        } else if name == "archived-sessions.idx" {
            if let Some(p) = schema::parse_archived_index(&data).1 {
                log.push(format!("WARNING after write: {name}: {p}"));
            }
        }
    }
    backup.applied = true;
    let _ = backups::save(&backup);
    say(&format!("Wrote {written} file(s), moved {moved} to the backup"));
    Ok(ApplyResult { backup, written, moved, log })
}

#[derive(Debug)]
pub enum Outcome {
    Applied { result: ApplyResult, reopened: bool },
    /// After Claude quit, the files no longer match the preview. Claude stays closed; show the new plan.
    PlanChanged(WritePlan),
}

/// Quit Claude, plan again from disk, check it still matches what the user saw, back up, apply, reopen Claude.
pub fn run(intent: &WriteIntent, preview_keys: &BTreeSet<String>, paths: &Paths, quit: QuitOptions, step: &mut dyn FnMut(&str)) -> Result<Outcome> {
    let mut quit_by_us = false;
    if paths.is_live_sessions_root() && claude_app::is_running() {
        step("Quitting Claude");
        claude_app::quit(quit)?;
        quit_by_us = true;
    }
    let result = (|| -> Result<Outcome> {
        step("Reading the files again");
        let plan = plans::plan(intent, paths);
        if !plan.problems.is_empty() {
            let list: Vec<String> = plan.problems.iter().map(|p| format!("{}: {}", p.path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(), p.message)).collect();
            return err(format!("Schema guard: {}", list.join("; ")));
        }
        if plan.keys() != *preview_keys {
            step("Files changed since the preview");
            return Ok(Outcome::PlanChanged(plan));
        }
        let result = apply(&plan, paths, step)?;
        Ok(Outcome::Applied { result, reopened: false })
    })();
    match result {
        Ok(Outcome::Applied { result, .. }) => {
            let mut reopened = false;
            if quit_by_us {
                step("Reopening Claude");
                reopened = claude_app::open().is_ok();
            }
            step("Done");
            Ok(Outcome::Applied { result, reopened })
        }
        Ok(changed) => Ok(changed),
        Err(e) => {
            if quit_by_us {
                step("Reopening Claude after an error");
                let _ = claude_app::open();
            }
            Err(e)
        }
    }
}
