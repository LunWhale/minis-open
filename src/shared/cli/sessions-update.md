# minis-sessions-cli: `update`, `groups`, and group/icon in `list` / `status`

Task FEAT-261018-08. **iOS is the reference implementation**; Android follows this
file. If an implementation and this file disagree, fix the implementation or raise
the difference — do not let them drift.

The cross-platform test list is in [`sessions-update-cases.md`](sessions-update-cases.md).

## 1. Commands

```
minis-sessions-cli update --id <session_id> [--title <text> | --title-auto] [--group <name>] [--icon <icon>]
minis-sessions-cli groups
minis-sessions-cli list   [existing options] [--group <name>]
minis-sessions-cli status --id <session_id>
```

`--compact` (single-line JSON) and `-q` / `--quiet` work as for every other
subcommand. `-q` prints only `data` on success, or only `error` on failure.

## 2. `update`

### 2.1 Arguments

| Option | Meaning |
|---|---|
| `--id <id>` | Required, except inside a chat: then it defaults to that chat (§5). |
| `--title <text>` | New title. Trimmed. Empty or blank after trimming → `invalid_arguments`. |
| `--title-auto` | Regenerate the title with the app's own **Regenerate Title** action (iOS: the session menu's "Regenerate Title"; Android: the same action in the chat). Cannot be combined with `--title`. See 2.4. |
| `--group <name>` | Trimmed. `""` or blank → move out of any group (ungrouped). Otherwise the group whose name equals `<name>` **exactly and case-sensitively**; when none exists, a group with that name is **created** (as the "Move to Group → New Group" picker does), and the session is moved into it. |
| `--icon <icon>` | One of the 16 icon keys in section 4. Matched after trimming and **case-insensitively** (`Code` = `code`). `""` or blank → default icon. Anything else → `invalid_icon`. |

- At least one of `--title`, `--title-auto`, `--group` or `--icon` is required.
  Fields not given are left unchanged.
- **Missing value.** These are `invalid_arguments`:
  - a value option (`--id`, `--title`, `--group`, `--icon`) that is the last token;
  - a value option followed directly by another option of the command, e.g. `--title --group X`.

  An explicit empty string (`--group ""`) **is** a value.
- **Duplicate group names.** Group names are not unique in the app. When several
  groups match, use the one whose member session was active most recently. If no
  match has members, take the oldest group. A group with members always beats an
  empty one. This is the app's own `findFolderByName` tie-break, without its case
  folding.

### 2.2 Errors and their order

Argument errors are reported **before** the session is looked up, in this order.
The first one that applies wins:

1. Missing value for a value option, or missing `--id` → `invalid_arguments`.
2. No field given → `invalid_arguments`.
3. `--title` together with `--title-auto` → `invalid_arguments`.
4. Empty or blank `--title` → `invalid_arguments`.
5. Unknown `--icon` → `invalid_icon`. The message lists all 16 valid keys.

After that, the session checks:

6. The session is unknown → `session_not_found`. This includes a deleted
   session: deletion removes the session's rows at once, in the app's store.
   Do **not** consult a recent-delete tombstone. On iOS it outlives a legitimate
   re-insert by a newer edit from another device, and would then refuse a live
   session.
7. The session is a hidden child session (a sub agent's run, `parent_session_id`
   set) → `not_allowed`.
8. `--title-auto` produced no title → `title_auto_failed`. Causes:
   - no usable model;
   - the provider failed;
   - 60 s timeout;
   - the session has no user message and reply yet.

   Nothing else in the request is applied.

Sessions synced from another device are editable, as in the app.

| Code | Exit status |
|---|---|
| `invalid_arguments`, `invalid_icon` | 2 |
| `session_not_found`, `not_allowed`, `title_auto_failed` | 1 |
| success | 0 |

Error output is the CLI's existing error envelope, with `error.code` set to one of
the codes above. A platform may add extra keys, such as Android's `valid_icons`,
but the code and the exit status must match.

> **Naming note.** Older subcommands report argument errors as `invalid_args`
> (`NOFF_ERR_INVALID_ARGS`). `update` uses `invalid_arguments`, as the task
> specified, so Android and iOS agree on the new command. Unifying the older code
> would be a separate, breaking change.

### 2.3 Success output

```json
{ "ok": true, "tool": "minis-sessions-cli", "action": "update", "timestamp": "…",
  "data": { "id": "…", "title": "…", "group": "…", "icon": "…", "changed": ["title", "group"],
            "id_source": "explicit" } }
```

- `title`, `group` and `icon` are the session's values **after** the update:
  - `title` is `""` when the session has none;
  - `group` is `""` when the session is ungrouped;
  - `icon` is `""` when the session uses the default icon.
- `changed` lists the fields whose **output value** differs from before, always in
  the order `title`, `group`, `icon`.
  - Setting a field to its current value is a no-op: it is left out of `changed`,
    and nothing is written.
  - `changed` compares group **names**. Moving between two groups with the same
    name does not count.
- `--title-auto` can change more than the title, exactly as the app's button does.
  That is why `changed` comes from comparing before and after, not from the
  options given. The regeneration may:
  - set the icon;
  - file a session that has **no** group into a suggested group.

### 2.4 Writes (must reuse the app's own paths)

| Field | Write | `updated_at` | Sync |
|---|---|---|---|
| title, icon | The edit sheet's title/category update (one write for both). | bumped, which reorders the list as a rename does | yes; the session merges last-writer-wins on `updated_at` |
| group | The group picker's set-folder; create-folder when the group is new. | not bumped (as in the app) | yes; folder membership and the new group sync as in the app |
| `--title-auto` | The Regenerate Title action. | as the action does | as the action does |

`--title-auto` runs first; if it fails, nothing else in the request is written.
The UI must refresh as after an edit in the app: the home list (sessions and
groups) and the title of an open chat. iOS posts `.sessionDidUpdate`; Android's
Room flows refresh on their own.

## 3. `list`, `status`, `groups`

### `list`
Each session object always carries:

| Key | Value |
|---|---|
| `title` | `""` when untitled. This key used to be omitted for untitled sessions. |
| `group` | Group name, `""` when ungrouped. A group id that no longer exists counts as ungrouped. |
| `icon` | Icon key, `""` when the session uses the default icon. |

`--group <name>` filters, applied before `--limit`:
- With a name: sessions in **every** group with that exact name.
- With `""`: ungrouped sessions only, including ones whose group no longer exists.
- With a name that matches no group: an empty list (`count: 0`), not an error.

### `status`
Adds `group` and `icon` next to the existing `title`. They sit in the same object
as `title` and `model_name`.

> **Known difference, older than this task.** iOS has always nested the status
> fields one level deeper, at `data.data.title` (the bridge returns
> `{ok, action, data}`, which the envelope wraps again). Android puts them at
> `data.title`. This change leaves both shapes alone. Unifying them is a separate
> change.

### `groups`
```json
{ "ok": true, "action": "groups", "data": { "count": 2, "groups": [ {"name": "Work", "session_count": 3}, {"name": "Empty", "session_count": 0} ] } }
```
- Every group, in the app's display order. Same-named groups appear as separate
  entries.
- `session_count` counts home-list sessions only. Hidden child sessions are not
  counted.

## 4. Icon keys

The session icon is the session's **category**, which already exists on both
platforms:
- iOS: `ChatSession.category`, in the edit sheet's grid.
- Android: `SessionListScreen` categories.

The keys are plain English words, so they are identical across platforms. Each
platform keeps drawing its own native glyph for a key. Emoji and SF Symbol names
are **not** accepted: neither app stores those as a session icon.

| Key | iOS SF Symbol | iOS color | Android glyph (`SessionListScreen.categoryStyle`) |
|---|---|---|---|
| `code` | `terminal.fill` | orange | `Icons.Outlined.Code` |
| `writing` | `doc.text.fill` | blue | `Icons.Outlined.Description` |
| `research` | `globe.americas.fill` | teal | `Icons.Outlined.Language` |
| `analysis` | `chart.pie.fill` | indigo | `Icons.Outlined.BarChart` |
| `creative` | `paintbrush.pointed.fill` | pink | `Icons.Outlined.Brush` |
| `chat` | `bubble.left.fill` | green | `Icons.Outlined.Forum` |
| `math` | `number.circle.fill` | purple | `Icons.Outlined.Calculate` |
| `translation` | `character.bubble` | cyan | `Icons.Outlined.Translate` |
| `health` | `heart.fill` | red | `Icons.Outlined.Favorite` |
| `finance` | `banknote.fill` | mint | `Icons.Outlined.Payments` |
| `travel` | `map.fill` | orange | `Icons.Outlined.Map` |
| `education` | `book.closed.fill` | blue | `Icons.Outlined.Book` |
| `design` | `paintpalette.fill` | pink | `Icons.Outlined.Palette` |
| `productivity` | `calendar.badge.checkmark` | yellow | `Icons.Outlined.CalendarMonth` |
| `support` | `gearshape.fill` | brown | `Icons.Outlined.Settings` |
| `other` | `square.grid.2x2.fill` | gray | `Icons.Outlined.GridView` |
| `""` (default) | `bubble.left.fill` | gray | `Icons.Outlined.Forum`, gray |

`chat` and the default are different states: `chat` is green, the default is gray.
Adding a key means adding it on both platforms and here. The iOS standalone test
(`SessionsCliUpdateTests.swift`) fails when the iOS edit sheet's keys and the
CLI's keys differ.

## 5. Default session (FEAT-261018-11)

Inside a chat, the session id may be left out. The command then acts on **the
chat that ran it**. Example: `minis-sessions-cli update --title "x"` run by an
agent in chat A renames chat A.

### 5.1 Which subcommands default

| Subcommand | Without its id option, inside a chat | Why |
|---|---|---|
| `update` | acts on the calling chat | Edits one existing session; acting on itself is safe |
| `status` | the calling chat | Read-only |
| `messages` | the calling chat | Read-only |
| `open` | the calling chat | Same as `open <current id>`; navigation only |
| `send` (`--session`) | **unchanged: starts a NEW session** | Omitted `--session` already means "new session". Also, a chat posting into itself while its own turn runs re-triggers itself |
| `retry` (`--session`) | **unchanged: `--session` required** | Retrying the chat that is running the command waits for that very turn, then re-runs it; the re-run can call `retry` again, without end |
| `list`, `search`, `groups` | n/a | They take no session |

### 5.2 How "the calling chat" is determined

- Only from the command's own execution context:
  - iOS: the fs_context stamped on the shell that the agent turn spawned. A
    process forked from that shell inherits it.
  - Android: the equivalent per-session token.
  The chat counts as known only when that token maps to a chat
  (`callerSessionId(...).source == "fs_context"`).
- **Never** "the most recently mounted / most recently active session". That
  is the chat that last started a command, which with several chats running
  can be any of them. The iOS device run showed this twice:
  - A no-context shell resolved to chat A.
  - The terminal opened **from chat A** resolved to an unrelated third chat.
  Defaulting on that would edit the wrong chat.
- A command typed in the **interactive terminal** has no context, even when
  the terminal was opened from a chat. On iOS the terminal's login shell is
  started by `ISHKernel.executeCommand` and is never stamped; the device log
  confirms `via mounted (no fs_context)`. The same holds for anything else
  with no context: Shortcuts, scripts, debug RPC shells without a session.
  All of these must pass the id.

### 5.3 Rules

1. **The explicit id always wins**, and behaves exactly as before. This
   includes an id option present with an empty or missing value: that is the
   old error, never a default.
2. The default applies only when the id option is **absent** from the command
   line.
3. With no id and no known chat, the command fails with **the same error code
   and exit status it already used for a missing id**:
   - `update`: `invalid_arguments`;
   - `status`, `messages`, `open`: `invalid_args`;
   - exit status 2 in every case.

   The message says there is no current session and asks for `--id`, e.g.
   `No current session: this command was not run from inside a chat (e.g. typed
   in the terminal, or run by a Shortcut or script), so pass --id <session_id>.
   Use 'list' to find one.`
4. A child (sub agent) chat defaulting to itself gets the usual answers. For
   example, `update` returns `not_allowed`.

### 5.4 Output

Each response that names a session gets a new key, `id_source`:
- `"explicit"` when the id was given;
- `"current_session"` when it was defaulted.

It sits in the same object as that command's session fields:

| Command | Location |
|---|---|
| `update` | `data.id_source` |
| `messages` | `data.id_source` |
| `open` | `data.id_source` |
| `status` | `data.data.id_source` on iOS (where its fields live, see §3); `data.id_source` on Android |

No existing key changes.

## 6. Implementations

| | iOS | Android |
|---|---|---|
| CLI parsing and help | `src/ios/NativeOffloads/SessionsOffload.m` (`cmd_update`, `cmd_groups`) | `sandbox/offload/SessionsOffloadHandler.kt` (`cmdUpdate`, `cmdGroups`) |
| Rules | `SessionsOffloadBridge.swift`, `SessionsUpdateRules` (between `BEGIN/END sessions-update-rules`) | `SessionIcons.kt` and the handler |
| Writes | `ChatStore.updateSessionTitleAndCategory`, `setFolder`, `createFolder`, `AIChatViewModel.regenerateSessionTitle` | repository equivalents |
| Unit test | `src/ios/MinisTests/Standalone/SessionsCliUpdateTests.swift` | `SessionsCliUpdateTest` (Android) |

## 7. Open points

- **`invalid_args` vs `invalid_arguments`**, and the **`status` nesting** (see
  above): both are older than this task, and each needs its own breaking-change
  decision.
- **`list` returns hidden child sessions.** This is unchanged by this task and
  inconsistent with `groups`' counts.
- **A same-name group in another case.** `--group work` creates a separate
  "work" group when "Work" exists; the spec asks for case-sensitive matching.
  The app's own New Group field would refuse that name and offer the existing
  "Work".
