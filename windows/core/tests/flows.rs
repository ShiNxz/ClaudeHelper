//! End-to-end checks against made-up account folders, logins and logs in a temporary folder.
//! They never touch the real Claude folders. Ported from the macOS app's self-test.
use relay_core::claude_app::QuitOptions;
use relay_core::executor::{self, is_allowed_target};
use relay_core::paths::Paths;
use relay_core::plans::{self, PullItem, SessionEdit, WriteIntent};
use relay_core::profiles::{self, Acceptance};
use relay_core::usage::AccountHistory;
use relay_core::{backups, scanner, schema};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

fn base() -> PathBuf {
    let b = std::env::temp_dir().join(format!("relay-flows-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&b).unwrap();
    b
}

fn write(path: &Path, s: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, s).unwrap();
}

fn age(path: &Path, seconds: i64) {
    relay_core::util::set_mtime(path, relay_core::util::now_ms() - seconds * 1000).unwrap();
}

fn session(uuid: &str, title: &str, archived: bool, starred: bool) -> String {
    format!(
        "{{\"sessionId\":\"local_{uuid}\",\"cliSessionId\":\"c-{uuid}\",\"cwd\":\"/tmp/project\",\"createdAt\":1700000000000,\"lastActivityAt\":1700000100000,\"isArchived\":{archived},\"title\":\"{title}\",\"isStarred\":{starred},\"spawnedFrom\":{{\"title\":\"nested\"}},\"cost\":0.30594340000000001}}"
    )
}

/// Every managed file in a folder, name -> bytes.
fn contents(dir: &Path) -> BTreeMap<String, Vec<u8>> {
    fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| schema::is_managed_name(n))
                .map(|n| (n.clone(), fs::read(dir.join(&n)).unwrap()))
                .collect()
        })
        .unwrap_or_default()
}

fn apply(intent: &WriteIntent, paths: &Paths) -> executor::ApplyResult {
    let plan = plans::plan(intent, paths);
    assert!(plan.problems.is_empty(), "problems: {:?}", plan.problems);
    executor::apply(&plan, paths, &mut |_| {}).unwrap()
}

#[test]
fn edits_sync_and_backup_restore() {
    let b = base();
    let paths = Paths::under(&b);
    let a = paths.sessions_root.join("acct-a/org-1");
    let bb = paths.sessions_root.join("acct-b/org-1");
    write(&bb.join("local_s1.json"), &session("s1", "Shared older", false, false));
    write(&a.join("local_s1.json"), &session("s1", "Shared newer", false, false));
    age(&bb.join("local_s1.json"), 3600);
    write(&a.join("local_s2.json"), &session("s2", "Archived in A", true, false));
    write(&bb.join("local_s3.json"), &session("s3", "Only in B", false, true));
    write(&bb.join("local_s4.json"), &session("s4", "Deleted in A", false, false));
    write(&a.join("deleted_s4"), "1700000000000");
    write(&a.join("archived-sessions.idx"), r#"{"v":1,"archived":["local_s2"]}"#);
    write(&bb.join("archived-sessions.idx"), r#"{"v":1,"archived":[]}"#);
    write(&bb.join("scheduled-tasks.json"), r#"{"keep":true}"#);

    let snap = scanner::scan(&paths);
    assert_eq!(snap.folders.len(), 2);
    assert_eq!(snap.all_sessions().count(), 5);
    assert!(snap.all_sessions().all(|s| s.problems.is_empty()));

    // Restore one archived chat: session file and archived list.
    let edit = SessionEdit { folder_id: "acct-a/org-1".into(), session_id: "local_s2".into(), is_archived: Some(false), ..Default::default() };
    let plan = plans::plan(&WriteIntent::Edits(vec![edit]), &paths);
    assert!(plan.can_apply() && plan.changes.len() == 2);
    let before = contents(&a);
    let r = executor::apply(&plan, &paths, &mut |_| {}).unwrap();
    let after = contents(&a);
    assert_eq!(schema::parse_archived_index(&after["archived-sessions.idx"]).0, Some(vec![]));
    assert!(String::from_utf8_lossy(&after["local_s2.json"]).contains("\"isArchived\":false"));
    assert!(String::from_utf8_lossy(&after["local_s2.json"]).contains("0.30594340000000001"));

    // Put the backup back: the folder is as it was.
    let restore = WriteIntent::RestoreBackup(backups::list(&paths).into_iter().find(|x| x.id == r.backup.id).unwrap());
    apply(&restore, &paths);
    assert_eq!(contents(&a), before);

    // Merge: newest copy wins, a deleted chat stays deleted, the archived list is the same everywhere.
    apply(&WriteIntent::Sync(vec!["acct-a/org-1".into(), "acct-b/org-1".into()]), &paths);
    let (ca, cb) = (contents(&a), contents(&bb));
    assert!(String::from_utf8_lossy(&cb["local_s1.json"]).contains("Shared newer"));
    assert!(ca.contains_key("local_s3.json") && !cb.contains_key("local_s4.json") && cb.contains_key("deleted_s4"));
    assert_eq!(ca, cb);
    assert!(bb.join("scheduled-tasks.json").exists(), "other files are left alone");
    assert!(plans::plan(&WriteIntent::Sync(vec!["acct-a/org-1".into(), "acct-b/org-1".into()]), &paths).changes.is_empty(), "a second sync has nothing to do");

    // The writer refuses anything outside the managed files.
    assert!(is_allowed_target(&a.join("local_x.json"), &paths));
    assert!(!is_allowed_target(&bb.join("scheduled-tasks.json"), &paths));
    assert!(!is_allowed_target(&paths.sessions_root.join("acct-a/local_x.json"), &paths));
    assert!(!is_allowed_target(&a.join("../org-1/local_x.json"), &paths));

    // The schema guard blocks a broken file.
    write(&a.join("local_bad.json"), r#"{"sessionId":"local_other","title":"x"}"#);
    let bad = SessionEdit { folder_id: "acct-a/org-1".into(), session_id: "local_bad".into(), is_starred: Some(true), ..Default::default() };
    assert!(!plans::plan(&WriteIntent::Edits(vec![bad]), &paths).problems.is_empty());
    let _ = fs::remove_dir_all(&b);
}

#[test]
fn copy_and_pull() {
    let b = base();
    let paths = Paths::under(&b);
    let src = paths.sessions_root.join("acct-s/org-1");
    let t = paths.sessions_root.join("acct-t/org-1");
    let t2 = paths.sessions_root.join("acct-t/org-2");
    write(&src.join("local_c1.json"), &session("c1", "Shared", false, false));
    write(&src.join("local_c2.json"), &session("c2", "Archived one", true, false));
    write(&src.join("local_c3.json"), &session("c3", "Deleted in source", false, false));
    write(&src.join("deleted_c3"), "1");
    write(&src.join("archived-sessions.idx"), r#"{"v":1,"archived":["local_c2"]}"#);
    write(&t.join("local_c1.json"), &session("c1", "Shared older", false, false));
    age(&t.join("local_c1.json"), 3600);
    write(&t.join("local_c5.json"), &session("c5", "Own chat", false, false));
    write(&t.join("archived-sessions.idx"), r#"{"v":1,"archived":[]}"#);
    fs::create_dir_all(&t2).unwrap();
    write(&t2.join("deleted_c2"), "1");
    let src_before = contents(&src);

    // Copy one way.
    apply(&WriteIntent::Copy { sources: vec!["acct-s/org-1".into()], targets: vec!["acct-t/org-1".into()] }, &paths);
    let ct = contents(&t);
    assert_eq!(contents(&src), src_before, "the source is never written");
    assert!(String::from_utf8_lossy(&ct["local_c1.json"]).contains("\"Shared\""));
    assert!(ct.contains_key("local_c2.json") && !ct.contains_key("local_c3.json") && ct.contains_key("local_c5.json"));

    // Add one chat to both of the account's chat lists; a deleted marker for it is moved out.
    let items = vec![PullItem { folder_id: "acct-s/org-1".into(), session_id: "local_c2".into() }];
    let intent = WriteIntent::Pull { items, targets: vec!["acct-t/org-1".into(), "acct-t/org-2".into()] };
    apply(&intent, &paths);
    let c2 = contents(&t2);
    assert!(c2.contains_key("local_c2.json") && !c2.contains_key("deleted_c2"));
    assert_eq!(schema::parse_archived_index(&c2["archived-sessions.idx"]).0, Some(vec!["local_c2".to_string()]));
    assert!(plans::plan(&intent, &paths).changes.is_empty(), "adding again has nothing to do");
    assert!(!plans::plan(&WriteIntent::Pull { items: vec![], targets: vec![] }, &paths).problems.is_empty());
    let _ = fs::remove_dir_all(&b);
}

/// A config.json with made-up token strings and a cookie database with marker rows.
fn fake_login(paths: &Paths, account: &str, token: &str, marker: &str) {
    write(
        &paths.claude_config(),
        &format!("{{\"locale\":\"en\",\"oauth:tokenCache\":\"v1-{token}\",\"oauth:tokenCacheV2\":\"v2-{token}\",\"lastKnownAccountUuid\":\"{account}\",\"windowState\":{{\"x\":1}}}}"),
    );
    let cookies = paths.claude_dir.join("Cookies");
    let _ = fs::remove_file(&cookies);
    let c = rusqlite::Connection::open(&cookies).unwrap();
    let expires = (relay_core::util::now_ms() / 1000 + 30 * 86400 + 11_644_473_600) * 1_000_000;
    c.execute_batch(&format!(
        "CREATE TABLE cookies(host_key TEXT, name TEXT, expires_utc INTEGER, encrypted_value BLOB);\
         INSERT INTO cookies VALUES('.claude.ai','sessionKey',{expires},x'763130');\
         INSERT INTO cookies VALUES('.claude.ai','{marker}',{expires},x'763130');"
    ))
    .unwrap();
}

fn cookie_count(path: &Path, like: &str) -> i64 {
    rusqlite::Connection::open(path).unwrap().query_row(&format!("SELECT count(*) FROM cookies WHERE name LIKE '{like}'"), [], |r| r.get(0)).unwrap()
}

#[test]
fn save_switch_rollback_and_carry() {
    let b = base();
    let paths = Paths::under(&b);
    assert!(!paths.is_live_claude_dir());
    fake_login(&paths, "acct-a", "A", "marker-a");
    let work = profiles::save_current("Work", &paths).unwrap();
    assert_eq!(work.account_id.as_deref(), Some("acct-a"));
    assert!(work.session_expires.unwrap() > relay_core::util::now_ms());
    fake_login(&paths, "acct-b", "B", "marker-b");
    let personal = profiles::save_current("Personal", &paths).unwrap();
    assert_eq!(profiles::list(&paths).len(), 2);
    assert_eq!(profiles::save_current("Personal again", &paths).unwrap().id, personal.id, "same account updates its profile");

    // Chats to bring along, then the switch.
    let from = paths.sessions_root.join("acct-b/org-1");
    let to = paths.sessions_root.join("acct-a/org-1");
    write(&from.join("local_w1.json"), &session("w1", "Working on this", false, false));
    fs::create_dir_all(&to).unwrap();
    let carry = WriteIntent::Pull { items: vec![PullItem { folder_id: "acct-b/org-1".into(), session_id: "local_w1".into() }], targets: vec!["acct-a/org-1".into()] };
    let r = profiles::switch_to(&work, None, Some(&carry), &paths, QuitOptions::default(), None, &mut |_| {}).unwrap();
    let config: serde_json::Value = serde_json::from_slice(&fs::read(paths.claude_config()).unwrap()).unwrap();
    assert!(r.switched && config["lastKnownAccountUuid"] == "acct-a" && config["oauth:tokenCacheV2"] == "v2-A");
    assert_eq!(config["windowState"]["x"], 1, "other config keys untouched");
    assert_eq!(cookie_count(&paths.cookies(), "marker-a"), 1);
    assert_eq!(cookie_count(&paths.cookies(), "marker-b%"), 0);
    assert!(to.join("local_w1.json").exists() && r.carry_backup.is_some(), "chats brought along");
    assert!(r.login_backup.as_ref().unwrap().join("config.json").exists());
    assert_eq!(profiles::login_swap_dates(&paths).len(), 1);
    assert!(AccountHistory::events(&paths).last().map(|e| matches!(&e.kind, relay_core::log::LoginKind::SignedIn { account, .. } if account == "acct-a")).unwrap());

    // A rejected switch goes back to the previous account and flags the rejected login.
    let personal = profiles::list(&paths).into_iter().find(|p| p.id == personal.id).unwrap();
    let r = profiles::switch_to(&personal, None, None, &paths, QuitOptions::default(), Some(&|_| Acceptance::Rejected), &mut |_| {}).unwrap();
    let config: serde_json::Value = serde_json::from_slice(&fs::read(paths.claude_config()).unwrap()).unwrap();
    assert!(!r.switched && config["lastKnownAccountUuid"] == "acct-a" && r.warnings[0].contains("back on Work"));
    assert!(profiles::list(&paths).into_iter().find(|p| p.id == personal.id).unwrap().problem.is_some());

    // Add another account: login moved aside, Claude left signed out, other keys kept.
    let fresh = profiles::prepare_fresh_login(&paths, None, QuitOptions::default(), &mut |_| {}).unwrap();
    let config: serde_json::Value = serde_json::from_slice(&fs::read(paths.claude_config()).unwrap()).unwrap();
    assert!(config.get("lastKnownAccountUuid").is_none() && config["locale"] == "en" && !paths.cookies().exists());
    assert!(fresh.login_backup.unwrap().join("Cookies").exists());

    // Expired logins are refused with a clear message.
    let mut expired = work.clone();
    expired.session_expires = Some(1);
    let e = profiles::switch_to(&expired, None, None, &paths, QuitOptions::default(), None, &mut |_| {}).unwrap_err();
    assert!(e.0.contains("expired") && e.0.contains("Log In Again"));
    let _ = fs::remove_dir_all(&b);
}
