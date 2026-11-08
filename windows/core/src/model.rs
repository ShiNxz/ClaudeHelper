//! What Relay reads from Claude's sidebar files.
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

/// One `<account>/<org>` folder under claude-code-sessions.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionFolder {
    pub account_id: String,
    pub org_id: String,
    pub path: PathBuf,
}

impl SessionFolder {
    pub fn id(&self) -> String {
        format!("{}/{}", self.account_id, self.org_id)
    }
    /// Folders like `<org>.backup-1792257286` are copies someone made by hand, not live folders.
    pub fn is_backup_copy(&self) -> bool {
        self.org_id.contains(".backup")
    }
    pub fn short_label(&self) -> String {
        let s = format!("{}/{}", crate::util::short(&self.account_id), crate::util::short(&self.org_id));
        if self.is_backup_copy() { s + " (backup copy)" } else { s }
    }
    pub fn archived_index_path(&self) -> PathBuf {
        self.path.join("archived-sessions.idx")
    }
    pub fn session_path(&self, session_id: &str) -> PathBuf {
        self.path.join(format!("{session_id}.json"))
    }
    pub fn marker_path(&self, uuid: &str) -> PathBuf {
        self.path.join(format!("deleted_{uuid}"))
    }
}

/// One sidebar entry: one `local_<uuid>.json` file in one folder.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecord {
    pub folder: SessionFolder,
    pub file: PathBuf,
    pub session_id: String,
    pub cli_session_id: Option<String>,
    pub prior_cli_session_ids: Vec<String>,
    pub title: String,
    pub title_source: Option<String>,
    pub cwd: String,
    pub is_archived: bool,
    pub is_starred: bool,
    pub last_activity_at: Option<i64>,
    pub created_at: Option<i64>,
    pub file_mtime: i64,
    pub file_size: u64,
    pub in_archived_index: bool,
    pub model: Option<String>,
    /// Schema guard findings. Not empty means Relay will not write this file.
    pub problems: Vec<String>,
}

impl SessionRecord {
    pub fn key(&self) -> String {
        format!("{}|{}", self.folder.id(), self.session_id)
    }
    /// The uuid part of `local_<uuid>`; `deleted_<uuid>` markers use it.
    pub fn uuid(&self) -> &str {
        self.session_id.strip_prefix("local_").unwrap_or(&self.session_id)
    }
    pub fn open_url(&self) -> String {
        format!("claude://claude.ai/epitaxy/{}", self.session_id)
    }
    pub fn resume_command(&self) -> Option<String> {
        let cli = self.cli_session_id.as_ref()?;
        Some(format!("cd {} && claude --resume {}", crate::util::shell_quote(&self.cwd), cli))
    }
    pub fn all_cli_ids(&self) -> Vec<String> {
        self.cli_session_id.iter().cloned().chain(self.prior_cli_session_ids.iter().cloned()).collect()
    }
    /// Latest sign of life: the recorded activity or the file's modification time.
    pub fn activity(&self) -> i64 {
        self.last_activity_at.unwrap_or(0).max(self.file_mtime)
    }
}

#[derive(Clone, Debug)]
pub struct ArchivedIndex {
    pub path: PathBuf,
    pub exists: bool,
    /// None when the file exists but does not match `{"v":1,"archived":[...]}`.
    pub ids: Option<Vec<String>>,
    pub problem: Option<String>,
}

#[derive(Clone, Debug)]
pub struct FolderScan {
    pub folder: SessionFolder,
    pub sessions: Vec<SessionRecord>,
    pub archived_index: ArchivedIndex,
    /// uuid -> marker file
    pub deleted_markers: BTreeMap<String, PathBuf>,
    /// Session files that could not be parsed at all.
    pub unreadable: Vec<(PathBuf, String)>,
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub folders: Vec<FolderScan>,
    pub active_account_id: Option<String>,
}

impl Snapshot {
    pub fn all_sessions(&self) -> impl Iterator<Item = &SessionRecord> {
        self.folders.iter().flat_map(|f| f.sessions.iter())
    }

    /// cli session id (current or earlier) -> sidebar entries using it.
    pub fn sessions_by_cli(&self) -> HashMap<String, Vec<SessionRecord>> {
        let mut map: HashMap<String, Vec<SessionRecord>> = HashMap::new();
        for s in self.all_sessions() {
            for cli in s.all_cli_ids() {
                map.entry(cli).or_default().push(s.clone());
            }
        }
        map
    }

    /// Best sidebar entry for a transcript: signed-in account first, then live folders, then newest.
    pub fn preferred_session<'a>(&self, cli: &str, map: &'a HashMap<String, Vec<SessionRecord>>) -> Option<&'a SessionRecord> {
        let list = map.get(cli)?;
        let active = self.active_account_id.as_deref();
        list.iter().max_by(|a, b| {
            let key = |s: &SessionRecord| {
                (Some(s.folder.account_id.as_str()) == active, !s.folder.is_backup_copy(), s.cli_session_id.as_deref() == Some(cli), s.file_mtime)
            };
            key(a).cmp(&key(b))
        })
    }

    /// Chat ids the given account has in its live folders.
    pub fn chat_ids_of(&self, account: &str) -> std::collections::HashSet<String> {
        self.folders.iter()
            .filter(|f| f.folder.account_id == account && !f.folder.is_backup_copy())
            .flat_map(|f| f.sessions.iter().map(|s| s.session_id.clone()))
            .collect()
    }

    /// The chat lists (folders) of an account that hold chats; all of its folders when none does yet.
    pub fn folder_ids_of(&self, account: &str) -> Vec<String> {
        let live: Vec<&FolderScan> = self.folders.iter().filter(|f| f.folder.account_id == account && !f.folder.is_backup_copy()).collect();
        let used: Vec<&FolderScan> = live.iter().copied().filter(|f| !f.sessions.is_empty() || !f.deleted_markers.is_empty()).collect();
        let pick = if used.is_empty() { live } else { used };
        pick.iter().map(|f| f.folder.id()).collect()
    }
}
