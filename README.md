# Relay

Use several Claude accounts on one Mac without logging in and out. Relay sits in the menu bar next to the Claude desktop app. It shows how much of each account's 5-hour and weekly limit is used, switches Claude between accounts in one click, can switch by itself when an account runs low, and keeps your Code chats with you whichever account you are on.

> **Unofficial.** Relay is a community tool. It is not made, endorsed or supported by Anthropic, and it is not affiliated with Anthropic in any way. "Claude" is a trademark of Anthropic.

It works with Claude's undocumented local files. A Claude update can change them at any time, which is why every write goes through a schema check and a full backup first. Relay makes no network requests.

## Why

If you have more than one Claude plan (work and personal, or a second account for when the first runs out), the Claude app makes you log out and back in to change accounts. Each account also keeps its own list of Code chats, so a chat you started on one account is not there when you move to the next, and you cannot see which account has room left until you are in it.

Relay fixes those three things:

- **Usage at a glance.** Every account's 5-hour and weekly use, with when it resets, so you know where to go next.
- **One-click switching.** Log in to each account once. After that Relay swaps Claude's login for you, with no login screen.
- **Your chats follow you.** Add a single chat to the account you are on, copy chats over on every switch, or keep all accounts in sync.

## Features

- **Accounts and usage.** Every account used on this Mac, by email, with its 5-hour and weekly usage bars and reset times. The menu bar shows the same list.
- **Switch accounts** from the menu bar or the Accounts tab. Relay quits Claude, saves the current login (so refreshed tokens are kept), puts the chosen login in place, reopens Claude and checks that Claude accepted it.
- **Auto-switch.** When the signed-in account reaches a threshold you pick (95% by default) of its 5-hour or weekly limit, Relay waits for running chats to finish, switches to the least used account and brings your recent chats along.
- **Sessions browser.** One row per Code chat across every account: title, project, which accounts have it, archived, pinned, last activity. A green dot marks chats the signed-in account has. Filter, sort, and double-click to open the chat in Claude.
- **Add a chat to this account.** A chat that only another account has gets an **Add to This Account** button, which copies it in so Claude can open it.
- **Search old chats.** Full-text search over your transcripts in `~/.claude/projects`, with a local index that updates in the background.
- **Sync chats between accounts.** Merge accounts (every account gets every chat) or copy one account's chats into the others. You see every change before anything is written.
- **Restore archived chats**, and bulk rename, pin and archive.
- **Backups.** Every write is backed up first, and any backup can be put back.
- **Notifications.** Results show as macOS notifications when Relay's window is not in front, and as a short message at the bottom of the window when it is.

## Install

Requirements: macOS 14 Sonoma or newer, Apple Silicon or Intel, and the Claude desktop app.

1. Download `Relay-<version>.dmg` from [Releases](https://github.com/ShiNxz/ClaudeHelper/releases).
2. Open the DMG and drag **Relay** to **Applications**.
3. Open it. Release builds are not notarized by Apple yet, so the first time macOS says it cannot verify the app. Click **Done** (not Move to Trash), then:
   - open **System Settings > Privacy & Security**,
   - scroll to the message about Relay being blocked and click **Open Anyway**,
   - confirm with your password.

   macOS remembers this, so you only do it once per version. If you prefer the terminal, this does the same:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Relay.app
   ```

Relay lives in the menu bar. Its window shows a Dock icon only while it is open.

**Coming from Claude Helper?** Relay is the same app under a new name. Your saved logins, settings and backups carry over. Quit Claude Helper and delete `Claude Helper.app` from Applications so only one copy is left (`./bundle.sh --install` does this for you).

## Quick start

1. Open **Accounts**. The account Claude is signed in to has a **Save** button. Click it.
2. Every other account has **Log In and Save**. Click it, and Claude reopens signed out (nothing is logged out). Log in to that account in Claude. Relay saves it by itself within a minute.
3. Switch between saved accounts from the menu bar, or with **Switch** in Accounts.
4. Optional: turn on **Auto-switch** in Accounts, and pick which accounts share chats in **Sync chats**.

Two things end a saved login, because Claude ends that session on the server:

- **Log out** inside Claude.
- **Signing in to a saved account again by hand.** Claude revokes the older sign-in about a minute later.

So switch only with Relay. To keep saved logins valid, Relay re-saves the signed-in account every few minutes and again right before each switch. It never saves while Claude is signed out.

## How it works

### Usage

The Claude app keeps its own record of plan usage in `~/Library/Application Support/Claude/plan-usage-history.json`: the percent used of the 5-hour and the weekly limit, taken about every 30 minutes while Claude runs. Relay reads that file. A record names an organization, not an account, so Relay matches each one to the account that was signed in when it was taken, using Claude's sign-in lines in its log, Relay's own note of which account it switched to, and the times of its login backups.

What that means for the numbers:

- **The signed-in account** is at most about 30 minutes behind.
- **Other accounts** show the last figure from when they were signed in. A limit counts as reset once its window has surely passed: the 5-hour limit five hours after its window started, the weekly limit a week after the reading, or earlier when Relay saw that account's weekly figure reset before (weekly limits reset at the same time each week).
- **Reset times** read "resets by": the limit resets at or before that time.
- An account that has never been signed in while Claude was running has no usage yet.

Relay never asks Anthropic's servers for usage. That would need your login tokens, and Relay never decrypts or sends them.

### Switching

Switching swaps the two things Claude uses for its login: the `Cookies` database and three login keys in `config.json`. Relay copies them into its own folder when it saves an account, and copies them back when it switches. They stay encrypted with Claude's own key, and Relay never decrypts them.

After a switch Relay reads Claude's log. If Claude rejects the saved login, Relay puts the previous account back and marks the rejected one **Log In Again**. **Log In Again** reopens Claude signed out (nothing is logged out). Log in to that account, and Relay saves it by itself.

**Add Another Account** is for an account that has never been used on this Mac.

### Auto-switch

Off by default. Turn it on in **Accounts > Auto-switch** and pick the threshold.

Every minute while Claude runs, Relay checks the signed-in account's usage, using only a reading taken since that account signed in. When its 5-hour or weekly use is at the threshold:

1. It picks the saved account with the lowest weekly use that is under the threshold on both limits. Accounts without usage data are tried last. **Accounts** marks this account **next**.
2. With **Wait until running chats finish** on (the default), it waits until no chat of the signed-in account is mid-turn. It reads the end of each recently changed transcript: an unanswered prompt, a tool result Claude has not replied to, or a tool call still running means the chat is working. A chat left mid-turn for more than 30 minutes, for example on a permission prompt nobody answered, does not hold the switch.
3. It quits Claude, copies the chats you worked on in the last 24 hours into the new account (backed up first), swaps the login, reopens Claude, checks that Claude accepted it, and opens the newest of those chats again.
4. A notification says where it went and why.

After an automatic switch it waits 10 minutes before trying again. If every other saved account is over the threshold too, it stays where it is and tells you, at most every three hours.

What it cannot do: send "continue" for you. Claude gives other apps no way to send a message to a chat, and Relay does not use Accessibility to type into Claude. A chat that hit the limit before the switch stays stopped until you open it and send "continue".

### Sessions and adding a chat to this account

Claude only opens chats of the account it is signed in to. The transcripts themselves live in `~/.claude/projects` and are shared by every account on the Mac, but each account has its own list of sidebar entries, so the same chat can appear in several accounts.

**Sessions** shows each chat once. The **Accounts** column says how many accounts have it (hover to see which), and **Signed-in account** shows a green dot when the signed-in account has it. A chat it does not have gets an **Add to This Account** button, and the **Not in this account** filter lists only those. Adding copies the chat's sidebar entry into the signed-in account, after a preview, with Claude closed and a backup first. Double-clicking such a chat, or opening it from **Search**, shows the same preview and then opens the chat in Claude.

Archive, pin and rename apply to every account's copy of a chat. To change only one account's copy, pick that account in the **Folder** menu first.

### Same chats in every account

Open **Sync chats**, tick the accounts, and choose how:

- **Merge:** every picked account ends up with every chat. When two accounts have the same chat, the newest copy wins, and a chat deleted in one account stays deleted in all of them.
- **Copy from one account to the others:** for example from the account you are signed in to. It only adds and updates chats in the other accounts, never deletes anything there, and never writes to the account it copies from. If an account already has a newer copy of a chat, it keeps its copy.

Claude keeps one chat list per account per organization. An account that used more than one organization has several, and all of them are included. **Preview** shows every change before anything is written. Turn on the merge option in **Accounts** to merge the picked accounts on every switch, Log In and Save, and Add Another Account.

For every chat found in any folder of the picked accounts, merge does this:

- If any picked folder has a `deleted_<id>` marker for it, it is not brought back. Copies in the picked folders are moved into the backup's `removed/` folder, and the marker is added to the folders that lack it.
- Otherwise the copy with the newest file modification time wins and is written to every picked folder where it is missing or different. The copy keeps the winner's modification time, so running sync again finds nothing to do.
- Each picked folder's `archived-sessions.idx` is rebuilt from the winners' `isArchived`, sorted, in the same compact format Claude writes.

### Search

- By default it indexes user and assistant text from the main transcripts (`~/.claude/projects/*/*.jsonl`). `<system-reminder>` blocks, thinking, meta lines and compact summaries are skipped.
- Index options add tool calls and tool output, and subagent and workflow transcripts. These can make the index many times larger and the first build much slower. Changing an option rebuilds the index.
- It is incremental. Transcripts only ever grow, so later runs read only the new lines. A replaced or truncated file is read again from the start. The app updates the index at launch and every 10 minutes.
- Query syntax: every word must match, the last word also matches as a prefix, and `"quoted text"` is a phrase. It uses SQLite FTS5, so it matches whole words and word prefixes, not text in the middle of a word.
- A result opens the chat that uses that transcript, preferring the signed-in account.

## Privacy

- **No network.** Relay makes no network requests and has no analytics or telemetry. Everything stays on your Mac. Opening a chat hands a `claude://` link to the Claude app, which is the only thing that leaves Relay.
- **What it reads:**
  - `~/Library/Application Support/Claude/claude-code-sessions/` (sidebar entries),
  - `~/.claude/projects/` (transcripts, never modified). Besides chat text, the indexer notes which account each transcript belongs to and the email Claude recorded for it, so accounts can be labeled with emails instead of ids. When auto-switch is about to switch, it also reads the end of the signed-in account's recently changed transcripts to tell whether a chat is mid-turn,
  - `~/Library/Application Support/Claude/plan-usage-history.json` (usage percentages per organization, with times),
  - `lastKnownAccountUuid` from `~/Library/Application Support/Claude/config.json`, to show which account is signed in,
  - sign-in and sign-out lines from Claude's log, `~/Library/Logs/Claude/main.log` and its older copies (`main1.log`, ...), to tell whether a switch worked, whether a saved login was ended, and which account each usage record belongs to. Other log lines are skipped and nothing from the log is stored,
  - only when you save or switch accounts: the login keys in that `config.json` (`oauth:tokenCache`, `oauth:tokenCacheV2`) and Claude's `Cookies` database. These are already encrypted by Claude with its own key from the macOS Keychain. Relay copies them as they are. It never decrypts them, never reads the Keychain, and never shows, logs or sends them. From the cookie database it reads only cookie names and expiry dates, to tell you when a saved login expires.
- **What it writes** is listed in the next section. Its own data lives in `~/Library/Application Support/ClaudeHelper/` (search index, backups, saved logins, and `account-history.json`, which holds account ids and times only), readable only by your user. Delete that folder to remove everything it stored. Saved logins only work on the Mac they were saved on.
- **macOS permission prompts:** only one, for notifications, the first time Relay has something to tell you while its window is not in front (or when you turn on auto-switch). If you decline, messages show in Relay's window instead. Reading these folders and quitting Claude with `NSRunningApplication.terminate()` did not trigger a Files and Folders, Full Disk Access or Automation prompt in testing on macOS 26. Relay does not use AppleScript or Accessibility.

## What each action writes

Paths below are inside `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/` unless stated.

| Action | Files written | Notes |
| --- | --- | --- |
| Browse, search, usage, open in Claude | none | Read-only, fine while Claude runs. |
| Restore from archive | the chat's `local_<id>.json` (`isArchived` false) and `archived-sessions.idx` (id removed) | |
| Archive | `local_<id>.json` (`isArchived` true, and `isStarred` false if it was pinned) and `archived-sessions.idx` (id added) | Claude does not allow pinned chats to be archived. |
| Pin / unpin | `local_<id>.json` (`isStarred`) | Best effort, see known gaps. |
| Rename | `local_<id>.json` (`title`, and `titleSource` set to `user` so Claude keeps the name) | Bulk rename does find and replace plus an optional prefix. |
| Add to this account | the chat's `local_<id>.json` added to (or updated in) the signed-in account's chat lists, and their `archived-sessions.idx` | Nothing else is copied. If that account had deleted the chat, its `deleted_<id>` marker is moved to the backup so the chat shows. |
| Sync chats: merge | `local_*.json` copied between the picked accounts' folders, `deleted_<id>` markers copied, `archived-sessions.idx` rebuilt | See merge in detail above. |
| Sync chats: copy from one account | `local_*.json` added or updated in the other accounts' folders and their `archived-sessions.idx` | The source account is never written. Nothing is deleted. |
| Restore backup | the backed-up `local_*.json`, `archived-sessions.idx` and `deleted_*` | Files in the folder now that are not in the backup are moved into a new safety backup, not deleted. |
| Back Up Now | none | Only writes a backup. |
| Save this login | none | Copies `Cookies` and the login keys of `config.json` into `ClaudeHelper/profiles/<name>/`. Works while Claude runs. |
| Switch account | `~/Library/Application Support/Claude/Cookies` (replaced, `Cookies-journal` removed) and the three login keys in `config.json` (every other key stays as it was) | The current login is saved to its profile and both files are backed up to `ClaudeHelper/backups/<date>-switch-login/` first. |
| Auto-switch | same as Switch account, plus adding the chats from the last 24 hours to the new account | Off unless you turn it on. |
| Add another account | moves `Cookies` out and removes the three login keys from `config.json` | Saves the current login first and keeps the moved files in `ClaudeHelper/backups/<date>-add-account/`. Claude reopens signed out. |
| Every minute | `ClaudeHelper/account-history.json` when the signed-in account changed | Account ids and times only. |

Editing a chat changes only the top-level keys listed above. The rest of the file stays byte for byte the same (key order, numbers, escaping), and each patched file is re-parsed and compared before it is written.

## Safety rules for every write

1. **Claude must be closed.** The apply button asks Claude to quit (`NSRunningApplication.terminate()`, never a force-kill), waits up to 45 seconds, re-reads the files, checks the plan still matches the preview, backs up, writes and reopens Claude. If Claude does not quit in time, nothing is written. If Claude changed files while quitting so the plan is different, it stops, leaves Claude closed and shows the new plan. Quitting Claude also stops any Code chat that is running.
2. **Backup first.** `ClaudeHelper/backups/<date>-<action>/snapshot.tar.gz` holds every `local_*.json`, `archived-sessions.idx` and `deleted_*` of each folder that will change, plus `manifest.json` with the planned changes and `removed/` for files moved out. The archive is listed back and checked before any write.
3. **Schema guard.** Nothing is written if a chat file involved is not a JSON object, is missing `sessionId` or `cliSessionId`, or its `sessionId` does not match the file name, or if an `archived-sessions.idx` is not exactly `{"v":1,"archived":[...]}`. The preview shows the file and what looked wrong.
4. **Allowlist.** The writer refuses any path other than `claude-code-sessions/<account>/<org>/` plus `local_*.json`, `archived-sessions.idx` or `deleted_*`. It never touches `~/.claude/projects`, `backlog/`, `waiting-input/` or `scheduled-tasks.json`, and those are not in backups either, so restoring a backup cannot touch them.
5. **Atomic writes.** Files are written to a temporary file in the same folder and renamed into place, mode 600.

## Build from source

Needs the Xcode Command Line Tools (Swift 5.10 or newer). Full Xcode is not required.

```bash
git clone https://github.com/ShiNxz/ClaudeHelper.git
cd ClaudeHelper
./bundle.sh                       # build/Relay.app for this Mac
./bundle.sh --universal --dmg     # arm64 + x86_64 app and a DMG
./bundle.sh --install             # copy the app to /Applications (quits and reopens a running copy)
```

The app is ad-hoc signed (`codesign -s -`). Set `SIGN_IDENTITY` to a Developer ID identity to sign it properly with the hardened runtime. The app is not sandboxed, because the sandbox would block it from reading Claude's folders.

The same binary has a terminal mode. In the app it is `Relay.app/Contents/MacOS/Relay`:

```bash
Relay --cli                       # list commands
Relay --cli selftest              # run the built-in tests against temporary fixtures
Relay --cli scan                  # account folders, counts, schema problems
Relay --cli usage                 # each account's 5-hour and weekly use, and chats mid-turn now
Relay --cli search "word"         # search from the terminal
Relay --cli pull <account/org> <local_id>             # dry run of adding a chat to the signed-in account
Relay --cli sync <account/org> <account/org>          # dry run of an account sync
Relay --cli backup                # back up all account folders now
```

`CLAUDE_HELPER_SESSIONS_ROOT`, `CLAUDE_HELPER_PROJECTS_ROOT`, `CLAUDE_HELPER_CLAUDE_DIR` and `CLAUDE_HELPER_DATA_DIR` point it at a copy of the data instead of the real folders.

## Releases

Pushing a tag such as `v0.3.0` runs `.github/workflows/release.yml` on a macOS runner. It builds a universal app, runs the self-test, makes a DMG with `hdiutil`, and attaches the DMG and a SHA-256 checksum to a GitHub Release. Pushes to `main` and pull requests run `.github/workflows/ci.yml` (build and self-test).

Builds are ad-hoc signed. To ship Developer ID signed and notarized builds instead, add these repository secrets. The signing and notarization steps run only when they exist, so nothing else needs to change:

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Developer ID Application certificate and private key, exported as `.p12`, base64 encoded |
| `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| `MACOS_SIGNING_IDENTITY` | For example `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character team id |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |

With those set, the DMG is notarized with `notarytool` and stapled, and the Open Anyway step above is no longer needed.

## Known gaps

- **Usage is Claude's own record.** It is about 30 minutes behind for the signed-in account and the last known figure for the others. Reset times are estimates (an upper bound), and an account's weekly reset is only known once Relay has seen it happen.
- **Auto-switch cannot continue a stopped chat.** A chat that hit its limit before the switch stays stopped until you send "continue" in it.
- **Pins.** Claude also keeps pins in its web storage (`starred-local-code-sessions` in Local Storage), which can disagree with `isStarred`. Relay sets `isStarred` only and does not edit Local Storage, so the sidebar may not follow.
- **Account switching** swaps the files Claude uses for its login today. A Claude update can move them. The app's cached web data (Local Storage, IndexedDB) is not swapped, so the window can show the previous account's cached state for a moment after switching.
- **Sidebar groups** and sections are not handled.
- **Large connector config.** A chat file with a very large `remoteMcpServersConfig` (over 100 KB) once failed to show in the sidebar after being copied to another account. The previews warn about these.
- **Applying stops running chats.** Applying a change or switching quits Claude, which stops every running Code chat until Claude reopens. Auto-switch waits for them by default; manual actions do not.
- **Old transcripts.** Claude Code deletes transcripts after its cleanup period, so search only covers what is still on disk.
- **Emails** are only known for accounts that have at least one Code transcript on this Mac from a recent Claude version. Others show their account id until you give them a nickname.
- **Icon.** The icon and menu bar icon are original artwork in warm colors. They are not Anthropic's logo.
- **Format changes.** If Claude changes its file formats, the schema guard should block writes. Reading may show odd values until Relay is updated.

## Testing

`Relay --cli selftest` builds made-up account folders, transcripts, logs and usage records in a temporary folder and checks the JSON patcher, the schema guard, the path allowlist, restore, sync (including deleted chats), adding a chat to an account, switching (including bringing chats along and rolling back a rejected login), usage matching and aging, the auto-switch pick, the mid-turn check, backup restore and the search index. CI runs it on every push. It never touches the real Claude folders.

## License

MIT, see [LICENSE](LICENSE).
