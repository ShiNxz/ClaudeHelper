//! Reads every account folder under claude-code-sessions. Read-only, safe while Claude runs.
use crate::model::{ArchivedIndex, FolderScan, SessionFolder, SessionRecord, Snapshot};
use crate::paths::Paths;
use crate::schema;
use crate::util::to_ms;
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;

fn subdirs(path: &Path) -> Vec<std::path::PathBuf> {
    let Ok(rd) = fs::read_dir(path) else { return vec![] };
    let mut out: Vec<_> = rd
        .filter_map(|e| e.ok())
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.') && e.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|e| e.path())
        .collect();
    out.sort();
    out
}

pub fn list_folders(root: &Path) -> Vec<SessionFolder> {
    let mut out = Vec::new();
    for acc in subdirs(root) {
        for org in subdirs(&acc) {
            out.push(SessionFolder {
                account_id: acc.file_name().unwrap().to_string_lossy().to_string(),
                org_id: org.file_name().unwrap().to_string_lossy().to_string(),
                path: org,
            });
        }
    }
    out.sort_by_key(|f| f.id());
    out
}

pub fn scan(paths: &Paths) -> Snapshot {
    Snapshot {
        folders: list_folders(&paths.sessions_root).into_iter().map(|f| scan_folder(&f)).collect(),
        active_account_id: paths.active_account_id(),
    }
}

pub fn read_archived_index(folder: &SessionFolder) -> ArchivedIndex {
    let path = folder.archived_index_path();
    if !path.exists() {
        return ArchivedIndex { path, exists: false, ids: Some(vec![]), problem: None };
    }
    match fs::read(&path) {
        Ok(data) => {
            let (ids, problem) = schema::parse_archived_index(&data);
            ArchivedIndex { path, exists: true, ids, problem }
        }
        Err(_) => ArchivedIndex { path, exists: true, ids: None, problem: Some("could not read the file".into()) },
    }
}

pub fn scan_folder(folder: &SessionFolder) -> FolderScan {
    let idx = read_archived_index(folder);
    let archived: HashSet<String> = idx.ids.clone().unwrap_or_default().into_iter().collect();
    let mut sessions = Vec::new();
    let mut markers = BTreeMap::new();
    let mut unreadable = Vec::new();
    let mut names: Vec<String> = fs::read_dir(&folder.path)
        .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default();
    names.sort();
    for name in names {
        let path = folder.path.join(&name);
        if let Some(uuid) = name.strip_prefix("deleted_") {
            markers.insert(uuid.to_string(), path);
            continue;
        }
        if !(name.starts_with("local_") && name.ends_with(".json")) {
            continue;
        }
        let meta = fs::metadata(&path).ok();
        let mtime = meta.as_ref().and_then(|m| m.modified().ok()).map(to_ms).unwrap_or(0);
        let size = meta.map(|m| m.len()).unwrap_or(0);
        let Ok(data) = fs::read(&path) else {
            unreadable.push((path, "could not read".into()));
            continue;
        };
        let v: Value = match serde_json::from_slice(&data) {
            Ok(v @ Value::Object(_)) => v,
            _ => {
                unreadable.push((path, "not valid JSON".into()));
                continue;
            }
        };
        sessions.push(record(&v, &path, folder, mtime, size, &archived));
    }
    FolderScan { folder: folder.clone(), sessions, archived_index: idx, deleted_markers: markers, unreadable }
}

fn record(d: &Value, path: &Path, folder: &SessionFolder, mtime: i64, size: u64, archived: &HashSet<String>) -> SessionRecord {
    let s = |k: &str| d.get(k).and_then(|v| v.as_str()).map(String::from);
    let ms = |k: &str| d.get(k).and_then(|v| v.as_f64()).map(|f| f as i64);
    let sid = s("sessionId").unwrap_or_else(|| path.file_stem().unwrap().to_string_lossy().to_string());
    SessionRecord {
        folder: folder.clone(),
        file: path.to_path_buf(),
        cli_session_id: s("cliSessionId"),
        prior_cli_session_ids: d.get("priorCliSessionIds").and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default(),
        title: s("title").unwrap_or_else(|| "(untitled)".into()),
        title_source: s("titleSource"),
        cwd: s("cwd").unwrap_or_default(),
        is_archived: d.get("isArchived").and_then(|v| v.as_bool()).unwrap_or(false),
        is_starred: d.get("isStarred").and_then(|v| v.as_bool()).unwrap_or(false),
        last_activity_at: ms("lastActivityAt"),
        created_at: ms("createdAt"),
        file_mtime: mtime,
        file_size: size,
        in_archived_index: archived.contains(&sid),
        model: s("model"),
        problems: schema::session_problems(d, path),
        session_id: sid,
    }
}
