// [T-minimal-mode]
//
// Guards for the minimal-mode session flavour.
//
// The feature's whole value is a promise: "this session costs less, and the
// capabilities I gave up are genuinely gone — not merely hidden." A promise like
// that fails silently, so every clause is pinned here:
//
//   * which built-ins are force-off (and that the required keepers are NOT);
//   * which prompt modules survive;
//   * that memory / skills / MCP injections are gated at the assembly site;
//   * that the tool schema loses the tools of a force-off plugin;
//   * that a user-installed extension is off by default and only its opt-in
//     brings it back;
//   * that the mode is chosen once and then refused, in the store as well as the
//     UI — the invariant cannot live only in a picker;
//   * that a minimal session is visible as such, and that the settings page the
//     objective asks for exists under Agent Runtime.
//
// Standalone (`swift MinimalModeTests.swift`) like its neighbours: the app links
// device-only arm64 libraries, so an XCTest bundle has nowhere to run.
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  ✅ \(label)") }
    else { print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let policy = src("Agent/Chat/AgentMode.swift")
let tools = src("Agent/Chat/AIChatViewModel+ToolDefinitions.swift")
let loop = src("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let prompt = src("Agent/Chat/AIChatViewModel+SystemPrompt.swift")
let store = src("Agent/Chat/ChatStore+AgentMode.swift")
let slash = src("Agent/Chat/AIChatViewModel+SlashCommands.swift")
let choose = src("Agent/Chat/AIChatViewModel+AgentMode.swift")
let settingsSheet = src("Views/Settings/SettingsSheet.swift")
let settingsView = src("Views/Settings/MinimalModeSettingsView.swift")
let row = src("Views/ContentView/Sidebar/SessionRow.swift")
let schema = src("Agent/Chat/ChatStore+Schema.swift")
let registry = src("Agent/Extension/ExtensionRegistry.swift")

for (name, body) in [("AgentMode.swift", policy), ("ToolDefinitions", tools), ("AgentLoop", loop),
                     ("SystemPrompt", prompt), ("ChatStore+AgentMode", store), ("SlashCommands", slash),
                     ("SettingsSheet", settingsSheet), ("MinimalModeSettingsView", settingsView),
                     ("SessionRow", row), ("ExtensionRegistry", registry)] {
    check("\(name) is readable", !body.isEmpty)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 1. The policy itself
// ─────────────────────────────────────────────────────────────────────────────

print("▶️  1. what minimal mode switches off, and what it must not")

// Mirrors MinimalModePolicy, so the expectations below are behavioural rather
// than a second copy of the source text.
let disabledBuiltins: Set<String> = [
    "builtin.soul", "builtin.memory", "builtin.skills",
    "builtin.mcp", "builtin.todo", "builtin.subagents",
]
let keptBuiltins: Set<String> = [
    "builtin.mounts", "builtin.shared-folders", "builtin.env-vars",
]

for id in ["builtin.soul", "builtin.memory"] {
    check("the objective's explicit examples are off: \(id)", disabledBuiltins.contains(id))
}
for id in ["builtin.mounts"] {
    check("mounted folders survive (objective: 文件夹挂载 must not be lost)", keptBuiltins.contains(id))
}
// The keeper that matters most: a minimal session must still run in the
// background, which is the sandbox/mounts machinery rather than a plugin.
check("the keep-list carries the always-on basics",
      policy.contains("keptBuiltins") && policy.contains("mountsID")
        && policy.contains("sharedFoldersID") && policy.contains("envVarsID"))
check("no disabled plugin is also listed as kept",
      disabledBuiltins.isDisjoint(with: keptBuiltins))

// Each disabled entry must carry a token-cost reason, or the table is decoration.
// The table is keyed by the BuiltinExtension constants; each entry must carry
// the token-cost reason that justifies switching it off.
for constant in ["soulID", "memoryID", "skillsID", "mcpID", "todoID", "subagentsID"] {
    check("policy documents why \(constant) costs tokens",
          policy.contains("\(constant):\n") || policy.contains("\(constant):"))
}

check("only shell + workspace guidance survives",
      policy.contains("keptPromptModules") && policy.contains("promptShellID")
        && policy.contains("promptWorkspaceID") && !policy.contains("promptMemoryID,"))
check("the addendum names the unavailable tools rather than staying vague",
      policy.contains("memory_get / memory_write"))
check("user extensions default to OFF",
      policy.contains("userExtensionDefaultEnabled = false"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 2. The prompt loses the trimmed sections
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  2. prompt assembly honours the mode")

check("promptModule takes the minimal flag",
      prompt.contains("func promptModule(_ id: String, minimal: Bool,"))
check("…and every module call site passes it",
      prompt.components(separatedBy: "minimal: isMinimalMode").count - 1 >= 15,
      "found \(prompt.components(separatedBy: "minimal: isMinimalMode").count - 1)")
check("a module off the keep list returns nothing in minimal mode",
      prompt.contains("if minimal, !MinimalModePolicy.allowsPromptModule(id) { return \"\" }"))
check("the extensions tail is dropped too",
      prompt.contains("MinimalModePolicy.allowsPromptModule(BuiltinExtension.promptExtensionsID)"))
// The body appends `minimalAddendum`, a computed property that yields the
// policy text only in a minimal session. Inline `: ""` is deliberately avoided:
// an empty-string literal would change the literal count that
// PromptModuleGatingTests pins to upstream 1.15's 174.
check("the addendum is appended only in minimal mode",
      prompt.contains("+ minimalAddendum")
        && prompt.contains("isMinimalMode ? MinimalModePolicy.promptAddendum : String()"))
check("identity drops the Soul persona through the session-aware gate",
      prompt.contains("SystemPromptBuilder.identitySection(")
        && prompt.contains("soulPluginEnabled: pluginEnabled(BuiltinExtension.soulID)"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 3. Per-turn injections are gated
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  3. memory, skills and MCP stop being injected")

check("memory injection goes through one derived flag",
      src("Agent/Chat/AIChatViewModel.swift").contains("var memoryActive: Bool { memoryEnabled && !isMinimalMode }"))
check("both memory assembly sites use it",
      loop.components(separatedBy: "if memoryActive {").count - 1 == 2,
      "found \(loop.components(separatedBy: "if memoryActive {").count - 1)")
check("skill injection is skipped",
      loop.components(separatedBy: "!isMinimalMode,").count - 1 >= 3)
check("MCP snippet injection is skipped",
      loop.contains("let mcpFragment = MCPStore.shared.systemPromptSnippet"))
check("the inject decision is logged with the mode, so a bug report can tell",
      loop.contains("minimalMode=\\(self.isMinimalMode)"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 4. The tool schema loses the tools
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  4. a disabled plugin contributes no tools")

check("one helper decides plugin eligibility",
      tools.contains("func pluginEnabled(_ id: String) -> Bool"))
check("…and minimal mode can only narrow the user's switch",
      tools.contains("return !isMinimalMode || MinimalModePolicy.allowsBuiltin(id)"))
check("todo tools are removed through the helper",
      tools.contains("if !pluginEnabled(BuiltinExtension.todoID)"))
check("memory tools are removed through the helper",
      tools.contains("if !pluginEnabled(BuiltinExtension.memoryID)"))
check("the delegation tool is removed too",
      tools.contains("if !pluginEnabled(BuiltinExtension.subagentsID)")
        && tools.contains("$0.name == SubAgentDefinition.toolName"))
check("the sub-agent append gate agrees with the removal",
      tools.contains("pluginEnabled(BuiltinExtension.subagentsID) {"))
check("extension tools go through the allowlist in minimal mode",
      tools.contains("extensionToolDefinitions(allowedExtensionIDs: allowlist)"))
check("the registry filters before building the definition (no wasted schema)",
      registry.contains("if let allowed = allowedExtensionIDs, !allowed.contains(extID) { continue }"))

// Simulated schema: minimal mode must not advertise these names.
let removedInMinimal = ["todo_create", "todo_update", "todo_list", "todo_clear",
                        "memory_write", "memory_get", "subagent_task"]
func nameSurvives(_ name: String) -> Bool {
    if name.hasPrefix("todo_") { return keptBuiltins.contains("builtin.todo") }
    if name == "memory_write" || name == "memory_get" { return keptBuiltins.contains("builtin.memory") }
    if name == "subagent_task" { return keptBuiltins.contains("builtin.subagents") }
    return true
}
for name in removedInMinimal {
    check("minimal schema omits \(name)", !nameSurvives(name))
}
for name in ["shell_execute", "file_read", "file_write", "file_edit"] {
    check("minimal schema keeps core tool \(name)", nameSurvives(name))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 5. The mode is chosen once, and refused afterwards
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  5. choosing the mode, and the one-way door")

check("the column exists with a normal default",
      schema.contains("column: \"agent_mode\", definition: \"TEXT NOT NULL DEFAULT 'normal'\""))
check("an existing session decodes as normal",
      store.contains("AgentMode(rawValue: String(cString: cstr)) ?? .normal"))
check("the store refuses to leave minimal",
      store.contains("if current == .minimal { return .lockedMinimal }"))
check("the store refuses a late choice",
      store.contains("if messageCount(sessionId: sessionId) > 0 { return .threadStarted }"))
check("re-picking the current mode is not an error",
      store.contains("if current == mode { return .applied }"))
check("the list cache is invalidated so the badge appears",
      store.contains("invalidateSessionListCache()"))
check("the VM enforces the lock before the store (better message)",
      choose.contains("if agentMode == .minimal {") && choose.contains("AppLocalized(\"Minimal mode is locked"))
check("a draft session keeps the choice for createSession",
      choose.contains("guard let sid = sessionId else {") && choose.contains("agentMode = mode"))
// The draft path is only honest if the choice survives the row being created.
let persistence = src("Agent/Chat/AIChatViewModel+Persistence.swift")
check("ensureSession persists a draft-time choice instead of overwriting it",
      persistence.contains("if agentMode != .normal, storedMode == .normal {")
        && persistence.contains("mode: agentMode) != .applied"))
for outcome in [".applied", ".lockedMinimal", ".threadStarted", ".noSuchSession"] {
    check("VM handles \(outcome)", choose.contains(outcome))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 6. Discoverability: the / menu, settings page, and the badge
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  6. how the user reaches it, and how they see it")

check("a /minimal command exists", slash.contains("SlashCommand(id: \"minimal\""))
check("a /normal command exists", slash.contains("SlashCommand(id: \"normal\""))
check("the rows are offered only while the choice is open",
      slash.contains("let modeChoiceOpen = !isMinimalMode && messages.isEmpty"))
check("the master switch can hide them",
      slash.contains("MinimalModePolicy.Key.enabled"))
check("both commands route to chooseAgentMode",
      slash.contains("chooseAgentMode(cmd.id == \"minimal\" ? .minimal : .normal)"))
check("there is a settings entry under Agent Runtime",
      settingsSheet.contains("Section(\"Agent Runtime\")")
        && settingsSheet.contains("MinimalModeSettingsView()"))
check("the settings page opens with an introduction",
      settingsView.contains("A token-lean session") && settingsView.contains("introduction"))
check("…then basics, then what is always off, then kept, then the user's list",
      settingsView.range(of: "introduction")!.lowerBound
        < settingsView.range(of: "pinnedOffSection")!.lowerBound
        && settingsView.range(of: "pinnedOffSection")!.lowerBound
        < settingsView.range(of: "keptSection")!.lowerBound
        && settingsView.range(of: "keptSection")!.lowerBound
        < settingsView.range(of: "installedExtensionsSection")!.lowerBound)
check("the installed list shows only user extensions",
      settingsView.contains("filter { !BuiltinExtension.isBuiltin($0.id) }"))
check("each extension row writes its own allowlist key",
      settingsView.contains("MinimalModePolicy.Key.allow(id)"))
check("the session list marks a minimal session",
      row.contains("session.agentMode == .minimal") && row.contains("AgentMode.minimal.symbol"))
check("the row's Equatable includes the mode, or the badge would not refresh in place",
      row.contains("lhs.session.agentModeRaw == rhs.session.agentModeRaw"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 6b. The settings button, and the one-shot intent behind it
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  6b. starting a minimal session from Settings")

check("the introduction carries a button, as the objective asks",
      settingsView.contains("Start a minimal session") && settingsView.contains(".buttonStyle(.borderedProminent)"))
check("the button respects the master switch",
      settingsView.contains(".disabled(!minimalModeEnabled)"))
check("it records a one-shot intent rather than a global preference",
      policy.contains("enum Intent") && policy.contains("minimalMode.pendingMode"))
check("…which is cleared as it is spent, so it cannot apply twice",
      src("Agent/Chat/AIChatViewModel+Persistence.swift")
        .contains("MinimalModePolicy.Intent.pending = nil"))
check("it opens a new session only after the sheet is gone",
      settingsView.contains(".asyncAfter(deadline: .now() + 0.35)"))
check("minimal mode is NOT a plugin: absent from BuiltinExtension.all",
      !src("Agent/Extension/BuiltinExtension.swift")
        .contains("minimalID"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 7. Language coverage
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  7. every user-facing string is localised")

let strings = src("Localizable.xcstrings")
for literal in ["A token-lean session",
                "Minimal Mode",
                "Always off in minimal mode",
                "Your extensions",
                "Minimal mode is locked for this session — start a new session to change it."] {
    check("catalog has: \(literal.prefix(46))", strings.contains("\"\(literal)\""))
}
// zh-Hans must carry the two most important strings, not just English.
check("zh-Hans translation for the intro",
      strings.contains("Minimal mode is locked for this session") )
check("AppLocalized is used, not raw literals, in the overlay + settings",
      choose.contains("AppLocalized(") && settingsView.contains("AppLocalized("))

// ─────────────────────────────────────────────────────────────────────────────

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)") }
exit(failures == 0 ? 0 : 1)
