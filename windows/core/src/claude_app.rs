//! Finding, quitting and opening the Claude desktop app.
//!
//! On Windows there is no "please quit" request like macOS has, so Relay sends WM_CLOSE to Claude's
//! windows and waits. If Claude only hides in the tray instead of quitting, and force is allowed,
//! it ends Claude's processes after the timeout. Claude Code CLI processes (also claude.exe) are told
//! apart from the desktop app by the app's resources\app.asar next to the executable.
use crate::util::{err, Result};
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread::sleep;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug)]
pub struct QuitOptions {
    pub timeout: Duration,
    /// End Claude's processes when it does not close by itself within `timeout`.
    pub force: bool,
}

impl Default for QuitOptions {
    fn default() -> Self {
        QuitOptions { timeout: Duration::from_secs(30), force: false }
    }
}

/// The executable of the last Claude that Relay closed, to start the same one again.
static LAST_EXE: Mutex<Option<PathBuf>> = Mutex::new(None);

pub fn is_running() -> bool {
    !imp::processes().is_empty()
}

/// Close Claude and wait until all of its processes are gone.
pub fn quit(opts: QuitOptions) -> Result<()> {
    let procs = imp::processes();
    if procs.is_empty() {
        return Ok(());
    }
    if let Some(main) = procs.iter().find(|p| p.main) {
        *LAST_EXE.lock().unwrap() = Some(main.exe.clone());
    }
    imp::ask_to_close(&procs)?;
    let deadline = Instant::now() + opts.timeout;
    while Instant::now() < deadline {
        if imp::processes().is_empty() {
            // Give it a moment to finish flushing files after the processes exit.
            sleep(Duration::from_millis(1500));
            return Ok(());
        }
        sleep(Duration::from_millis(250));
    }
    if opts.force {
        imp::force_quit(&imp::processes());
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if imp::processes().is_empty() {
                sleep(Duration::from_millis(1500));
                return Ok(());
            }
            sleep(Duration::from_millis(250));
        }
    }
    err(format!(
        "Claude did not quit within {} seconds. It may be showing a dialog or still be running in the tray. Quit it from its tray icon, then try again. Nothing was written.",
        opts.timeout.as_secs()
    ))
}

/// Start Claude and wait a little for it to come up.
pub fn open() -> Result<()> {
    let last = LAST_EXE.lock().unwrap().clone();
    imp::launch(last)?;
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline && !is_running() {
        sleep(Duration::from_millis(250));
    }
    Ok(())
}

/// Hand a claude:// link to the system, which passes it to the Claude app.
pub fn open_url(url: &str) -> Result<()> {
    if !url.starts_with("claude://") {
        return err("Only claude:// links are opened.");
    }
    imp::open_url(url)
}

pub struct ClaudeProcess {
    pub pid: u32,
    pub exe: PathBuf,
    /// The main process (not a renderer, GPU or utility helper).
    pub main: bool,
}

#[cfg(windows)]
mod imp {
    use super::ClaudeProcess;
    use crate::util::{err, Result};
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
    use windows_sys::core::BOOL;
    use windows_sys::Win32::Foundation::{HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{EnumWindows, GetWindowThreadProcessId, PostMessageW, WM_CLOSE};

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    const DETACHED_PROCESS: u32 = 0x0000_0008;

    fn is_desktop_exe(exe: &Path) -> bool {
        let named = exe.file_name().map(|n| n.to_string_lossy().eq_ignore_ascii_case("claude.exe")).unwrap_or(false);
        named && exe.parent().map(|d| d.join("resources").join("app.asar").exists()).unwrap_or(false)
    }

    pub fn processes() -> Vec<ClaudeProcess> {
        let Ok(mut sys) = System::new() else { return vec![] };
        sys.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet).with_cmd(UpdateKind::OnlyIfNotSet),
        );
        sys.processes()
            .values()
            .filter_map(|p| {
                let exe = p.exe()?.to_path_buf();
                if !is_desktop_exe(&exe) {
                    return None;
                }
                let main = !p.cmd().iter().any(|a| a.to_string_lossy().starts_with("--type="));
                Some(ClaudeProcess { pid: p.pid().as_u32(), exe, main })
            })
            .collect()
    }

    unsafe extern "system" fn close_window(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let pids = &*(lparam as *const Vec<u32>);
        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        if pids.contains(&pid) {
            PostMessageW(hwnd, WM_CLOSE, 0, 0);
        }
        1
    }

    /// WM_CLOSE to every top-level window of Claude's main process, like clicking its close button.
    pub fn ask_to_close(procs: &[ClaudeProcess]) -> Result<()> {
        let pids: Vec<u32> = procs.iter().filter(|p| p.main).map(|p| p.pid).collect();
        unsafe {
            EnumWindows(Some(close_window), &pids as *const Vec<u32> as LPARAM);
        }
        Ok(())
    }

    pub fn force_quit(procs: &[ClaudeProcess]) {
        let Ok(mut sys) = System::new() else { return };
        sys.refresh_processes(ProcessesToUpdate::All, true);
        // Main process first, so it does not restart its helpers.
        let mut ordered: Vec<&ClaudeProcess> = procs.iter().collect();
        ordered.sort_by_key(|p| !p.main);
        for p in ordered {
            if let Some(proc_) = sys.process(sysinfo::Pid::from_u32(p.pid)) {
                proc_.kill();
            }
        }
    }

    fn local_app_data() -> Option<PathBuf> {
        std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
    }

    /// Where Claude may be installed, best first.
    fn candidates(last: Option<PathBuf>) -> Vec<PathBuf> {
        let mut out = Vec::new();
        if let Some(l) = local_app_data() {
            // The installer's launcher, which always starts the newest installed version.
            out.push(l.join("AnthropicClaude").join("claude.exe"));
        }
        if let Some(exe) = last {
            if let Some(dir) = exe.parent() {
                if dir.file_name().map(|n| n.to_string_lossy().starts_with("app-")).unwrap_or(false) {
                    if let Some(root) = dir.parent() {
                        out.push(root.join("claude.exe"));
                    }
                }
            }
            out.push(exe);
        }
        if let Some(l) = local_app_data() {
            out.push(l.join("Programs").join("Claude").join("Claude.exe"));
        }
        if let Some(p) = std::env::var_os("ProgramFiles") {
            out.push(PathBuf::from(p).join("Claude").join("Claude.exe"));
        }
        out
    }

    pub fn launch(last: Option<PathBuf>) -> Result<()> {
        for exe in candidates(last) {
            if exe.is_file() {
                Command::new(&exe).creation_flags(DETACHED_PROCESS).spawn()?;
                return Ok(());
            }
        }
        // Store installs: let Windows start it through its link handler.
        open_url("claude://claude.ai/epitaxy")
    }

    pub fn open_url(url: &str) -> Result<()> {
        let status = Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).creation_flags(CREATE_NO_WINDOW).status()?;
        if status.success() { Ok(()) } else { err("Windows could not open the claude:// link. Is Claude installed?") }
    }
}

#[cfg(not(windows))]
mod imp {
    //! Other systems: Relay for Windows only reads here (for development and tests). It never quits or
    //! starts Claude outside Windows; the macOS app does that on a Mac.
    use super::ClaudeProcess;
    use crate::util::{err, Result};
    use std::path::PathBuf;
    use std::process::Command;

    pub fn processes() -> Vec<ClaudeProcess> {
        let pattern = if cfg!(target_os = "macos") { "Claude.app/Contents/MacOS/Claude$" } else { "[Cc]laude-desktop" };
        let out = Command::new("pgrep").args(["-f", pattern]).output();
        let Ok(out) = out else { return vec![] };
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.trim().parse::<u32>().ok())
            .map(|pid| ClaudeProcess { pid, exe: PathBuf::new(), main: true })
            .collect()
    }

    pub fn ask_to_close(_procs: &[ClaudeProcess]) -> Result<()> {
        err("Relay for Windows only quits Claude on Windows.")
    }

    pub fn force_quit(_procs: &[ClaudeProcess]) {}

    pub fn launch(_last: Option<PathBuf>) -> Result<()> {
        err("Relay for Windows only starts Claude on Windows.")
    }

    pub fn open_url(url: &str) -> Result<()> {
        let tool = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
        Command::new(tool).arg(url).status()?;
        Ok(())
    }
}
