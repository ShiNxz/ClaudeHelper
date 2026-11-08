# Relay for Windows: UI to Rust contract

The UI in `ui/` is plain HTML and JavaScript (no build step). It talks to the Rust side through
`window.__TAURI__.core.invoke(name, args)` and listens with `window.__TAURI__.event.listen(name, cb)`.
Argument keys are camelCase in JavaScript; Tauri maps them to the snake_case Rust parameters.
Times are milliseconds since 1970 (numbers). Errors reject the promise with a string message.

`ui/mock.js` provides a fake `window.__TAURI__` with made-up data when the page is opened in a normal
browser, so the UI can be previewed and screenshotted without Windows.

## State

### `get_state()` -> `AppState`

```json
{
  "appVersion": "0.4.0",
  "platform": "windows",
  "claudeRunning": true,
  "activeAccountId": "uuid or null",
  "switching": false,
  "steps": ["Quitting Claude", "Saving the current login"],
  "accounts": [AccountEntry],
  "autoSwitch": {
    "enabled": false, "threshold": 95, "waitForIdle": true, "forceQuit": true,
    "status": "string or null", "nextAccountId": "uuid or null"
  },
  "switchSync": false,
  "sync": { "accounts": ["uuid"], "source": "uuid or null" },
  "index": { "running": false, "fraction": 0.0, "status": "2,345 chats, 120,000 messages indexed",
             "includeTools": false, "includeSubagents": false },
  "paths": { "data": "C:\\Users\\me\\AppData\\Roaming\\Relay", "backups": "...", "claude": "..." }
}
```

`AccountEntry`:

```json
{
  "id": "account uuid",
  "title": "work@example.com",
  "email": "work@example.com or null",
  "nickname": "Work or null",
  "isActive": true,
  "profile": { "id": "work", "name": "Work", "savedAt": 0, "sessionExpires": 0, "problem": null, "needsLogin": false },
  "status": { "text": "Saved 8 Nov 15:14, valid until 6 Dec", "warning": false },
  "usage": { "fiveHour": 42, "fiveHourResetsAt": 0, "week": 81, "weekResetsAt": 0, "sampledAt": 0, "current": true },
  "chatCount": 335,
  "folderIds": ["account/org"]
}
```

`profile` is null for an account that is not saved yet. `usage` is null when nothing is known.
`fiveHourResetsAt` and `weekResetsAt` are "resets by" upper bounds, or null.

## Chats

### `list_sessions()`

```json
{
  "activeAccountId": "uuid or null",
  "folders": [{ "id": "account/org", "accountId": "...", "orgId": "...", "label": "work@example.com (signed in)",
                "isBackupCopy": false, "count": 335 }],
  "sessions": [{
    "key": "account/org|local_x", "folderId": "account/org", "accountId": "...", "sessionId": "local_x",
    "cliSessionId": "uuid or null", "title": "Fix the login page", "titleSource": "user or null", "cwd": "C:\\code\\app",
    "isArchived": false, "isStarred": false, "inArchivedIndex": false, "lastActivity": 0, "createdAt": 0,
    "fileMTime": 0, "fileSize": 1234, "file": "C:\\...\\local_x.json", "model": "string or null",
    "problems": [], "resumeCommand": "cd ... && claude --resume ..."
  }]
}
```

The UI groups sessions by `sessionId` (one row per chat). A chat is "in this account" when a live
(non backup copy) folder of `activeAccountId` has it.

### Plans (preview, then apply)

- `preview_edits({ edits: [{ folderId, sessionId, title?, isArchived?, isStarred? }] })` -> `Plan`
- `preview_pull({ items: [{ folderId, sessionId }], openAfter?: sessionId, note?: string })` -> `Plan`
  (adds chats to the signed-in account)
- `preview_sync()` -> `Plan` (uses the saved sync settings)
- `preview_restore({ backupId })` -> `Plan`
- `discard_plan({ planId })`
- `apply_plan({ planId })` -> `{ "status": "applied", "written": 3, "moved": 0, "backupDir": "...", "reopened": true, "warnings": [] }`
  or `{ "status": "planChanged", "plan": Plan }`. Progress arrives as `relay://steps` events.

`Plan`:

```json
{
  "id": "plan id", "title": "Add 1 chat to the signed-in account", "summary": "2 change(s) in 1 folder(s)",
  "changes": [{ "folderId": "...", "folderLabel": "...", "kind": "add", "summary": "\"Fix the login page\": add from 1234/5678", "detail": "active, last change ..." }],
  "problems": [{ "path": "...", "message": "missing cliSessionId" }],
  "warnings": ["..."], "canApply": true, "note": "string or null", "openAfter": "sessionId or null"
}
```

`kind` is one of `edit`, `add`, `update`, `removeDeleted`, `addMarker`, `archivedIndex`, `putBack`, `moveOut`.

### Opening

- `open_chat({ sessionId })` opens `claude://claude.ai/epitaxy/<sessionId>` in Claude.
- `reveal({ path })` shows a file in Explorer.

## Accounts

- `switch_account({ accountId })` -> `{ "switched": true, "notes": [], "warnings": [] }` (the UI confirms first)
- `log_in_and_save({ accountId })` -> `{ "notes": [], "warnings": [] }`
- `add_account()` -> `{ "notes": [], "warnings": [] }`
- `save_login({ name, quitClaude? })` -> `AccountEntry`. Fails with an error starting with `LOCKED:` when
  Claude keeps its login files locked; the UI then asks and calls again with `quitClaude: true`.
- `rename_profile({ profileId, name })`, `forget_profile({ profileId })`
- `set_settings({ ...any of: autoSwitchEnabled, autoSwitchThreshold, autoSwitchWaitForIdle, forceQuit, switchSync,
  syncAccounts, syncSource (empty string for merge), includeTools, includeSubagents })` -> `AppState`

## Search

- `search({ query, role: "any|user|assistant|tool", order: "relevance|newest" })` ->

```json
{ "elapsedMs": 12, "groups": [{
  "file": { "id": 1, "cliSessionId": "uuid", "title": "string or null", "firstPrompt": "string or null", "cwd": "...",
            "lastTimestamp": "ISO string or null", "messages": 40, "isSubagent": false },
  "hits": [{ "id": 9, "role": "user", "timestamp": "ISO string or null", "snippet": "text with \u0002match\u0003" }],
  "session": { "folderId": "...", "sessionId": "local_x", "title": "...", "inSignedIn": true } }] }
```

`session` is null for a transcript with no sidebar entry in any account.

- `index_now()`, `cancel_index()`

## Backups

- `list_backups()` -> `[{ "id": "...", "created": 0, "title": "...", "reason": "sync", "folders": ["1234/5678"],
  "files": 12, "changes": ["..."], "removed": 0, "applied": true, "dir": "..." }]`
- `backup_now()` -> `{ "dir": "...", "files": 12 }`

## Events from Rust

- `relay://state` payload `{ "sessions": true|false }`: state changed; call `get_state()` (and `list_sessions()` when `sessions` is true).
- `relay://steps` payload `["Quitting Claude", ...]`: progress of the running switch or apply.
- `relay://toast` payload `{ "title": "string or null", "text": "...", "warning": false }`: show a short in-window message.
- `relay://navigate` payload `"accounts"`: show that screen (from the tray menu).
