//! Small shared helpers: the error type, times, atomic writes.
use chrono::{Local, NaiveDateTime, TimeZone};
use std::fmt;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Every failure is a message meant for the user.
#[derive(Debug, Clone, PartialEq)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error(e.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error(format!("JSON: {e}"))
    }
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error(format!("SQLite: {e}"))
    }
}

impl From<String> for Error {
    fn from(s: String) -> Self {
        Error(s)
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

/// Milliseconds since 1970.
pub fn now_ms() -> i64 {
    to_ms(SystemTime::now())
}

pub fn to_ms(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_millis() as i64,
        Err(e) => -(e.duration().as_millis() as i64),
    }
}

/// Modification time of a file in milliseconds, or 0.
pub fn mtime_ms(path: &Path) -> i64 {
    fs::metadata(path).and_then(|m| m.modified()).map(to_ms).unwrap_or(0)
}

pub fn set_mtime(path: &Path, ms: i64) -> Result<()> {
    let ft = filetime::FileTime::from_unix_time(ms.div_euclid(1000), (ms.rem_euclid(1000) * 1_000_000) as u32);
    filetime::set_file_mtime(path, ft)?;
    Ok(())
}

/// Write to a temporary file in the same folder, then rename it into place.
pub fn write_atomic(path: &Path, data: &[u8], mtime: Option<i64>) -> Result<()> {
    let dir = path.parent().ok_or_else(|| Error(format!("no folder for {}", path.display())))?;
    fs::create_dir_all(dir)?;
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.relay-tmp"));
    fs::write(&tmp, data)?;
    restrict(&tmp);
    if let Some(ms) = mtime {
        set_mtime(&tmp, ms)?;
    }
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return err(format!("Could not write {name}: {e}"));
    }
    Ok(())
}

/// Readable only by this user. On Windows the per-user AppData folders already are.
pub fn restrict(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = if path.is_dir() { 0o700 } else { 0o600 };
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
    }
    #[cfg(not(unix))]
    let _ = path;
}

pub fn shell_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    let safe = |c: char| c.is_ascii_alphanumeric() || "-_./:@%+=\\".contains(c);
    if s.chars().all(safe) {
        return s.to_string();
    }
    if cfg!(windows) {
        format!("\"{}\"", s.replace('"', "\\\""))
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// "2026-11-08_151408", local time, used in backup folder names.
pub fn stamp(ms: i64) -> String {
    local(ms).format("%Y-%m-%d_%H%M%S").to_string()
}

pub fn parse_stamp(s: &str) -> Option<i64> {
    let naive = NaiveDateTime::parse_from_str(s, "%Y-%m-%d_%H%M%S").ok()?;
    Local.from_local_datetime(&naive).earliest().map(|d| d.timestamp_millis())
}

/// "2026-11-08 15:14:08", local time.
pub fn fmt_date(ms: i64) -> String {
    local(ms).format("%Y-%m-%d %H:%M:%S").to_string()
}

pub fn local(ms: i64) -> chrono::DateTime<Local> {
    Local.timestamp_millis_opt(ms).single().unwrap_or_else(|| Local.timestamp_millis_opt(0).unwrap())
}

/// A chat title inside a sentence, isolated so a right-to-left title does not turn the sentence around.
pub fn quoted(title: &str) -> String {
    format!("\"\u{2068}{title}\u{2069}\"")
}

pub fn short(id: &str) -> &str {
    &id[..id.len().min(8)]
}
