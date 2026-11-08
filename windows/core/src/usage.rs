//! Plan usage as Claude itself records it in plan-usage-history.json, matched to accounts.
//!
//! Claude samples the percent used of the five-hour and the weekly limit, per organization, about every
//! 30 minutes while it runs. A sample names an organization, not an account, so Relay works out the account
//! from who was signed in when it was taken: Claude's log, Relay's own account history, and the times of
//! its login backups (each one marks a moment the login files were swapped).
use crate::log::{self, LoginEvent, LoginKind};
use crate::paths::Paths;
use crate::util::{now_ms, write_atomic};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::Mutex;

const WEEK: i64 = 7 * 86_400_000;
const FIVE_HOURS: i64 = 5 * 3_600_000;

#[derive(Clone, Debug, PartialEq)]
pub struct UsageSample {
    pub org: String,
    pub date: i64,
    /// None when the sample has no five-hour window (nothing used in the last five hours).
    pub five_hour: Option<i64>,
    pub seven_day: Option<i64>,
}

/// The latest known usage of one account.
#[derive(Clone, Debug, PartialEq)]
pub struct AccountUsage {
    pub account_id: String,
    pub org: String,
    pub sampled_at: i64,
    /// Percent of the five-hour limit used when sampled (0 when no window was open).
    pub five_hour: i64,
    pub seven_day: Option<i64>,
    /// Latest time the five-hour window open at `sampled_at` can end, when the samples show when it began.
    pub five_hour_resets_by: Option<i64>,
    /// A time the weekly limit reset at or before. Later resets are this plus whole weeks.
    pub week_anchor: Option<i64>,
}

impl AccountUsage {
    pub fn five_hour_window_end(&self) -> Option<i64> {
        if self.five_hour <= 0 {
            return None;
        }
        let cap = self.sampled_at + FIVE_HOURS;
        Some(self.five_hour_resets_by.map(|r| r.min(cap)).unwrap_or(cap))
    }

    /// First estimated weekly reset after `date`.
    pub fn week_reset_after(&self, date: i64) -> Option<i64> {
        let a = self.week_anchor?;
        let k = ((date - a) as f64 / WEEK as f64).floor() as i64 + 1;
        Some(a + k.max(1) * WEEK)
    }

    pub fn five_hour_now(&self, now: i64) -> i64 {
        match self.five_hour_window_end() {
            Some(end) if now < end => self.five_hour,
            _ => 0,
        }
    }

    /// The latest time the open five-hour window resets, while it is still open.
    pub fn five_hour_reset(&self, now: i64) -> Option<i64> {
        self.five_hour_window_end().filter(|end| *end > now)
    }

    pub fn seven_day_now(&self, now: i64) -> Option<i64> {
        let s = self.seven_day?;
        if now - self.sampled_at >= WEEK {
            return Some(0);
        }
        if self.week_reset_after(self.sampled_at).map(|r| r <= now).unwrap_or(false) {
            return Some(0);
        }
        Some(s)
    }

    pub fn week_reset(&self, now: i64) -> Option<i64> {
        self.week_reset_after(now)
    }
}

fn pct(v: Option<&Value>) -> Option<i64> {
    v.and_then(|x| x.as_f64()).map(|f| f.round().clamp(0.0, 100.0) as i64)
}

/// `{"version":2,"samples":[{"org":"<uuid>","t":<ms>,"u":{"fh":<pct>,"sd":<pct>}}]}`
pub fn parse_samples(data: &[u8]) -> Vec<UsageSample> {
    let Ok(v) = serde_json::from_slice::<Value>(data) else { return vec![] };
    let Some(list) = v.get("samples").and_then(|s| s.as_array()) else { return vec![] };
    let mut out: Vec<UsageSample> = list
        .iter()
        .filter_map(|s| {
            let org = s.get("org")?.as_str()?.to_string();
            let t = s.get("t")?.as_f64()?;
            let u = s.get("u")?.as_object()?;
            let date = if t > 1e11 { t as i64 } else { (t * 1000.0) as i64 };
            Some(UsageSample { org, date, five_hour: pct(u.get("fh")), seven_day: pct(u.get("sd")) })
        })
        .collect();
    out.sort_by_key(|s| s.date);
    out
}

pub fn read_samples(paths: &Paths) -> Vec<UsageSample> {
    fs::read(paths.usage_history()).map(|d| parse_samples(&d)).unwrap_or_default()
}

/// The account signed in at `date`, or None when Claude was signed out or the log does not go back that far.
fn account_at(events: &[LoginEvent], date: i64) -> Option<String> {
    // The log has whole seconds; a sample in the same second as a sign-in belongs to it.
    let e = events.iter().rev().find(|e| e.date <= date + 1000)?;
    match &e.kind {
        LoginKind::SignedIn { account, .. } => Some(account.clone()),
        _ => None,
    }
}

fn last_sign_in(events: &[LoginEvent], account: &str) -> Option<i64> {
    events.iter().rev().find(|e| matches!(&e.kind, LoginKind::SignedIn { account: a, .. } if a == account)).map(|e| e.date)
}

/// Each sample with its account. A sample the timeline cannot place (older than the log, or right after a
/// switch Claude did not log) is matched by its organization when the placed samples show it belongs to one account.
pub fn attribute(samples: &[UsageSample], events: &[LoginEvent]) -> Vec<(UsageSample, String)> {
    let mut direct: Vec<(UsageSample, Option<String>)> = samples.iter().map(|s| (s.clone(), account_at(events, s.date))).collect();
    let mut owners: HashMap<String, HashMap<String, usize>> = HashMap::new();
    for (s, a) in &direct {
        if let Some(a) = a {
            *owners.entry(s.org.clone()).or_default().entry(a.clone()).or_default() += 1;
        }
    }
    let owner = |org: &str| -> Option<String> {
        let counts = owners.get(org)?;
        let (top, n) = counts.iter().max_by_key(|(_, n)| **n)?;
        let total: usize = counts.values().sum();
        (*n as f64 >= 0.75 * total as f64).then(|| top.clone())
    };
    for d in direct.iter_mut().filter(|d| d.1.is_none()) {
        d.1 = owner(&d.0.org);
    }
    direct.into_iter().filter_map(|(s, a)| a.map(|a| (s, a))).collect()
}

/// Everything known about who was signed in when, oldest first. At the same moment a swap comes before
/// the sign-in it led to.
pub fn timeline_events(paths: &Paths) -> Vec<LoginEvent> {
    let mut all = log::all_login_events(paths);
    all.extend(AccountHistory::events(paths));
    all.extend(crate::profiles::login_swap_dates(paths).into_iter().map(|d| LoginEvent { date: d, kind: LoginKind::SignedOut { from: None } }));
    all.sort_by(|a, b| a.date.cmp(&b.date).then((!a.is_sign_out()).cmp(&!b.is_sign_out())));
    all
}

pub fn account_usage(samples: &[UsageSample], events: &[LoginEvent]) -> HashMap<String, AccountUsage> {
    let mut by_account: HashMap<String, Vec<UsageSample>> = HashMap::new();
    for (s, a) in attribute(samples, events) {
        by_account.entry(a).or_default().push(s);
    }
    let mut out = HashMap::new();
    for (account, mut list) in by_account {
        list.sort_by_key(|s| s.date);
        let last = list.last().unwrap().clone();
        // Only the latest organization's samples describe the same limits.
        let same: Vec<UsageSample> = list.into_iter().filter(|s| s.org == last.org).collect();
        out.insert(account.clone(), AccountUsage {
            account_id: account,
            org: last.org.clone(),
            sampled_at: last.date,
            five_hour: last.five_hour.unwrap_or(0),
            seven_day: last.seven_day,
            five_hour_resets_by: five_hour_end(&same),
            week_anchor: week_anchor(&same),
        });
    }
    out
}

pub fn account_usage_for(paths: &Paths) -> HashMap<String, AccountUsage> {
    account_usage(&read_samples(paths), &timeline_events(paths))
}

/// Five hours after the earliest sample surely in the window open at the last sample: samples close
/// together, the figure never dropping, all within five hours.
fn five_hour_end(list: &[UsageSample]) -> Option<i64> {
    let last = list.last()?;
    if last.five_hour.unwrap_or(0) <= 0 {
        return None;
    }
    let mut earliest = last.date;
    let mut i = list.len() - 1;
    while i > 0 {
        let (cur, prev) = (&list[i], &list[i - 1]);
        let Some(pv) = prev.five_hour else { break };
        if pv <= 0 || pv > cur.five_hour.unwrap_or(0) || cur.date - prev.date > 45 * 60_000 || last.date - prev.date >= FIVE_HOURS {
            break;
        }
        earliest = prev.date;
        i -= 1;
    }
    Some(earliest + FIVE_HOURS)
}

/// The latest weekly reset seen: the weekly figure dropping between two samples at most six hours apart.
/// The later sample's time is used, so the real reset is at or before it.
fn week_anchor(list: &[UsageSample]) -> Option<i64> {
    for i in (1..list.len()).rev() {
        let (cur, prev) = (&list[i], &list[i - 1]);
        if let (Some(c), Some(p)) = (cur.seven_day, prev.seven_day) {
            if p - c >= 3 && cur.date - prev.date <= 6 * 3_600_000 {
                return Some(cur.date);
            }
        }
    }
    None
}

/// True when `usage` was sampled after the account's latest sign-in, so it describes this session.
pub fn is_current(usage: &AccountUsage, events: &[LoginEvent]) -> bool {
    last_sign_in(events, &usage.account_id).map(|s| usage.sampled_at >= s).unwrap_or(true)
}

/// Relay's own record of which account Claude was signed in to, in <Relay>/account-history.json.
/// Only account ids and times.
pub struct AccountHistory;

#[derive(Serialize, Deserialize, Clone)]
struct HistoryEntry {
    t: i64,
    account: Option<String>,
}

static HISTORY_LOCK: Mutex<()> = Mutex::new(());

impl AccountHistory {
    fn file(paths: &Paths) -> std::path::PathBuf {
        paths.data_dir.join("account-history.json")
    }

    fn load(paths: &Paths) -> Vec<HistoryEntry> {
        fs::read(Self::file(paths)).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    /// Note that `account` (None: signed out) is signed in from `date` on. Nothing is written when it already is.
    pub fn record(account: Option<&str>, date: i64, paths: &Paths) {
        let _guard = HISTORY_LOCK.lock().unwrap();
        let mut list = Self::load(paths);
        if list.last().map(|l| l.account.as_deref() == account).unwrap_or(false) {
            return;
        }
        list.push(HistoryEntry { t: date, account: account.map(String::from) });
        if list.len() > 1000 {
            let extra = list.len() - 1000;
            list.drain(..extra);
        }
        let _ = paths.ensure_data_dirs();
        if let Ok(data) = serde_json::to_vec(&list) {
            let _ = write_atomic(&Self::file(paths), &data, None);
        }
    }

    pub fn note_current(paths: &Paths) {
        let account = if crate::profiles::is_signed_in(paths) { paths.active_account_id() } else { None };
        Self::record(account.as_deref(), now_ms(), paths);
    }

    pub fn events(paths: &Paths) -> Vec<LoginEvent> {
        Self::load(paths)
            .into_iter()
            .map(|e| LoginEvent {
                date: e.t,
                kind: match e.account {
                    Some(a) => LoginKind::SignedIn { account: a, was_signed_out: false },
                    None => LoginKind::SignedOut { from: None },
                },
            })
            .collect()
    }
}

/// Picks the account to move to when the signed-in one runs low.
pub mod auto_switch {
    use super::AccountUsage;

    pub struct Candidate {
        pub account_id: String,
        pub usage: Option<AccountUsage>,
    }

    /// Why the signed-in account should be left, or None when it is under the threshold.
    pub fn reason(u: &AccountUsage, threshold: i64, now: i64) -> Option<String> {
        let week = u.seven_day_now(now).unwrap_or(0);
        let five = u.five_hour_now(now);
        if week >= threshold {
            return Some(format!("its weekly limit is at {week}%"));
        }
        if five >= threshold {
            return Some(format!("its 5-hour limit is at {five}%"));
        }
        None
    }

    /// The least used account under the threshold: lowest weekly use, then lowest 5-hour use.
    /// Accounts without usage data come last.
    pub fn pick(candidates: &[Candidate], threshold: i64, now: i64) -> Option<&Candidate> {
        candidates
            .iter()
            .filter(|c| c.usage.as_ref().map(|u| u.seven_day_now(now).unwrap_or(0) < threshold && u.five_hour_now(now) < threshold).unwrap_or(true))
            .min_by_key(|c| match &c.usage {
                Some(u) => (0, u.seven_day_now(now).unwrap_or(0), u.five_hour_now(now), c.account_id.clone()),
                None => (1, 0, 0, c.account_id.clone()),
            })
    }
}

/// Chats in the middle of a turn, judged by the end of their transcripts.
pub mod activity {
    use super::*;
    use std::io::{Read, Seek, SeekFrom};

    /// Of the given cli session ids, the ones whose transcript changed in the last `window_ms` and ends
    /// mid-turn: a prompt or tool result not answered yet, or a tool call still running.
    pub fn busy_transcripts(paths: &Paths, ids: &HashSet<String>, window_ms: i64, now: i64) -> HashSet<String> {
        let mut out = HashSet::new();
        if ids.is_empty() {
            return out;
        }
        let Ok(dirs) = fs::read_dir(&paths.projects_root) else { return out };
        for dir in dirs.filter_map(|e| e.ok()) {
            let Ok(files) = fs::read_dir(dir.path()) else { continue };
            for f in files.filter_map(|e| e.ok()) {
                let path = f.path();
                if path.extension().map(|e| e != "jsonl").unwrap_or(true) {
                    continue;
                }
                let id = path.file_stem().unwrap().to_string_lossy().to_string();
                if !ids.contains(&id) {
                    continue;
                }
                let m = crate::util::mtime_ms(&path);
                if now - m < window_ms && ends_mid_turn(&path) {
                    out.insert(id);
                }
            }
        }
        out
    }

    /// Reads the last 512 KB of a transcript and looks at its last prompt or reply.
    pub fn ends_mid_turn(path: &Path) -> bool {
        let Ok(mut f) = fs::File::open(path) else { return false };
        let size = f.metadata().map(|m| m.len()).unwrap_or(0);
        let _ = f.seek(SeekFrom::Start(size.saturating_sub(512 * 1024)));
        let mut buf = vec![];
        if f.read_to_end(&mut buf).is_err() {
            return false;
        }
        for line in buf.split(|b| *b == b'\n').rev() {
            let Ok(d) = serde_json::from_slice::<Value>(line) else { continue };
            let msg = d.get("message");
            match d.get("type").and_then(|t| t.as_str()) {
                Some("assistant") => {
                    // An API error or a hit limit ends the turn.
                    if d.get("error").is_some() || d.get("isApiErrorMessage").and_then(|v| v.as_bool()) == Some(true) {
                        return false;
                    }
                    return match msg.and_then(|m| m.get("stop_reason")).and_then(|s| s.as_str()) {
                        Some("tool_use") | None => true,
                        Some(_) => false,
                    };
                }
                Some("user") => {
                    if d.get("isMeta").and_then(|v| v.as_bool()) == Some(true) {
                        continue;
                    }
                    let content = msg.and_then(|m| m.get("content"));
                    let text = match content {
                        Some(Value::String(s)) => s.clone(),
                        Some(Value::Array(a)) => a.iter().filter_map(|b| b.get("text").and_then(|t| t.as_str())).collect::<Vec<_>>().join(""),
                        _ => String::new(),
                    };
                    return !text.contains("[Request interrupted by user");
                }
                _ => continue,
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::auto_switch::{pick, reason, Candidate};
    use super::*;

    fn s(org: &str, minutes: i64, fh: Option<i64>, sd: Option<i64>) -> UsageSample {
        UsageSample { org: org.into(), date: 1_700_000_000_000 + minutes * 60_000, five_hour: fh, seven_day: sd }
    }

    fn signed_in(minutes: i64, a: &str) -> LoginEvent {
        LoginEvent { date: 1_700_000_000_000 + minutes * 60_000, kind: LoginKind::SignedIn { account: a.into(), was_signed_out: true } }
    }

    #[test]
    fn parses_history() {
        let json = br#"{"version":2,"samples":[{"org":"org-x","t":1700000000000,"u":{"fh":10,"sd":40}},{"org":"org-y","t":1700000600000,"u":{"sd":7}},{"org":"org-x","t":1700001200000,"u":{"fh":12.6,"sd":41,"xu":0}},{"bad":1}]}"#;
        let v = parse_samples(json);
        assert_eq!(v.len(), 3);
        assert_eq!(v[1].five_hour, None);
        assert_eq!(v[2].five_hour, Some(13));
        assert_eq!(v[2].date, 1_700_001_200_000);
    }

    #[test]
    fn attribution_with_unlogged_swap() {
        let events = vec![
            signed_in(-1, "acct-x"),
            LoginEvent { date: 1_700_000_000_000 + 100 * 60_000, kind: LoginKind::SignedOut { from: None } },
            signed_in(300, "acct-y"),
        ];
        let list = vec![s("org-x", 0, Some(5), Some(20)), s("org-x", 30, Some(8), Some(22)), s("org-x", 150, Some(30), Some(50)), s("org-y", 301, None, Some(70))];
        let a: Vec<String> = attribute(&list, &events).into_iter().map(|(_, a)| a).collect();
        assert_eq!(a, vec!["acct-x", "acct-x", "acct-x", "acct-y"]);
    }

    #[test]
    fn windows_and_resets() {
        let t0 = 1_700_000_000_000i64;
        let x = vec![s("org-x", 0, Some(0), Some(90)), s("org-x", 30, Some(10), Some(95)), s("org-x", 60, Some(20), Some(2)), s("org-x", 90, Some(40), Some(5))];
        let u = account_usage(&x, &[signed_in(-1, "acct-x")]).remove("acct-x").unwrap();
        assert_eq!(u.five_hour, 40);
        assert_eq!(u.five_hour_resets_by, Some(t0 + 30 * 60_000 + FIVE_HOURS));
        assert_eq!(u.week_anchor, Some(t0 + 60 * 60_000));
        let later = t0 + 90 * 60_000;
        assert_eq!(u.five_hour_now(later + 60_000), 40);
        assert_eq!(u.five_hour_now(later + 6 * 3_600_000), 0);
        assert_eq!(u.seven_day_now(later + 86_400_000), Some(5));
        assert_eq!(u.seven_day_now(t0 + 60 * 60_000 + WEEK + 1), Some(0));
        assert_eq!(u.week_reset(later), Some(t0 + 60 * 60_000 + WEEK));
    }

    fn cand(id: &str, fh: i64, sd: i64) -> Candidate {
        Candidate {
            account_id: id.into(),
            usage: Some(AccountUsage { account_id: id.into(), org: "o".into(), sampled_at: now_ms(), five_hour: fh, seven_day: Some(sd), five_hour_resets_by: None, week_anchor: None }),
        }
    }

    #[test]
    fn auto_switch_rules() {
        let now = now_ms();
        assert!(reason(cand("a", 10, 96).usage.as_ref().unwrap(), 95, now).unwrap().contains("weekly"));
        assert!(reason(cand("a", 96, 10).usage.as_ref().unwrap(), 95, now).unwrap().contains("5-hour"));
        assert!(reason(cand("a", 94, 94).usage.as_ref().unwrap(), 95, now).is_none());
        let list = vec![cand("b", 0, 60), cand("c", 99, 10), cand("d", 20, 30), Candidate { account_id: "e".into(), usage: None }];
        assert_eq!(pick(&list, 95, now).unwrap().account_id, "d");
        let list = vec![cand("c", 99, 10), Candidate { account_id: "e".into(), usage: None }];
        assert_eq!(pick(&list, 95, now).unwrap().account_id, "e");
        assert!(pick(&[cand("c", 99, 10)], 95, now).is_none());
    }

    #[test]
    fn mid_turn() {
        let dir = std::env::temp_dir().join(format!("relay-turns-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(dir.join("proj")).unwrap();
        let turn = |name: &str, lines: &[&str]| {
            let p = dir.join("proj").join(format!("{name}.jsonl"));
            fs::write(&p, lines.join("\n") + "\n").unwrap();
            activity::ends_mid_turn(&p)
        };
        let prompt = r#"{"type":"user","message":{"role":"user","content":"do it"}}"#;
        let tool_use = r#"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#;
        let tool_result = r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#;
        let done = r#"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#;
        let limit = r#"{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"message":{"stop_reason":"stop_sequence","content":[]}}"#;
        let interrupted = r#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#;
        let summary = r#"{"type":"system","subtype":"stop_hook_summary"}"#;
        assert!(turn("a", &[prompt]) && turn("b", &[prompt, tool_use]) && turn("c", &[prompt, tool_use, tool_result]));
        assert!(!turn("d", &[prompt, tool_use, tool_result, done, summary]) && !turn("e", &[prompt, limit]) && !turn("f", &[prompt, tool_use, interrupted]));
        let paths = Paths { projects_root: dir.clone(), ..Paths::under(&dir) };
        let ids: HashSet<String> = ["b", "d", "zzz"].iter().map(|s| s.to_string()).collect();
        let busy = activity::busy_transcripts(&paths, &ids, 1_800_000, now_ms());
        assert_eq!(busy, ["b".to_string()].into_iter().collect());
        let _ = fs::remove_dir_all(&dir);
    }
}
