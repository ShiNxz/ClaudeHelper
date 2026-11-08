//! Full-text search over Claude Code transcripts in ~/.claude/projects. Transcripts are only ever read.
//!
//! The index is a SQLite database with an FTS5 table. It is incremental: transcripts only grow, so each run
//! reads only the complete lines appended since the last run. A replaced or truncated file is read again
//! from the start. Port of TranscriptIndex.swift from the macOS app.
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexSettings {
    pub include_tools: bool,
    pub include_subagents: bool,
}

impl IndexSettings {
    /// Bump the version when the extraction rules change; a different key forces a full rebuild.
    pub fn key(&self) -> String {
        format!("v4;tools={};subagents={}", self.include_tools, self.include_subagents)
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub running: bool,
    pub files_total: usize,
    pub files_done: usize,
    pub bytes_total: u64,
    pub bytes_done: u64,
}

impl Progress {
    pub fn fraction(&self) -> f64 {
        if self.bytes_total > 0 { (self.bytes_done as f64 / self.bytes_total as f64).min(1.0) }
        else if self.files_total > 0 { self.files_done as f64 / self.files_total as f64 } else { 0.0 }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub files: i64,
    pub messages: i64,
    pub last_run: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role { Any, User, Assistant, Tool }

impl Role {
    fn column_value(&self) -> Option<&'static str> {
        match self {
            Role::Any => None,
            Role::User => Some("user"),
            Role::Assistant => Some("assistant"),
            Role::Tool => Some("tool"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Order { Relevance, Newest }

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexedFile {
    pub id: i64,
    pub path: String,
    pub cli_session_id: String,
    pub is_subagent: bool,
    pub project_dir: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub first_prompt: Option<String>,
    pub first_timestamp: Option<String>,
    pub last_timestamp: Option<String>,
    pub messages: i64,
    pub size: i64,
}

impl IndexedFile {
    /// The chat's title, its first prompt, or its id.
    pub fn display_title(&self) -> String {
        if let Some(t) = self.title.as_deref().filter(|t| !t.is_empty()) { return t.to_string(); }
        if let Some(p) = self.first_prompt.as_deref().filter(|p| !p.is_empty()) { return p.to_string(); }
        self.cli_session_id.clone()
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub id: i64,
    pub file_id: i64,
    pub role: String,
    pub timestamp: Option<String>,
    /// Snippet with \u{2} ... \u{3} around matched terms.
    pub snippet: String,
    pub rank: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchGroup {
    pub file: IndexedFile,
    pub hits: Vec<SearchHit>,
    pub best_rank: f64,
}

fn err(e: impl std::fmt::Display) -> String { e.to_string() }

// MARK: Database

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS files(
    id INTEGER PRIMARY KEY,
    path TEXT UNIQUE NOT NULL,
    inode INTEGER, size INTEGER, mtime REAL, offset INTEGER,
    cli_session_id TEXT, is_subagent INTEGER, project_dir TEXT,
    cwd TEXT, title TEXT, title_kind INTEGER, first_prompt TEXT,
    first_ts TEXT, last_ts TEXT, messages INTEGER DEFAULT 0,
    account_uuid TEXT, email TEXT);
CREATE INDEX IF NOT EXISTS files_cli ON files(cli_session_id);
CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
    text, role UNINDEXED, file_id UNINDEXED, ts UNINDEXED,
    tokenize='unicode61 remove_diacritics 2');
";

fn open_rw(db: &Path) -> Result<Connection, String> {
    if let Some(dir) = db.parent() { fs::create_dir_all(dir).map_err(err)?; }
    let conn = Connection::open(db).map_err(err)?;
    conn.busy_timeout(Duration::from_secs(5)).map_err(err)?;
    conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;").map_err(err)?;
    conn.execute_batch(SCHEMA).map_err(err)?;
    Ok(conn)
}

/// A read-only connection, or None when the index does not exist yet.
fn open_ro(db: &Path) -> Option<Connection> {
    if !db.exists() { return None; }
    let conn = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()?;
    let _ = conn.busy_timeout(Duration::from_secs(5));
    Some(conn)
}

fn get_meta(conn: &Connection, key: &str) -> Option<String> {
    conn.query_row("SELECT value FROM meta WHERE key=?1", [key], |r| r.get::<_, Option<String>>(0))
        .optional().ok().flatten().flatten()
}

fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<(), String> {
    conn.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?1,?2)", params![key, value]).map(|_| ()).map_err(err)
}

fn stats_of(conn: &Connection) -> Stats {
    let (files, messages) = conn
        .query_row("SELECT count(*), coalesce(sum(messages),0) FROM files", [], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))
        .unwrap_or((0, 0));
    Stats { files, messages, last_run: get_meta(conn, "last_run") }
}

/// Number of indexed transcripts, messages, and when the last full pass finished.
pub fn stats(db: &Path) -> Stats {
    open_ro(db).map(|c| stats_of(&c)).unwrap_or_default()
}

/// Account id -> email, from transcripts that carry both a session-owner line and the
/// "The user's email address is ..." context line. The most common email per account wins.
pub fn account_emails(db: &Path) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Some(conn) = open_ro(db) else { return out };
    let Ok(mut s) = conn.prepare(
        "SELECT account_uuid, email, count(*) AS n FROM files WHERE account_uuid IS NOT NULL AND email IS NOT NULL GROUP BY 1,2 ORDER BY n ASC",
    ) else { return out };
    let Ok(rows) = s.query_map([], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?))) else { return out };
    // Ascending, so the most common one is written last.
    for (a, e) in rows.flatten() {
        if let (Some(a), Some(e)) = (a, e) { out.insert(a, e); }
    }
    out
}

/// Every indexed main transcript, for listing chats that have no desktop session.
pub fn all_files(db: &Path) -> Vec<IndexedFile> {
    let Some(conn) = open_ro(db) else { return vec![] };
    let Ok(mut s) = conn.prepare(&format!("{} WHERE is_subagent=0", FILE_COLUMNS)) else { return vec![] };
    let Ok(rows) = s.query_map([], file_from_row) else { return vec![] };
    rows.flatten().collect()
}

const FILE_COLUMNS: &str =
    "SELECT id,path,cli_session_id,is_subagent,project_dir,cwd,title,first_prompt,first_ts,last_ts,messages,size FROM files";

fn file_from_row(r: &rusqlite::Row) -> rusqlite::Result<IndexedFile> {
    Ok(IndexedFile {
        id: r.get(0)?,
        path: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
        cli_session_id: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
        is_subagent: r.get::<_, Option<i64>>(3)?.unwrap_or(0) != 0,
        project_dir: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
        cwd: r.get(5)?,
        title: r.get(6)?,
        first_prompt: r.get(7)?,
        first_timestamp: r.get(8)?,
        last_timestamp: r.get(9)?,
        messages: r.get::<_, Option<i64>>(10)?.unwrap_or(0),
        size: r.get::<_, Option<i64>>(11)?.unwrap_or(0),
    })
}

// MARK: Discovery

struct Candidate {
    path: PathBuf,
    cli_session_id: String,
    is_subagent: bool,
    project_dir: String,
    inode: i64,
    size: i64,
    mtime: f64,
}

impl Candidate {
    fn key(&self) -> String { self.path.to_string_lossy().into_owned() }
}

#[cfg(unix)]
fn file_id(m: &fs::Metadata) -> i64 {
    use std::os::unix::fs::MetadataExt;
    m.ino() as i64
}

/// Stable file ids need unstable APIs on Windows; size and modification time catch replaced files there.
#[cfg(not(unix))]
fn file_id(_m: &fs::Metadata) -> i64 { 0 }

fn seconds(t: SystemTime) -> f64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    }
}

/// A regular file (not a symlink) as an index candidate.
fn candidate(path: PathBuf, cli: String, sub: bool, proj: &str) -> Option<Candidate> {
    let m = fs::symlink_metadata(&path).ok()?;
    if !m.file_type().is_file() { return None; }
    Some(Candidate {
        inode: file_id(&m),
        size: m.len() as i64,
        mtime: m.modified().map(seconds).unwrap_or(0.0),
        path,
        cli_session_id: cli,
        is_subagent: sub,
        project_dir: proj.to_string(),
    })
}

fn sorted_entries(dir: &Path) -> Vec<(String, PathBuf)> {
    let Ok(rd) = fs::read_dir(dir) else { return vec![] };
    let mut v: Vec<(String, PathBuf)> = rd.flatten().map(|e| (e.file_name().to_string_lossy().into_owned(), e.path())).collect();
    v.sort();
    v
}

/// Every .jsonl under `dir`, recursively, without following symlinked folders.
fn walk_jsonl(dir: &Path, out: &mut Vec<PathBuf>) {
    for (name, path) in sorted_entries(dir) {
        let Ok(ft) = fs::symlink_metadata(&path).map(|m| m.file_type()) else { continue };
        if ft.is_dir() { walk_jsonl(&path, out); } else if ft.is_file() && name.ends_with(".jsonl") { out.push(path); }
    }
}

fn discover(projects_root: &Path, settings: IndexSettings) -> Vec<Candidate> {
    let mut out = vec![];
    for (proj, proj_path) in sorted_entries(projects_root) {
        if proj.starts_with('.') { continue; }
        if !proj_path.is_dir() { continue; }
        for (item, path) in sorted_entries(&proj_path) {
            if let Some(cli) = item.strip_suffix(".jsonl") {
                if let Some(c) = candidate(path, cli.to_string(), false, &proj) { out.push(c); }
            } else if settings.include_subagents {
                // <cli id>/subagents/agent-*.jsonl and <cli id>/subagents/workflows/<wf>/agent-*.jsonl
                let sub_dir = path.join("subagents");
                if !sub_dir.is_dir() { continue; }
                let mut files = vec![];
                walk_jsonl(&sub_dir, &mut files);
                for f in files {
                    if let Some(c) = candidate(f, item.clone(), true, &proj) { out.push(c); }
                }
            }
        }
    }
    out
}

// MARK: Update

#[derive(Clone, Debug, Default)]
struct FileState {
    id: i64,
    inode: i64,
    size: i64,
    mtime: f64,
    offset: i64,
    title_kind: i64, // 0 none, 1 summary, 2 ai-title, 3 custom-title
    title: Option<String>,
    cwd: Option<String>,
    first_prompt: Option<String>,
    first_ts: Option<String>,
    last_ts: Option<String>,
    messages: i64,
    account_uuid: Option<String>,
    email: Option<String>,
}

/// Index new bytes of every transcript. Safe to call repeatedly; only appended lines are read.
/// Returns when done or when `cancelled` turns true (then `last_run` is not updated).
pub fn update(db: &Path, projects_root: &Path, settings: IndexSettings,
              progress: &mut dyn FnMut(&Progress), cancelled: &dyn Fn() -> bool) -> Result<Stats, String> {
    let mut p = Progress { running: true, ..Default::default() };
    progress(&p);
    let conn = open_rw(db)?;

    if get_meta(&conn, "settings").as_deref() != Some(settings.key().as_str()) {
        conn.execute_batch("DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS files;").map_err(err)?;
        conn.execute_batch(SCHEMA).map_err(err)?;
        set_meta(&conn, "settings", &settings.key())?;
    }

    let found = discover(projects_root, settings);
    let mut known: HashMap<String, FileState> = HashMap::new();
    {
        let mut q = conn.prepare(
            "SELECT id,path,inode,size,mtime,offset,title_kind,title,cwd,first_prompt,first_ts,last_ts,messages,account_uuid,email FROM files",
        ).map_err(err)?;
        let rows = q.query_map([], |r| {
            Ok((r.get::<_, Option<String>>(1)?.unwrap_or_default(), FileState {
                id: r.get(0)?,
                inode: r.get::<_, Option<i64>>(2)?.unwrap_or(0),
                size: r.get::<_, Option<i64>>(3)?.unwrap_or(0),
                mtime: r.get::<_, Option<f64>>(4)?.unwrap_or(0.0),
                offset: r.get::<_, Option<i64>>(5)?.unwrap_or(0),
                title_kind: r.get::<_, Option<i64>>(6)?.unwrap_or(0),
                title: r.get(7)?,
                cwd: r.get(8)?,
                first_prompt: r.get(9)?,
                first_ts: r.get(10)?,
                last_ts: r.get(11)?,
                messages: r.get::<_, Option<i64>>(12)?.unwrap_or(0),
                account_uuid: r.get(13)?,
                email: r.get(14)?,
            }))
        }).map_err(err)?;
        for row in rows { let (k, v) = row.map_err(err)?; known.insert(k, v); }
    }

    // Forget files that no longer exist.
    let found_paths: HashSet<String> = found.iter().map(|c| c.key()).collect();
    let gone: Vec<i64> = known.iter().filter(|(k, _)| !found_paths.contains(*k)).map(|(_, st)| st.id).collect();
    if !gone.is_empty() {
        conn.execute_batch("BEGIN").map_err(err)?;
        for id in gone {
            conn.execute("DELETE FROM messages WHERE file_id=?1", [id]).map_err(err)?;
            conn.execute("DELETE FROM files WHERE id=?1", [id]).map_err(err)?;
        }
        conn.execute_batch("COMMIT").map_err(err)?;
    }

    // Work list: new files, grown files, replaced or truncated files. Newest first.
    let mut work: Vec<(Candidate, Option<FileState>)> = vec![];
    for c in found {
        let st = known.get(&c.key()).cloned();
        if let Some(st) = &st {
            if st.inode == c.inode && st.size == c.size && st.mtime == c.mtime { continue; }
        }
        work.push((c, st));
    }
    work.sort_by(|a, b| b.0.mtime.partial_cmp(&a.0.mtime).unwrap_or(std::cmp::Ordering::Equal));

    p.files_total = work.len();
    p.bytes_total = work.iter().map(|(c, st)| {
        let start = match st {
            Some(st) if st.inode == c.inode && c.size >= st.offset => st.offset,
            _ => 0,
        };
        (c.size - start).max(0) as u64
    }).sum();
    progress(&p);

    let mut last_report = Instant::now();
    for (c, st) in work {
        if cancelled() { p.running = false; progress(&p); return Ok(stats_of(&conn)); }
        index_file(&conn, settings, &c, st, &mut p, &mut |pp| {
            if last_report.elapsed() > Duration::from_millis(250) { progress(pp); last_report = Instant::now(); }
        }, cancelled)?;
        p.files_done += 1;
        if last_report.elapsed() > Duration::from_millis(250) { progress(&p); last_report = Instant::now(); }
    }
    if cancelled() { p.running = false; progress(&p); return Ok(stats_of(&conn)); }
    set_meta(&conn, "last_run", &iso_now())?;
    p.running = false;
    progress(&p);
    Ok(stats_of(&conn))
}

fn index_file(conn: &Connection, settings: IndexSettings, c: &Candidate, state: Option<FileState>, p: &mut Progress,
              report: &mut dyn FnMut(&Progress), cancelled: &dyn Fn() -> bool) -> Result<(), String> {
    conn.execute_batch("BEGIN").map_err(err)?;
    let mut st = match state {
        Some(mut existing) => {
            if existing.inode != c.inode || c.size < existing.offset {
                // Replaced or truncated: start over for this file.
                conn.execute("DELETE FROM messages WHERE file_id=?1", [existing.id]).map_err(err)?;
                existing = FileState { id: existing.id, ..Default::default() };
            }
            existing.inode = c.inode;
            existing
        }
        None => {
            conn.execute(
                "INSERT INTO files(path,inode,size,mtime,offset,cli_session_id,is_subagent,project_dir,messages) VALUES(?1,?2,0,0,0,?3,?4,?5,0)",
                params![c.key(), c.inode, c.cli_session_id, c.is_subagent as i64, c.project_dir],
            ).map_err(err)?;
            FileState { id: conn.last_insert_rowid(), inode: c.inode, ..Default::default() }
        }
    };

    // Only record size and mtime once the whole file is consumed, so a partial run resumes from the offset.
    let save_state = |st: &FileState, finished: bool| -> Result<(), String> {
        conn.prepare_cached(
            "UPDATE files SET inode=?1,size=?2,mtime=?3,offset=?4,title=?5,title_kind=?6,cwd=?7,first_prompt=?8,first_ts=?9,last_ts=?10,messages=?11,account_uuid=?12,email=?13 WHERE id=?14",
        ).map_err(err)?.execute(params![
            st.inode, if finished { c.size } else { -1 }, if finished { c.mtime } else { 0.0 }, st.offset,
            st.title, st.title_kind, st.cwd, st.first_prompt, st.first_ts, st.last_ts, st.messages,
            st.account_uuid, st.email, st.id,
        ]).map(|_| ()).map_err(err)
    };

    let mut file = match fs::File::open(&c.path) {
        Ok(f) => f,
        Err(_) => {
            save_state(&st, true)?;
            conn.execute_batch("COMMIT").map_err(err)?;
            return Ok(());
        }
    };
    file.seek(SeekFrom::Start(st.offset as u64)).map_err(err)?;

    let extractor = LineExtractor { settings, is_subagent_file: c.is_subagent };
    let mut buf: Vec<u8> = vec![];
    let mut chunk = vec![0u8; 8 << 20];
    let mut pending_in_batch = 0usize;
    let mut stopped_early = false;

    loop {
        if cancelled() { stopped_early = true; break; }
        let n = file.read(&mut chunk).map_err(err)?;
        if n == 0 { break; }
        buf.extend_from_slice(&chunk[..n]);
        let mut consumed = 0usize;
        let mut lines: Vec<(usize, usize)> = vec![];
        let mut start = 0usize;
        while let Some(rel) = buf[start..].iter().position(|&b| b == b'\n') {
            let end = start + rel;
            if end > start {
                let line = &buf[start..end];
                extractor.scan_identity(line, &mut st);
                if extractor.wants(line) { lines.push((start, end)); }
            }
            start = end + 1;
            consumed = start;
        }
        for (s, e) in lines {
            for item in extractor.extract(&buf[s..e], &mut st) {
                conn.prepare_cached("INSERT INTO messages(text, role, file_id, ts) VALUES(?1,?2,?3,?4)").map_err(err)?
                    .execute(params![item.text, item.role, st.id, item.ts]).map_err(err)?;
                st.messages += 1;
                pending_in_batch += 1;
            }
        }
        if consumed > 0 {
            st.offset += consumed as i64;
            buf.drain(..consumed);
        }
        p.bytes_done += n as u64;
        report(p);
        if pending_in_batch > 20_000 {
            save_state(&st, false)?;
            conn.execute_batch("COMMIT; BEGIN").map_err(err)?;
            pending_in_batch = 0;
        }
    }
    save_state(&st, !stopped_early && buf.is_empty())?;
    conn.execute_batch("COMMIT").map_err(err)?;
    Ok(())
}

/// Now in UTC, like "2026-11-08T14:01:46Z".
fn iso_now() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, rem / 3600, (rem % 3600) / 60, rem % 60)
}

// MARK: Line extraction

struct Item {
    text: String,
    role: &'static str,
    ts: Option<String>,
}

/// Decides cheaply which transcript lines are worth parsing, then pulls user and assistant text out of them.
struct LineExtractor {
    settings: IndexSettings,
    is_subagent_file: bool,
}

const TYPE_PREFIX: &[u8] = b"{\"type\":\"";
const TYPE_USER: &[u8] = b"{\"type\":\"user\"";
const TYPE_ASSISTANT: &[u8] = b"{\"type\":\"assistant\"";
const TITLE_TYPES: [&[u8]; 3] = [b"{\"type\":\"custom-title\"", b"{\"type\":\"ai-title\"", b"{\"type\":\"summary\""];
const CONTENT_KEY: &[u8] = b"\"content\":";
const ATTACHMENT_KEY: &[u8] = b"\"attachment\":";
const SKIP_BLOCKS: [&[u8]; 2] = [b"[{\"type\":\"thinking\"", b"[{\"type\":\"redacted_thinking\""];
const TOOL_BLOCKS: [&[u8]; 3] = [b"[{\"type\":\"tool_use\"", b"[{\"type\":\"tool_result\"", b"[{\"tool_use_id\""];
const OWNER_PREFIX: &[u8] = b"{\"type\":\"session-owner\",\"accountUuid\":\"";
const EMAIL_MARKER: &[u8] = b"The user's email address is ";

fn has_prefix_at(p: &[u8], needle: &[u8], at: usize) -> bool {
    at + needle.len() <= p.len() && &p[at..at + needle.len()] == needle
}

/// First position of `needle` that lies entirely within the first `limit` bytes.
fn find(p: &[u8], needle: &[u8], limit: usize) -> Option<usize> {
    let n = limit.min(p.len());
    if needle.is_empty() || needle.len() > n { return None; }
    let first = needle[0];
    let mut i = 0;
    while i + needle.len() <= n {
        match p[i..n - needle.len() + 1].iter().position(|&b| b == first) {
            None => return None,
            Some(off) => {
                i += off;
                if &p[i..i + needle.len()] == needle { return Some(i); }
                i += 1;
            }
        }
    }
    None
}

fn is_email_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'%' | b'+' | b'-' | b'@')
}

/// The first `n` characters of `s`.
fn prefix_chars(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

impl LineExtractor {
    /// Which account a transcript belongs to and that account's email, read straight from the bytes.
    fn scan_identity(&self, p: &[u8], st: &mut FileState) {
        if st.account_uuid.is_none() && has_prefix_at(p, OWNER_PREFIX, 0) {
            let start = OWNER_PREFIX.len();
            if start + 36 <= p.len() {
                let id = &p[start..start + 36];
                if id.iter().all(|b| b.is_ascii_hexdigit() || *b == b'-') {
                    st.account_uuid = Some(String::from_utf8_lossy(id).into_owned());
                }
            }
        }
        if st.email.is_none() {
            if let Some(at) = find(p, EMAIL_MARKER, p.len()) {
                let mut i = at + EMAIL_MARKER.len();
                let mut bytes: Vec<u8> = vec![];
                while i < p.len() && is_email_char(p[i]) && bytes.len() < 254 { bytes.push(p[i]); i += 1; }
                while bytes.last() == Some(&b'.') { bytes.pop(); }
                let email = String::from_utf8_lossy(&bytes).into_owned();
                if let Some(sign) = email.find('@') {
                    if email[sign + 1..].contains('.') { st.email = Some(email); }
                }
            }
        }
    }

    fn wants(&self, p: &[u8]) -> bool {
        if has_prefix_at(p, TYPE_PREFIX, 0) {
            if has_prefix_at(p, TYPE_USER, 0) || has_prefix_at(p, TYPE_ASSISTANT, 0) { return true; }
            return TITLE_TYPES.iter().any(|t| has_prefix_at(p, t, 0)) && p.len() < 64 * 1024;
        }
        let window = 4096;
        let ci = find(p, CONTENT_KEY, window);
        if let Some(ai) = find(p, ATTACHMENT_KEY, window) {
            if ci.map_or(true, |c| ai < c) { return false; }
        }
        let Some(c) = ci else { return p.len() < 256 * 1024 };
        let after = c + CONTENT_KEY.len();
        if after < p.len() && p[after] == b'"' { return true; } // "content":"string"
        if SKIP_BLOCKS.iter().any(|b| has_prefix_at(p, b, after)) { return false; }
        if TOOL_BLOCKS.iter().any(|b| has_prefix_at(p, b, after)) { return self.settings.include_tools; }
        true
    }

    fn extract(&self, line: &[u8], st: &mut FileState) -> Vec<Item> {
        let Ok(Value::Object(d)) = serde_json::from_slice::<Value>(line) else { return vec![] };
        let Some(ty) = d.get("type").and_then(Value::as_str) else { return vec![] };
        let str_of = |k: &str| d.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
        let role: &'static str = match ty {
            "custom-title" => {
                if let Some(t) = str_of("customTitle") { st.title = Some(t); st.title_kind = 3; }
                return vec![];
            }
            "ai-title" => {
                if st.title_kind <= 2 { if let Some(t) = str_of("aiTitle") { st.title = Some(t); st.title_kind = 2; } }
                return vec![];
            }
            "summary" => {
                if st.title_kind <= 1 { if let Some(t) = str_of("summary") { st.title = Some(t); st.title_kind = 1; } }
                return vec![];
            }
            "user" => "user",
            "assistant" => "assistant",
            _ => return vec![],
        };
        let flag = |k: &str| d.get(k).and_then(Value::as_bool) == Some(true);
        if flag("isMeta") || flag("isCompactSummary") { return vec![]; }
        if !self.is_subagent_file && !self.settings.include_subagents && flag("isSidechain") { return vec![]; }
        let ts = d.get("timestamp").and_then(Value::as_str).map(str::to_string);
        if let Some(ts) = &ts {
            if st.first_ts.is_none() { st.first_ts = Some(ts.clone()); }
            if st.last_ts.as_ref().map_or(true, |l| ts > l) { st.last_ts = Some(ts.clone()); }
        }
        if st.cwd.is_none() { if let Some(cwd) = str_of("cwd") { st.cwd = Some(cwd); } }
        let Some(Value::Object(msg)) = d.get("message") else { return vec![] };

        let mut out = vec![];
        let mut add = |raw: &str, role: &'static str, st: &mut FileState| {
            let stripped;
            let text = if role == "tool" { raw } else { stripped = strip_reminders(raw); stripped.as_str() };
            let mut text = text.trim();
            if text.is_empty() { return; }
            if text.len() > 100_000 { text = prefix_chars(text, 100_000); }
            if role == "user" && st.first_prompt.is_none() && !text.starts_with('<') {
                st.first_prompt = Some(prefix_chars(text, 160).replace('\n', " "));
            }
            out.push(Item { text: text.to_string(), role, ts: ts.clone() });
        };
        match msg.get("content") {
            Some(Value::String(s)) => add(s, role, st),
            Some(Value::Array(blocks)) => {
                for b in blocks {
                    let Value::Object(b) = b else { continue };
                    match b.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            if let Some(t) = b.get("text").and_then(Value::as_str) { add(t, role, st); }
                        }
                        Some("tool_use") if self.settings.include_tools => {
                            let name = b.get("name").and_then(Value::as_str).unwrap_or("tool");
                            let mut input = String::new();
                            if let Some(i) = b.get("input") {
                                if let Ok(json) = serde_json::to_vec(i) {
                                    input = String::from_utf8_lossy(&json[..json.len().min(4000)]).into_owned();
                                }
                            }
                            add(&format!("[{}] {}", name, input), "tool", st);
                        }
                        Some("tool_result") if self.settings.include_tools => {
                            match b.get("content") {
                                Some(Value::String(s)) => add(prefix_chars(s, 8000), "tool", st),
                                Some(Value::Array(arr)) => {
                                    let joined = arr.iter()
                                        .filter_map(|x| x.get("text").and_then(Value::as_str))
                                        .collect::<Vec<_>>().join("\n");
                                    add(prefix_chars(&joined, 8000), "tool", st);
                                }
                                _ => {}
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
        out
    }
}

/// Removes <system-reminder> ... </system-reminder> blocks; an unclosed one cuts the rest.
fn strip_reminders(s: &str) -> String {
    const OPEN: &str = "<system-reminder>";
    const CLOSE: &str = "</system-reminder>";
    if !s.contains(OPEN) { return s.to_string(); }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(open) = rest.find(OPEN) {
        out.push_str(&rest[..open]);
        let after = &rest[open + OPEN.len()..];
        match after.find(CLOSE) {
            Some(close) => rest = &after[close + CLOSE.len()..],
            None => { rest = ""; break; }
        }
    }
    out.push_str(rest);
    out
}

// MARK: Search

/// Turns what the user typed into an FTS5 query: words are ANDed, "quoted text" is a phrase,
/// and the last word matches as a prefix while typing.
pub fn fts_query(input: &str) -> Option<String> {
    let mut rest: Vec<char> = input.chars().collect();
    let mut phrases: Vec<String> = vec![];
    while let Some(open) = rest.iter().position(|&c| c == '"') {
        let Some(rel) = rest[open + 1..].iter().position(|&c| c == '"') else { break };
        let close = open + 1 + rel;
        phrases.push(rest[open + 1..close].iter().collect());
        rest.splice(open..=close, [' ']);
    }
    let rest: String = rest.into_iter().map(|c| if c == '"' { ' ' } else { c }).collect();
    let mut parts: Vec<String> = vec![];
    for ph in &phrases {
        if ph.trim().is_empty() { continue; }
        parts.push(format!("\"{}\"", ph.replace('"', "\"\"")));
    }
    let words: Vec<&str> = rest.split(char::is_whitespace).filter(|w| !w.is_empty()).collect();
    let ends_with_space = input.chars().last().map_or(false, char::is_whitespace);
    for (i, w) in words.iter().enumerate() {
        if !w.chars().any(char::is_alphanumeric) { continue; }
        let mut term = format!("\"{}\"", w.replace('"', "\"\""));
        let is_last = i == words.len() - 1 && !ends_with_space;
        if is_last && phrases.is_empty() && w.chars().count() >= 2 { term.push('*'); }
        parts.push(term);
    }
    if parts.is_empty() { None } else { Some(parts.join(" ")) }
}

pub fn search(db: &Path, query: &str, role: Role, order: Order, limit: usize) -> Result<Vec<SearchGroup>, String> {
    let Some(fts) = fts_query(query) else { return Ok(vec![]) };
    let Some(conn) = open_ro(db) else { return Ok(vec![]) };
    let mut sql = String::from(
        "SELECT rowid, file_id, role, ts, snippet(messages, 0, char(2), char(3), '\u{2026}', 24), bm25(messages) \
         FROM messages WHERE messages MATCH ?1",
    );
    let role_value = role.column_value();
    if role_value.is_some() { sql.push_str(" AND role = ?2"); }
    sql.push_str(if order == Order::Relevance { " ORDER BY rank" } else { " ORDER BY ts DESC" });
    sql.push_str(&format!(" LIMIT {}", limit));
    let mut s = conn.prepare(&sql).map_err(err)?;
    let map_hit = |r: &rusqlite::Row| -> rusqlite::Result<SearchHit> {
        Ok(SearchHit {
            id: r.get(0)?,
            file_id: r.get::<_, Option<i64>>(1)?.unwrap_or(0),
            role: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            timestamp: r.get(3)?,
            snippet: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
            rank: r.get::<_, Option<f64>>(5)?.unwrap_or(0.0),
        })
    };
    let hits: Vec<SearchHit> = match role_value {
        Some(rv) => s.query_map(params![fts, rv], map_hit).map_err(err)?.collect::<Result<_, _>>().map_err(err)?,
        None => s.query_map(params![fts], map_hit).map_err(err)?.collect::<Result<_, _>>().map_err(err)?,
    };

    let mut ids: Vec<i64> = hits.iter().map(|h| h.file_id).collect::<HashSet<_>>().into_iter().collect();
    ids.sort();
    let mut files: HashMap<i64, IndexedFile> = HashMap::new();
    if !ids.is_empty() {
        let list = ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
        let mut f = conn.prepare(&format!("{} WHERE id IN ({})", FILE_COLUMNS, list)).map_err(err)?;
        for file in f.query_map([], file_from_row).map_err(err)? {
            let file = file.map_err(err)?;
            files.insert(file.id, file);
        }
    }
    let mut groups: Vec<SearchGroup> = vec![];
    let mut at: HashMap<i64, usize> = HashMap::new();
    for h in hits {
        let Some(file) = files.get(&h.file_id) else { continue };
        let i = *at.entry(h.file_id).or_insert_with(|| {
            groups.push(SearchGroup { file: file.clone(), hits: vec![], best_rank: h.rank });
            groups.len() - 1
        });
        groups[i].hits.push(h);
    }
    Ok(groups)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A temp folder removed when dropped.
    struct TempDir(PathBuf);
    impl TempDir {
        fn new() -> TempDir {
            static N: AtomicUsize = AtomicUsize::new(0);
            let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
            let p = std::env::temp_dir().join(format!("relay-index-test-{}-{}-{}", std::process::id(), nanos, N.fetch_add(1, Ordering::SeqCst)));
            fs::create_dir_all(&p).unwrap();
            TempDir(p)
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
    }

    const OWNER: &str = r#"{"type":"session-owner","accountUuid":"11111111-2222-3333-4444-555555555555","organizationUuid":"org","sessionId":"c1"}"#;

    fn fixture_lines() -> Vec<&'static str> {
        vec![
            OWNER,
            r#"{"type":"custom-title","customTitle":"Fixture chat","sessionId":"c1"}"#,
            r##"{"parentUuid":null,"isSidechain":false,"type":"user","isMeta":true,"message":{"role":"user","content":"# userEmail\nThe user's email address is someone.test@example.com. Use it only to identify the user."},"uuid":"m0","timestamp":"2026-01-01T09:59:00.000Z"}"##,
            r#"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"please fix the zebracorn parser"},"uuid":"u1","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/project"}"#,
            r#"{"parentUuid":"u1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret thoughts quokka"}]},"type":"assistant","uuid":"a0","timestamp":"2026-01-01T10:00:01.000Z"}"#,
            r#"{"parentUuid":"u1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Fixed the parser <system-reminder>hidden wombat</system-reminder> done"}]},"type":"assistant","uuid":"a1","timestamp":"2026-01-01T10:00:02.000Z"}"#,
            r#"{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"tool output platypus"}]},"uuid":"u2","timestamp":"2026-01-01T10:00:03.000Z"}"#,
        ]
    }

    struct Fixture {
        _dir: TempDir,
        db: PathBuf,
        projects: PathBuf,
        transcript: PathBuf,
    }

    fn fixture() -> Fixture {
        let dir = TempDir::new();
        let projects = dir.0.join("projects");
        let transcript = projects.join("-tmp-project").join("c1.jsonl");
        fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        fs::write(&transcript, fixture_lines().join("\n") + "\n").unwrap();
        let db = dir.0.join("data").join("index.sqlite");
        Fixture { db, projects, transcript, _dir: dir }
    }

    fn run(f: &Fixture, settings: IndexSettings) -> Stats {
        update(&f.db, &f.projects, settings, &mut |_| {}, &|| false).unwrap()
    }

    fn hits(f: &Fixture, q: &str) -> usize {
        search(&f.db, q, Role::Any, Order::Relevance, 600).unwrap().iter().map(|g| g.hits.len()).sum()
    }

    #[test]
    fn indexes_text_and_skips_hidden_parts() {
        let f = fixture();
        let s = run(&f, IndexSettings::default());
        assert_eq!(s.files, 1);
        assert!(s.last_run.is_some());
        assert_eq!(hits(&f, "zebracorn"), 1, "user text found");
        assert_eq!(hits(&f, "zebra"), 1, "last word matches as a prefix");
        assert_eq!(hits(&f, "parser fixed"), 1, "words are ANDed");
        assert_eq!(hits(&f, "quokka"), 0, "thinking skipped");
        assert_eq!(hits(&f, "wombat"), 0, "system reminders stripped");
        assert_eq!(hits(&f, "platypus"), 0, "tool output off by default");
        assert_eq!(hits(&f, "someone"), 0, "meta context lines not indexed as messages");
        let groups = search(&f.db, "zebracorn", Role::Any, Order::Relevance, 600).unwrap();
        let file = &groups[0].file;
        assert_eq!(file.title.as_deref(), Some("Fixture chat"), "custom title picked up");
        assert_eq!(file.cli_session_id, "c1");
        assert_eq!(file.cwd.as_deref(), Some("/tmp/project"));
        assert_eq!(file.first_prompt.as_deref(), Some("please fix the zebracorn parser"));
        assert_eq!(file.first_timestamp.as_deref(), Some("2026-01-01T10:00:00.000Z"));
        assert_eq!(file.last_timestamp.as_deref(), Some("2026-01-01T10:00:02.000Z"));
        assert!(groups[0].hits[0].snippet.contains("\u{2}zebracorn\u{3}"), "snippet marks the match");
    }

    #[test]
    fn account_linked_to_email() {
        let f = fixture();
        run(&f, IndexSettings::default());
        let emails = account_emails(&f.db);
        assert_eq!(emails.len(), 1);
        assert_eq!(emails.get("11111111-2222-3333-4444-555555555555").map(String::as_str), Some("someone.test@example.com"));
    }

    #[test]
    fn appended_line_indexed_once() {
        let f = fixture();
        run(&f, IndexSettings::default());
        let before = stats(&f.db).messages;
        let mut fh = fs::OpenOptions::new().append(true).open(&f.transcript).unwrap();
        writeln!(fh, r#"{{"parentUuid":"u2","isSidechain":false,"type":"user","message":{{"role":"user","content":"appended narwhal line"}},"uuid":"u3","timestamp":"2026-01-01T10:01:00.000Z"}}"#).unwrap();
        drop(fh);
        run(&f, IndexSettings::default());
        assert_eq!(hits(&f, "narwhal"), 1);
        assert_eq!(hits(&f, "zebracorn"), 1, "old lines not duplicated");
        assert_eq!(stats(&f.db).messages, before + 1);
        // Nothing changed: a third run reads nothing new.
        run(&f, IndexSettings::default());
        assert_eq!(stats(&f.db).messages, before + 1);
    }

    #[test]
    fn partial_last_line_waits_for_its_newline() {
        let f = fixture();
        let mut fh = fs::OpenOptions::new().append(true).open(&f.transcript).unwrap();
        write!(fh, r#"{{"type":"user","message":{{"role":"user","content":"half written ocelot"}},"uuid":"u9","timestamp":"2026-01-01T10:02:00.000Z"}}"#).unwrap();
        drop(fh);
        run(&f, IndexSettings::default());
        assert_eq!(hits(&f, "ocelot"), 0, "a line without its newline is not read yet");
        let mut fh = fs::OpenOptions::new().append(true).open(&f.transcript).unwrap();
        writeln!(fh).unwrap();
        drop(fh);
        run(&f, IndexSettings::default());
        assert_eq!(hits(&f, "ocelot"), 1, "read once the line is complete");
    }

    #[test]
    fn truncated_file_is_read_again() {
        let f = fixture();
        run(&f, IndexSettings::default());
        fs::write(&f.transcript, r#"{"type":"user","message":{"role":"user","content":"brand new axolotl"},"uuid":"x","timestamp":"2026-02-01T00:00:00.000Z"}"#.to_string() + "\n").unwrap();
        run(&f, IndexSettings::default());
        assert_eq!(hits(&f, "axolotl"), 1);
        assert_eq!(hits(&f, "zebracorn"), 0, "old content dropped");
    }

    #[test]
    fn removed_file_is_forgotten() {
        let f = fixture();
        run(&f, IndexSettings::default());
        fs::remove_file(&f.transcript).unwrap();
        run(&f, IndexSettings::default());
        assert_eq!(stats(&f.db).files, 0);
        assert_eq!(hits(&f, "zebracorn"), 0);
    }

    #[test]
    fn tools_and_subagents_options_rebuild() {
        let f = fixture();
        let sub = f.projects.join("-tmp-project").join("c1").join("subagents").join("workflows").join("wf");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("agent-1.jsonl"),
                  r#"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent pangolin task"},"uuid":"s1","timestamp":"2026-01-01T11:00:00.000Z"}"#.to_string() + "\n").unwrap();
        run(&f, IndexSettings::default());
        assert_eq!(hits(&f, "platypus"), 0);
        assert_eq!(hits(&f, "pangolin"), 0, "subagents off by default");
        let s = run(&f, IndexSettings { include_tools: true, include_subagents: true });
        assert_eq!(s.files, 2, "changing options rebuilds and finds the subagent transcript");
        assert_eq!(hits(&f, "platypus"), 1, "tool output indexed when asked");
        assert_eq!(hits(&f, "pangolin"), 1);
        let tool = search(&f.db, "platypus", Role::Tool, Order::Relevance, 600).unwrap();
        assert_eq!(tool.len(), 1);
        assert_eq!(tool[0].hits[0].role, "tool");
        let sub_file = search(&f.db, "pangolin", Role::Any, Order::Relevance, 600).unwrap();
        assert!(sub_file[0].file.is_subagent);
        assert_eq!(sub_file[0].file.cli_session_id, "c1");
        assert_eq!(all_files(&f.db).len(), 1, "all_files lists main transcripts only");
    }

    #[test]
    fn role_filter_and_newest_order() {
        let f = fixture();
        run(&f, IndexSettings::default());
        let user = search(&f.db, "parser", Role::User, Order::Relevance, 600).unwrap();
        assert_eq!(user.iter().map(|g| g.hits.len()).sum::<usize>(), 1);
        assert_eq!(user[0].hits[0].role, "user");
        let assistant = search(&f.db, "parser", Role::Assistant, Order::Relevance, 600).unwrap();
        assert_eq!(assistant[0].hits[0].role, "assistant");
        let newest = search(&f.db, "parser", Role::Any, Order::Newest, 600).unwrap();
        let ts: Vec<_> = newest[0].hits.iter().map(|h| h.timestamp.clone().unwrap()).collect();
        assert_eq!(ts, vec!["2026-01-01T10:00:02.000Z".to_string(), "2026-01-01T10:00:00.000Z".to_string()]);
    }

    #[test]
    fn phrase_query_matches_exact_words() {
        let f = fixture();
        run(&f, IndexSettings::default());
        assert_eq!(hits(&f, "\"zebracorn parser\""), 1);
        assert_eq!(hits(&f, "\"parser zebracorn\""), 0);
    }

    #[test]
    fn missing_index_is_empty() {
        let dir = TempDir::new();
        let db = dir.0.join("none.sqlite");
        assert!(search(&db, "anything", Role::Any, Order::Relevance, 10).unwrap().is_empty());
        assert_eq!(stats(&db).files, 0);
        assert!(account_emails(&db).is_empty());
    }

    #[test]
    fn cancel_stops_before_indexing() {
        let f = fixture();
        let s = update(&f.db, &f.projects, IndexSettings::default(), &mut |_| {}, &|| true).unwrap();
        assert_eq!(s.messages, 0);
        assert!(s.last_run.is_none(), "a cancelled run does not count as finished");
    }

    #[test]
    fn query_building() {
        assert_eq!(fts_query("\"exact phrase\" more").as_deref(), Some("\"exact phrase\" \"more\""));
        assert_eq!(fts_query("hello wor").as_deref(), Some("\"hello\" \"wor\"*"));
        assert_eq!(fts_query("hello wor ").as_deref(), Some("\"hello\" \"wor\""));
        assert_eq!(fts_query("a").as_deref(), Some("\"a\""));
        assert_eq!(fts_query("--- ...").as_deref(), None);
        assert_eq!(fts_query("   ").as_deref(), None);
        assert_eq!(fts_query("say \"hi").as_deref(), Some("\"say\" \"hi\"*"));
        assert_eq!(fts_query("שלום עולם").as_deref(), Some("\"שלום\" \"עולם\"*"));
    }

    #[test]
    fn reminders_and_email_parsing() {
        assert_eq!(strip_reminders("a <system-reminder>x</system-reminder> b"), "a  b");
        assert_eq!(strip_reminders("a <system-reminder>never closed"), "a ");
        let ex = LineExtractor { settings: IndexSettings::default(), is_subagent_file: false };
        let mut st = FileState::default();
        ex.scan_identity(b"x The user's email address is bad-email. y", &mut st);
        assert!(st.email.is_none(), "an address without a domain dot is ignored");
        ex.scan_identity(b"x The user's email address is ok@example.co.uk. y", &mut st);
        assert_eq!(st.email.as_deref(), Some("ok@example.co.uk"), "trailing dot dropped");
        assert!(!ex.wants(br#"{"parentUuid":"x","attachment":{"a":1},"content":"no"}"#), "attachment lines skipped");
        assert!(!ex.wants(br#"{"parentUuid":"x","message":{"content":[{"type":"thinking","thinking":"t"}]}}"#), "thinking-only lines skipped");
    }

    #[test]
    fn iso_time_shape() {
        let s = iso_now();
        assert_eq!(s.len(), 20);
        assert!(s.ends_with('Z') && s.as_bytes()[10] == b'T');
    }
}
