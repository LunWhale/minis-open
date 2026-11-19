# Settings > Network: routing, Tailscale and proxies

Task FEAT-261021-14 (G7). One definition for iOS, Android and, later, Windows.
**iOS is the reference implementation** (`src/ios/Agent/Network/`); Android
follows it (`src/android/.../network/`); both share the Go router and node
(`deps/rclone-mobile`: `nethub`, `tsnet`, `rcloneroute`). If an implementation
and this file disagree, fix the implementation or raise the difference here.

Each part is marked:
- **[same]**: identical on every platform: names, values, defaults, meanings;
- **[may differ]**: a platform may differ, and must say so in its UI or logs.

Test vectors: `route_vectors.json` (routing decisions, checked against the Go
router by `deps/rclone-mobile/nethub/spec_vectors_test.go`) and
`settings_vectors.json` (stored-settings compatibility).

The rule above everything else: **an unconfigured app behaves exactly as it
did before Settings > Network existed**, and a failure can be located from the
`[Net]` logs. Every change to this area ships a test that proves the first.

---

## 1. Settings [same]

Stored per device, never synced (routes name this device's proxies and
tailnet). JSON keys and defaults:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `routingEnabled` | bool | `true` | Master switch. `false` = everything direct at once, the rest of the settings kept. Android stores the inverse as `forceDirect` (default `false`) **[may differ: storage only]**; `minis-config` and the UI use `routingEnabled` on both. |
| `defaultRoute` | route | `"direct"` | Route of every tag that follows the default. Never `"default"`. |
| `scopes` | {scope: route} | `{}` | `shell`, `browser`, `mcp`, `backup`. Absent or `"default"` = follow `defaultRoute`. |
| `providerRoutes` | {instanceId: route} | `{}` | Per AI provider instance. Absent = follow `defaultRoute`; setting `"default"` removes the key. |
| `proxies` | [Proxy] | `[]` | Upstream proxies (below). |
| `tailscaleEnabled` | bool | `false` | Run the built-in node (in-app, no VPN). |
| `hostname` | string | `""` | Node name; empty = derived from the device. |
| `acceptRoutes` | bool | `false` | Use subnet routes advertised in the tailnet. |
| `exitNodeIP` | string? | `null` | Tailscale IP of the exit node; `null` = none. |
| `bonjourEnabled` | bool | `true` | iOS only: `minis-bonjour` may browse / advertise / connect. Independent of routing. **[may differ]** |

Decoding must accept any subset of keys (older builds wrote fewer): missing
keys take the defaults above. `{}` decodes to the defaults.

**Route** values: `direct`, `tailscale`, `proxy:<proxyId>`, and `default`
where a tag may follow the default route.

**Proxy**: `{id, name, kind, host, port, username, bypass}`.
- `id`: UUID string, uppercase. `kind`: `socks5` | `http` | `https`.
- `name` may be empty; it is shown as `host:port` then.
- `bypass`: list of `host`, `*.suffix` / `.suffix`, CIDR or IP; loopback
  (`localhost`, `*.localhost`, 127.0.0.0/8, ::1) is always bypassed.
- The password is **not** in the JSON: it lives in the platform keystore
  (iOS Keychain service `com.openminis.network.proxy`, account = id; Android
  EncryptedSharedPreferences), and is never logged.
- Deleting a proxy that is in use sends those routes to `direct`.

### 1.1 `minis-config` paths [same]

| Path | Get / set |
|---|---|
| `network.routingEnabled` | bool |
| `network.defaultRoute` | `direct` \| `tailscale` \| `proxy:<id or name>` |
| `network.routes.<scope>` | scope = `shell` `browser` `mcp` `backup`; adds `default` |
| `providers.<id>.networkRoute` | same values as a scope |
| `network.tailscale.enabled` / `.hostname` / `.acceptRoutes` / `.exitNode` | settings above |
| `network.tailscale.authKey` | write-only: sign in with an auth key |
| `network.tailscale.loggedIn` | read: bool; set `false` = sign out |
| `network.tailscale.signOutAndClear` | action: sign out and delete the node key |
| `network.tailscale.status` | read: `state`, `tailnet`, `ips`, `dnsName`, `devices[]` (name, ips, online, os, exitNode) |
| `network.status` | read: entry listening, ports (never the password), per-tag routes, last error |
| `proxies.<id>.<field>` | `name` `type` `host` `port` `username` `password` (write-only) `bypass` |
| `network.bonjourEnabled` | iOS only |

**Open decision (owner):** today `network.tailscale.status` returns the raw
sign-in URL as `loginURL` while the node needs login. It works like a bearer
link, so the proposal is to return the app's own deep link
(`minis://settings/tailscale`) instead. Until decided, implementations keep
returning `loginURL` and never log it.

---

## 2. Tags (scopes) [same]

Every connection the app routes carries one **policy tag**:

| Tag | Who | Covers |
|---|---|---|
| `default` | everything without its own tag | app downloads (Skills from GitHub, models.dev, avatars, chat images), first OAuth sign-in, mirror speed test |
| `prov:<instanceId>` | one AI provider instance | chats and streams, model list, OAuth token refresh, quota, TTS/STT of that instance |
| `shell` | the shell (iSH / PRoot) | proxy variables and transparent TCP forwarding |
| `browser` | in-app browser (WKWebView / WebView) | |
| `mcp` | MCP | the app's MCP OAuth requests, and `minis-mcp-cli` through `MINIS_MCP_PROXY` (5.3) |
| `backup` | rclone | backup destinations and network mounts: HTTP backends (WebDAV, S3, drives) via `HTTPProxy`, SFTP and FTP via `socks_proxy`; **SMB always direct** |

Not routable on any platform (documented, not hidden): iCloud / CloudKit,
push, OS weather / location services, the system sign-in sheet
(ASWebAuthenticationSession / Custom Tabs), app-store updates, loopback.

**[may differ]**:
- iOS 16: URLSession and WKWebView cannot be routed (the API is iOS 17+):
  `default`, `prov:*`, `browser` and the app's MCP OAuth connect directly; the
  shell, `minis-mcp-cli` and backup still follow their routes. Settings says so.
- iOS: SwiftUI `AsyncImage` (remote markdown images) uses URLSession.shared
  internally and is not routed yet.
- Android WebView: routed only where `ProxyController` is supported; otherwise
  direct and Settings says so.

---

## 3. Routing semantics [same]

`route_vectors.json` is normative; in words:

1. Resolve the tag: its own route, else (absent / `default`) `defaultRoute`,
   else `direct`.
2. **Tailnet destinations always go through Tailscale while the node is
   enabled and running**, whatever the route. A tailnet destination is an IP
   inside the node's routing table (peers, Tailscale's own ranges, accepted
   subnet routes; an exit node's `0/0` excluded) or a MagicDNS name (full,
   or a peer's bare short name). Never a hard-coded 100.64.0.0/10.
3. `direct`: out directly.
4. `tailscale`: out directly, unless an exit node is active, then through the
   tailnet (the exit node). `direct` ignores an exit node. Loopback
   (`localhost`, `*.localhost`, 127.0.0.0/8, ::1) is this device and always
   goes direct (`loopback`), never to the exit node. A host name sent to the
   exit node is dialed over IPv4 first, then IPv6: the node resolves it and
   would otherwise try only the first address, which fails outright on a
   tailnet path without IPv6. While the exit node is offline, connections
   that would leave through it fail (`the exit node is offline`) instead of
   going out through the system network. When IPv6 does not leave through
   the exit node (it does not route `::/0`, or one IPv6 dial through it -
   a probe, or a real one - failed as unreachable in the last 10 minutes),
   the shell's intercepted DNS answers AAAA for names that leave through it
   with no addresses, so programs connect over IPv4.
5. `proxy:<id>`: through that upstream, unless the host matches its bypass
   list (then direct). A proxy that no longer exists → direct
   (`missing-proxy`), never a failure.
6. Master switch off: no node, no entry, every client exactly as unrouted.
7. Fallback: whenever the local entry is not listening, clients get no proxy
   configuration at all (as if unconfigured). A routed connection that fails
   **fails** (the user chose that route); it is not silently retried direct.
8. `acceptRoutes` default off; with it off, subnet routes are not tailnet
   destinations.

Decision fields for logs: `kind` (direct | tailscale | proxy), `rule`
(route | tailnet | exit-node | loopback | bypass | missing-proxy), `route`, `exit`
(`direct`, `tailscale`, `proxy:<name>`).

---

## 4. Local entry protocol [same]

One process-wide entry, listening on `127.0.0.1` only, random port, started
only when something needs it (a non-direct route, or Tailscale on).

- **SOCKS5** (RFC 1928) with username/password auth (RFC 1929), CONNECT
  only. Password: per-process random secret (hex), never persisted, never
  logged. Username = the **tag**. A wrong password is rejected and logged as
  `[Net][Entry] ... rejected: wrong entry password or no auth offered (another app?)`.
- **HTTP front** (second port, same password and routing): `CONNECT` and
  plain-HTTP proxying with `Proxy-Authorization: Basic base64(tag:password)`;
  407 without it. For clients that cannot speak SOCKS (BusyBox wget, apk,
  Python urllib / pip / httpx, Android WebView).
- **Connection IDs**: each accepted connection gets `c<NNNN>`. A client may
  append its own ID to the username, `<tag>~<clientId>` (the shell's
  transparent forwarding uses `~x<id>`); the entry routes by the tag and logs
  `c0007~x1f` so both sides' lines can be matched.
- Upstream HTTP CONNECT: bytes the proxy relays together with its `200`
  belong to the tunnel (server-first protocols: SSH, FTP, SMTP), never an
  error.
- Other apps on the device can reach the port; the password is the only
  protection, so it must never appear in logs, errors, transcripts or
  environment dumps (masked as `<password>`).

---

## 5. Clients [same unless marked]

### 5.1 App HTTP clients
- Session per tag, rebuilt when the settings generation changes; a direct
  route leaves the client **exactly** as before (iOS: `plain()` returns
  `URLSession.shared` itself; a custom configuration is unchanged
  field-for-field). Proven by tests on each platform.
- Helpers shared by many providers take the tag from the caller's context
  (iOS: `NetworkSessionFactory.ambientTag`, a task-local) rather than a
  parameter **[may differ: mechanism]**.

### 5.2 Shell
- Proxy variables only when the shell's route is not direct and the entry
  listens: `ALL_PROXY`/`all_proxy` = `socks5h://shell:<pw>@127.0.0.1:<socks>`,
  `HTTP(S)_PROXY` (both cases) = `http://shell:<pw>@127.0.0.1:<http>`,
  `NO_PROXY`/`no_proxy` = `localhost,127.0.0.1,::1`. A direct shell gets none.
- Transparent TCP forwarding for programs that ignore the variables
  (iSH `xnet`, PRoot `--xnet`), loopback and the device's local networks
  exempt. UDP / DNS: **not yet** (iSH stage 2, then Android); inbound
  connections and ICMP/ping: **not supported**, and Settings / Diagnose say so.

### 5.3 MCP
- `MINIS_MCP_PROXY` = `http://mcp:<pw>@127.0.0.1:<http>` whenever the HTTP
  front listens (also for a direct MCP route, so the entry applies the mcp
  tag); absent otherwise. `minis-mcp-cli` then uses it for every HTTP MCP
  request and OAuth refresh and ignores the shell's proxy variables; a
  server on loopback is never proxied. stdio MCP servers do no networking of
  their own.

### 5.4 Backup (rclone)
- `HTTPProxy` = `socks5://backup:<pw>@127.0.0.1:<socks>` (HTTP backends) and
  `socks_proxy` = `backup:<pw>@127.0.0.1:<socks>` for SFTP and FTP (set like
  `--sftp-socks-proxy`, a remote's own value wins), both only while the
  backup tag has an endpoint; cleared otherwise. A change clears rclone's fs
  cache. SMB: direct (no proxy option in rclone; an unauthenticated local
  forwarder was rejected).

---

## 6. Logs [same]

Prefix `[Net]` then a component: `[Entry]` `[Policy]` `[Proxy]` `[Dial]`
`[Session]` `[Shell]` `[Xparent]` `[Browser]` `[Backup]` `[TS]` `[Alert]`
`[Recovered]` `[Badge]` `[Diag]`. Required lines:
- every settings apply: `[Net] applied routing=on|OFF tailscale=... entry=<port|off> default=<route> proxies=N providerRoutes=N`;
- each session / client built for a tag: tag, generation, `via=direct` or `via=entry 127.0.0.1:<port> route=<route>`;
- each routed connection's decision (rate-limited) and **every** failure:
  `FAIL stage=<stage> via=<exit> target=<host:port> class=<class> after <ms>ms tag=<tag>: <error>`.

Stages: `direct`, `tailnet`, `proxy-connect`, `proxy-tls`, `proxy-handshake`,
`proxy-target`. Classes: `dns`, `refused`, `timeout`, `unreachable`, `tls`,
`proxy-auth`, `proxy-rejected`, `closed`, `other`.

Never logged: the entry password, proxy passwords, Tailscale auth keys and
sign-in URLs.

A proxy or Tailscale failing 3 connections in a row raises an alert
(`[Net][Alert]`, a banner that opens that setting); the first success after
it logs `[Net][Recovered]`.

---

## 7. Diagnose [same items, may differ in order]

Each item: `{name, status, detail, ms}`, status `ok` | `warn` | `fail` | `skip`.
Items: `settings`, `platform`, `os-network`, `runtime`, `entry` (SOCKS self
test), `http entry` (password check and a tunnel), one per upstream proxy
(CONNECT to a fixed target), `dns`, `direct` probe, Tailscale state /
MagicDNS / peer ping, the shell's transparent forwarding (hook, counters),
and explicit `skip` items for what is not routed (shell UDP/DNS, inbound,
ping, WebView without ProxyController, iOS 16 app requests). The copied
report is redacted (no passwords, keys or sign-in URLs).
