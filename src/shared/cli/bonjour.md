# minis-bonjour: find, publish and reach Bonjour (mDNS / DNS-SD) services

Task FEAT-261018-12. **iOS is the reference implementation**
(`src/ios/NativeOffloads/PeerBridge.swift`, `BonjourOffload.m`). Android and
Windows will ship a command with the same name and the same interface; each
platform implements it its own way. If an implementation and this file disagree,
fix the implementation or raise the difference. Do not let them drift.

Each part below is marked:
- **[same]**: must be identical on every platform: names, options, codes, exit
  statuses, JSON keys and their meaning;
- **[may differ]**: a platform may differ here, and must report it in the output
  rather than hide it.

Why the command exists: programs in the shell (iSH guest on iOS, PRoot on Android,
ish.exe on Windows) only have plain sockets, and the host OS does not let them do
multicast DNS. iOS also hides AWDL from them. So the app does the Bonjour work,
and the shell gets plain TCP on `127.0.0.1`.

## 1. Commands [same]

```
minis-bonjour types     [--category <c>]
minis-bonjour browse    <type> [--timeout <s>] [--domain <d>] [--p2p-only]
minis-bonjour advertise <type> <name> <port> [key=value ...]
minis-bonjour connect   <name> [--type <type>] [--domain <d>] [--p2p-only]
minis-bonjour connect   --host <addr> --port <n> [--p2p-only]
minis-bonjour resolve   <name> [--type <type>] [--domain <d>] [--timeout <s>] [--p2p-only]
minis-bonjour resolve   --host <addr> --port <n> [--timeout <s>] [--p2p-only]
minis-bonjour list
minis-bonjour stop      <id> | --all
```

- No command means `list`.
- `--help` / `-h` prints the help to stderr and exits 0.
- `--compact` prints single-line JSON.
- `-q` / `--quiet` prints only `data` on success, or only `error` on failure.
- An unknown command or option → `invalid_args`. The message names the valid ones.

### 1.1 Arguments [same]

| Argument | Rule |
|---|---|
| `<type>` | `_name._tcp` or `_name._udp`. `name` is 1–62 letters, digits or `-`, not starting or ending with `-`. Case is folded and one trailing `.` is dropped. Longer than RFC 6335's 15 characters is allowed, because Apple's own types are (`_remotepairing-pairable-host._tcp`). Anything else → `invalid_args`. |
| `<name>` (advertise) | 1–63 bytes of UTF-8. |
| `<port>` | 1–65535. For `advertise` it is the port the server listens on **inside the shell**. |
| `key=value` | TXT entries. A bare `key` is stored with an empty value. Keys are printable ASCII without `=`. Each entry is at most 255 bytes. The same key twice → `invalid_args`. |
| `--timeout <s>` | `0 < s ≤ 60`. Defaults: `browse` 3, `resolve` 5. |
| `--domain <d>` | Defaults to `local.`. |
| `--type <type>` | For `connect` / `resolve` by name. Without it, the name must have been seen by an earlier `browse` in this app run. Otherwise → `invalid_args`, telling the user to browse first or pass `--type`. |
| `--host` / `--port` | Connect to an address instead of a service name. Given together with a name → `invalid_args`. |
| `--p2p-only` | Use the peer-to-peer link only (§4). `advertise --p2p-only` → `invalid_args`, because a published service is offered on every link. |
| `--category <c>` | `types` only, case-insensitive (§3). |

`advertise`, `connect` and `resolve` forward **TCP**. A `_udp` type is accepted by
`browse` only. With the others → `invalid_args`.

## 2. Output [same]

All output is the shared native-offload envelope:

```json
{ "ok": true,  "tool": "minis-bonjour", "action": "browse", "timestamp": "…", "data": { … } }
{ "ok": false, "tool": "minis-bonjour", "action": "browse", "timestamp": "…",
  "error": { "code": "not_declared", "message": "…" } }
```

### 2.1 Error codes and exit status [same]

| Code | Exit | When |
|---|---|---|
| (success) | 0 | |
| `invalid_args` | 2 | Bad arguments, or an unknown `stop` id or service name. The help is also printed to stderr. |
| `authorization_denied` | 3 | The OS refused local-network access (iOS: Local Network permission off, or the prompt is not answered yet). |
| `disabled` | 3 | The user turned local discovery off in the app's settings (iOS: Settings › Network › Local Discovery, on by default). Only `browse`, `advertise`, `connect` and `resolve` are refused; `types`, `list` and `stop` still run. Turning it off closes every open item. |
| `not_declared` | 4 | The type is not on the platform's allow-list (only where `restricted` is true, §3). |
| `not_available` | 4 | The platform cannot do it: the feature is missing on this platform (§5), no peer-to-peer link has been seen, a connection timed out or was refused, the OS failed to start a listener, or the item limit was reached. |
| `internal_error` | 1 | The bridge did not answer (75 s guard). |

`message` is English and says what to do next. Its wording **[may differ]**.

### 2.2 `data` per command

Keys listed here are **[same]**. A platform may add keys. A key that does not
apply is left out, not set to `null`.

**browse**: a snapshot after `--timeout` seconds.
```json
{ "type": "_ictrl._tcp", "domain": "local.", "count": 1, "p2p_only": false, "waited_seconds": 3.0,
  "services": [ { "name": "My iPad", "type": "_ictrl._tcp.", "domain": "local.",
                  "txt": { "v": "1" },
                  "interfaces": [ { "name": "en0", "type": "wifi", "peer_to_peer": false },
                                  { "name": "awdl0", "type": "wifi", "peer_to_peer": true } ] } ],
  "warning": "browser reported: …" }
```
- `services` is sorted by name.
- `warning` appears only when the OS reported a non-fatal problem.
- `interfaces[].type` is one of `wifi`, `wired`, `cellular`, `loopback`, `other`, `unknown`. AWDL reports `wifi`, so `peer_to_peer` is the field to read.
- `peer_to_peer` is true for an AWDL / NAN interface (iOS: `awdl*`, `llw*`).
- The `type` echoed inside each service is the OS's spelling and **[may differ]**
  (iOS adds a trailing dot).

**advertise**: answers once the registration is confirmed, or after 8 s.
```json
{ "id": "adv-1", "kind": "advertise", "type": "_ictrl._tcp", "name": "My Shell", "requested_name": "My Shell",
  "guest_port": 8080, "listener_port": 52311, "txt": { "version": "1" }, "state": "ready",
  "accepted": 0, "open_connections": 0, "failed_connections": 0 }
```
- `name` is the name the OS registered. It can differ from `requested_name` after
  a conflict, e.g. `My Shell (2)`.
- `warning` is set when the 8 s passed without confirmation.

**connect**:
```json
{ "id": "fwd-2", "kind": "connect", "address": "127.0.0.1:53001", "local_port": 53001,
  "target": { "service": "My iPad", "type": "_ictrl._tcp", "domain": "local." },
  "state": "ready", "p2p_only": false, "accepted": 0, "open_connections": 0, "failed_connections": 0 }
```
- Each connection to `address` is piped to a new connection to the target.
- `target` is `{ "host", "port" }` for `--host`.
- `last_path` (as `resolve.path`) appears after the first connection.

**resolve**: one connection, closed again. It reports the path the connection
took.
```json
{ "target": { … }, "connected": true, "p2p_only": false, "seconds": 0.21,
  "path": { "remote": "fe80::…%awdl0.52311", "local": "…", "interface": "awdl0",
            "uses_peer_to_peer": true, "interfaces": [ … ] } }
```

**list**:
```json
{ "advertisements": [ … ], "forwards": [ … ], "declared_types": [ … ], "app_in_background": false }
```
- Each item has the same shape as the `advertise` or `connect` answer.
- `declared_types` is the same list as `types.types`.

**stop**: `{ "stopped": ["adv-1", "fwd-2"], "count": 2 }`. An unknown id →
`invalid_args`. `--all` with nothing open → `count: 0`.

### 2.3 Item states [same]

`state` is one of `starting`, `ready`, `failed`, `stopped`.
- A `failed` item also has `failed_reason` and `restarts_on_foreground`.
- A failed item never holds a listener or a port.
- At most 32 items are open at once. A new one beyond that → `not_available`.

What happens when the app is suspended **[may differ]** (§5). It must be visible
in `list` (`app_in_background`, `failed_reason`, `restarts_on_foreground`).

## 3. `types` [same]

```json
{ "types": ["_ictrl._tcp", "_hap._tcp", …],
  "source": "Info.plist NSBonjourServices",
  "restricted": true,
  "entries": [ { "type": "_hap._tcp", "category": "smart-home",
                 "description": "HomeKit accessories", "declared": true }, … ],
  "category": "smart-home" }
```

- **`types`**: the types the command will accept. On a restricted platform it is
  exactly the allow-list. It is kept from the first version for old scripts and
  must not be removed or renamed.
- **`source`** **[may differ]**: where the list comes from (iOS:
  `Info.plist NSBonjourServices`).
- **`restricted`**:
  - `true`: the OS accepts only the listed types. Any other type fails with
    `not_declared`, and only a new app build can add one.
  - `false`: any well-formed type works. Then `types` / `entries` list the
    platform's suggestions, every entry has `declared: false`, and `not_declared`
    is never returned.
  - iOS is `true`. Android and Windows are expected to be `false` (§5, not yet
    verified).
- **`entries`**: one per listed type, in list order. Each has
  `{type, category, description, declared}`.
  - `category` and `description` come from a table in the code, not from the
    platform's manifest. All platforms should use the same table (§3.1).
  - A listed type missing from the table is kept with `category: "other"` and
    `description: ""`, never dropped and never an error.
- **`--category <c>`** narrows `types` and `entries` to one category and echoes
  `category`.
  - The categories are those in §3.1 plus `other`.
  - An unknown category → `invalid_args`, and the message lists the valid ones.
- There is no `types --all`.

### 3.1 Type table (iOS, 29 types)

| Category | Types |
|---|---|
| remote-control | `_ictrl._tcp` |
| apple-devices | `_remotepairing-pairable-host._tcp`, `_remotepairing._tcp`, `_remoted._tcp` |
| smart-home | `_hap._tcp`, `_matter._tcp`, `_matterc._udp` (browse only), `_hue._tcp` |
| media | `_airplay._tcp`, `_googlecast._tcp`, `_raop._tcp`, `_spotify-connect._tcp`, `_daap._tcp`, `_dpap._tcp`, `_companion-link._tcp` |
| printing | `_ipp._tcp`, `_ipps._tcp`, `_printer._tcp`, `_uscan._tcp`, `_scanner._tcp` |
| file-sharing | `_smb._tcp`, `_afpovertcp._tcp`, `_nfs._tcp`, `_webdav._tcp` |
| general | `_http._tcp`, `_https._tcp`, `_ssh._tcp`, `_sftp-ssh._tcp`, `_workstation._tcp` |

The descriptions are in `PeerBridgeRules.typeCatalog`. Copy them, so the same
type reads the same everywhere.

## 4. Peer-to-peer (`--p2p-only`) [same meaning]

- `--p2p-only` means "never Wi-Fi infrastructure, wired or cellular; only a direct
  peer-to-peer link".
  - On iOS that link is AWDL.
  - `browse --p2p-only` keeps only services seen on such a link.
  - `connect` / `resolve --p2p-only` pin the connection to the peer-to-peer
    interface that the last `browse` saw. With none seen yet → `not_available`.
- Output must never call an infrastructure Wi-Fi path peer-to-peer. The
  interface name and `peer_to_peer` / `uses_peer_to_peer` are the evidence.
- A platform without such a link answers every `--p2p-only` request with
  `not_available` (§5).

## 5. Platform differences [may differ]

| | iOS (implemented, tested on iPhone 11) | Android (**not implemented, not tested**) | Windows (**not implemented, not tested**) |
|---|---|---|---|
| API | Network.framework: `NWBrowser`, `NWListener` + `NWListener.Service`, `NWConnection` | `NsdManager` (discover / resolve / register); Android 14+ `registerServiceInfoCallback` | System `DnsServiceBrowse` and related calls (`windns.h`, Windows 10+, desktop apps only), or a Rust mDNS library in the host |
| `restricted` | `true`: types must be in Info.plist `NSBonjourServices`, else `not_declared` | `false`: no declaration | `false`: nothing to declare or request |
| App switch | Settings › Network › Local Discovery, on by default; also `minis-config set network.bonjourEnabled false`. Off → `disabled`. | **to add** with the same default | **to add** with the same default |
| Permissions | Local Network prompt on first use. Denied → `authorization_denied`. | `CHANGE_WIFI_MULTICAST_STATE`, `NEARBY_WIFI_DEVICES`, and a `WifiManager.MulticastLock` held while multicast is needed | none known |
| `_services._dns-sd._udp` (list every type) | Not available: `NWBrowser` fails with BadParam (measured), so it is not declared, and browsing it gives `not_declared` | **to verify**: whether `NsdManager` can browse it | **to verify** |
| advertise / connect / resolve | TCP only | TCP; UDP not specified | TCP; UDP not specified |
| Peer-to-peer | AWDL, through `includePeerToPeer` | none specified → `--p2p-only` is `not_available` until one is designed | none → `not_available` |
| Suspension | iOS suspends the app. Advertisements are withdrawn while suspended and published again on foreground. Forwards come back on the same `127.0.0.1` port. | **to verify** | the app is not suspended |
| Shell's own multicast | Fails: `sendto` → EHOSTUNREACH without the multicast entitlement, which is why this command exists | **to verify**: whether guest multicast fails without the app's MulticastLock, and whether a PRoot guest can send multicast directly | ish.exe's Winsock path has no multicast support, so the work has to be done on the host side |

The rules every platform keeps:
- **No pretending.** A feature the platform lacks returns `not_available` (exit 4)
  with a message that says so. It must not return an empty success.
  - Example: `browse` that cannot run must not answer `count: 0`.
  - Example: `--p2p-only` with no peer-to-peer link must not fall back to Wi-Fi.
- An empty result is success only when the search really ran: `browse` that ran
  and found nothing is `count: 0`.
- Never report a path as peer-to-peer without interface evidence.

### 5.1 To verify before Android / Windows ship

1. **Android:** can `NsdManager` browse `_services._dns-sd._udp`?
2. **Android:** without the app's `MulticastLock`, does multicast from the guest
   fail?
3. **Android:** can a PRoot guest send multicast directly? If it can, the command
   may only be needed for permissions and lifecycle.
4. **Windows:** `DnsServiceBrowse` versus an mDNS library: does each work from
   the packaged app, and with or without the Windows firewall prompt?
5. **Both:** what `restricted: false` lists in `types` (the §3.1 table as
   suggestions is the default proposal).

## 6. Known limits / open decisions

- **UDP forwarding:** not done. `_udp` types can be browsed but not reached
  through the bridge. Undecided whether to add it.
- **Adding a type on iOS** needs an app release (Info.plist) and a table row.
  Apple documents no limit on the number of `NSBonjourServices` entries.
- **AWDL with no shared Wi-Fi** is not verified yet. Every iOS AWDL measurement
  so far had both devices on the same Wi-Fi.
- **iOS after Local Network permission is denied** is not verified: the device
  was already authorized. The expected answer is `authorization_denied`.
- **`connect --host fe80::…%awdl0`** without a prior browse is not verified.
- **iOS multicast entitlement**
  (`com.apple.developer.networking.multicast`) would let the shell do mDNS
  itself. It needs Apple's approval and has not been requested.
- The `browse` snapshot model (one answer after `--timeout`) is the interface.
  A streaming `browse --watch` is not specified.
