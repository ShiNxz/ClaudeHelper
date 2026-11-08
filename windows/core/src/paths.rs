//! Where the Claude desktop app keeps its files, and where Relay keeps its own.
//! Environment overrides point everything at a copy of the data for testing:
//! CLAUDE_HELPER_SESSIONS_ROOT, CLAUDE_HELPER_CLAUDE_DIR, CLAUDE_HELPER_PROJECTS_ROOT,
//! CLAUDE_HELPER_DATA_DIR, CLAUDE_HELPER_CLAUDE_LOG.
use crate::util::{restrict, Result};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Paths {
    /// <Claude>/claude-code-sessions: one folder per account and organization with the sidebar entries.
    pub sessions_root: PathBuf,
    /// The Claude app's own folder (config.json, Cookies, plan-usage-history.json).
    pub claude_dir: PathBuf,
    /// ~/.claude/projects: Claude Code transcripts, only ever read.
    pub projects_root: PathBuf,
    /// Relay's own folder: saved logins, backups, search index.
    pub data_dir: PathBuf,
    /// Claude's main log, read only for sign-in and sign-out lines.
    pub claude_log: PathBuf,
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// %APPDATA%\Claude on Windows, ~/Library/Application Support/Claude on macOS, ~/.config/Claude on Linux.
pub fn default_claude_dir() -> PathBuf {
    dirs::config_dir().unwrap_or_else(home).join("Claude")
}

fn default_log(claude_dir: &Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/Logs/Claude/main.log")
    } else {
        claude_dir.join("logs").join("main.log")
    }
}

fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var_os(key).filter(|v| !v.is_empty()).map(PathBuf::from)
}

impl Paths {
    pub fn standard() -> Paths {
        let claude_dir = env_path("CLAUDE_HELPER_CLAUDE_DIR").unwrap_or_else(default_claude_dir);
        let projects = env_path("CLAUDE_HELPER_PROJECTS_ROOT").unwrap_or_else(|| {
            env_path("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home().join(".claude")).join("projects")
        });
        Paths {
            sessions_root: env_path("CLAUDE_HELPER_SESSIONS_ROOT").unwrap_or_else(|| claude_dir.join("claude-code-sessions")),
            claude_log: env_path("CLAUDE_HELPER_CLAUDE_LOG").unwrap_or_else(|| default_log(&claude_dir)),
            data_dir: env_path("CLAUDE_HELPER_DATA_DIR").unwrap_or_else(|| dirs::config_dir().unwrap_or_else(home).join("Relay")),
            projects_root: projects,
            claude_dir,
        }
    }

    /// A self-contained set of folders under `base`, for tests.
    pub fn under(base: &Path) -> Paths {
        Paths {
            sessions_root: base.join("sessions"),
            claude_dir: base.join("claude"),
            projects_root: base.join("projects"),
            data_dir: base.join("data"),
            claude_log: base.join("logs").join("main.log"),
        }
    }

    pub fn claude_config(&self) -> PathBuf {
        self.claude_dir.join("config.json")
    }

    /// Claude's cookie database. Newer Chromium keeps it in Network\Cookies.
    pub fn cookies(&self) -> PathBuf {
        let network = self.claude_dir.join("Network").join("Cookies");
        if network.exists() { network } else { self.claude_dir.join("Cookies") }
    }

    pub fn usage_history(&self) -> PathBuf {
        self.claude_dir.join("plan-usage-history.json")
    }

    pub fn profiles_dir(&self) -> PathBuf {
        self.data_dir.join("profiles")
    }

    pub fn backups_dir(&self) -> PathBuf {
        self.data_dir.join("backups")
    }

    pub fn index_db(&self) -> PathBuf {
        self.data_dir.join("index.sqlite")
    }

    pub fn settings_file(&self) -> PathBuf {
        self.data_dir.join("settings.json")
    }

    /// True when this is the folder the running Claude app uses, so Claude has to be closed before writing.
    pub fn is_live_claude_dir(&self) -> bool {
        same_path(&self.claude_dir, &default_claude_dir())
    }

    pub fn is_live_sessions_root(&self) -> bool {
        same_path(&self.sessions_root, &default_claude_dir().join("claude-code-sessions"))
    }

    pub fn ensure_data_dirs(&self) -> Result<()> {
        for d in [self.data_dir.clone(), self.backups_dir(), self.profiles_dir()] {
            fs::create_dir_all(&d)?;
            restrict(&d);
        }
        Ok(())
    }

    /// The account Claude was last signed in to. Reads only this key of config.json.
    pub fn active_account_id(&self) -> Option<String> {
        let data = fs::read(self.claude_config()).ok()?;
        let v: serde_json::Value = serde_json::from_slice(&data).ok()?;
        v.get("lastKnownAccountUuid")?.as_str().map(String::from)
    }
}

pub fn same_path(a: &Path, b: &Path) -> bool {
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => a == b,
    }
}
