//! Timestamped tar.gz backups of the session files in each folder a write touches.
//! Only the files Relay manages are included: local_*.json, archived-sessions.idx, deleted_*.
use crate::model::SessionFolder;
use crate::paths::Paths;
use crate::schema::is_managed_name;
use crate::util::{err, now_ms, stamp, Result};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderRef {
    pub account_id: String,
    pub org_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupInfo {
    /// Folder name, like 2026-11-08_151408-sync.
    pub id: String,
    pub created: i64,
    pub reason: String,
    pub title: String,
    pub folders: Vec<FolderRef>,
    /// Paths relative to claude-code-sessions.
    pub files: Vec<String>,
    pub changes: Vec<String>,
    pub applied: bool,
    /// Files moved into removed/ while applying.
    pub removed: Vec<String>,
    #[serde(skip)]
    pub dir: PathBuf,
}

impl BackupInfo {
    pub fn snapshot(&self) -> PathBuf {
        self.dir.join("snapshot.tar.gz")
    }
    pub fn removed_dir(&self) -> PathBuf {
        self.dir.join("removed")
    }
}

pub fn create(folders: &[SessionFolder], reason: &str, title: &str, changes: Vec<String>, paths: &Paths) -> Result<BackupInfo> {
    paths.ensure_data_dirs()?;
    let base = format!("{}-{}", stamp(now_ms()), reason);
    let mut name = base.clone();
    let mut n = 2;
    while paths.backups_dir().join(&name).exists() {
        name = format!("{base}-{n}");
        n += 1;
    }
    let dir = paths.backups_dir().join(&name);
    fs::create_dir_all(&dir)?;

    let mut entries: Vec<(String, Option<PathBuf>)> = Vec::new();
    let mut refs = Vec::new();
    for f in folders {
        refs.push(FolderRef { account_id: f.account_id.clone(), org_id: f.org_id.clone() });
        if !f.path.is_dir() {
            continue;
        }
        if !entries.iter().any(|(r, _)| *r == f.account_id) {
            entries.push((f.account_id.clone(), None));
        }
        let folder_rel = format!("{}/{}", f.account_id, f.org_id);
        entries.push((folder_rel.clone(), None));
        let mut names: Vec<String> = fs::read_dir(&f.path)?
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| is_managed_name(n))
            .collect();
        names.sort();
        for n in names {
            entries.push((format!("{folder_rel}/{n}"), Some(f.path.join(&n))));
        }
    }

    let snapshot = dir.join("snapshot.tar.gz");
    {
        let gz = GzEncoder::new(fs::File::create(&snapshot)?, Compression::default());
        let mut tar = tar::Builder::new(gz);
        for (rel, file) in &entries {
            match file {
                Some(p) => tar.append_path_with_name(p, rel)?,
                None => {
                    let mut h = tar::Header::new_gnu();
                    h.set_entry_type(tar::EntryType::Directory);
                    h.set_mode(0o700);
                    h.set_size(0);
                    h.set_mtime((now_ms() / 1000) as u64);
                    h.set_cksum();
                    tar.append_data(&mut h, format!("{rel}/"), std::io::empty())?;
                }
            }
        }
        tar.into_inner()?.finish()?;
    }
    // Read the archive back: every entry must be there before anything is written.
    let listed: BTreeSet<String> = list_archive(&snapshot)?;
    let wanted: BTreeSet<String> = entries.iter().map(|(r, _)| r.clone()).collect();
    if let Some(missing) = wanted.difference(&listed).next() {
        return err(format!("Backup is missing entries, not applying. First: {missing}"));
    }
    let info = BackupInfo {
        id: name,
        created: now_ms(),
        reason: reason.into(),
        title: title.into(),
        folders: refs,
        files: entries.iter().filter(|(_, f)| f.is_some()).map(|(r, _)| r.clone()).collect(),
        changes,
        applied: false,
        removed: vec![],
        dir,
    };
    save(&info)?;
    Ok(info)
}

fn list_archive(path: &Path) -> Result<BTreeSet<String>> {
    let mut ar = tar::Archive::new(GzDecoder::new(fs::File::open(path)?));
    let mut out = BTreeSet::new();
    for e in ar.entries()? {
        let e = e?;
        let p = e.path()?.to_string_lossy().replace('\\', "/");
        out.insert(p.trim_end_matches('/').to_string());
    }
    Ok(out)
}

pub fn save(info: &BackupInfo) -> Result<()> {
    crate::util::write_atomic(&info.dir.join("manifest.json"), &serde_json::to_vec_pretty(info)?, None)
}

pub fn list(paths: &Paths) -> Vec<BackupInfo> {
    let Ok(rd) = fs::read_dir(paths.backups_dir()) else { return vec![] };
    let mut out: Vec<BackupInfo> = rd
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let data = fs::read(e.path().join("manifest.json")).ok()?;
            let mut info: BackupInfo = serde_json::from_slice(&data).ok()?;
            info.dir = e.path();
            Some(info)
        })
        .collect();
    out.sort_by(|a, b| b.created.cmp(&a.created));
    out
}

/// Unpack a snapshot into a temporary folder inside Relay's data folder.
pub fn extract(info: &BackupInfo, paths: &Paths) -> Result<PathBuf> {
    let tmp = paths.data_dir.join("tmp").join(format!("restore-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&tmp)?;
    let mut ar = tar::Archive::new(GzDecoder::new(fs::File::open(info.snapshot())?));
    for e in ar.entries()? {
        let mut e = e?;
        let rel = e.path()?.to_string_lossy().replace('\\', "/");
        // Only <account>/<org>/<managed file> entries; nothing can escape the folder.
        let parts: Vec<&str> = rel.trim_end_matches('/').split('/').collect();
        if parts.iter().any(|p| p.is_empty() || *p == ".." || *p == ".") {
            continue;
        }
        let target = parts.iter().fold(tmp.clone(), |acc, p| acc.join(p));
        if e.header().entry_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else if parts.len() == 3 && is_managed_name(parts[2]) {
            fs::create_dir_all(target.parent().unwrap())?;
            e.unpack(&target)?;
        }
    }
    Ok(tmp)
}
