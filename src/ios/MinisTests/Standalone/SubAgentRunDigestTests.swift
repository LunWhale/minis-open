#!/usr/bin/env swift
// [T-subagent-detail-rich] The sub agent detail card in the "Minis Computer"
// sheet showed a title, a status, the model and the one tool running right
// now - nothing about what the sub agent was asked to do or how far it had
// got. It now adds, from data the app already holds: the task and context it
// was given (collapsed when long), summary chips (tool calls and their
// outcome, turns, tokens, time left of its budget), the last few tool calls
// with status and duration, what it last wrote, start / finish times, how the
// result is delivered, and - while it runs - a course correction and Stop.
//
// The rule this test guards: nothing is invented. A figure that cannot be
// read is absent, not zero and not a dash.
//
// [1] compiles the shipping digest block and runs it.
// [2] pins the wiring: where each fact is read from, and the order of the
//     card's sections.
//
// Run: swift SubAgentRunDigestTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.lowerBound..<rb.lowerBound])
}
func index(_ hay: String, _ needle: String) -> Int {
    hay.range(of: needle).map { hay.distance(from: hay.startIndex, to: $0.lowerBound) } ?? -1
}

let detail = source("Views/Chat/AIChatView/Sheets/SubAgentRunDetail.swift")
let card = source("Views/Chat/HelperBlockView.swift")
let digestBlock = between(detail, "// BEGIN SubAgentRunDigest", "// END SubAgentRunDigest")

// MARK: - 1. The shipping block

let scenario = #"""

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
typealias D = SubAgentRunDigest
func call(_ i: Int, _ tool: String, _ state: D.CallState, _ duration: TimeInterval? = nil, _ title: String = "") -> D.Call {
    D.Call(id: "c\(i)", tool: tool, title: title, state: state, duration: duration)
}

print("1a. Counting the tool calls")
var d = D()
check("a run that has done nothing is empty: no chips, no timeline", d.isEmpty && d.total == 0 && d.byTool.isEmpty && d.recent(8).isEmpty)
d.calls = [call(1, "shell_execute", .ok, 1.2), call(2, "file_read", .ok, 0.1), call(3, "shell_execute", .failed, 4),
           call(4, "browser_use", .ok, 9), call(5, "shell_execute", .ok, 0.4), call(6, "file_edit", .cancelled),
           call(7, "shell_execute", .running)]
check("total, succeeded, failed, cancelled and still running are counted apart",
      d.total == 7 && d.okCount == 4 && d.failedCount == 1 && d.cancelledCount == 1 && d.runningCount == 1)
check("the outcome counts add up to the total", d.okCount + d.failedCount + d.cancelledCount + d.runningCount == d.total)
check("split by tool: most used first, ties in order of first use",
      d.byTool.map(\.tool) == ["shell_execute", "file_read", "browser_use", "file_edit"] && d.byTool.map(\.count) == [4, 1, 1, 1])
check("recent calls: newest first, at most the limit", d.recent(3).map(\.id) == ["c7", "c6", "c5"] && d.recent(100).count == 7 && d.recent(0).isEmpty)
check("a call still running has no duration; a finished one keeps its own", d.recent(1).first?.duration == nil && d.calls[0].duration == 1.2)
check("not empty once anything is known", !d.isEmpty && { var t = D(); t.turns = 1; return !t.isEmpty }() && { var t = D(); t.latestText = "x"; return !t.isEmpty }())
check("tokens are shown only when some were counted", !d.hasTokens && { var t = D(); t.tokensOut = 5; return t.hasTokens }())

print("1b. Figures")
check("token counts: plain under 1000, one decimal to 10k, whole k after, M beyond",
      D.compact(0) == "0" && D.compact(950) == "950" && D.compact(1234) == "1.2k" && D.compact(9_950) == "9.9k"
      && D.compact(45_678) == "46k" && D.compact(999_400) == "999k" && D.compact(2_300_000) == "2.3M")
check("durations: tenths under 10 s, whole seconds, minutes and seconds, hours and minutes",
      D.durationLabel(0.84) == "0.8s" && D.durationLabel(9.94) == "9.9s" && D.durationLabel(12.4) == "12s"
      && D.durationLabel(75) == "1m 15s" && D.durationLabel(605) == "10m 05s" && D.durationLabel(3720) == "1h 2m")
check("a negative duration (clock skew) is not printed as one", D.durationLabel(-3) == "0s")

print("1c. The delegation's arguments")
let full = SubAgentTaskArgs.parse(#"{"tool_title":"Port HTTP client","task":"  Port pkg/http to Swift.\nKeep the API.  ","context":"See /tmp/goipa","max_minutes":25,"wait":true,"progress_report":"Moderate","agent":"LENS"}"#)
check("task, context, minutes, wait, progress level and agent are read; text is trimmed",
      full?.task == "Port pkg/http to Swift.\nKeep the API." && full?.context == "See /tmp/goipa" && full?.maxMinutes == 25
      && full?.wait == true && full?.progressReport == "moderate" && full?.agent == "LENS")
let bare = SubAgentTaskArgs.parse(#"{"task":"just do it"}"#)
check("only a task: everything else stays unknown, nothing is defaulted",
      bare?.task == "just do it" && bare?.context == "" && bare?.maxMinutes == nil && bare?.wait == nil
      && bare?.progressReport == nil && bare?.agent == nil)
check("minutes given as a number with a fraction are accepted", SubAgentTaskArgs.parse(#"{"task":"t","max_minutes":12.0}"#)?.maxMinutes == 12)
check("an unknown progress level is not shown as one", SubAgentTaskArgs.parse(#"{"task":"t","progress_report":"hourly"}"#)?.progressReport == nil)
check("a control call (status / cancel / steer) has no task: no task card",
      SubAgentTaskArgs.parse(#"{"action":"steer","job_id":"abc","message":"go left"}"#) == nil
      && SubAgentTaskArgs.parse(#"{"action":"status"}"#) == nil)
check("no arguments, broken JSON, a blank task: nil",
      SubAgentTaskArgs.parse(nil) == nil && SubAgentTaskArgs.parse("") == nil && SubAgentTaskArgs.parse("{not json") == nil
      && SubAgentTaskArgs.parse(#"{"task":"   "}"#) == nil && SubAgentTaskArgs.parse(#"["task"]"#) == nil)

print("1d. The time budget")
func minutes(_ recorded: Int?, _ requested: Int?, _ hasArgs: Bool) -> Int? {
    SubAgentTimeBudget.minutes(recorded: recorded, requested: requested, hasArgs: hasArgs, defaultMinutes: 10, maxMinutes: 60)
}
check("the run's own start record wins", minutes(25, 5, true) == 25 && minutes(25, nil, false) == 25)
check("else what was asked for, clamped like the runner: 1 to 60", minutes(nil, 30, true) == 30 && minutes(nil, 0, true) == 1 && minutes(nil, 500, true) == 60)
check("nothing asked for: the runner's default", minutes(nil, nil, true) == 10)
check("no record and no arguments: unknown - no number is made up", minutes(nil, nil, false) == nil && minutes(0, nil, false) == nil)
let start = Date(timeIntervalSince1970: 1_000_000)
check("time left counts down from the start", SubAgentTimeBudget.remaining(budgetMinutes: 10, startedAt: start, now: start.addingTimeInterval(125)) == 475)
check("... and goes negative once the budget is spent", SubAgentTimeBudget.remaining(budgetMinutes: 1, startedAt: start, now: start.addingTimeInterval(90)) == -30)
check("label parts: minutes while any are left, then seconds",
      SubAgentTimeBudget.remainingLabel(475)?.minutes == 7 && SubAgentTimeBudget.remainingLabel(475)?.seconds == 55
      && SubAgentTimeBudget.remainingLabel(45)?.minutes == 0 && SubAgentTimeBudget.remainingLabel(45)?.seconds == 45)
check("nothing left: no \"0s left\" - the chip falls back to the budget", SubAgentTimeBudget.remainingLabel(0.4) == nil && SubAgentTimeBudget.remainingLabel(-30) == nil)

print("1e. When text is collapsed")
check("a short task is shown whole, with no Show more", !SubAgentTextPreview.isLong("Port the HTTP client.") && !SubAgentTextPreview.isLong("a\nb\nc\nd"))
check("more than four lines collapses", SubAgentTextPreview.isLong("a\nb\nc\nd\ne"))
check("one very long line collapses", SubAgentTextPreview.isLong(String(repeating: "长", count: 221)) && !SubAgentTextPreview.isLong(String(repeating: "长", count: 220)))
check("blank lines count as lines", SubAgentTextPreview.isLong("a\n\n\n\nb"))

exit(failures == 0 ? 0 : 1)
"""#

print("1. The shipping digest block")
check("the block was found", digestBlock.contains("struct SubAgentRunDigest: Equatable {") && digestBlock.contains("enum SubAgentTimeBudget {"))
if failures == 0 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubAgentRunDigest-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? ("import Foundation\n" + digestBlock + scenario).write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text, terminator: "")
    let passed = text.components(separatedBy: "✅").count - 1
    check("harness ran to the end (\(passed) checks) and exited 0", p.terminationStatus == 0 && passed >= 29)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 2. Wiring

print("\n2a. Where each fact is read from")
let make = between(detail, "    static func make(child: AIChatViewModel) -> SubAgentRunDigest {", "/// When the run started and ended")
check("tool calls come from the child session's tool blocks, state from the block's own status",
      make.contains("for message in child.messages where message.role == .assistant {")
      && make.contains("guard let status = block.toolStatus else { continue }")
      && make.contains("case .streaming, .running: state = .running") && make.contains("case .success: state = .ok")
      && make.contains("case .failed: state = .failed") && make.contains("case .cancelled: state = .cancelled"))
check("a call's duration is the block's recorded one, and none while it runs",
      make.contains("duration: state == .running ? nil : block.toolDuration))"))
check("turns and tokens are the child's own counters - nothing estimated",
      make.contains("let stats = child.sessionTokenStats") && make.contains("digest.turns = stats.loopCount")
      && make.contains("digest.tokensIn = stats.input") && make.contains("digest.tokensOut = stats.output"))
check("the latest output is the child's newest non-empty text block",
      make.contains("if case .text = block.kind {") && make.contains("if !text.isEmpty { latest = text }"))
let clock = between(detail, "struct SubAgentRunClock: Equatable {", "/// [T-subagent-detail-rich] A course correction")
check("start / finish come from the job registry, with the block's start stamp as fallback - no guessing after a restart",
      clock.contains("AgentJobRegistry.shared.list().first(where: { $0.runSessionId == childSessionId })")
      && clock.contains("clock.startedAt = job.startedAt") && clock.contains("clock.finishedAt = job.finishedAt")
      && clock.contains("if clock.startedAt == nil { clock.startedAt = block.toolStartTime }"))
check("the task comes from the parent block's own tool arguments", card.contains("let taskArgs = SubAgentTaskArgs.parse(block.toolInputArgs)"))
check("the budget uses the run's start record first, then the runner's own default and ceiling",
      card.contains("AIChatViewModel.parseDelegateResult(block.content)?[\"budget_minutes\"]")
      && card.contains("defaultMinutes: AIChatViewModel.helperDefaultMinutes,\n                                          maxMinutes: AIChatViewModel.helperMaxMinutes)"))
check("time left needs a live run, a budget and a known start",
      card.contains("guard info.isRunning, let budget, let started = clock.startedAt else { return nil }"))

print("\n2b. The card, top to bottom")
let body = between(card, "struct HelperDetailCard: View {", "    // MARK: Header card")
/// The same text without comment lines.
let bodyCode = body.components(separatedBy: "\n")
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
let order = ["headerCard(info, args: taskArgs, budgetMinutes: budget)", "SubAgentStatChips(digest: digest",
             "SubAgentTaskCard(args: taskArgs)", "AgentDetailCard(title: AppLocalized(\"Current tool\")",
             "SubAgentToolTimelineCard(digest: digest)", "AgentDetailCard(title: AppLocalized(\"Latest screenshot\")",
             "AgentDetailCard(title: AppLocalized(\"Error\")", "AgentDetailCard(title: AppLocalized(\"Latest output\")",
             "AgentDetailCard(title: resultTitle", "SubAgentActionsCard(childSessionId: childId"]
let positions = order.map { index(body, $0) }
check("header, chips, task, current tool, timeline, screenshot, error, latest output, result, actions - all present, in that order",
      positions.allSatisfy { $0 > 0 } && positions == positions.sorted())
check("chips appear only when there is something to say", body.contains("if let digest, !digest.isEmpty || remaining != nil {"))
check("the timeline appears only once a tool has been called", body.contains("if let digest, digest.total > 0 {"))
check("the task card appears only for a delegation (not a control call, not a callback cell)", body.contains("if let taskArgs {\n                    SubAgentTaskCard(args: taskArgs)"))
check("the latest output is for a run in progress whose block carries no message yet",
      body.contains("if !isFinished, (result ?? \"\").isEmpty, let latest = digest?.latestText {"))
check("actions only while it runs; a correction only while a job is live to receive it",
      body.contains("if info.isRunning, let childId {\n                    SubAgentActionsCard(childSessionId: childId, canSteer: clock.jobIsLive)"))
check("the figures refresh every 3 s while it runs, from a loop in the view's task",
      body.contains(".task(id: childId) {\n            await loadChildFacts()\n            while !Task.isCancelled {\n                try? await Task.sleep(nanoseconds: 3_000_000_000)")
      && body.contains("if HelperBlockInfo.parse(block).isRunning { await loadChildFacts() }"))
// Found on a device: the view is rebuilt every second while the block's clock
// ticks, a Timer.publish property is re-created with it, and a 3 s timer that
// is replaced every second never fires - the timeline froze at the moment the
// card was opened.
check("REGRESSION: no Timer held by the view struct drives the refresh",
      !bodyCode.contains("Timer.publish") && !bodyCode.contains(".onReceive("))
check("... and they are read once more when the run ends",
      body.contains(".onChange(of: info.isRunning) { running in\n            if !running { Task { await loadChildFacts() } }"))
check("the payload's tools / turns / tokens rows stay as the fallback when the session could not be read",
      card.contains("let chipsCoverIt = !(digest?.isEmpty ?? true)")
      && card.contains("if t.hasPrefix(\"tools \") { if !chipsCoverIt {"))

print("\n2c. Stop and steer reuse what exists")
let steer = between(detail, "enum SubAgentUserSteer {", "// MARK: - Summary chips")
check("a correction goes through the child's steer queue, only for a live job, and nudges an idle child - as the model's steer does",
      steer.contains("job.state == .running || job.state == .pending,")
      && steer.contains("child.pendingSteerMessages.append(\"(sent directly by the user) \\(message)\")")
      && steer.contains("if !child.isProcessing {\n            _ = child.submitProgrammaticPrompt(AIChatViewModel.steerNudgePrompt,"))
check("a blank correction is not sent", steer.contains("guard !message.isEmpty,") && detail.contains(".disabled(isBlank)"))
let actions = between(detail, "struct SubAgentActionsCard: View {", "\n}\n")
check("Stop asks first, then takes the same two steps as the Stop on the transcript block",
      actions.contains(".confirmationDialog(AppLocalized(\"Stop this sub agent?\")")
      && actions.contains("AgentJobRegistry.shared.stopSubAgentByUser(\n            childSessionId: childSessionId, reason: \"user stopped this sub agent\")")
      && actions.contains("if stopped == 0 { ViewModelCache.shared.get(for: childSessionId)?.cancel() }"))

print("\n2d. Every new string is translated")
let catalog = source("Localizable.xcstrings")
let newKeys = ["%lld succeeded", "%lld turns", "Tokens: %1$@ in, %2$@ out", "%lldm left", "%llds left", "%lldm budget",
               "Recent tool calls", "Latest %1$lld of %2$lld", "Send a course correction…",
               "Sent. The sub agent reads it at its next turn.",
               "Read at the sub agent's next turn; a tool call already running is not interrupted.",
               "Stop this sub agent?", "Sub agents started in the same turn are stopped too. Work finished so far is kept.",
               "Latest output", "Finished", "Time budget", "The conversation waits for the result",
               "Result arrives as a new message", "Frequent (every 15 s when something changed)", "Moderate (every 60 s)"]
if let data = catalog.data(using: .utf8),
   let strings = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any] {
    let untranslated = newKeys.filter { key in
        let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        return !["en", "zh-Hans", "zh-Hant"].allSatisfy { locs[$0] != nil }
    }
    check("all \(newKeys.count) new keys are in the catalog with en, zh-Hans and zh-Hant", untranslated.isEmpty)
    if !untranslated.isEmpty { print("     missing: \(untranslated)") }
    // Every key the two files use exists in the catalog.
    var used = Set<String>()
    let pattern = try! NSRegularExpression(pattern: #"AppLocalized\("((?:[^"\\]|\\.)*)"\)"#)
    for text in [detail, between(card, "struct HelperDetailCard: View {", "struct AgentDetailCard<")] {
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            used.insert(String(text[Range(m.range(at: 1), in: text)!]))
        }
    }
    let absent = used.filter { strings[$0] == nil }.sorted()
    check("no string on the card is missing from the catalog (\(used.count) keys used)", absent.isEmpty)
    if !absent.isEmpty { print("     absent: \(absent)") }
} else {
    check("the string catalog could be read", false)
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
