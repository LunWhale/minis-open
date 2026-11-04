# Changelog

All fork commits are listed here, newest first. The base is upstream
OpenMinis v1.10 (`9cf3a85`), rebased onto upstream v1.12 (`09fc199`),
then merged with upstream v1.14 (`b4c0661`) and v1.15 (`6eda552`).

## [1.15] - 2026-10-31

Fork version 1.15, tracking upstream OpenMinis v1.15. Still **iOS only**.

### Merge upstream v1.15

18 commits, 2173 files (+376k/-64k), keeping every fork feature.

- **iOS 26 background execution.** Upstream's `BackgroundKeepAliveManager` grew
  from 1855 to 2874 lines and now uses `BGContinuedProcessingTask` — the iOS 26
  API that keeps a long agent run alive while showing a Live Activity. Settings →
  Agent Runtime → Enhanced Background exposes the opt-in switch (default off,
  iOS 26+ only), and `Info.plist` declares `com.openminis.app.continued.*`.
  This is the answer to iPad suspending long runs.
- Big files split upstream, and the fork's additions were ported into the new
  layout: `Views/ContentView.swift` → `Views/ContentView/**`,
  `Views/Chat/AIChatView.swift` → `Views/Chat/AIChatView/**`,
  `Agent/Chat/AIChatViewModel.swift` → `Agent/Chat/AIChatViewModel+*.swift`.
- `deps/ish` advanced to upstream's 1.15 pin (`0fd17a1`), which brings the AOJIT
  runtime; `deps/build_ish.sh` keeps the fork's patch replay and gains upstream's
  per-platform loop plus `build_aot.sh`.
- Android kept out, as the fork requires: 349 conflicting `src/android/**` paths
  plus `deps/proot` and the Android scripts stay deleted. `scripts/drop-android.sh
  --check` passes.

### Minimal mode (new)

A token-lean session flavour, modelled on DeepSeek Harness's Minimal preset
(2 tools, one short prompt, ~1k tokens of context):

- **2 tools**: `shell_execute` + `file_write`. File inspection goes through
  `cat`/`rg` in the shell.
- **Prompt replaced, not trimmed**: 1014 chars ≈ 254 tokens versus the normal
  prompt's 27101 ≈ 6775 — **24.7x** smaller.
- **Off**: persona (Soul), memory, skills, MCP, todo, sub-agents, and 8 of the 10
  prompt modules.
- **Kept, deliberately**: background execution, mounted folders, shared folders,
  environment variables.
- **Chosen once**: `/minimal` or `/normal` in a session that has no messages yet,
  or the "Start a minimal session" button in Settings. Once minimal, the session
  is locked — enforced in the view model, in `ChatStore.setAgentMode`, and by the
  message count, so a stale UI cannot write it either.
- **Marked**: a leaf badge in the sidebar; the mode travels through the session
  list, single-session reads and search results.
- Settings → Agent Runtime → Minimal Mode: introduction, the start button, the
  off/kept tables with reasons, and the user's own installed extensions (all off
  by default, opted in one at a time).

### Prompt modules wired to 1.15

The fork's pluginizable system prompt had become dead switches in the merge —
upstream rewrote the prompt as one 27 KB concatenation and nothing read the ten
module switches any more. Fixed by gating the sections upstream writes inline:

- 9 modules wrap 15 section runs; `promptExtensions` plus user-typed per-plugin
  guidance ride in a tail.
- **Contract**: with every module enabled and no override — the stock state —
  the assembled prompt is upstream 1.15's prompt **byte for byte** (174 ordered
  string literals, 27101 chars, enforced by `PromptModuleGatingTests`).
- A module's stored override still replaces its section, so modules stay
  editable exactly as before.

### Icons, versions, about

- All **13** app-icon variants are upstream 1.15's artwork rotated 180°, including
  the new `Icon-1024-Tinted.png`. The icon picker had been showing upstream's
  unflipped thumbnails, and the 1.14 merge had reverted the two 1024 icons.
- `MARKETING_VERSION` 1.15 / `CURRENT_PROJECT_VERSION` 5 across all 14
  configurations.
- About names the upstream base ("fork of OpenMinis 1.15"), because the fork
  tracks upstream numbering and the number alone cannot identify the codebase.

### Fixes carried in this release

- **"Kernel boot failed: -22"** no longer dead-ends. `-22` is `EINVAL` from
  `fake_db_init` failing to open `meta.db`; `isInstalled` used to answer from
  `data/` plus the `.arch` tag alone, so such a tree looked installed for ever.
  It now requires a usable database, replaces an unbootable tree, and the failure
  screen offers Reinstall Rootfs / Try Again. A merely unwritable database is
  reported rather than wiped.
- **Soul, Todo, Memory, sub-agent and extension gates** restored after upstream's
  split dropped them from the schema and the settings list.
- **Honest limit**: a repaired rootfs keeps `/root`'s bytes, but fakefs resolves
  through `meta.db`, so the guest shell does not list them. `/var/minis` is the
  user data that genuinely survives. The log says so.

### Fix: the iOS 26 background switch could never register (build 6)

`BGTaskSchedulerPermittedIdentifiers` is matched **literally** — a `*` is an
asterisk, not a wildcard — and `BGTaskScheduler.register` answers a non-permitted
identifier with an Objective-C exception Swift cannot catch, so the failure was a
crash rather than the `register` returning false the caller checked for.

This release shipped `com.openminis.app.continued.*` in the plist while the code
built `com.openminis.app.continued.` + a random UUID per request. The two could
never match, so the iOS 26 continued-processing switch did nothing, and any path
that reached registration could die instead of logging.

- One fixed identifier, `com.openminis.app.continued.run`, listed verbatim.
- Registered once per process (registering the same id twice is what kills the app);
  every later request reuses it.
- The plist is read and checked **before** registering, so a future mismatch is a
  warning line, never a crash.
- `BGTaskIdentifierTests` pins all of it: no wildcard in the list, the code's
  identifier present verbatim, no interpolated identifiers at any register call.

### Fix: the sandbox could not execute a single guest instruction (build 7)

Upstream 1.15 changed how iSH is compiled: `-Djit=true -Djit_emit=false`, an
**AOT-only** runtime that "never maps executable memory" and can only run code
from the AOT images linked into the app. Those images are ~1 GB of assembly and
are gitignored, so this tree has none — and `build_ish.sh` still built happily,
producing a 720-byte empty `libish_aot.a`.

The result is a runtime with neither a translator nor any pre-translated code:
`jit_init()` falls through to "running gadgets only" and no guest block can run.
That is a crash the instant the sandbox starts, which is exactly the three-dot
boot screen.

- `build_ish.sh` now decides from reality: AOT runtime only when
  `deps/aot/aot_*.S` exist, otherwise the plain interpreter — the configuration
  this fork shipped up to 1.14 and the one verified on device.
- `jit_control` / `jit_describe` are `weak_import` with NULL guards, so the
  interpreter build links and the AOJIT UI reports "unavailable" instead of
  calling through NULL.

Also in build 7: the BGTaskScheduler identifier fix from build 6 (a wildcard that
can never match, with an uncatchable ObjC exception behind it).

### Fix: run the guest with the plain interpreter (build 8)

Build 7 kept the JIT and merely re-enabled its run-time translator, which needs
**executable memory** — and a re-signed sideload has no JIT entitlement, so the
map fails and the runtime is left with neither a translator nor any AOT image.
Same dead end as build 5, which is why (7) still crashed at the boot screen.

Build 8 returns to the configuration this fork shipped up to 1.14, the only one
that needs no executable memory at all:

- `build_ish.sh` now builds `-Djit=false` (plain interpreter) when `deps/aot`
  holds no images, and only uses the AOT runtime when the images exist.
- `ISHJITStubs.c` supplies **weak** definitions of the three symbols the app
  references but an interpreter libish does not define — `jit_control`,
  `jit_describe`, `jit_crash_sync`. Weak, so an AOT/JIT build's strong
  definitions override them; `weak_import` alone was not enough, because a
  static archive linked straight into the executable still needs the symbol.
- Consequence: `in_jit` is always 0, so the JIT crash-recovery path can never be
  taken, and the AOJIT switch reports "unavailable" instead of pretending.

Verified in the shipped binary: `dual mapping` and `running gadgets only` — both
strings live in `jit.c` — are absent, i.e. no JIT code is linked at all.

### Fix: launch crash from a missing App Group (build 10)

The crash report named it exactly:

```
EXC_BREAKPOINT / SIGTRAP
0  libswiftCore  _assertionFailure
1  AIChatViewModel.minisAppGroupRoot.getter
2  AIChatViewModel.minisMemoryPersistentDir.getter
3  SoulStore.fileURL.getter
4  SoulStore.load()
5  SoulStore.refreshCache()
6  MinisApp.init()
```

`minisAppGroupRoot` and `minisConfigRoot` force-unwrapped
`containerURL(forSecurityApplicationGroupIdentifier:)`. That returns nil whenever
the binary is re-signed under a different bundle id — the report shows
`com.openminis.appp` — because the group `group.com.openminis.app` is then not
entitled. `MinisApp.init()` reaches it through `SoulStore.refreshCache()`, so the
process died before a single frame of UI, which is why in-app logs were never
reachable and why LiveContainer (which provides its own container) looked fine.

`SharedContainerStore.resolvedContainerRoot` — which already falls back to
`Library/AppGroupFallback` when the group is unavailable — is now the only way
that lookup happens. Both getters go through it, so a sideload with any bundle id
starts normally and simply loses the Files-app/FileProvider integration.

### App Group is now a single configuration point

The group id was a hardcoded literal in `SharedContainerStore` that also had to
appear in four entitlement files, with nothing connecting the five. It is now
documented as the one place to change, and `AppGroupFallbackTests` fails if any of
the five disagrees — so pointing a fork at its own group (an App Group identifier
is scoped to a developer TEAM, so a paid account can register
`group.com.openminis.app` itself, or any other name) cannot silently split the app
from its extensions.

A build-time `MINIS_APP_GROUP_ID` xcconfig key was attempted first and reverted:
the group also has to be baked into the entitlements, which Xcode substitutes from
build settings only at signing time, so a key that the runtime honoured but the
signature did not would have been worse than one honest constant.

### Docs and tests

- `docs/pluginization-audit.md`: what the plugin promise still covers, what it
  does not (the 10 prompt modules are now wired; below them, features that were
  never pluginized are listed explicitly), and a diagnosis of every failing
  standalone test.
- `MinimalModeTests` 102 checks, `PromptModuleGatingTests` 28, both green.
  Suite total 294 passing / 25 failing — all 25 are upstream-1.15 drift,
  itemised in the audit doc rather than silently updated.
- All keys in `Localizable.xcstrings` have zh-Hans and zh-Hant.

## [1.14] - 2026-09-13

### Fix: "Kernel boot failed: -22"

A rootfs whose fakefs database (`meta.db`) was missing or unreadable could
never boot again, and the UI offered no way out — it showed a full-screen
`Kernel boot failed: -22` and nothing else.

`-22` is `EINVAL`, and the only place in the iSH boot path that returns it is
`fake_db_init` (`deps/ish/fs/fake-db.c`) when
`sqlite3_open_v2(meta.db, ..., SQLITE_OPEN_READWRITE, NULL)` fails; every other
boot failure reports `-5`/`-2`/`-13`. The tree became unrecoverable because
`RootfsManager.isInstalled` answered from `data/` plus the `.arch` tag alone,
and `installIfNeeded()` *repairs* a missing tag in place — so a tree with no
`meta.db` looked installed for ever and the install never ran again. Nothing on
the C side can recreate the database (`fakefs_migrate` only applies schema
migrations; `fakefs_rebuild` copies out of the existing `paths`/`stats`
tables), so reinstalling from the bundled zip is the only fix.

- `isInstalled` now also requires a usable `meta.db` (present, non-empty,
  writable). A read-only file has its permissions repaired first — reinstalling
  destroys the user's guest files, so it stays the last resort.
- A tree whose database is merely *unwritable* is reported, not wiped: the tree
  is intact, and destroying `/var/minis` data to fix a chmod would be a
  disproportionate repair. Missing or empty is what triggers the automatic
  reinstall, because nothing can recreate those.
- The automatic reinstall now stashes `data/root` (the guest home directory) and
  restores it after the fresh install. `/var/minis` was already safe — its
  subdirectories are symlinks into `Library/MinisChat/minis`, outside the
  rootfs — but everything under `/root`, plus installed packages and `/etc`
  edits, was collateral damage of a repair the user never asked for. The stash
  is released by `defer`, so a failed unzip cannot abandon the only copy.
- A tree that is present but not bootable is **replaced**, not unzipped over:
  a fresh `meta.db` describes only the pristine paths, which would leave the
  user's later files on disk but invisible to the guest.
- The boot-failure overlay is no longer a dead end: it names the cause instead
  of printing an errno, and offers **Reinstall Rootfs** and **Try Again**.
- `fake_db_init` logs the database path, the sqlite reason and the host errno,
  and no longer leaves a closed handle behind for `fake_db_deinit` to re-close.

`MinisTests/Standalone/RootfsMetaDBBootabilityTests.swift` pins the whole chain:
that `-22` identifies one call site, that `sqlite3_open_v2` reproduces it on a
missing file, the five installed-check cases, and an end-to-end recovery of a
broken tree from the bundled zip.

Build 4.

### Merge upstream v1.14

Fork version bumped to 1.14 to track the upstream base (shown in About).
The merge brings in all of upstream's v1.13/v1.14 work while keeping every
fork feature.

**From upstream** (26 commits, 1339 files):
- iOS: agent/chat work, iCloud sync (V2), backup & restore to folders and
  rclone remotes (new `Rclone.xcframework` dependency), usage tracking,
  Shortcuts intents, localization (`AppLocalized`), scheduled jobs
  (`minis-scheduled`), and a new Sub Agents / Helper system.
- Providers: OAuth, thinking levels, voice, model routing.
- iSH: advanced to the upstream 1.14 source merge (68 commits beyond the
  fork's previous pin).

**Fork integration decisions**:
- `deps/ish` switched back to upstream's pin (`e6521d9c`): upstream has
  absorbed the fork's FCVTN/FCVTXN + `/proc/<pid>/mem` seek work, so the
  fork's own ish branch is no longer needed.
- Android support was removed entirely — see **iOS-only fork** below.
- Sub-agents: adopted upstream's Helper system (`subagent_task` +
  `HelperRunner` + `SubAgentStore`, with background runs, steering,
  resume, per-agent definitions). The fork's own `agent_delegate`
  implementation was retired. The "Sub-agent Delegation" plugin switch
  (Settings → Extensions) now gates upstream's tool instead.
- Plugin gating preserved throughout: Todo, Memory, Skills, MCP, Soul,
  mounts, environment variables, coding workflow and prompt modules still
  toggle from the Extensions manager; gating is wired into upstream's new
  code paths (prompt assembly, tool definitions, dispatch, settings UI).
- Fork UI fixes preserved: UIKit document picker (iOS 26 file-import fix),
  `DeferredPresentation` menu-dismissal fixes, fork branding in About.

### iOS-only fork

This fork ships **iOS only**. Everything Android was removed, and future
upstream merges must be followed by the same cleanup:

- **Removed**: `src/android/` (Kotlin/Compose app + JNI, 1190 files), the
  `deps/proot` and `deps/talloc` trees, `deps/build_proot.sh`,
  `deps/build_rclone_android.sh`, `scripts/prepare_android_sandbox.sh`,
  `scripts/check_android_locale.py`, `scripts/gen_debug_skill_android.sh`,
  the rclone `gomobile` binding, and `assets/badge-android.svg`.
- **Kept**: `src/shared/bashism/` — an iOS bundle resource referenced from
  `Minis.xcodeproj`, not an Android asset.
- **Docs**: `README`, `README-ZH`, `BUILDING.md`, `THIRD_PARTY_LICENSES.md`,
  `.gitignore` and the issue template no longer describe an Android build.
- **Future merges**: `scripts/drop-android.sh` re-applies the policy
  (`--check` fails if Android came back, `--dry-run` previews). See
  [BUILDING.md](BUILDING.md#ios-only-fork).
- Two standalone tests that diffed iOS against Android Kotlin sources
  (`OpenRouterVoiceCatalogTests`, `TurnLifecycleWireEdgeTests`) now assert the
  iOS side only.
- Build fixes surfaced by the merge: explicit type annotation in
  `DebugJSONRPC.swift` (type-checker timeout), `toolResult` pattern updated
  for upstream's 9th associated value, empty `Subagent` pbxproj group removed.

**Verification**: xcodebuild Debug (generic/platform=iOS) BUILD SUCCEEDED;
extension smoke tests 43/43 (JS) + 14/14 (Lua); About shows 1.14.

## [1.13.2] - 2026-09-13

### Plugin system: provider request interception + usability overhaul

App version bumped to 1.13.2 (shown in About). No other behavior change
for sessions without extensions.

Headline: plugins can now rewrite outgoing AI model requests — URL, method,
headers and body — from JS, for every provider (OpenAI-compatible, Gemini,
Antigravity, Anthropic). This removes the reason the OpenCode Go plugin
needed a local HTTP relay: a pure-JS interceptor can inject headers or point
requests at a different base URL directly. Interception requires the new
`requests` permission in the manifest; the first intercepted request asks
once and the grant persists across launches.

- `feat(extensions)`: `minis.api.request.intercept(handler)` registers a
  request interceptor; `unintercept(id)` and `clear()` remove them. The
  handler receives `{provider, model, sessionId?, url, method, headers,
  body?}`, may mutate it in place and/or return a patch
  (`{url, method, headers, body | bodyJSON}`), and may be async (Promise).
  Wired into `OpenAIProvider` (chat completions, responses API, raw
  passthrough, image gen/edit), `GeminiProvider`, `AntigravityProvider`,
  and the three Anthropic URLProtocols (`OAuthURLProtocol`,
  `EagerStreamingURLProtocol`, `DualAuthURLProtocol`). Non-UTF8/binary
  bodies are preserved byte-for-byte unless a handler patches `body`.
- `feat(extensions)`: permission grants now persist in UserDefaults
  (`ext.perm.<id>.<kind>`) instead of re-prompting every launch; denials
  stay session-only. Uninstalling an extension drops its grants.
- `fix(extensions)`: `minis.log` is variadic again — scalars, objects and
  arrays are stringified and joined (the old bridge crashed on anything
  that was not an array of strings). Handlers may use any arguments.
- `fix(extensions)`: command and tool handlers may return Promises; the
  host now awaits them instead of surfacing `"[object Promise]"`. Rejects
  surface as errors. Plain values keep working unchanged.
- `fix(extensions)`: `minis.api.ui` supports both `ui(data)` and the
  documented `ui.postMessage(data)` shape (demo widget tool used the
  latter and previously failed).
- `fix(extensions)`: file API (`read`/`write`/`list`/`delete`) resolves
  `/var/minis/**` through the real mount layer (App Group shared/memory/
  skills dirs, per-session workspace/attachments/offloads/browser buckets,
  external mounts) instead of a flat `Library/MinisChat/minis/` guess.
  New `minis.api.file.list` / `minis.api.file.delete`.
- `feat(extensions)`: `minis.http.fetch` forwards a `headers` object.
- `fix(extensions)`: extension slash-command rows in the `/` menu now fill
  the composer (tap was a no-op); typed commands accept args
  (`/ext-hello Alice` → `args = ["Alice"]`).
- `feat(extensions)`: lifecycle events `tool_call` (before dispatch, with
  args) and `tool_result` (after completion, with a bounded output
  preview) now fire alongside `agent_start` / `agent_end`.
- `feat(examples)`: new `examples/request-interceptor` (injects a header
  via `minis.api.request.intercept`; provider filter + enable toggle in
  settings). `examples/demo-extension` gains an async command, async tool,
  a file-API tool (`demo_notes`), and hooks for all four lifecycle events.
- `fix(tooling)`: `scripts/build_extension.sh` writes a compatibility
  manifest entry (`x/../manifest.json`) so archives load on installer
  builds that skipped the manifest; packaging now goes through python3
  zipfile (deterministic entry order, dotfiles excluded).
- `test(extensions)`: `scripts/extension-smoke/run.sh` compiles the real
  `ExtensionJSRuntime.swift` against test stubs and runs 43 checks across
  the runtime API and the shipped example plugins (including the
  opencode-go relay as a regression guard). `scripts/extension-smoke/run-lua.sh`
  does the same for the vendored Lua runtime (14 checks: positional shell
  args, the `api.file` table, settings, permission requests).
- `docs`: full rewrite of `docs/extensions.md` / `docs/extensions.en.md` —
  complete manifest reference, the full JS API (registration, events, host
  APIs, request interception, JavaScriptCore environment limits), permissions,
  lifecycle/debugging, common pitfalls, and a copy-paste **AI prompt template**
  for generating working plugins.
- `fix(ios)`: `ExtensionInstaller` writes `manifest.json` explicitly
  (future installs no longer depend on the compatibility entry).

## [0.3.0] - 2026-08-26

### Rebase onto upstream v1.12

- `e76904d` chore(ish): update submodule pin to `6d53973c` (untrack
  build-ios artifacts so a fresh clone is clean).
- `3b99464` fix(ish): restore the `make_fp_vec_cmp_zero` macro header that
a lost during the FCVT merge (build fix).
- `f5618c9` chore(ish): update `deps/ish` pin to `602e4e17` — a merge of
  upstream v1.12's fork-guard + FCVTL work and our FCVTN/proc-mem-seek.
- `bac5dad` docs: add `README-ZH.md`.
- Rebased the full fork history onto upstream v1.12 (`09fc199`), bringing
  in: iCloud backup/restore surface, memory-pressure fork guard (stalls
  guest fork under real memory pressure, bounded wait, fallback allows),
  ASIMD FCVTN/FCVTL/FCVTXN lane gadgets (numpy float casts), waitid
  `si_uid`, pids_lock release on malloc failure, skill empty-description
  refresh fix (GH#215), SessionBadgeStore, MemoryWriteRevoker, thinking
  rules, provider group slots, and 343 files of upstream improvements.
- `deps/ish` submodule now points at `LunWhale/ish-arm64`
  `feature/fcvt-arm64` (our fork of the upstream ish-arm64 fork), which
  carries both our FCVTN/proc-mem-seek and upstream's fork-guard/FCVTL.

## [0.2.0] - 2026-08-15

### Built-in plugins + per-extension settings

- `4691c11` fix: hide the "Sub-agent Roles" settings entry and gate the
  todo/sub-agent guidance sections in the system prompt when the
  corresponding built-in plugin is disabled. Same fix applied to the
  UIKit chat menu's "Todos in Session" row.
- `c1ea346` fix: skip built-in plugins in `ExtensionRegistry.reload` (they
  have no bundle to load, so they no longer log spurious errors).
- `c128fe1` feat: todo and sub-agents become default plugins. They are
  seeded into the extensions store as `builtin.todo` / `builtin.subagents`
  and can be turned off from the Extensions manager. Disabling a plugin
  removes its agent tools, blocks tool dispatch, hides its chat menu
  entries, and drops its system-prompt guidance. New per-extension
  settings surface: `settings` in the manifest, a gear button and
  settings form per extension, UserDefaults-backed persistence, and
  `minis.api.settings.get/set` in both the JS and Lua runtimes.

## [0.1.0] - earlier fork work (vs upstream v1.10)

### Extension system

- `733cbb9` feat: implement all documented `minis` APIs — store
  (get/set), `api.file.write`, `api.http.fetch` (network permission
  gated), `api.offload`, `api.ui.postMessage` — with zero placeholders.
- `886cb77` feat: vendored Lua 5.4 runtime (31 C files compiled in),
  extension event bus, debug log panel, `minis://extensions/debug` deep
  link, `/extensions` slash command, `examples/lua-demo`.
- `ebc6b62` fix: widget panel rendering from the chat menu, sub-session
  run viewing, terminal button, reactive theme manager, docs
  marked with real API status.
- `50a4742` fix: wire `registerCommand`/`on`, WebView widget host, theme
  application, terminal button.
- `3c03a23` feat: move demo-extension into the repo under `examples/`.
- `03b0388` feat: the `.minisx` extension system — manifest parser, zip
  installer, SQLite registry, JavaScriptCore runtime, extension manager.
- `51fe5d4` fix: make `minis.api.ui.postMessage` a real end-to-end
  broadcast (message center → widget coordinator → `window.minisBridge`),
  removing the previous no-op.
- `02166b6` feat: real Lua native bridges (`api.shell/file/permission`),
  bilingual extension docs, and an agent-to-widget demo tool.

### Todo, sub-agents, coding workflow

- `39560ee` feat: session-scoped todo system (SQLite-backed store, four
  agent tools, chat panel, system-prompt guidance).
- `b430b63` feat: sub-agent delegation — role presets, bounded runner
  (max 25 turns, 600s timeout), background/foreground modes, run history.
- `fa5e62a` feat: workspace context injection (`AGENTS.md`/`CLAUDE.md`
  into the agent prompt) and coding-norms guidance.
- `6a452cd` feat: `minis-toolchain` one-shot dev toolchain installer in
  the sandbox (bun/node/python/git/ripgrep), with npm/pip/apk mirror
  support.

### iSH kernel

- `5d8bfb2` chore: pin `deps/ish` to `39e5bace` (FCVTN/FCVTXN ARM64
  decoding, `/proc/<pid>/mem` seek) — needed for the coding toolchain.
- `e3f0f0c` chore: remove a dead `loaded` flag in `ExtensionRegistry`.

---

## Provenance

This fork's commits were authored by **deepseek-v4-flash** (a third-party
model, reached through a relay/proxy service) driving the **pi-agent**
coding harness. Each change went through an independent completion audit;
the audit's findings drove the fix commits in this history.
