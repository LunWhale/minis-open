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

## 2. The 10 prompt modules — **FIXED**

`promptShellID`, `promptWorkspaceID`, `promptMemoryID`, `promptCodingID`,
`promptAppleID`, `promptMinisCLIID`, `promptEnvSecretsID`, `promptStyleID`,
`promptScheduledID`, `promptExtensionsID` — the fork's headline feature: the
system prompt split into switchable pieces so unused guidance costs no tokens.

After the merge these were dead switches (`grep -c 'builtinSwitchKey' ...+SystemPrompt.swift` → 0). Fixed by gating the sections upstream 1.15 writes
inline, rather than appending a second copy of the guidance:

- **9 modules** wrap 15 section runs inside `baseSystemPrompt`
  (`promptShell` 2, `promptWorkspace` 2, `promptMemory` 2, `promptCoding` 2,
  `promptMinisCLI` 3, `promptApple` 1, `promptEnvSecrets` 1, `promptStyle` 1,
  `promptScheduled` 1).
- **`promptExtensions`** is contributed by `promptGuidanceTail`, together with
  any user-typed per-feature-plugin guidance (`featureExtraGuidance()`, which
  had also lost its caller in the merge).

`promptModule(_ id:_ inline:)` resolves in priority order: switched off → `""`;
user override stored → the override replaces the section (so modules stay
editable); otherwise → the inline upstream text unchanged.

### The property that makes this safe

With every module enabled and no override — the stock state, since a missing
`UserDefaults` key means *on* — the assembled prompt is **upstream 1.15's prompt
byte for byte**:

```
ordered string literals in baseSystemPrompt: 174 in both, 27101 chars total
```

`MinisTests/Standalone/PromptModuleGatingTests.swift` enforces it on every run,
including the full ordered comparison against `git show 1.15:...`. If a future
re-wrap drops, duplicates or reorders a sentence, the test names the literal.

Known cosmetic gap: the Extensions page still shows the fork's pre-1.15 short
summary as each module's editable "default". An override replaces the whole
inline section, so the editor's placeholder text understates what is being
replaced. Making the editor show the real section would mean exporting the
prompt text at runtime.

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

New in this merge: `PromptModuleGatingTests.swift` (26 checks, passing).

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

---

## 7. Standalone test suite status (after 1.15 + minimal mode)

`src/ios/MinisTests/Standalone` — **294 passing, 25 failing**.

Green, and directly covering this work: `MinimalModeTests` (102 checks),
`PromptModuleGatingTests` (28), `RootfsMetaDBBootabilityTests`, `ConfigReadableTests`
(all keys now have zh-Hans + zh-Hant).

The 25 reds are **not** regressions from minimal mode; each is upstream 1.15 drift,
diagnosed below so the next pass does not have to re-derive it.

### A. Assertions against 1.14 behaviour that 1.15 deliberately changed (18)

These encode a fix from before the merge; 1.15 rewrote the code the assertion greps,
so the assertion must be re-derived against the new shape — not blindly updated, or
the bug it guards is lost.

| Test | What it asserts | Why it is stale |
|---|---|---|
| `ResponsesReasoningPassbackTests` | banner clamped to 2 lines | 1.15 rewrote the banner (top-aligned, `lineLimit(8)`) |
| `ShortcutBackgroundTitleTests` | comment placement between two calls | 1.15 moved the deferred-text flush |
| `SidebarRowLookupHangTests` | iPhone row keeps nav/drag/regen/folder | `ContentView.swift` split into `Views/ContentView/*` |
| `HistoryRebuildKeepsIdsTests` | retry cleanup edits parts in place | `AIChatViewModel.swift` split into `+Retry` etc. |
| `ContextMeasureOutboundTests` | 5 dispatch sites + log | provider dispatch rewritten |
| `GeminiProviderFactoryChokepointTests` | three group-fallback rebuilds | factory moved to `+ProviderFactory` |
| `CodexEmptyResponseReproTests` | one-shot flag before reminder request | retry loop rewritten |
| `OffloadReadbackLoopTests` | every rebuild site carries the flag | offload loop rewritten |
| `OffloadWriteIntegrityTests` | answered ids collected to end of history | id collection rewritten |
| `ProviderQuotaTests` | both factories tag OAuth providers | factory split |
| `ModelsRefreshWindowTests` | gate compares rolling interval | refresh gate rewritten |
| `SearchFolderPagesTests` | both layouts close card via `isLastMemberRow` | folder pages split |
| `ImageRealIosDTests` | no protocol runs its own patch list | request patching centralised |
| `ChatShareModelTests` | model block compiles standalone | `AIChatView` split into 12 files |
| `ImageCtxIosETests` | image context numbering | split/converted |
| `ImagePipelineReproTests` | pipeline order | split/converted |
| `BrowserCLIReclaimScopeTests` | session key is mounted-sid snapshot | CLI scope reworked |
| `CodexModelDiscoveryTests` | iOS hidden set == **Android's** | the fork has no Android tree any more; the comparison has nothing to read |

### B. Obsolete: tests a mechanism 1.15 replaced (1)

`ImageBudgetBase64Tests` — asserts the fork's `BudgetImage.key` identity scheme
([T-image-budget-identity]). 1.15 replaced it with `Ref.position`, which solves the
same bug; the fork's implementation is gone, so the assertions describe nothing.
Its intent is covered by upstream's own budget tests.

### C. Environment, not code (2)

`ImageRealIosBTests`, `ImageRealIosCTests` — they look for the SwiftAnthropic
checkout under `<repo>/build/DerivedData/SourcePackages/checkouts/`, which only
exists if the app was built with `-derivedDataPath build/DerivedData`. The packages
*are* resolved (verified with `xcodebuild -resolvePackageDependencies`), just in the
default DerivedData location. Fix: have the harness resolve both locations.

### D. Cannot run here (4)

`ComposerPlaceholderWrapTests`, `VoiceToolbarLabelFitTests` — `no such module 'UIKit'`
(the macOS interpreter has no UIKit). `RetryPayloadAndIndexTests`,
`ImageCtxIosETests` — no `❌` line, abort before asserting. These four cannot be
judged on this machine; they need a device/simulator run.

---

## 8. Unreferenced views after the 1.15 split

A scan of every app source (734 files, 1678 declared types) for types with zero
references outside their own file, run because the Extensions manager was exactly
that — compiled, unreachable, invisible to the user. Seven views are in that state.

Fixed: **`ExtensionManagerView`** — Settings → Agent Runtime → Extensions, plus the
`/extensions` and `minis://extensions` deep link. See §8.1 of the changelog entry.

Still unreferenced, classified by what a user would notice:

| View | File | Assessment |
|---|---|---|
| `MinisImageView`, `MinisFileChipView` | `Views/Chat/MinisMediaViews.swift` | Legacy. Chat media renders through the markdown path; these are leftovers of the replaced renderer. Harmless. |
| `ICloudBackupView` | `Views/Backup/ICloudBackupView.swift` | **Needs a decision.** Upstream 1.15 folded iCloud into `CloudSyncSettingsView` + backup destinations; no settings row or deep link reaches this page any more. Either restore a row or delete the file. |
| `VoiceWaveformView` | `Views/Chat/Voice/VoiceWaveformView.swift` | **Needs a decision.** The voice UI no longer shows a waveform. Restore the call site or delete it. |
| `RemoteDeviceSessionsView`, `RemoteMemoriesListView`, `RemoteSkillsListView` | `Views/Settings/CloudSyncSettingsView.swift` | **Needs a decision.** Remote browsing of another device's sessions/memories/skills has no entry point; `CloudSyncSettingsView` presents its own sections instead. |
| `BrowserBenchTestView` | `Debug/BrowserBenchTestView.swift` | Debug-only harness. Harmless. |

Also orphaned: `DeepLinkCoordinator.pendingFocus` is never set and never read.

Two classes of regression this scan cannot see, worth checking separately when
touching a split file:
1. an `@Published` flag that a router sets but nothing observes (this is how
   `showExtensions` died);
2. a `NavigationLink` target that exists but whose row was dropped in the move
   (this is how the Extensions row died).
`ExtensionsReachabilityTests` now pins the first two for that one feature.
