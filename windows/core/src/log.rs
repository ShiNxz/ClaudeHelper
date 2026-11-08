//! Sign-in and sign-out lines from Claude's own log. Only these lines are parsed; nothing else is kept.
//! Best effort: if Claude changes its wording, Relay falls back to checking the login files.
use crate::paths::Paths;
use chrono::{Local, NaiveDateTime, TimeZone};
use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Debug, PartialEq)]
pub enum LoginKind {
    /// Signed out. `from` is the account that was signed in, when the log says.
    SignedOut { from: Option<String> },
    /// Signed in to `account`. `was_signed_out` is true for a real sign-in after a signed-out state.
    SignedIn { account: String, was_signed_out: bool },
}

#[derive(Clone, Debug, PartialEq)]
pub struct LoginEvent {
    pub date: i64,
    pub kind: LoginKind,
}

impl LoginEvent {
    pub fn is_sign_out(&self) -> bool {
        matches!(self.kind, LoginKind::SignedOut { .. })
    }
}

fn transition() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    // "[account] Login-state transition (loggedOut: false → true, uuid: <id> → <none>), clearing oauth cache"
    R.get_or_init(|| Regex::new(r"Login-state transition \(loggedOut: (true|false) \S+ (true|false), uuid: (\S+) \S+ ([0-9a-f-]{36}|<none>)\)").unwrap())
}

fn line_date(line: &str) -> Option<i64> {
    // "2026-11-04 19:28:39 [info] ..." or "[2026-11-04 19:28:39.123] [info] ...", local time.
    let s = line.trim_start_matches('[');
    let stamp = s.get(..19)?;
    let naive = NaiveDateTime::parse_from_str(stamp, "%Y-%m-%d %H:%M:%S").ok()?;
    Local.from_local_datetime(&naive).earliest().map(|d| d.timestamp_millis())
}

pub fn parse(text: &str, since: Option<i64>) -> Vec<LoginEvent> {
    let mut out = vec![];
    for line in text.lines().filter(|l| l.contains("[account]")) {
        let Some(date) = line_date(line) else { continue };
        if since.map(|s| date < s).unwrap_or(false) {
            continue;
        }
        if line.contains("Navigated to /logout") {
            out.push(LoginEvent { date, kind: LoginKind::SignedOut { from: None } });
            continue;
        }
        let Some(c) = transition().captures(line) else { continue };
        let now_out = &c[2] == "true";
        let was_out = &c[1] == "true";
        let from = c[3].trim_end_matches(',').to_string();
        let to = c[4].to_string();
        if now_out {
            out.push(LoginEvent { date, kind: LoginKind::SignedOut { from: (from != "<none>").then_some(from) } });
        } else if to != "<none>" {
            out.push(LoginEvent { date, kind: LoginKind::SignedIn { account: to, was_signed_out: was_out } });
        }
    }
    out
}

/// Events at or after `since`, oldest first, from the last `tail_bytes` of the current log.
pub fn login_events(paths: &Paths, since: Option<i64>, tail_bytes: u64) -> Vec<LoginEvent> {
    let Ok(mut f) = fs::File::open(&paths.claude_log) else { return vec![] };
    let size = f.metadata().map(|m| m.len()).unwrap_or(0);
    let start = size.saturating_sub(tail_bytes);
    let _ = f.seek(SeekFrom::Start(start));
    let mut buf = vec![];
    let _ = f.read_to_end(&mut buf);
    parse(&String::from_utf8_lossy(&buf), since)
}

struct Cached {
    size: u64,
    mtime: i64,
    offset: u64,
    events: Vec<LoginEvent>,
}

fn cache() -> &'static Mutex<HashMap<PathBuf, Cached>> {
    static C: OnceLock<Mutex<HashMap<PathBuf, Cached>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The log and its older copies (main.log, main1.log, main2.log, main.old.log).
fn log_files(paths: &Paths) -> Vec<PathBuf> {
    let Some(dir) = paths.claude_log.parent() else { return vec![] };
    let stem = paths.claude_log.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "main".into());
    let Ok(rd) = fs::read_dir(dir) else { return vec![] };
    rd.filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| {
            let Some(mid) = n.strip_prefix(&stem).and_then(|r| r.strip_suffix(".log")) else { return false };
            mid.chars().all(|c| c.is_ascii_digit()) || mid == ".old"
        })
        .map(|n| dir.join(n))
        .collect()
}

fn read_from(path: &Path, offset: u64) -> Vec<u8> {
    let Ok(mut f) = fs::File::open(path) else { return vec![] };
    let _ = f.seek(SeekFrom::Start(offset));
    let mut buf = vec![];
    let _ = f.read_to_end(&mut buf);
    buf
}

/// Every sign-in and sign-out event in the log and its older copies, oldest first. Each file is parsed
/// once and then only its new lines, so this is cheap to call every minute.
pub fn all_login_events(paths: &Paths) -> Vec<LoginEvent> {
    let mut cache = cache().lock().unwrap();
    let mut all = vec![];
    for path in log_files(paths) {
        let Ok(meta) = fs::metadata(&path) else { continue };
        let size = meta.len();
        let mtime = meta.modified().map(crate::util::to_ms).unwrap_or(0);
        let entry = cache.entry(path.clone()).or_insert(Cached { size: 0, mtime: 0, offset: 0, events: vec![] });
        if entry.size == size && entry.mtime == mtime {
            all.extend(entry.events.iter().cloned());
            continue;
        }
        if size < entry.offset {
            *entry = Cached { size: 0, mtime: 0, offset: 0, events: vec![] };
        }
        let data = read_from(&path, entry.offset);
        // Only whole lines; a line still being written is read next time.
        if let Some(last_nl) = data.iter().rposition(|b| *b == b'\n') {
            entry.events.extend(parse(&String::from_utf8_lossy(&data[..=last_nl]), None));
            entry.offset += (last_nl + 1) as u64;
        }
        entry.size = size;
        entry.mtime = mtime;
        all.extend(entry.events.iter().cloned());
    }
    all.sort_by_key(|e| e.date);
    all
}

/// True when the newest event says Claude is signed out. None when the log has no such event.
pub fn last_state_is_signed_out(paths: &Paths) -> Option<bool> {
    all_login_events(paths).last().map(|e| e.is_sign_out())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_sign_in_and_out() {
        let text = "2026-11-07 04:44:21 [info] [account] Login-state transition (loggedOut: false \u{2192} true, uuid: aaaaaaaa-0000-0000-0000-000000000001 \u{2192} <none>), clearing oauth cache\n\
                    2026-11-07 04:44:22 [info] [account] Navigated to /logout, synthesizing logged-out\n\
                    2026-11-07 04:44:50 [info] [account] Login-state transition (loggedOut: true \u{2192} false, uuid: aaaaaaaa-0000-0000-0000-000000000001 \u{2192} bbbbbbbb-0000-0000-0000-000000000002)\n\
                    2026-11-07 04:45:00 [info] [oauth-v2] unrelated\n";
        let ev = parse(text, None);
        assert_eq!(ev.len(), 3);
        assert_eq!(ev[0].kind, LoginKind::SignedOut { from: Some("aaaaaaaa-0000-0000-0000-000000000001".into()) });
        assert_eq!(ev[1].kind, LoginKind::SignedOut { from: None });
        assert_eq!(ev[2].kind, LoginKind::SignedIn { account: "bbbbbbbb-0000-0000-0000-000000000002".into(), was_signed_out: true });
    }
}
