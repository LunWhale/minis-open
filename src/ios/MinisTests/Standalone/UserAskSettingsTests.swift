#!/usr/bin/env swift
// [T-user-ask] Settings defaults, the agent-side write rules, and the wiring
// of the user_ask tool into the app (shipping sources).
//
// [1] compiles the real UserAskSettings + UserAskCore blocks: defaults
//     (enabled, 5 min, notifications on), timeout clamping, and the launch-
//     time removal of the retired always-allow / auto-default keys
//     ([T-user-ask-no-policy]).
// [2] pins the wiring: minis-config fields and their one-way guards, tool
//     exposure (setting AND interactive run), the two prompt fragments, the
//     dispatcher, Stop / new-message hooks, recovery, notification routing,
//     and every setNotificationCategories caller going through the registry.
//
// Run: swift UserAskSettingsTests.swift   (needs swiftc)
import Foundation

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

let settingsSrc = source("Agent/Chat/UserAskSettings.swift")
let coreSrc = source("Agent/Chat/UserAskCore.swift")
guard let settingsBlock = between(settingsSrc, "// BEGIN UserAskSettings", "// END UserAskSettings"),
      let coreBlock = between(coreSrc, "// BEGIN UserAskCore", "// END UserAskCore") else {
    print("❌ blocks not found"); exit(1)
}

let harness = #"""
import Foundation
func R(_ k: String, _ v: Any) { print("R \(k)=\(v)") }
let d = UserDefaults(suiteName: "user-ask-settings-\(UUID().uuidString)")!
let s = UserAskSettings.load(d)
R("defaults", "\(s.enabled)|\(s.timeoutMinutes)|\(s.notifyInBackground)")
d.set(99999, forKey: UserAskSettings.timeoutMinutesKey)
R("clampHigh", UserAskSettings.load(d).timeoutMinutes)
d.set(-3, forKey: UserAskSettings.timeoutMinutesKey)
R("clampLow", UserAskSettings.load(d).timeoutMinutes)
d.set(false, forKey: UserAskSettings.enabledKey)
R("disabled", UserAskSettings.load(d).enabled)
R("nudgeDefault", UserAskSettings.load(d).textAskNudge)
d.set(true, forKey: UserAskSettings.textAskNudgeKey)
R("nudgeOn", UserAskSettings.load(d).textAskNudge)
// Old builds stored these; the launch purge must remove them and nothing else.
d.set(["git.push", "rm.tmp"], forKey: "agent.tools.userAsk.alwaysAllowRules")
d.set("options_and_medium_confirm", forKey: "agent.tools.userAsk.autoDefaultMode")
let purged = UserAskSettings.purgeLegacyKeys(d)
R("purge", "\(purged.sorted())|\(d.object(forKey: "agent.tools.userAsk.alwaysAllowRules") == nil)|\(d.object(forKey: "agent.tools.userAsk.autoDefaultMode") == nil)|\(d.object(forKey: UserAskSettings.enabledKey) != nil)")
R("purgeAgain", UserAskSettings.purgeLegacyKeys(d).count)
R("paths", [UserAskSettings.enabledPath, UserAskSettings.timeoutMinutesPath, UserAskSettings.notifyInBackgroundPath].joined(separator: ","))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-settings-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = [("core.swift", "import Foundation\n" + coreBlock), ("settings.swift", "import Foundation\n" + settingsBlock), ("main.swift", harness)]
for (n, t) in files { try t.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
print("1. Settings (shipping block)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
check("UserAskSettings + UserAskCore compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}
check("defaults: on, 5 min, notify on", r["defaults"] == "true|5|true")
check("timeout clamped to 0…1440", r["clampHigh"] == "1440" && r["clampLow"] == "0")
check("text-ask nudge: off by default, on when the key is set", r["nudgeDefault"] == "false" && r["nudgeOn"] == "true")
check("the switch can be turned off", r["disabled"] == "false")
check("launch purge removes the old always-allow rules and auto-default mode (only those)",
      r["purge"] == #"["agent.tools.userAsk.alwaysAllowRules", "agent.tools.userAsk.autoDefaultMode"]|true|true|true"#)
check("the purge is a no-op once done", r["purgeAgain"] == "0")
check("config paths live under agentTools.userAsk.*",
      r["paths"] == "agentTools.userAsk.enabled,agentTools.userAsk.timeoutMinutes,agentTools.userAsk.notifyInBackground")

print("\n2. Wiring")
let builtins = source("Shared/Config/ConfigRegistry+Builtins.swift")
let reg = between(builtins, "static func registerAgentTools(into r: ConfigRegistry) {", "\n    }\n") ?? ""
check("registerAgentTools is called by registerBuiltins", builtins.contains("        registerAgentTools(into: r)\n"))
check("three fields registered", ["enabledPath", "timeoutMinutesPath", "notifyInBackgroundPath"]
      .allSatisfy { reg.contains("path: UserAskSettings.\($0)") })
// [T-user-ask-no-policy] No auto-default mode, no always-allow rules: in the
// settings model, minis-config, the Settings page or the center.
check("no auto-default / always-allow anywhere (settings, minis-config, Settings page, center)",
      !settingsSrc.contains("var autoDefaultMode") && !settingsSrc.contains("autoDefaultModeKey") && !settingsSrc.contains("var alwaysAllowRules")
      && !settingsSrc.contains("func addAlwaysAllow") && !settingsSrc.contains("func isAlwaysAllowed")
      && !reg.contains("autoDefaultMode") && !reg.contains("alwaysAllowRules")
      && !source("Views/Settings/ToolsSettingsView.swift").contains("If there is no answer")
      && !source("Views/Settings/ToolsSettingsView.swift").contains("Always Allowed")
      && !source("Agent/Chat/UserAskCenter.swift").contains("AlwaysAllow"))
check("the center purges the legacy keys at start", source("Agent/Chat/UserAskCenter.swift").contains("let purged = UserAskSettings.purgeLegacyKeys()"))
// Answering from the notification and hiding the question used to be
// settings; they are fixed behaviour now (actions always on where the ask
// allows them, the question always in the body - the lock screen follows
// iOS's own preview setting). No dead field may come back.
let retired = ["notifyActionsEnabled", "notifyHideContent"]
check("retired notification options are gone from the model and minis-config",
      retired.allSatisfy { !settingsSrc.contains($0) && !builtins.contains($0) })
let toolsView = source("Views/Settings/ToolsSettingsView.swift")
check("Settings shows only on/off, wait, notify-in-background",
      !toolsView.contains("Answer from the notification") && !toolsView.contains("Hide the question in notifications")
      && toolsView.contains("Toggle(isOn: $userAskNotify) {\n                    Text(AppLocalized(\"Notify when in the background\")).padding(.leading, Self.subRowIndent)")
      && toolsView.contains("Text(AppLocalized(\"Wait for an answer\")).padding(.leading, Self.subRowIndent)")
      && toolsView.contains("static let subRowIndent: CGFloat = toolIconColumn + toolIconSpacing")
      && !retired.contains { toolsView.contains($0) })
let catalog = source("Localizable.xcstrings")
check("their strings are removed from the catalog",
      !catalog.contains("\"Answer from the notification\" : {") && !catalog.contains("\"Hide the question in notifications\" : {"))
check("timeout 0…1440 with 0 = wait indefinitely", reg.contains("min: 0, max: UserAskSettings.maxTimeoutMinutes") && reg.contains("zeroLabel: \"Wait indefinitely\""))

let ext = source("Agent/Chat/AIChatViewModel+UserAsk.swift")
let vm = chatViewModelSource()
let defs = source("Agent/Chat/AIChatViewModel+ToolDefinitions.swift")
check("exposure: setting off or a sub agent → no tool",
      ext.contains("guard UserAskSettings.load().enabled else { return (false, false, \"setting off\") }")
      && ext.contains("if isHelper { return (false, false, \"sub agent\") }"))
// [T-user-ask-deferred] REPORT §5.1A: runs no one can answer get the tool in
// deferred mode instead of no tool (and a prompt that said to ask in prose).
check("exposure: silent / programmatic / background-started runs → tool in DEFERRED mode",
      ext.contains("if programmaticSilentTurn { return (true, true, \"silent programmatic turn\") }")
      && ext.contains("if let origin = programmaticTurnOrigin { return (true, true, \"programmatic turn (\\(origin.logLabel))\") }")
      && ext.contains("if !foreground { return (true, true, \"run started in background\") }")
      && ext.contains("return (true, false, \"interactive foreground run\")"))
check("exposure: the user's answer to a deferred card, app in foreground → a normal (waiting) ask",
      ext.contains("if programmaticTurnOrigin == .userAskAnswer, !programmaticSilentTurn, foreground {\n            return (true, false, \"answer to a deferred ask, app in foreground\")"))
check("decided once per run, before the tool list is built",
      vm.contains("let userAskDecision = computeUserAskExposure()\n        userAskExposedThisRun = userAskDecision.exposed\n        userAskDeferredThisRun = userAskDecision.deferred")
      && vm.range(of: "userAskExposedThisRun = userAskDecision.exposed")!.lowerBound < vm.range(of: "var tools = makeAgentTools()")!.lowerBound)
check("tool list: user_ask only when exposed", defs.contains("if userAskExposed {\n            tools.append(Self.userAskToolDefinition)"))
// [T-user-ask-prompt-consolidated] The tool switch gates every user_ask text:
// off (or a sub agent) means no line in the system prompt and no tool in the
// list; the rest of the text travels with the tool definition itself.
let core = source("Agent/Chat/UserAskCore.swift")
let sysPrompt = source("Agent/Chat/AIChatViewModel+SystemPrompt.swift")
check("system prompt: the only user_ask text is UserAskPromptText.systemPromptText(exposed:)",
      sysPrompt.contains("+ UserAskPromptText.systemPromptText(exposed: userAskExposed)")
      && !sysPrompt.contains("\"- user_ask") && !sysPrompt.contains("(user_ask)") && !vm.contains("\"- user_ask"))
let sysPromptCode = sysPrompt.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n").lowercased()
check("system prompt builder: no user_ask or question-card wording outside UserAskPromptText (case-insensitive, comments excluded)",
      !sysPromptCode.contains("user_ask") && !sysPromptCode.contains("question card"))
check("switch off → not exposed → no tool, no prompt line, no text-ask nudge, no deferred answer message",
      ext.contains("guard UserAskSettings.load().enabled else { return (false, false, \"setting off\") }")
      && defs.contains("if userAskExposed {\n            tools.append(Self.userAskToolDefinition)")
      && source("Agent/Chat/AIChatViewModel+AgentLoop.swift").contains("if UserAskSettings.load().textAskNudge, userAskExposed,")
      && source("Agent/Chat/UserAskCenter.swift").contains("guard UserAskDeferred.sendsAnswer(ask), UserAskSettings.load().enabled else {"))
check("no 'cannot ask' fragment any more (switch off and sub agents get no user_ask text)",
      !ext.contains("You cannot ask the user questions") && !ext.contains("userAskPromptFragment")
      && !sysPrompt.contains("userAskPromptFragment") && !core.contains("You cannot ask the user"))
check("tool description and schema come from one place",
      ext.contains("description: UserAskPromptText.toolDescription,")
      && ext.contains("\"questions\": AgentToolParam(type: .array, description: \"Required. 1-4 question objects, each with `type` and `question`.\""))
check("general tool-call style lines are the original text (no user_ask additions)",
      sysPrompt.contains("+ \"- When a tool exists for an action, use it directly instead of explaining what you plan to do or asking the user to confirm.\\n\"")
      && sysPrompt.contains("Only ask for clarification when genuinely ambiguous.\\n\\n\""))
check("deferred mode is explained only by the tool result (no system prompt paragraph)",
      !ext.contains("userAskDeferred ? \"\"\"") && !ext.contains("In this run user_ask does not wait"))
check("an empty call is told to call again with `questions`",
      core.contains("`questions` is required: call user_ask again with 1-4 question objects, each with `type` and `question`."))
check("calling user_ask when it is not in the run: a bare error, no guidance prose",
      source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift").contains("toolOutput = \"Error: user_ask is not available in this run.\""))
check("tool schema: nested questions array, 1-4, with default as a string",
      ext.contains("\"questions\": AgentToolParam(type: .array") && ext.contains("minItems: 1, maxItems: 4")
      && ext.contains("(name: \"default\", node: .string("))
check("timeout guidance is in the tool description only: nothing applied, `default` only a suggestion, only approved authorizes",
      core.contains("On timeout nothing was applied; a `default` there is only a suggestion: decide yourself and say the question timed out.")
      && core.contains("Only `approved` authorizes a confirm") && !ext.contains("scope_key") && !ext.contains("timeout_"))
check("the programmatic origin is recorded and cleared",
      source("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift").contains("programmaticTurnOrigin = origin")
      && vm.contains("programmaticTurnOrigin = nil  // [T-user-ask]"))
let tools = source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
// [T-user-ask-fallback] One hidden reminder when a run that has the tool ends
// with a decision asked in text, and has not used the tool.
let loopSrc = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let storeModels = source("Agent/Chat/ChatStoreModels.swift")
check("text-ask nudge: setting (default OFF), exposed, once per run, not after a user_ask call, not in a sub agent, clean endTurn only",
      loopSrc.contains("if UserAskSettings.load().textAskNudge, userAskExposed, !textAskNudgeSent, !userAskAskedThisRun,\n                   helperConfig == nil, stopReason == .endTurn, !canResume, !self.userDidCancel,\n                   UserAskTextAsk.endsWithDecisionRequest(assistantText) {")
      && loopSrc.contains("textAskNudgeSent = true")
      && settingsSrc.contains("static let defaultTextAskNudge = false"))
check("…a queued user message or the scheduled resume nudge goes first (checked before it)",
      loopSrc.range(of: "let endInjection = await injectQueuedPromptsAsNewTurn(")!.lowerBound < loopSrc.range(of: "UserAskTextAsk.endsWithDecisionRequest(assistantText)")!.lowerBound
      && loopSrc.range(of: "if scheduledResumeNudgeOwed, stopReason == .endTurn")!.lowerBound < loopSrc.range(of: "UserAskTextAsk.endsWithDecisionRequest(assistantText)")!.lowerBound)
check("the nudge is a hidden user row (never rendered) and an empty answer to it is not an error",
      storeModels.contains("static let internalUserNudgeTexts: [String] = [scheduledResumeNudgeText, userAskTextAskNudgeText")
      && storeModels.contains("\"<system-reminder>If you are waiting on the user to decide something, ask it with user_ask.</system-reminder>\"")
      && loopSrc.contains("&& !textAskNudgeSent")
      && loopSrc.contains("if UserAskSettings.load().textAskNudge, userAskExposed,"))
// [T-user-ask-deferred]
let centerSrc = source("Agent/Chat/UserAskCenter.swift")
let ppSrc = source("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
check("deferred call: no countdown, card begun as deferred, `deferred` result returned at once (no wait)",
      ext.contains("timeoutMinutes: deferred ? 0 : s.timeoutMinutes)")
      && ext.contains("if deferred { ask.deferred = true }")
      && ext.contains("UserAskCenter.shared.beginDeferred(record)")
      && ext.contains("let out = UserAskDeferred.toolResult(questionCount: request.questions.count)")
      && ext.range(of: "UserAskCenter.shared.beginDeferred(record)")!.lowerBound < ext.range(of: "await UserAskCenter.shared.wait(requestId: ask.requestId)")!.lowerBound)
check("center: a deferred ask is not in-process; a newer deferred card replaces an older one in the same chat",
      centerSrc.contains("if !r.ask.isDeferred { inProcess.insert(r.ask.requestId) }")
      && centerSrc.contains("for ask in older { dismiss(requestId: ask.requestId, reason: .replacedByNewAsk) }"))
check("center: the loop's delivery keeps a deferred record; Stop leaves a deferred card open; a new user message closes it",
      centerSrc.contains("if asks[rid]?.isDeferred == true, asks[rid]?.consumed == false { continue }")
      && centerSrc.contains("if reason == .stopped, ask.isDeferred { continue }"))
check("center: resolving a deferred ask hands it on — fills in the stored result, then sends a real answer as the next message",
      centerSrc.contains("} else if ask.isDeferred {\n            Task { @MainActor in await self.deliverDeferred(requestId: requestId) }")
      && centerSrc.contains("await Self.replaceToolResult(sessionId: sid, toolUseId: ask.toolCallId, output: json)")
      && centerSrc.contains("guard UserAskDeferred.sendsAnswer(ask), UserAskSettings.load().enabled else {")
      && centerSrc.contains("vm.submitProgrammaticPrompt(UserAskDeferred.answerMessage(ask), origin: .userAskAnswer,\n                                                  silent: false, bypassContextPrompt: true)"))
check("center: recovery restores a pending deferred card and hands on an answered one",
      centerSrc.contains("case .deliverDeferred:") && centerSrc.contains("await deliverDeferred(requestId: rid)"))
check("the answer's origin is not gentle: it reaches a running loop like a user message",
      ppSrc.contains("case userAskAnswer") && ppSrc.contains("let gentle: Bool = { if case .job = origin { return true } else { return false } }()"))
check("a turn that ends silently after a deferred card is not an \"empty response\" error",
      loopSrc.contains("&& !(userAskDeferred && userAskAskedThisRun) {"))
check("the card labels a replaced deferred ask",
      source("Views/Chat/UserAskCardView.swift").contains("case .replacedByNewAsk?: s = AppLocalized(\"Replaced by a newer question\")"))
// [T-user-ask-observe]
check("tool-call assistant rows carry the model that wrote them (per-model counts of tool use)",
      loopSrc.contains("let deferredAssistantRaw = await buildRawMessage(assistantMessage, thoughtSignatures: sigMap,\n                                                             modelEntryId: activeEntryId)"))
check("one [UserAsk] turn-end line per finished run: exposed / asked / textAsk / nudged / origin",
      loopSrc.contains("logger.info(\"[UserAsk] turn-end exposed=\\(userAskExposed) asked=\\(userAskAskedThisRun) textAsk=\\(UserAskTextAsk.endsWithDecisionRequest(assistantText)) nudged=\\(textAskNudgeSent)"))
check("Usage stats still count only rows with token usage (tool rows have none), so model_id on them changes no total",
      source("Agent/Chat/ChatStore+UsageStats.swift").components(separatedBy: "m.token_usage IS NOT NULL").count - 1 >= 2)
check("a user_ask call in the run counts as asked; reset per run",
      source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift").contains("userAskAskedThisRun = true  // [T-user-ask-fallback]")
      && loopSrc.contains("userAskAskedThisRun = false  // [T-user-ask-fallback]"))
check("dispatcher: user_ask case, refused when not exposed",
      tools.contains("case UserAskTool.name:") && tools.contains("guard userAskExposed else {")
      && tools.contains("let askResult = await executeUserAsk(args: toolArgs, toolUseId: tu.id, msgIdx: msgIdx, blockIdx: blockIdx)"))
check("the snapshot is persisted before the card / notification (begin before wait)",
      ext.range(of: "UserAskCenter.shared.begin(record)")!.lowerBound < ext.range(of: "await UserAskCenter.shared.wait(requestId: ask.requestId)")!.lowerBound
      && vm.contains("currentBatchAssistantRaw = deferredAssistantRaw"))
check("delivered answers drop their records after the batch is persisted",
      vm.contains("if !askIds.isEmpty { UserAskCenter.shared.markDelivered(toolUseIds: askIds) }"))
check("Stop ends the wait", vm.contains("        cancelPendingUserAsk()\n        userDidCancel = true"))
check("a new user message supersedes the pending question (not job prompts)",
      source("Agent/Chat/AIChatViewModel+Misc.swift").contains("if !silent && !deferUntilIdle {\n            supersedePendingUserAsk()"))
check("no Resume banner while a restored question waits",
      source("Agent/Chat/AIChatViewModel+Persistence.swift").contains("} else if UserAskCenter.shared.hasPendingAsk(inSession: sessionId) {"))
let center = source("Agent/Chat/UserAskCenter.swift")
check("wait is cancellation-aware (Stop resolves it as stopped)",
      center.contains("withTaskCancellationHandler") && center.contains("dismiss(requestId: requestId, reason: .stopped)"))
check("wall-clock tick resolves expired asks (also after suspension)", center.contains("for ask in asks.values where ask.isExpired(at: now) { resolveTimedOut(requestId: ask.requestId) }"))
check("recovery: scan on launch and on becoming active",
      source("AppDelegate.swift").contains("await UserAskCenter.shared.recoverAll()") && center.contains("Task { @MainActor in await self.recoverAll() }"))
check("recovery is idempotent by toolCallId (checks the transcript first)",
      center.contains("if await Self.toolResultExists(sessionId: sid, toolUseId: ask.toolCallId) {"))
check("swiping the notification away does not resolve the ask",
      center.contains("if action == UNNotificationDismissActionIdentifier { return .handled }  // swiped away: keep waiting"))
check("notification text input is an answer, not a dismissal", center.contains("// An answer typed into the notification — not a dismissal"))
check("Allow once requires unlocking; every confirm, any risk, uses the one confirm category",
      coreSrc.contains(".init(id: actionAllow, title: titles.allow, requiresAuthentication: true)")
      && coreSrc.contains("case .confirm:\n            return confirmCategory")
      && !coreSrc.contains("confirmHighCategory"))
check("notify-in-background off posts nothing; on, the body is always the question",
      center.contains("guard s.notifyInBackground, ask.state == .pending, !ask.isExpired(at: Date()),\n              let index = UserAskNotificationPlan.notifiedIndex(ask) else { return }")
      && center.contains("content.body = Self.notificationBody(ask)")
      && !center.contains("content.body = AppLocalized(")
      && center.contains("let categoryId = UserAskNotificationPlan.categoryId(for: ask)\n"))
check("the lock-screen placeholder still follows iOS's preview setting",
      center.contains("hiddenPreviewsBodyPlaceholder: AppLocalized(\"A question is waiting for your answer\")"))
let delegate = source("Agent/Intents/SendPromptIntent.swift")
check("the notification delegate routes user_ask responses first",
      delegate.contains("if userInfo[\"userAskRequestId\"] != nil {") && delegate.contains("UserAskCenter.shared.handleNotificationResponse(response)"))
let callers = ["Agent/Background/BackgroundKeepAliveManager.swift", "Agent/Intents/SendPromptIntent.swift",
               "Agent/Intents/ShortcutRunTracker.swift", "Shared/Config/Confirm/ConfigConfirmationGate.swift"]
check("every other feature registers categories through the shared registry (setNotificationCategories replaces the set)",
      callers.allSatisfy { let s = source($0); return s.contains("NotificationCategoryCenter.shared.register(") && !s.contains("center.setNotificationCategories(") })
check("in-process asks are never delivered by recovery (no duplicate tool_result)",
      center.contains("for (rid, r) in store.all() where waiters[rid] == nil && !inProcess.contains(rid) {")
      && center.contains("} else if !inProcess.contains(requestId), records[requestId] != nil {"))
check("a stopped / superseded ask is written but its run is not restarted",
      center.contains("guard ask.state == .answered || ask.state == .timedOut else {"))
check("the recommended option is preselected by the center (begin + each Next), not as an interaction",
      center.contains("Self.preselectRecommended(&r.ask, at: first)") && center.contains("Self.preselectRecommended(&ask, at: next)")
      && center.contains("ask.answers[index].selected = [0]")
      && !source("Views/Chat/UserAskCardView.swift").contains("preselectRecommended()"))
check("every question's answer category is registered when the ask begins, before any notification",
      center.contains("let specs = UserAskNotificationPlan.dynamicCategories(for: r.ask, otherTitle: AppLocalized(\"Other…\"))")
      && center.range(of: "specs.forEach { categoryRegistry.add($0) }")!.lowerBound < center.range(of: "logger.info(\"[UserAsk] BEGIN")!.lowerBound)
// [T-user-ask-notif-multi] Several questions, one notification at a time.
check("the notification names the question it shows, and its title starts with 🙋",
      center.contains("\"userAskQuestionIndex\": index]")
      && center.contains("content.title = \"\\(UserAskNotificationPlan.actionMarker) \\(title)\"")
      && source("Agent/Chat/UserAskCore.swift").contains("static let actionMarker = \"🙋\""))
check("an answer goes to the question shown; a stale one is ignored and the open question re-shown",
      center.contains("guard index == UserAskNotificationPlan.notifiedIndex(ask) else {")
      && center.contains("var a = ask.answers[index]")
      && center.contains("ask.setAnswer(a, at: index)\n        let outcome = ask.submit(index, now: Date())"))
check("after an answer the same notification moves on quietly (background only); the last one resolves",
      center.contains("case .advanced(let next):")
      && center.contains("if BackgroundKeepAliveManager.shared.userIsAway { postNotification(for: ask, sound: false) }")
      && center.contains("case .complete:\n            resolveAnswered(requestId: requestId, source: .notification)")
      && center.contains("content.sound = sound ? .default : nil"))
check("a freshly registered question category is in place before its notification posts",
      center.contains("if registeredDynamic {\n            center.getNotificationCategories {"))
check("cleanup removes every per-question category",
      center.contains("UserAskNotificationPlan.dynamicCategoryIds(requestId: requestId, questionCount: count))"))
check("the card renders for the new block kind and is never folded",
      source("Views/Chat/AssistantBlockView.swift").contains("case .userAskTool:\n            // [T-user-ask] The interactive question card.\n            UserAskCardView(block: block)")
      && source("Agent/MessageList/ToolFoldPlanner.swift").contains("case .info, .delegateTool, .userAskTool:"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
