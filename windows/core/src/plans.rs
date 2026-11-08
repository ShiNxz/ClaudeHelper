//! Turns what the user asked for into a list of file changes, without writing anything.
//! Plans are always rebuilt from disk, so the same intent can be planned again after Claude quits.
use crate::backups::{self, BackupInfo};
use crate::model::{FolderScan, SessionFolder, SessionRecord};
use crate::paths::Paths;
use crate::scanner;
use crate::schema;
use crate::util::{fmt_date, quoted};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub enum FileOp {
    /// Create or replace a file. `mtime` keeps the source file's modification time (sync, restore).
    Write { data: Vec<u8>, mtime: Option<i64> },
    /// Move the file into the backup's removed/ folder instead of deleting it.
    MoveToBackup,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChangeKind {
    Edit,
    Add,
    Update,
    RemoveDeleted,
    AddMarker,
    ArchivedIndex,
    PutBack,
    MoveOut,
}

#[derive(Clone, Debug)]
pub struct PlannedChange {
    pub folder: SessionFolder,
    pub kind: ChangeKind,
    pub target: PathBuf,
    pub summary: String,
    pub detail: Option<String>,
    pub op: FileOp,
}

impl PlannedChange {
    /// Identity used to compare a preview with the plan rebuilt after Claude quits.
    pub fn key(&self) -> String {
        format!("{:?}|{}", self.kind, self.target.display())
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct GuardProblem {
    pub path: PathBuf,
    pub message: String,
}

#[derive(Clone, Debug, Default)]
pub struct WritePlan {
    pub title: String,
    pub reason: String,
    pub changes: Vec<PlannedChange>,
    pub problems: Vec<GuardProblem>,
    pub warnings: Vec<String>,
    /// Folders backed up before applying.
    pub folders: Vec<SessionFolder>,
}

impl WritePlan {
    fn new(title: impl Into<String>, reason: &str) -> Self {
        WritePlan { title: title.into(), reason: reason.into(), ..Default::default() }
    }
    pub fn keys(&self) -> BTreeSet<String> {
        self.changes.iter().map(|c| c.key()).collect()
    }
    pub fn can_apply(&self) -> bool {
        self.problems.is_empty() && !self.changes.is_empty()
    }
    fn problem(&mut self, path: PathBuf, message: impl Into<String>) {
        self.problems.push(GuardProblem { path, message: message.into() });
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEdit {
    pub folder_id: String,
    pub session_id: String,
    pub title: Option<String>,
    pub is_archived: Option<bool>,
    pub is_starred: Option<bool>,
}

impl SessionEdit {
    pub fn is_empty(&self) -> bool {
        self.title.is_none() && self.is_archived.is_none() && self.is_starred.is_none()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullItem {
    pub folder_id: String,
    pub session_id: String,
}

#[derive(Clone, Debug)]
pub enum WriteIntent {
    Edits(Vec<SessionEdit>),
    /// Merge: every folder ends up with every chat.
    Sync(Vec<String>),
    /// One way: chats of the source folders are added to or updated in the targets. Nothing is deleted.
    Copy { sources: Vec<String>, targets: Vec<String> },
    /// Copy chosen chats into the target folders (the signed-in account).
    Pull { items: Vec<PullItem>, targets: Vec<String> },
    RestoreBackup(BackupInfo),
}

pub fn plan(intent: &WriteIntent, paths: &Paths) -> WritePlan {
    match intent {
        WriteIntent::Edits(e) => plan_edits(e, paths),
        WriteIntent::Sync(ids) => plan_sync(ids, paths),
        WriteIntent::Copy { sources, targets } => plan_copy(sources, targets, paths),
        WriteIntent::Pull { items, targets } => plan_pull(items, targets, paths),
        WriteIntent::RestoreBackup(b) => plan_restore(b, paths),
    }
}

fn find_folder(id: &str, paths: &Paths) -> Option<SessionFolder> {
    scanner::list_folders(&paths.sessions_root).into_iter().find(|f| f.id() == id)
}

fn idx_delta(added: usize, removed: usize) -> String {
    let mut parts = vec![];
    if added > 0 {
        parts.push(format!("add {added}"));
    }
    if removed > 0 {
        parts.push(format!("remove {removed}"));
    }
    parts.join(", ")
}

fn plural(n: usize, word: &str) -> String {
    format!("{n} {word}{}", if n == 1 { "" } else { "s" })
}

fn archived_change(plan: &mut WritePlan, scan: &FolderScan, before: &HashSet<String>, after: &HashSet<String>) {
    if before == after {
        return;
    }
    let added = after.difference(before).count();
    let removed = before.difference(after).count();
    let ids: Vec<String> = after.iter().cloned().collect();
    match schema::encode_archived_index(&ids) {
        Ok(data) => plan.changes.push(PlannedChange {
            folder: scan.folder.clone(),
            kind: ChangeKind::ArchivedIndex,
            target: scan.archived_index.path.clone(),
            summary: format!("Archived list: {} ({} total)", idx_delta(added, removed), after.len()),
            detail: if scan.archived_index.exists { None } else { Some("file will be created".into()) },
            op: FileOp::Write { data, mtime: None },
        }),
        Err(e) => plan.problem(scan.archived_index.path.clone(), e.0),
    }
}

fn big_warning(plan: &mut WritePlan, title: &str, size: usize) {
    if size > 100_000 {
        plan.warnings.push(format!("{} is {} KB (connector config). A copy this big once failed to show in the sidebar.", quoted(title), size / 1024));
    }
}

// MARK: Edits (restore, archive, pin, rename)

fn plan_edits(edits: &[SessionEdit], paths: &Paths) -> WritePlan {
    let n = edits.len();
    let mut plan = WritePlan::new(format!("Change {}", plural(n, "chat")), "edit");
    let mut by_folder: BTreeMap<String, Vec<&SessionEdit>> = BTreeMap::new();
    for e in edits.iter().filter(|e| !e.is_empty()) {
        by_folder.entry(e.folder_id.clone()).or_default().push(e);
    }
    for (folder_id, list) in by_folder {
        let Some(folder) = find_folder(&folder_id, paths) else {
            plan.problem(paths.sessions_root.join(&folder_id), "folder not found");
            continue;
        };
        plan.folders.push(folder.clone());
        let idx = scanner::read_archived_index(&folder);
        let mut add_idx = HashSet::new();
        let mut remove_idx = HashSet::new();
        for edit in list {
            let path = folder.session_path(&edit.session_id);
            let Ok(data) = fs::read(&path) else {
                plan.problem(path, "session file not found or unreadable");
                continue;
            };
            let v: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
            let problems = schema::session_problems(&v, &path);
            if !problems.is_empty() {
                for p in problems {
                    plan.problem(path.clone(), p);
                }
                continue;
            }
            let title = v["title"].as_str().unwrap_or("(untitled)").to_string();
            let archived = v["isArchived"].as_bool().unwrap_or(false);
            let starred = v["isStarred"].as_bool().unwrap_or(false);
            let mut sets: Vec<(&str, Value)> = vec![];
            let mut what: Vec<String> = vec![];
            if let Some(t) = &edit.title {
                if *t != title {
                    sets.push(("title", json!(t)));
                    sets.push(("titleSource", json!("user")));
                    what.push(format!("rename to {}", quoted(t)));
                }
            }
            if let Some(a) = edit.is_archived {
                if a != archived {
                    sets.push(("isArchived", json!(a)));
                    what.push(if a { "archive".into() } else { "restore from archive".into() });
                }
                if a {
                    add_idx.insert(edit.session_id.clone());
                } else {
                    remove_idx.insert(edit.session_id.clone());
                }
                if a && starred && edit.is_starred.is_none() {
                    sets.push(("isStarred", json!(false)));
                    what.push("unpin (archived chats cannot stay pinned)".into());
                }
            }
            if let Some(s) = edit.is_starred {
                if s != starred && !(edit.is_archived == Some(true) && s) {
                    sets.push(("isStarred", json!(s)));
                    what.push(if s { "pin".into() } else { "unpin".into() });
                }
            }
            if sets.is_empty() {
                continue;
            }
            match crate::json_patch::patch(&data, &sets) {
                Ok(patched) => plan.changes.push(PlannedChange {
                    folder: folder.clone(),
                    kind: ChangeKind::Edit,
                    summary: format!("{}: {}", quoted(&title), what.join(", ")),
                    detail: path.file_name().map(|n| n.to_string_lossy().to_string()),
                    target: path,
                    op: FileOp::Write { data: patched, mtime: None },
                }),
                Err(e) => plan.problem(path, e.0),
            }
        }
        if !add_idx.is_empty() || !remove_idx.is_empty() {
            let Some(ids) = idx.ids.clone() else {
                plan.problem(idx.path.clone(), idx.problem.clone().unwrap_or_else(|| "unreadable".into()));
                continue;
            };
            let before: HashSet<String> = ids.into_iter().collect();
            let after: HashSet<String> = before.difference(&remove_idx).cloned().chain(add_idx.iter().cloned()).collect();
            let scan = FolderScan { folder: folder.clone(), sessions: vec![], archived_index: idx, deleted_markers: Default::default(), unreadable: vec![] };
            archived_change(&mut plan, &scan, &before, &after);
        }
    }
    plan
}

// MARK: Merge

fn plan_sync(ids: &[String], paths: &Paths) -> WritePlan {
    let mut plan = WritePlan::new(format!("Sync {} account folders", ids.len()), "sync");
    let all = scanner::list_folders(&paths.sessions_root);
    let folders: Vec<SessionFolder> = ids.iter().filter_map(|id| all.iter().find(|f| f.id() == *id).cloned()).collect();
    for id in ids.iter().filter(|id| !folders.iter().any(|f| f.id() == **id)) {
        plan.problem(paths.sessions_root.join(id), "folder not found");
    }
    if folders.len() < 2 {
        plan.problem(paths.sessions_root.clone(), "pick at least two folders");
        return plan;
    }
    plan.folders = folders.clone();
    let scans: Vec<FolderScan> = folders.iter().map(scanner::scan_folder).collect();
    for scan in &scans {
        if let Some(p) = &scan.archived_index.problem {
            plan.problem(scan.archived_index.path.clone(), p.clone());
        }
        for (path, why) in &scan.unreadable {
            plan.problem(path.clone(), why.clone());
        }
        if scan.folder.is_backup_copy() {
            plan.warnings.push(format!("{} is a hand-made backup copy, not a live account folder.", scan.folder.short_label()));
        }
    }

    // Deleted markers: union across folders, the earliest marker is the one copied.
    struct Marker {
        mtime: i64,
        data: Vec<u8>,
        folder: SessionFolder,
    }
    let mut markers: BTreeMap<String, Marker> = BTreeMap::new();
    for scan in &scans {
        for (uuid, path) in &scan.deleted_markers {
            let mtime = crate::util::mtime_ms(path);
            let Ok(data) = fs::read(path) else {
                plan.problem(path.clone(), "could not read deleted marker");
                continue;
            };
            if markers.get(uuid).map(|m| m.mtime <= mtime).unwrap_or(false) {
                continue;
            }
            markers.insert(uuid.clone(), Marker { mtime, data, folder: scan.folder.clone() });
        }
    }

    let mut copies: BTreeMap<String, Vec<&SessionRecord>> = BTreeMap::new();
    for scan in &scans {
        for s in &scan.sessions {
            copies.entry(s.session_id.clone()).or_default().push(s);
        }
    }
    let mut titles: HashMap<String, String> = HashMap::new();
    let mut final_archived: HashMap<String, bool> = HashMap::new();
    for (sid, list) in &copies {
        let uuid = list[0].uuid().to_string();
        titles.insert(uuid.clone(), list[0].title.clone());
        if let Some(marker) = markers.get(&uuid) {
            for s in list {
                plan.changes.push(PlannedChange {
                    folder: s.folder.clone(),
                    kind: ChangeKind::RemoveDeleted,
                    target: s.file.clone(),
                    summary: format!("{}: deleted in {}, move this copy to the backup", quoted(&s.title), marker.folder.short_label()),
                    detail: s.file.file_name().map(|n| n.to_string_lossy().to_string()),
                    op: FileOp::MoveToBackup,
                });
            }
            continue;
        }
        let bad: Vec<&&SessionRecord> = list.iter().filter(|s| !s.problems.is_empty()).collect();
        if !bad.is_empty() {
            for s in bad {
                for p in &s.problems {
                    plan.problem(s.file.clone(), p.clone());
                }
            }
            continue;
        }
        let winner = *list.iter().max_by_key(|s| (s.file_mtime, s.last_activity_at.unwrap_or(0))).unwrap();
        let Ok(winner_data) = fs::read(&winner.file) else {
            plan.problem(winner.file.clone(), "could not read");
            continue;
        };
        final_archived.insert(sid.clone(), winner.is_archived);
        big_warning(&mut plan, &winner.title, winner_data.len());
        for scan in &scans {
            let target = scan.folder.session_path(sid);
            if let Some(mine) = list.iter().find(|s| s.folder == scan.folder) {
                if mine.folder == winner.folder {
                    continue;
                }
                let Ok(mine_data) = fs::read(&mine.file) else { continue };
                if mine_data == winner_data {
                    continue;
                }
                let mut detail = format!("newer copy {} replaces {}", fmt_date(winner.file_mtime), fmt_date(mine.file_mtime));
                if mine.title != winner.title {
                    detail += &format!(", title was {}", quoted(&mine.title));
                }
                if mine.is_archived != winner.is_archived {
                    detail += if winner.is_archived { ", becomes archived" } else { ", becomes active" };
                }
                plan.changes.push(PlannedChange {
                    folder: scan.folder.clone(),
                    kind: ChangeKind::Update,
                    target,
                    summary: format!("{}: update from {}", quoted(&winner.title), winner.folder.short_label()),
                    detail: Some(detail),
                    op: FileOp::Write { data: winner_data.clone(), mtime: Some(winner.file_mtime) },
                });
            } else {
                plan.changes.push(PlannedChange {
                    folder: scan.folder.clone(),
                    kind: ChangeKind::Add,
                    target,
                    summary: format!("{}: add from {}", quoted(&winner.title), winner.folder.short_label()),
                    detail: Some(format!("{}, last change {}", if winner.is_archived { "archived" } else { "active" }, fmt_date(winner.file_mtime))),
                    op: FileOp::Write { data: winner_data.clone(), mtime: Some(winner.file_mtime) },
                });
            }
        }
    }

    for (uuid, marker) in &markers {
        for scan in scans.iter().filter(|s| !s.deleted_markers.contains_key(uuid)) {
            let name = titles.get(uuid).map(|t| format!(" ({})", quoted(t))).unwrap_or_default();
            plan.changes.push(PlannedChange {
                folder: scan.folder.clone(),
                kind: ChangeKind::AddMarker,
                target: scan.folder.marker_path(uuid),
                summary: format!("Deleted marker for {}{} from {}", crate::util::short(uuid), name, marker.folder.short_label()),
                detail: Some(format!("deleted_{uuid}")),
                op: FileOp::Write { data: marker.data.clone(), mtime: Some(marker.mtime) },
            });
        }
    }

    // Every folder ends up with the same chats, so the archived list is the same everywhere.
    let wanted: HashSet<String> = final_archived.iter().filter(|(_, a)| **a).map(|(k, _)| k.clone()).collect();
    for scan in &scans {
        let Some(current) = &scan.archived_index.ids else { continue };
        let cur: HashSet<String> = current.iter().cloned().collect();
        if cur == wanted || (!scan.archived_index.exists && wanted.is_empty()) {
            continue;
        }
        archived_change(&mut plan, scan, &cur, &wanted);
    }
    plan
}

// MARK: One-way copy

fn plan_copy(source_ids: &[String], target_ids: &[String], paths: &Paths) -> WritePlan {
    let mut plan = WritePlan::new(format!("Copy chats into {}", plural(target_ids.len(), "folder")), "copy");
    let all = scanner::list_folders(&paths.sessions_root);
    let sources: Vec<SessionFolder> = source_ids.iter().filter_map(|id| all.iter().find(|f| f.id() == *id).cloned()).collect();
    let targets: Vec<SessionFolder> = target_ids.iter().filter(|id| !source_ids.contains(id))
        .filter_map(|id| all.iter().find(|f| f.id() == *id).cloned()).collect();
    if sources.is_empty() || targets.is_empty() {
        plan.problem(paths.sessions_root.clone(), "pick an account to copy from and at least one to copy to");
        return plan;
    }
    plan.folders = targets.clone();
    let source_scans: Vec<FolderScan> = sources.iter().map(scanner::scan_folder).collect();
    let target_scans: Vec<FolderScan> = targets.iter().map(scanner::scan_folder).collect();
    for scan in source_scans.iter().chain(target_scans.iter()) {
        for (path, why) in &scan.unreadable {
            plan.problem(path.clone(), why.clone());
        }
    }
    for scan in &target_scans {
        if let Some(p) = &scan.archived_index.problem {
            plan.problem(scan.archived_index.path.clone(), p.clone());
        }
    }
    let source_markers: HashSet<&String> = source_scans.iter().flat_map(|s| s.deleted_markers.keys()).collect();
    let mut best: BTreeMap<String, &SessionRecord> = BTreeMap::new();
    for scan in &source_scans {
        for s in scan.sessions.iter().filter(|s| !source_markers.contains(&s.uuid().to_string())) {
            if !s.problems.is_empty() {
                for p in &s.problems {
                    plan.problem(s.file.clone(), p.clone());
                }
                continue;
            }
            if best.get(&s.session_id).map(|c| c.file_mtime >= s.file_mtime).unwrap_or(false) {
                continue;
            }
            best.insert(s.session_id.clone(), s);
        }
    }
    for scan in &target_scans {
        let before: HashSet<String> = scan.archived_index.ids.clone().unwrap_or_default().into_iter().collect();
        let mut archived = before.clone();
        let mine: HashMap<&str, &SessionRecord> = scan.sessions.iter().map(|s| (s.session_id.as_str(), s)).collect();
        for (sid, src) in &best {
            if scan.deleted_markers.contains_key(src.uuid()) {
                continue;
            }
            let Ok(data) = fs::read(&src.file) else {
                plan.problem(src.file.clone(), "could not read");
                continue;
            };
            if let Some(have) = mine.get(sid.as_str()) {
                if !have.problems.is_empty() {
                    for p in &have.problems {
                        plan.problem(have.file.clone(), p.clone());
                    }
                    continue;
                }
                if have.file_mtime >= src.file_mtime || fs::read(&have.file).ok().as_ref() == Some(&data) {
                    continue;
                }
                plan.changes.push(PlannedChange {
                    folder: scan.folder.clone(),
                    kind: ChangeKind::Update,
                    target: scan.folder.session_path(sid),
                    summary: format!("{}: update from {}", quoted(&src.title), src.folder.short_label()),
                    detail: Some(format!("newer copy {} replaces {}", fmt_date(src.file_mtime), fmt_date(have.file_mtime))),
                    op: FileOp::Write { data: data.clone(), mtime: Some(src.file_mtime) },
                });
            } else {
                plan.changes.push(PlannedChange {
                    folder: scan.folder.clone(),
                    kind: ChangeKind::Add,
                    target: scan.folder.session_path(sid),
                    summary: format!("{}: add from {}", quoted(&src.title), src.folder.short_label()),
                    detail: Some(format!("{}, last change {}", if src.is_archived { "archived" } else { "active" }, fmt_date(src.file_mtime))),
                    op: FileOp::Write { data: data.clone(), mtime: Some(src.file_mtime) },
                });
            }
            if src.is_archived {
                archived.insert(sid.clone());
            } else {
                archived.remove(sid);
            }
            big_warning(&mut plan, &src.title, data.len());
        }
        if scan.archived_index.ids.is_some() {
            archived_change(&mut plan, scan, &before, &archived);
        }
    }
    plan.warnings.sort();
    plan.warnings.dedup();
    plan
}

// MARK: Add chosen chats to an account

fn plan_pull(items: &[PullItem], target_ids: &[String], paths: &Paths) -> WritePlan {
    let count = items.iter().map(|i| &i.session_id).collect::<HashSet<_>>().len();
    let mut plan = WritePlan::new(format!("Add {} to the signed-in account", plural(count, "chat")), "add-to-account");
    let all = scanner::list_folders(&paths.sessions_root);
    let targets: Vec<SessionFolder> = target_ids.iter().filter_map(|id| all.iter().find(|f| f.id() == *id).cloned()).collect();
    if targets.is_empty() {
        plan.problem(paths.sessions_root.clone(), "the signed-in account has no chat list yet. Open the Code tab in Claude once, then try again.");
        return plan;
    }
    plan.folders = targets.clone();

    // The newest copy of each chat among the folders it was picked from.
    let mut scans: HashMap<String, FolderScan> = HashMap::new();
    let mut best: BTreeMap<String, (SessionRecord, Vec<u8>)> = BTreeMap::new();
    for item in items.iter().filter(|i| !target_ids.contains(&i.folder_id)) {
        let Some(folder) = all.iter().find(|f| f.id() == item.folder_id) else {
            plan.problem(paths.sessions_root.join(&item.folder_id), "folder not found");
            continue;
        };
        let scan = scans.entry(folder.id()).or_insert_with(|| scanner::scan_folder(folder));
        let Some(rec) = scan.sessions.iter().find(|s| s.session_id == item.session_id).cloned() else {
            plan.problem(folder.session_path(&item.session_id), "chat not found");
            continue;
        };
        if !rec.problems.is_empty() {
            for p in &rec.problems {
                plan.problem(rec.file.clone(), p.clone());
            }
            continue;
        }
        let Ok(data) = fs::read(&rec.file) else {
            plan.problem(rec.file.clone(), "could not read");
            continue;
        };
        if best.get(&rec.session_id).map(|(c, _)| c.file_mtime >= rec.file_mtime).unwrap_or(false) {
            continue;
        }
        best.insert(rec.session_id.clone(), (rec, data));
    }

    for scan in targets.iter().map(scanner::scan_folder) {
        for (path, why) in &scan.unreadable {
            plan.problem(path.clone(), why.clone());
        }
        if let Some(p) = &scan.archived_index.problem {
            plan.problem(scan.archived_index.path.clone(), p.clone());
            continue;
        }
        let before: HashSet<String> = scan.archived_index.ids.clone().unwrap_or_default().into_iter().collect();
        let mut archived = before.clone();
        let mine: HashMap<&str, &SessionRecord> = scan.sessions.iter().map(|s| (s.session_id.as_str(), s)).collect();
        for (sid, (src, data)) in &best {
            if let Some(have) = mine.get(sid.as_str()) {
                if !have.problems.is_empty() {
                    for p in &have.problems {
                        plan.problem(have.file.clone(), p.clone());
                    }
                    continue;
                }
                // Already here, as the same or a newer copy.
                if have.file_mtime >= src.file_mtime || fs::read(&have.file).ok().as_ref() == Some(data) {
                    continue;
                }
                plan.changes.push(PlannedChange {
                    folder: scan.folder.clone(),
                    kind: ChangeKind::Update,
                    target: scan.folder.session_path(sid),
                    summary: format!("{}: update from {}", quoted(&src.title), src.folder.short_label()),
                    detail: Some(format!("newer copy {} replaces {}", fmt_date(src.file_mtime), fmt_date(have.file_mtime))),
                    op: FileOp::Write { data: data.clone(), mtime: Some(src.file_mtime) },
                });
            } else {
                plan.changes.push(PlannedChange {
                    folder: scan.folder.clone(),
                    kind: ChangeKind::Add,
                    target: scan.folder.session_path(sid),
                    summary: format!("{}: add from {}", quoted(&src.title), src.folder.short_label()),
                    detail: Some(format!("{}, last change {}", if src.is_archived { "archived" } else { "active" }, fmt_date(src.file_mtime))),
                    op: FileOp::Write { data: data.clone(), mtime: Some(src.file_mtime) },
                });
            }
            if let Some(marker) = scan.deleted_markers.get(src.uuid()) {
                plan.changes.push(PlannedChange {
                    folder: scan.folder.clone(),
                    kind: ChangeKind::MoveOut,
                    target: marker.clone(),
                    summary: format!("{}: was deleted in this account, move its deleted marker to the backup so it shows again", quoted(&src.title)),
                    detail: marker.file_name().map(|n| n.to_string_lossy().to_string()),
                    op: FileOp::MoveToBackup,
                });
            }
            if src.is_archived {
                archived.insert(sid.clone());
            } else {
                archived.remove(sid);
            }
            big_warning(&mut plan, &src.title, data.len());
        }
        archived_change(&mut plan, &scan, &before, &archived);
    }
    plan.warnings.sort();
    plan.warnings.dedup();
    plan
}

// MARK: Restore a backup

fn plan_restore(backup: &BackupInfo, paths: &Paths) -> WritePlan {
    let mut plan = WritePlan::new(format!("Restore backup {}", backup.id), "restore-backup");
    let tmp = match backups::extract(backup, paths) {
        Ok(t) => t,
        Err(e) => {
            plan.problem(backup.snapshot(), e.0);
            return plan;
        }
    };
    let names_in = |dir: &std::path::Path| -> BTreeSet<String> {
        fs::read_dir(dir).map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| schema::is_managed_name(n)).collect()).unwrap_or_default()
    };
    for r in &backup.folders {
        let folder = SessionFolder { account_id: r.account_id.clone(), org_id: r.org_id.clone(), path: paths.sessions_root.join(&r.account_id).join(&r.org_id) };
        plan.folders.push(folder.clone());
        let snap_dir = tmp.join(&r.account_id).join(&r.org_id);
        let snap_files = names_in(&snap_dir);
        let cur_files = names_in(&folder.path);
        for name in &snap_files {
            let Ok(data) = fs::read(snap_dir.join(name)) else { continue };
            let target = folder.path.join(name);
            if name.starts_with("local_") {
                let v: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
                for p in schema::session_problems(&v, &target) {
                    plan.problem(target.clone(), format!("in backup: {p}"));
                }
            } else if name == "archived-sessions.idx" {
                if let Some(p) = schema::parse_archived_index(&data).1 {
                    plan.problem(target.clone(), format!("in backup: {p}"));
                }
            }
            let current = fs::read(&target).ok();
            if current.as_ref() == Some(&data) {
                continue;
            }
            let mtime = Some(crate::util::mtime_ms(&snap_dir.join(name))).filter(|m| *m > 0);
            plan.changes.push(PlannedChange {
                folder: folder.clone(),
                kind: ChangeKind::PutBack,
                summary: format!("{}{}", if current.is_none() { "Put back " } else { "Revert " }, describe(name, &data)),
                detail: Some(name.clone()),
                target,
                op: FileOp::Write { data, mtime },
            });
        }
        for name in cur_files.difference(&snap_files) {
            let target = folder.path.join(name);
            let data = fs::read(&target).unwrap_or_default();
            plan.changes.push(PlannedChange {
                folder: folder.clone(),
                kind: ChangeKind::MoveOut,
                summary: format!("Move out {} (not in the backup)", describe(name, &data)),
                detail: Some(name.clone()),
                target,
                op: FileOp::MoveToBackup,
            });
        }
    }
    let _ = fs::remove_dir_all(&tmp);
    plan
}

fn describe(name: &str, data: &[u8]) -> String {
    if name.starts_with("local_") {
        if let Ok(v) = serde_json::from_slice::<Value>(data) {
            if let Some(t) = v["title"].as_str() {
                return quoted(t);
            }
        }
    }
    name.to_string()
}
