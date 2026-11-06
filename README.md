# Claude Helper

A macOS menubar app for the Code tab of the Claude desktop app. It lists every Code session across all the accounts you have used on this Mac, searches your old chats, restores archived chats, keeps account folders in sync, and does bulk rename, pin and archive.

> **Unofficial.** Claude Helper is a community tool. It is not made, endorsed or supported by Anthropic, and it is not affiliated with Anthropic in any way. "Claude" is a trademark of Anthropic.

It works with Claude's undocumented local files. A Claude update can change them at any time, which is why every write goes through a schema check and a full backup first.

## Features

- **Sessions browser.** One table of every Code session in every account folder: title, project, account folder, archived, pinned, last activity. Filter, sort, double-click to open the chat in Claude. Read-only, works while Claude is running.
- **Search old chats.** Full-text search over your transcripts in `~/.claude/projects`, with a local SQLite index that updates incrementally in the background. A result opens the chat in Claude, or, for chats with no sidebar entry, copies the `claude --resume` command.
- **Restore archived chats** back into the sidebar.
- **Account sync.** Pick the account folders that should hold the same chats. The newest copy of each chat wins and goes to every picked folder, deleted chats stay deleted, and each folder's archived list is rebuilt. You see every change before anything is written.
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
  - `~/.claude/projects/` (transcripts, never modified),
  - one key, `lastKnownAccountUuid`, from `~/Library/Application Support/Claude/config.json`, to show which account is signed in. Nothing else in that file is read.
- **What it writes** is listed in the next section. Its own data lives in `~/Library/Application Support/ClaudeHelper/` (search index and backups). Delete that folder to remove everything it stored.
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
| Account sync | `local_*.json` copied between the picked folders, `deleted_<id>` markers copied, `archived-sessions.idx` rebuilt | See below. |
| Restore backup | the backed-up `local_*.json`, `archived-sessions.idx` and `deleted_*` | Files in the folder now that are not in the backup are moved into a new safety backup, not deleted. |
| Back Up Now | none | Only writes a backup. |

Editing a chat changes only the top-level keys listed above. The rest of the file stays byte for byte the same (key order, numbers, escaping), and each patched file is re-parsed and compared before it is written.

### Account sync in detail

For every chat found in any picked folder:

- If any picked folder has a `deleted_<id>` marker for it, it is not brought back. Copies in the picked folders are moved into the backup's `removed/` folder, and the marker is added to the folders that lack it.
- Otherwise the copy with the newest file modification time wins and is written to every picked folder where it is missing or different. The copy keeps the winner's modification time, so running sync again finds nothing to do.
- Each picked folder's `archived-sessions.idx` is rebuilt from the winners' `isArchived`, sorted, in the same compact format Claude writes.

## Safety rules for every write

1. **Claude must be closed.** The apply button asks Claude to quit (`NSRunningApplication.terminate()`, never a force-kill), waits up to 45 seconds, re-reads the files, checks the plan still matches the preview, backs up, writes and reopens Claude. If Claude does not quit in time, nothing is written. If Claude changed files while quitting so the plan is different, it stops, leaves Claude closed and shows the new plan. Quitting Claude also stops any Code session that is running.
2. **Backup first.** `ClaudeHelper/backups/<date>-<action>/snapshot.tar.gz` holds every `local_*.json`, `archived-sessions.idx` and `deleted_*` of each folder that will change, plus `manifest.json` with the planned changes and `removed/` for files moved out. The archive is listed back and checked before any write.
3. **Schema guard.** Nothing is written if a chat file involved is not a JSON object, is missing `sessionId` or `cliSessionId`, or its `sessionId` does not match the file name, or if an `archived-sessions.idx` is not exactly `{"v":1,"archived":[...]}`. The preview shows the file and what looked wrong.
4. **Allowlist.** The writer refuses any path other than `claude-code-sessions/<account>/<org>/` plus `local_*.json`, `archived-sessions.idx` or `deleted_*`. It never touches `~/.claude/projects`, `backlog/`, `waiting-input/` or `scheduled-tasks.json`, and those are not in backups either, so restoring a backup cannot touch them.
5. **Atomic writes.** Files are written to a temporary file in the same folder and renamed into place, mode 600.

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

- **Pins.** Claude keeps a second pin record somewhere outside the chat file, and it can disagree with `isStarred`. Pin and unpin set `isStarred` only, so the sidebar may not follow.
- **Sidebar groups** and sections are not handled.
- **Other accounts.** A chat that exists only in an account folder you are not signed in to may not open from the link. The helper warns, and account sync can copy it over.
- **Large connector config.** A chat file with a very large `remoteMcpServersConfig` (over 100 KB) once failed to show in the sidebar after being copied to another account. The sync preview warns about these.
- **Applying stops running sessions.** Applying a change quits Claude, which stops every running Code session until Claude reopens.
- **Old transcripts.** Claude Code deletes transcripts after its cleanup period, so search only covers what is still on disk.
- **Process name.** Claude's own background processes are also called "Claude Helper" in Activity Monitor. This app's process is `ClaudeHelper` (no space), bundle id `io.github.shinxz.ClaudeHelper`.
- **Format changes.** If Claude changes its file formats, the schema guard should block writes. Reading may show odd values until the helper is updated.

## Testing

`ClaudeHelper --cli selftest` builds made-up account folders and transcripts in a temporary folder and checks the JSON patcher, the schema guard, the path allowlist, restore, sync (including deleted chats), backup restore and the search index. CI runs it on every push. It never touches the real Claude folders.

## License

MIT, see [LICENSE](LICENSE).
