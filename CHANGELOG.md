# Changelog

All fork commits are listed here, newest first. The base is upstream
OpenMinis v1.10 (`9cf3a85`), rebased onto upstream v1.12 (`09fc199`),
then merged with upstream v1.14 (`b4c0661`).

## [1.14] - 2026-09-13

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
