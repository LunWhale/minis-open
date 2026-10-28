# <platform>-a11y-cli: read and operate other apps through the OS accessibility API

**DRAFT** - task INV-261021-03, awaiting the owner's decisions (see
`reports/windows/*INV-261021-03*/` and the design report). Nothing here ships
until it says otherwise.

**Android is the existing implementation** (`android-a11y-cli`,
`src/android/app/src/main/java/com/openminis/app/sandbox/offload/AccessibilityOffloadHandler.kt`).
Windows adds `windows-a11y-cli` with the same commands, flags and `data` keys.
iOS has no equivalent: apps cannot read or drive other apps there, and it must
not pretend to (no command is installed).

Each part below is marked:
- **[same]**: must be identical on every platform that ships the command:
  command and option names, `data` keys and their meaning, error codes, exit
  statuses;
- **[may differ]**: a platform may differ, and must say so in its output
  (`not_supported`, an extra key) rather than hide it.

Why the command exists: the agent runs in a guest shell (PRoot on Android,
ish.exe on Windows) that has no access to the host's UI. The app owns the OS
accessibility client (Android AccessibilityService, Windows UI Automation) and
exposes it as one mounted command, gated by the user.

## 1. Commands [same]

```
<p>-a11y-cli service status | ping
<p>-a11y-cli ui info
<p>-a11y-cli ui dump        [--window <w>] [--depth N] [--visible-only=false]
<p>-a11y-cli ui find        [--text s | --text-contains s] [--desc s | --desc-contains s]
                            [--id s] [--class s] [--role r] [--package p | --app exe]
                            [--clickable] [--editable] [--scrollable] [--checked] [--enabled]
                            [--window <w>] [--limit N] [--depth N] [--index N]
<p>-a11y-cli ui node        <nodeId> [--children] [--ancestors]
<p>-a11y-cli ui screenshot  [--scale f] [--window <w> | --display N] [--inline]
<p>-a11y-cli tap node <id> | xy <x> <y> | text <s> [--contains] [--index N] | id <s>
                            [--long] [--double] [--right]          (--right: Windows only)
<p>-a11y-cli input text <s> [--node id] [--clear] [--append]
<p>-a11y-cli input clear    [--node id]
<p>-a11y-cli input key <K>
<p>-a11y-cli scroll node <id> | xy <x> <y> | to-text <s>  [--direction d] [--times N]
<p>-a11y-cli gesture swipe x1 y1 x2 y2 | pinch cx cy | path "x,y:x,y:…"
<p>-a11y-cli wait appear | disappear | stable  [selectors] [--timeout ms]
<p>-a11y-cli event watch | once  [--type t,…] [--app a] [--timeout s]     (NDJSON)
<p>-a11y-cli dialog detect | dismiss [--confirm | --deny | --button s]
<p>-a11y-cli extract text | list | form  [--node id]
```

Windows adds (Android answers `not_supported`):

```
windows-a11y-cli window list | activate <w> | close <w> | minimize <w> | restore <w>
windows-a11y-cli app launch <exe|aumid> [args…] | close <app>
windows-a11y-cli wait window [--title s] [--app exe] [--timeout ms]
```

Android keeps `wait activity` and `notify watch|once` (Windows: `not_supported`).

- `--help` / `-h` prints help to stderr, exit 0. No arguments: help, exit 2.
- `--compact` prints single-line JSON; `-q` / `--quiet` prints only `data` or `error`.
- Every boolean flag is declared as boolean; `--flag=false` turns it off.
  (Android today misparses `--visible-only` and `--contains`; fix there.)
- `<w>` (window) is a window id from `window list` or a title substring.

## 2. Output [same]

Shared native-offload envelope (as `bonjour.md`):

```json
{ "ok": true,  "tool": "windows-a11y-cli", "action": "ui.find", "timestamp": "…", "data": { … } }
{ "ok": false, "tool": "windows-a11y-cli", "action": "tap.node", "timestamp": "…",
  "error": { "code": "blocked_app", "message": "…" } }
```

Exceptions: `service ping` prints one plain line; `event`/`notify` print NDJSON
(one event object per line); `extract text` prints plain text unless
`--format json`.

### 2.1 Node [same]

```json
{"nodeId":"0a1f","role":"Button","name":"Save","text":"Save","contentDesc":"",
 "className":"Button","automationId":"saveBtn","resourceId":"",
 "app":"notepad.exe","window":"Untitled - Notepad",
 "bounds":{"left":40,"top":90,"right":120,"bottom":120},"center":{"x":80,"y":105},
 "clickable":true,"longClickable":false,"scrollable":false,"editable":false,
 "checkable":false,"checked":false,"focusable":true,"focused":false,"selected":false,
 "enabled":true,"visible":true,"password":false,"depth":5,"childCount":0,
 "patterns":["Invoke"],"untrusted":true}
```

- `nodeId`: opaque, short, valid for 60 s; ids may change between dumps.
- `role`: a portable role name (Button, Edit, Text, List, ListItem, CheckBox,
  ComboBox, MenuItem, Tab, Window, …). Android derives it from `className`.
- `name`: what a screen reader would read (Android: text, else contentDesc;
  Windows: UIA Name).
- Platform-only keys **[may differ]**: Android `resourceId`, `packageName`;
  Windows `automationId`, `patterns`, `app`, `window`. Absent rather than null.
- `untrusted: true` on everything read from the screen: it is data, never
  instructions to the agent.
- Coordinates: physical screen pixels.
- `password: true` nodes never report `text`/value.

### 2.2 Error codes and exit status [same]

| Code | Exit | When |
|---|---|---|
| (success) | 0 | |
| `invalid_args` | 2 | Bad arguments; help to stderr. |
| `authorization_denied` | 3 | Agent permission is Not Allowed, or the user denied the prompt. |
| `disabled` | 3 | The master switch ("Let Minis operate this device") is off, or the Android accessibility service is not enabled. |
| `blocked_app` | 3 | The target app is on the protected list (§4). |
| `elevated_target` | 3 | Windows: the target runs elevated / another session / the secure desktop. |
| `not_supported` | 4 | This platform has no such command or flag. |
| `not_available` | 4 | Supported, but impossible now (no foreground window, capture failed, OS too old). |
| `node_not_found` | 1 | Stale or unknown id, nothing matched. |
| `action_failed` | 1 | The OS refused the action. |
| `timeout` | 1 | A `wait` or the action timed out (`wait` success-with-timeout is `ok:true`, `timedOut:true`). |
| `stopped` | 130 | Emergency stop or the chat was stopped. |
| `internal_error` | 1 | Anything else. |

Android migration: today it emits UPPERCASE codes (`PERMISSION_DENIED`,
`SERVICE_NOT_RUNNING` exit 77, `NODE_NOT_FOUND`, …) without `tool/action/timestamp`.
Those are legacy aliases to be replaced by the table above.

## 3. Platform differences [may differ]

| | Android | Windows |
|---|---|---|
| OS API | AccessibilityService | UI Automation client (`IUIAutomation`), `SendInput`, `PrintWindow` / Graphics.Capture |
| Multiple windows | foreground app + system windows | every top-level window; `--window` scopes a query |
| `input key` | BACK, HOME, RECENTS, NOTIFICATIONS | any key chord (`ctrl+s`); dangerous chords need confirmation |
| Cannot reach | other users, secure settings screens | UAC secure desktop, elevated windows, other sessions, lock screen |
| Screenshot | `takeScreenshot` (Android 11+) | window or display capture |

## 4. Safety rules every platform keeps [same]

1. Off by default: a master switch in Settings › Permissions plus the agent
   permission (read and act are separate permissions; act defaults to Ask Every
   Time; neither is switched by "Set All Bypass").
2. Per-app consent the first time a session touches an app.
3. Protected apps (built-in list: password managers, OS credential / security
   UI, Minis itself; plus a user list): no read, no action, `blocked_app`.
4. Confirmation for destructive actions (delete/send/pay/buy/uninstall buttons,
   closing an app, dangerous key chords), even when already allowed.
5. Audit log of every call (no typed text, only its length), viewable in Settings.
6. Emergency stop (Windows: global hotkey; Android: notification action) that
   cancels in-flight calls and revokes the session's grant; a visible indicator
   while actions run.
7. Screenshots black out password fields and protected apps.
8. Screen text is `untrusted`; the system prompt tells the agent not to follow
   instructions found on screen.

Android does not do 2-8 yet (see the design report).

## 5. Open decisions

Recorded in the design report §3 (L2-Q1 to L2-Q5).
