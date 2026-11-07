# Claude Helper

A macOS menubar app for the Code tab of the Claude desktop app. It switches the Claude app between accounts you have logged in to before, lists every Code session across all those accounts, searches your old chats, restores archived chats, keeps account folders in sync, and does bulk rename, pin and archive.

> **Unofficial.** Claude Helper is a community tool. It is not made, endorsed or supported by Anthropic, and it is not affiliated with Anthropic in any way. "Claude" is a trademark of Anthropic.

It works with Claude's undocumented local files. A Claude update can change them at any time, which is why every write goes through a schema check and a full backup first.

## Features

- **Switch accounts without logging in again.** Save the login of each account once, then switch Claude between them from the menu bar. The helper quits Claude, saves the current login (so refreshed tokens are kept), optionally syncs chats between the accounts, puts the chosen login in place and reopens Claude.
- **Accounts by email.** Account folders are labeled with the email of each account, learned from your own transcripts, so you can tell the ids apart.
- **Sessions browser.** One table of every Code session in every account folder: title, project, account folder, archived, pinned, last activity. Filter, sort, double-click to open the chat in Claude. Read-only, works while Claude is running.
- **Search old chats.** Full-text search over your transcripts in `~/.claude/projects`, with a local SQLite index that updates incrementally in the background. A result opens the chat in Claude, or, for chats with no sidebar entry, copies the `claude --resume` command.
- **Restore archived chats** back into the sidebar.
- **Sync chats between accounts.** Tick accounts and either merge them (every account gets every chat) or copy one account's chats into the others. You see every change before anything is written.
- **Bulk rename, pin and archive** from the browser.
- **Backups.** Every write is backed up first, and any backup can be put back.

## Install

Requirements: macOS 14 Sonoma or newer, Apple Silicon or Intel, and the Claude desktop app.

1. Download `Claude-Helper-<version>.dmg` from [Releases](https://github.com/ShiNxz/ClaudeHelper/releases).
2. Open the DMG and drag **Claude Helper** to **Applications**.
3. Open it. Release builds are not notarized by Apple yet, so the first time macOS says it cannot verify the app. Click **Done** (not Move to Trash), then:
   - open **System Settings > Privacy & Security**,
   - scroll to the message about Claude Helper being blocked and click **Open Anyway**,
   - confirm with your password.

   macOS remembers this, so you only do it once per version. If you prefer the terminal, this does the same:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Claude Helper.app"
   ```

The app lives in the menu bar. Its window shows a Dock icon only while it is open.

## Build from source

Needs the Xcode Command Line Tools (Swift 5.10 or newer). Full Xcode is not required.

```bash
git clone https://github.com/ShiNxz/ClaudeHelper.git
cd ClaudeHelper
./bundle.sh                       # build/Claude Helper.app for this Mac
./bundle.sh --universal --dmg     # arm64 + x86_64 app and a DMG
./bundle.sh --install             # copy the app to /Applications
```

The app is ad-hoc signed (`codesign -s -`). Set `SIGN_IDENTITY` to a Developer ID identity to sign it properly with the hardened runtime. The app is not sandboxed, because the sandbox would block it from reading Claude's folders.

The same binary has a terminal mode:

```bash
ClaudeHelper --cli                # list commands
ClaudeHelper --cli selftest       # run the built-in tests against temporary fixtures
ClaudeHelper --cli scan           # account folders, counts, schema problems
ClaudeHelper --cli search "word"  # search from the terminal
ClaudeHelper --cli sync <account/org> <account/org>   # dry run of an account sync
ClaudeHelper --cli backup         # back up all account folders now
```

`CLAUDE_HELPER_SESSIONS_ROOT`, `CLAUDE_HELPER_PROJECTS_ROOT` and `CLAUDE_HELPER_DATA_DIR` point it at a copy of the data instead of the real folders.

## Privacy

- **No network.** Claude Helper makes no network requests and has no analytics or telemetry. Everything stays on your Mac. Opening a chat hands a `claude://` link to the Claude app, which is the only thing that leaves the helper.
- **What it reads:**
  - `~/Library/Application Support/Claude/claude-code-sessions/` (sidebar entries),
  - `~/.claude/projects/` (transcripts, never modified). Besides chat text, the indexer notes which account each transcript belongs to and the email Claude recorded for it, so account folders can be labeled with emails instead of ids,
  - `lastKnownAccountUuid` from `~/Library/Application Support/Claude/config.json`, to show which account is signed in,
  - sign-in and sign-out lines from Claude's log, `~/Library/Logs/Claude/main.log`, to tell whether a switch worked and whether a saved login was ended. Other log lines are skipped and nothing from the log is stored,
  - only when you save or switch accounts: the login keys in that `config.json` (`oauth:tokenCache`, `oauth:tokenCacheV2`) and Claude's `Cookies` database. These are already encrypted by Claude with its own key from the macOS Keychain. The helper copies them as they are. It never decrypts them, never reads the Keychain, and never shows, logs or sends them. From the cookie database it reads only cookie names and expiry dates, to tell you when a saved login expires.
- **What it writes** is listed in the next section. Its own data lives in `~/Library/Application Support/ClaudeHelper/` (search index, backups, saved logins), readable only by your user. Delete that folder to remove everything it stored. Saved logins only work on the Mac they were saved on.
- **macOS permission prompts:** none. Reading these folders and quitting Claude with `NSRunningApplication.terminate()` did not trigger a Files and Folders, Full Disk Access or Automation ("wants to control") prompt. This was tested on macOS 26 with the app launched normally under a bundle id the system had never seen. The helper does not use AppleScript.

## What each action writes

All paths below are inside `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`.

| Action | Files written | Notes |
| --- | --- | --- |
| Browse, search, open in Claude | none | Read-only, fine while Claude runs. |
| Restore from archive | the chat's `local_<id>.json` (`isArchived` false) and `archived-sessions.idx` (id removed) | |
| Archive | `local_<id>.json` (`isArchived` true, and `isStarred` false if it was pinned) and `archived-sessions.idx` (id added) | Claude does not allow pinned chats to be archived. |
| Pin / unpin | `local_<id>.json` (`isStarred`) | Best effort, see known gaps. |
| Rename | `local_<id>.json` (`title`, and `titleSource` set to `user` so Claude keeps the name) | Bulk rename does find and replace plus an optional prefix. |
| Sync chats: merge | `local_*.json` copied between the picked accounts' folders, `deleted_<id>` markers copied, `archived-sessions.idx` rebuilt | See below. |
| Sync chats: copy from one account | `local_*.json` added or updated in the other accounts' folders and their `archived-sessions.idx` | The source account is never written. Nothing is deleted. |
| Restore backup | the backed-up `local_*.json`, `archived-sessions.idx` and `deleted_*` | Files in the folder now that are not in the backup are moved into a new safety backup, not deleted. |
| Back Up Now | none | Only writes a backup. |
| Save this login | none | Copies `Cookies` and the login keys of `config.json` into `ClaudeHelper/profiles/<name>/`. Works while Claude runs. |
| Switch account | `~/Library/Application Support/Claude/Cookies` (replaced, `Cookies-journal` removed) and the three login keys in `config.json` (every other key stays as it was) | The current login is saved to its profile and both files are backed up to `ClaudeHelper/backups/<date>-switch-login/` first. |
| Add another account | moves `Cookies` out and removes the three login keys from `config.json` | Saves the current login first and keeps the moved files in `ClaudeHelper/backups/<date>-add-account/`. Claude reopens signed out. |

Editing a chat changes only the top-level keys listed above. The rest of the file stays byte for byte the same (key order, numbers, escaping), and each patched file is re-parsed and compared before it is written.

### Merge in detail

For every chat found in any folder of the picked accounts:

- If any picked folder has a `deleted_<id>` marker for it, it is not brought back. Copies in the picked folders are moved into the backup's `removed/` folder, and the marker is added to the folders that lack it.
- Otherwise the copy with the newest file modification time wins and is written to every picked folder where it is missing or different. The copy keeps the winner's modification time, so running sync again finds nothing to do.
- Each picked folder's `archived-sessions.idx` is rebuilt from the winners' `isArchived`, sorted, in the same compact format Claude writes.

## Safety rules for every write

1. **Claude must be closed.** The apply button asks Claude to quit (`NSRunningApplication.terminate()`, never a force-kill), waits up to 45 seconds, re-reads the files, checks the plan still matches the preview, backs up, writes and reopens Claude. If Claude does not quit in time, nothing is written. If Claude changed files while quitting so the plan is different, it stops, leaves Claude closed and shows the new plan. Quitting Claude also stops any Code session that is running.
2. **Backup first.** `ClaudeHelper/backups/<date>-<action>/snapshot.tar.gz` holds every `local_*.json`, `archived-sessions.idx` and `deleted_*` of each folder that will change, plus `manifest.json` with the planned changes and `removed/` for files moved out. The archive is listed back and checked before any write.
3. **Schema guard.** Nothing is written if a chat file involved is not a JSON object, is missing `sessionId` or `cliSessionId`, or its `sessionId` does not match the file name, or if an `archived-sessions.idx` is not exactly `{"v":1,"archived":[...]}`. The preview shows the file and what looked wrong.
4. **Allowlist.** The writer refuses any path other than `claude-code-sessions/<account>/<org>/` plus `local_*.json`, `archived-sessions.idx` or `deleted_*`. It never touches `~/.claude/projects`, `backlog/`, `waiting-input/` or `scheduled-tasks.json`, and those are not in backups either, so restoring a backup cannot touch them.
5. **Atomic writes.** Files are written to a temporary file in the same folder and renamed into place, mode 600.

## Switching accounts

**Accounts** lists every account used on this Mac, by email, and the menu bar icon shows the same list.

1. The account Claude is signed in to has a **Save** button. Click it once.
2. Every other account has **Log In and Save**. Claude reopens signed out (nothing is logged out). Log in to that account there, and the helper saves it by itself within a minute.
3. From then on, pick any saved account from the menu bar or click **Switch**. Claude quits, switches and reopens.

**Add Another Account** is for an account that has never been used on this Mac.

Two things end a saved login, because Claude ends that session on the server:

- **Log out** inside Claude.
- **Signing in to the same account again by hand.** Claude revokes the older sign-in about a minute later.

So switch only with the helper. To keep saved logins valid, the helper re-saves the signed-in account every few minutes and again right before each switch. It never saves while Claude is signed out.

After a switch the helper reads Claude's log. If Claude rejects the saved login, the helper puts the previous account back and marks the rejected one **Log in again**. **Log In Again** reopens Claude signed out (nothing is logged out), you log in to that account, and the helper saves it by itself.

### Same chats in every account

Open **Sync chats**, tick the accounts, and choose how:

- **Merge:** every picked account ends up with every chat. When two accounts have the same chat, the newest copy wins, and a chat deleted in one account stays deleted in all of them.
- **Copy from one account to the others:** for example from the account you are signed in to. It only adds and updates chats in the other accounts, never deletes anything there, and never writes to the account it copies from. If an account already has a newer copy of a chat, it keeps its copy.

Claude keeps one chat list per account per organization. An account that used more than one organization has several, and all of them are included, so you never have to pick folders. **Preview** shows every change before anything is written. Turn on the merge option in **Accounts** to merge the picked accounts on every switch.

## Search index

- By default it indexes user and assistant text from the main transcripts (`~/.claude/projects/*/*.jsonl`). `<system-reminder>` blocks, thinking, meta lines and compact summaries are skipped.
- Index options add tool calls and tool output, and subagent and workflow transcripts (`<session>/subagents/**`). These can make the index many times larger and the first build much slower. Changing an option rebuilds the index.
- It is incremental. Each transcript's inode, size, modification time and byte offset are stored, and since transcripts only ever grow, later runs read only the new complete lines. A replaced or truncated file is read again from the start. The app updates the index at launch and every 10 minutes.
- Query syntax: every word must match, the last word also matches as a prefix, and `"quoted text"` is a phrase. It uses SQLite FTS5 with the `unicode61` tokenizer, so it matches whole words and word prefixes, not text in the middle of a word.
- A result opens the chat that uses that transcript (its `cliSessionId` or an earlier one), preferring the account that is signed in.

## Releases

Pushing a tag such as `v0.2.0` runs `.github/workflows/release.yml` on a macOS runner. It builds a universal app, runs the self-test, makes a DMG with `hdiutil`, and attaches the DMG and a SHA-256 checksum to a GitHub Release. Pushes to `main` and pull requests run `.github/workflows/ci.yml` (build and self-test).

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

- **Pins.** Claude also keeps pins in its web storage (`starred-local-code-sessions` in Local Storage), which can disagree with `isStarred`. The helper sets `isStarred` only and does not edit Local Storage, so the sidebar may not follow.
- **Account switching** swaps the files Claude uses for its login today. A Claude update can move them. The app's cached web data (Local Storage, IndexedDB) is not swapped, so the window can show the previous account's cached state for a moment after switching.
- **Sidebar groups** and sections are not handled.
- **Other accounts.** A chat that exists only in an account folder you are not signed in to may not open from the link. The helper warns, and account sync can copy it over.
- **Large connector config.** A chat file with a very large `remoteMcpServersConfig` (over 100 KB) once failed to show in the sidebar after being copied to another account. The sync preview warns about these.
- **Applying stops running sessions.** Applying a change quits Claude, which stops every running Code session until Claude reopens.
- **Old transcripts.** Claude Code deletes transcripts after its cleanup period, so search only covers what is still on disk.
- **Emails** are only known for accounts that have at least one Code transcript on this Mac from a recent Claude version. Others show their account id until you give them a nickname.
- **Icon.** The icon and menu bar icon are original artwork in warm colors. They are not Anthropic's logo.
- **Process name.** Claude's own background processes are also called "Claude Helper" in Activity Monitor. This app's process is `ClaudeHelper` (no space), bundle id `io.github.shinxz.ClaudeHelper`.
- **Format changes.** If Claude changes its file formats, the schema guard should block writes. Reading may show odd values until the helper is updated.

## Testing

`ClaudeHelper --cli selftest` builds made-up account folders and transcripts in a temporary folder and checks the JSON patcher, the schema guard, the path allowlist, restore, sync (including deleted chats), backup restore and the search index. CI runs it on every push. It never touches the real Claude folders.

## License

MIT, see [LICENSE](LICENSE).
