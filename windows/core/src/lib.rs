//! Relay core: everything Relay does with the Claude desktop app's files, without any UI.
//! It builds and tests on macOS and Linux too; the Windows-only parts are in `claude_app`.

pub mod backups;
pub mod claude_app;
pub mod executor;
pub mod index;
pub mod json_patch;
pub mod log;
pub mod model;
pub mod paths;
pub mod plans;
pub mod profiles;
pub mod scanner;
pub mod schema;
pub mod usage;
pub mod util;

pub use util::{Error, Result};
