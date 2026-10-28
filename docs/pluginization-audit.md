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
