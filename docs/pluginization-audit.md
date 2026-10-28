# Pluginization audit — after the upstream 1.15 merge

Scope: what the fork's "everything is a plugin" promise still covers, and where
switching a plugin off leaves UI or capability behind.

Method: every finding below is a grep/search over `src/ios`, not a guess. The
commands are reproducible; where a count is quoted it is the number of hit sites.

Legend: **OK** = gated and verified · **FIXED** = was broken, repaired in this
merge · **OPEN** = still broken, needs work.

---

## 1. The 9 feature plugins

`BuiltinExtension`: `todoID`, `subagentsID`, `soulID`, `mcpID`, `mountsID`,
`memoryID`, `skillsID`, `envVarsID`, `sharedFoldersID`.

| Plugin | Settings row | Tool schema | Chat UI | Verdict |
|---|---|---|---|---|
| Todo | FIXED | FIXED | OPEN | tool + row gated; the todo panel still renders |
| Sub-agents | FIXED | OK (upstream never lost it) | n/a | complete |
| Soul | FIXED | n/a | FIXED | sidebar title now reads `activeDisplayName` |
| MCP | FIXED | n/a (MCP tools come from servers) | n/a | row gated |
| Mounts | FIXED | n/a | n/a | row gated |
| Memory | FIXED | FIXED | n/a | `memory_write`/`memory_get` removed from the schema |
| Skills | FIXED | n/a (skills are prompt context) | n/a | row gated |
| Env vars | FIXED | n/a | n/a | row gated |
| Shared folders | FIXED | n/a | n/a | row gated |

Detail on the two FIXED tool gates: upstream 1.15's schema builder kept only the
sub-agent gate (`AIChatViewModel+ToolDefinitions.swift:230`), so after the merge a
disabled Todo or Memory plugin still advertised `todo_*` / `memory_*` to the
model. Both are removed from the schema again, and the dispatcher guards in
`AIChatViewModel+ConcurrentTools.swift` stay as the mid-run half of the pair.

## 2. The 10 prompt modules — **OPEN**

`promptShellID`, `promptWorkspaceID`, `promptMemoryID`, `promptCodingID`,
`promptAppleID`, `promptMinisCLIID`, `promptEnvSecretsID`, `promptStyleID`,
`promptScheduledID`, `promptExtensionsID`.

These are the fork's headline feature: the system prompt split into switchable
pieces so unused guidance costs no tokens. **After the merge they are dead
switches.** Evidence:

```
grep -c 'builtinSwitchKey|isBuiltinEnabled' src/ios/Agent/Chat/AIChatViewModel+SystemPrompt.swift
→ 0
```

Upstream 1.15 rewrote the prompt as a single ~235-line concatenation with its own
inline `toolEnabled(.browser)` / `isAgentVisible` conditionals. Nothing reads the
10 plugin switches, so toggling "Prompt: Shell" in the Extensions page changes
nothing.

Why it was not fixed here: re-splitting upstream's rewritten prompt into the ten
modules is a content decision, not a mechanical edit — the 1.15 text changed
substantially, so the fork's old module bodies no longer match it. A rushed
re-wrap risks silently degrading the agent prompt, which is worse than a
documented gap. It needs a deliberate pass: read the 1.15 prompt, assign each
paragraph to a module, wrap, then diff the assembled prompt against 1.15's to
prove nothing was dropped.

Also note the UI consequence: the Extensions page still lists those ten switches
and lets the user edit their `promptText`. Until this is wired, that UI is
misleading.

## 3. Settings rows — no plugin leaves a row behind

`Views/Settings/SettingsSheet.swift` has 20 `NavigationLink`s. Eight are plugin
rows and all eight are gated with `.shown(...)` against `@AppStorage` mirrors of
the same keys `ExtensionStore` writes (a plain `ExtensionRegistry.builtinEnabled()
call would only re-evaluate on an unrelated rebuild).

Deliberately **not** gated — these are app settings, not agent capabilities:
Appearance, LLM Providers, Model Groups, Extensions itself, Storage, Permissions,
Logs, About, iCloud Sync, Tools, Usage, Backup, Face ID, Enhanced background.
Keeping Extensions always reachable means a plugin can never lock its own owner
out.

## 4. Features that are not plugins at all

Found while sweeping; each is a real "this costs tokens/UI but cannot be switched
off" case. None were addressed in this merge — listed so the decision is explicit
rather than accidental.

- **Tools → granular switches** (`Self.toolEnabled`) cover browser, agents and a
  few others. Shell, file_read/write/edit are always present. That is defensible
  (they are the product), but it means "minimal mode" can never get below them.
- **Backup / iCloud sync / Usage stats** — full settings pages with no plugin
  switch.
- **Voice (TTS/ASR), Always-on, Live Activities** — UI and background machinery
  that run regardless.
- **Browser** (`browser_use`) — has a tool switch but its settings/entry points
  are not tied to a plugin.
- **Scheduled tasks** (`minis-scheduled`) — the capability is wired through the
  prompt module `promptScheduledID`, which is the dead switch from §2.

## 5. Test-suite drift from upstream's file split

Upstream 1.15 deleted `Views/ContentView.swift`, `Views/Chat/AIChatView.swift` and
`SelectableMarkdownView.swift`, and split `AIChatViewModel.swift`. Several
standalone tests resolve source by literal path and therefore fail on a missing
file rather than on a behaviour change.

Passing: 290 of 317 standalone tests.

Pre-existing (not caused by this merge — they need UIKit, which the macOS
interpreter does not have): `ComposerPlaceholderWrapTests`, `VoiceToolbarLabelFitTests`.

Obsolete after the merge (test a fork implementation upstream superseded):
`ImageBudgetBase64Tests` — asserts the `BudgetImage.key` identity scheme the fork
added for [T-image-budget-identity]; upstream's 1.15 rewrite replaced it with
`Ref.position`, so the assertions no longer describe the code.

Needs a path update (each resolves a file upstream split):

```
AOJITTests                      ChatShareModelTests          CodexEmptyResponseReproTests
CodexModelDiscoveryTests        ConfigReadableTests          ContextMeasureOutboundTests
GeminiProviderFactoryChokepointTests  HistoryRebuildKeepsIdsTests  ImageCtxIosETests
ImagePipelineReproTests         ImageRealIosBTests           ImageRealIosCTests
ImageRealIosDTests              ModelsRefreshWindowTests     OffloadReadbackLoopTests
OffloadWriteIntegrityTests      ProviderQuotaTests           ResponsesReasoningPassbackTests
RetryPayloadAndIndexTests       SearchFolderPagesTests       ShortcutBackgroundTitleTests
SidebarRowLookupHangTests       ChatScrollActivityTests      NewChatDraftParkingTests
ScheduledActiveSessionTests
```

The general fix is one line per test: make the `src()`/`read()` helper fall back
to concatenating the split directory when the single file no longer exists.

## 6. Known limit: a repaired rootfs keeps bytes, not the guest's view

`RootfsManager.stashUserHome()` preserves `data/root` across the automatic
`meta.db` repair, but fakefs resolves paths through `meta.db`'s `paths` table and
the fresh database from the bundle has no rows for the restored files —
`fakefs_readdir` skips unregistered host entries and `fakefs_open` returns ENOENT.
So they are on disk and invisible in the guest shell. The log now says exactly
that instead of implying a restore. `/var/minis` (symlinked into
`Library/MinisChat/minis`, outside the rootfs) is the user data that genuinely
survives.
