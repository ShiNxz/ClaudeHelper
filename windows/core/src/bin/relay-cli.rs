//! `relay-cli`: read-only checks of Relay's core against the real (or an overridden) Claude folder.
//!   relay-cli scan      account folders, chat counts, schema problems
//!   relay-cli usage     each account's 5-hour and weekly use
//!   relay-cli pull <account/org> <local_id>   dry run of adding a chat to the signed-in account
use relay_core::paths::Paths;
use relay_core::plans::{self, PullItem, WriteIntent};
use relay_core::util::{fmt_date, now_ms, short};
use relay_core::{index, scanner, usage};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let paths = Paths::standard();
    match args.first().map(String::as_str) {
        Some("scan") => {
            let snap = scanner::scan(&paths);
            println!("signed in: {}", snap.active_account_id.as_deref().map(short).unwrap_or("-"));
            for f in &snap.folders {
                let problems: usize = f.sessions.iter().filter(|s| !s.problems.is_empty()).count();
                println!("{}  {} chats, {} deleted markers, {} with problems", f.folder.id(), f.sessions.len(), f.deleted_markers.len(), problems);
            }
        }
        Some("usage") => {
            let emails = index::account_emails(&paths.index_db());
            let events = usage::timeline_events(&paths);
            let samples = usage::read_samples(&paths);
            println!("{} samples, {} matched, {} timeline events", samples.len(), usage::attribute(&samples, &events).len(), events.len());
            let now = now_ms();
            let mut list: Vec<_> = usage::account_usage(&samples, &events).into_iter().collect();
            list.sort_by(|a, b| a.0.cmp(&b.0));
            for (id, u) in list {
                let when = |d: Option<i64>| d.map(fmt_date).unwrap_or_else(|| "-".into());
                println!("{}  org {}  sampled {}", emails.get(&id).cloned().unwrap_or_else(|| short(&id).to_string()), short(&u.org), fmt_date(u.sampled_at));
                println!("  5-hour {}% then, {}% now, resets by {}", u.five_hour, u.five_hour_now(now), when(u.five_hour_reset(now)));
                println!("  week   {:?}% then, {:?}% now, resets by {}", u.seven_day, u.seven_day_now(now), when(u.week_reset(now)));
            }
        }
        Some("pull") if args.len() >= 3 => {
            let snap = scanner::scan(&paths);
            let targets = snap.active_account_id.as_deref().map(|a| snap.folder_ids_of(a)).unwrap_or_default();
            let intent = WriteIntent::Pull { items: vec![PullItem { folder_id: args[1].clone(), session_id: args[2].clone() }], targets };
            let plan = plans::plan(&intent, &paths);
            println!("== {}: {} change(s), {} problem(s)", plan.title, plan.changes.len(), plan.problems.len());
            for c in &plan.changes {
                println!("  {:?}: {}", c.kind, c.summary);
            }
            for p in &plan.problems {
                println!("  PROBLEM {}: {}", p.path.display(), p.message);
            }
            println!("dry run, nothing written");
        }
        _ => {
            eprintln!("usage: relay-cli scan | usage | pull <account/org> <local_id>");
            std::process::exit(2);
        }
    }
}
