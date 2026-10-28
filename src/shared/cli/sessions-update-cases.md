# minis-sessions-cli update / groups: cross-platform test cases

Contract: [`sessions-update.md`](sessions-update.md). Every platform runs these cases
through the **real CLI** in its shell (iOS: iSH, Android: proot), against a
throwaway session `$S`. `$C` is a hidden child session (a sub agent's run).
`$X` is an id that does not exist, e.g. `00000000-0000-0000-0000-000000000000`.

Groups `GA`/`GB` must not exist beforehand; use names that cannot collide, e.g.
`CLI测试A` / `CLI-Test-B`. Afterwards, dissolve every group the run created and
delete `$S`.

**Setup:** `update --id $S --group "" --icon ""`, so the session starts
ungrouped with the default icon.

"rc" is the exit status. `changed` must match exactly, including its order.

## Field changes

| # | Command (after `minis-sessions-cli`) | rc | Expected |
|---|---|---|---|
| 1 | `update --id $S --title "CLI 改名 1"` | 0 | `title`="CLI 改名 1", `changed`=["title"] |
| 2 | `update --id $S --icon code` | 0 | `icon`="code", `changed`=["icon"] |
| 3 | `update --id $S --group GA` (GA does not exist) | 0 | `group`="GA", `changed`=["group"]; GA now exists |
| 4 | `update --id $S --group GA` (again) | 0 | `changed`=[] (no-op, nothing written) |
| 5 | `update --id $S --title "CLI 改名 2" --group GB --icon research` | 0 | data is exactly `{id:$S, title:"CLI 改名 2", group:"GB", icon:"research", changed:["title","group","icon"], id_source:"explicit"}` |
| 10 | `update --id $S --group <GB in lower case>` | 0 | a new group is created (case-sensitive match); `changed`=["group"] |
| 11 | `update --id $S --group ""` | 0 | `group`="", `changed`=["group"] |
| 13 | `update --id $S --icon ""` | 0 | `icon`="", `changed`=["icon"] |
| 29 | `update --id $S --icon " Code "` | 0 | `icon`="code" (trimmed, case-insensitive) |
| 27 | `update --id $S --title-auto` (`$S` has one exchange) | 0 | `title` regenerated (not "" and not the previous title); `changed` contains "title". It may also contain "icon", and "group" when `$S` was ungrouped. |

## Reading back

| # | Command | rc | Expected |
|---|---|---|---|
| 6 | `status --id $S` | 0 | `group`="GB", `icon`="research", `title`="CLI 改名 2" (iOS: under `data.data`, Android: under `data`) |
| 7 | `list --group GB` | 0 | `count`=1; the row is `$S` with `group`="GB", `icon`="research" |
| 8 | `list --group no-such-group-xyz` | 0 | `count`=0, `sessions`=[] |
| 9 | `groups` | 0 | contains `{name:"GB", session_count:1}` and `{name:"GA", session_count:0}` |
| 12 | `list --group "" --ids $S` (after #11) | 0 | `count`=1, the row's `group`="" |

## Errors

| # | Command | rc | Expected `error.code` |
|---|---|---|---|
| 14 | `update --id $S --icon rocket` | 2 | `invalid_icon`; the message lists the 16 keys |
| 15 | `update --id $S` | 2 | `invalid_arguments` (no field) |
| 16 | `update --id $S --title ""` | 2 | `invalid_arguments` |
| 17 | `update --id $S --title x --title-auto` | 2 | `invalid_arguments` |
| 18 | `update --title x` | 2 | `invalid_arguments` (no `--id`) |
| 19 | `update --id $S --title` | 2 | `invalid_arguments` (option without a value) |
| 20 | `update --id $S --title --group GA` | 2 | `invalid_arguments` (an option is not a value) |
| 21 | `update --id $X --title x` | 1 | `session_not_found` |
| 22 | `update --id $X --icon rocket` | 2 | `invalid_icon` (argument errors come before the lookup) |
| 23 | `update --id $C --title x` | 1 | `not_allowed` |
| 28 | `frobnicate` | 2 | the unknown-command message names `update` and `groups` |

## Output modes

| # | Command | rc | Expected |
|---|---|---|---|
| 24 | `update --id $S --icon math --compact` | 0 | JSON on a single line |
| 25 | `update --id $S --icon math -q` (already `math`) | 0 | only the data object: keys exactly `id,title,group,icon,changed,id_source`; `changed`=[] |
| 26 | `update --id $S --icon rocket -q` | 2 | only the error object: `{code:"invalid_icon", message}` |

## Default session (FEAT-261018-11, spec §5)

Cases 1–29 above must run in a shell with **no** chat context. On iOS that
means `debug.shellExecute` without `sessionId`; on Android, the equivalent.
Otherwise #18 would default to that chat instead of failing.

The D-cases need two throwaway chats, `$A` and `$B`. "In A" means run by an
agent turn of chat A, or by a shell stamped with A's context. On iOS that is
`debug.shellExecute {sessionId: A, stdinScript: true}`: only the stdinScript
path forwards the fs_context.

| # | Where / command | rc | Expected |
|---|---|---|---|
| D1 | in A: `update --title "A x"` | 0 | A renamed; B untouched; `data.id_source`="current_session", `data.id`=$A |
| D2 | in A: `status` | 0 | A's status; `id_source`="current_session" (iOS: `data.data`) |
| D3 | in A: `messages --limit 2` | 0 | `data.session_id`=$A, `data.id_source`="current_session" |
| D4 | in A: `status --id $B` | 0 | B's status, `id_source`="explicit" (an explicit id wins inside a chat) |
| D5 | in A and in B at the same time, 10 rounds: `update --title "<A or B>-<n>"` | 0 | Every round: A's title from A's command, B's from B's; no crosstalk |
| D6 | while B runs a long turn, A's agent runs `update --title …` | 0 | Only A changes |
| D7 | no context: `update --title x` | 2 | `invalid_arguments`, message starts "No current session"; nothing renamed |
| D8 | no context: `status`, `messages`, `open` | 2 | `invalid_args`, message starts "No current session" |
| D9 | the interactive terminal opened FROM chat A: `status` | 2 | `invalid_args` "No current session". The terminal has no context; the log shows `via mounted (no fs_context)` |
| D10 | in A: `send hello` (no `--session`) | 0 | Unchanged: a NEW session is created (`is_new_session`=true); A gets nothing |
| D11 | in A: `retry` (no `--session`) | 2 | Unchanged: `--session <id> is required for retry` |
| D12 | in A: `update --id` (no value) / `--id ""` | 2 | The old missing-id error; never a default |

## UI and persistence (manual or screenshot)

| # | Check |
|---|---|
| U1 | With the home list on screen, `update --title … --icon health --group ""` changes the row's title and icon and moves it out of its group, with no user action. |
| U2 | `update --group <existing> --icon finance` moves the row into that group, in place. |
| U3 | With the chat open, `update --title …` changes the chat's title. |
| U4 | Kill and relaunch the app: the values survive (they are persisted, not only in memory). |
| U5 | With sync on and a second device: title and icon arrive there, and so does the group change. |

## iOS results (FEAT-261018-08, iPhone 11, iOS 27.2, build 2026-10-18T08:43Z)

- Cases 1–29: **29/29 pass** on the device, through the real CLI in iSH
  (`debug.shellExecute`).
- U1–U3: pass, shown by before/after screenshots.
- U4: not tested separately. The rows are written by the same `ChatStore` SQL as
  the app's edit sheet and group picker.
- U5: not tested (the test iPhone has no second device).
- Unit test: `src/ios/MinisTests/Standalone/SessionsCliUpdateTests.swift`,
  all checks pass.
