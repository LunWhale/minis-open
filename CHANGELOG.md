# Changelog

All fork commits are listed here, newest first. The base is upstream
OpenMinis v1.10 (`9cf3a85`), rebased onto upstream v1.12 (`09fc199`).

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
  run viewing, Android terminal button, reactive theme manager, docs
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
