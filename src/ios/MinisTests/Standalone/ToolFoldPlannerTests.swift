// Tests for [T-fold-consecutive-tools] — which runs of tool calls the message
// list folds into one "Ran N tools" row. Compiles the REAL ToolFoldPlanner out
// of Agent/MessageList/ToolFoldPlanner.swift and runs it, then checks the list,
// settings and localization wiring in source.
//
// Standalone: `swift ToolFoldPlannerTests.swift` from this directory.
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

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

/// The home screen sources - Views/ContentView/ plus Views/Settings/SettingsSheet.swift
/// and AppearanceSettingsView.swift, formerly the single file ContentView.swift -
/// read as one text with the files in path order.
func contentViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/ContentView")
    var files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    files += ["Views/Settings/SettingsSheet.swift", "Views/Settings/AppearanceSettingsView.swift"]
        .map { ios.appendingPathComponent($0) }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func read(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let plannerSrc = read("Agent/MessageList/ToolFoldPlanner.swift")
check("ToolFoldPlanner.swift readable", !plannerSrc.isEmpty)
guard let s = plannerSrc.range(of: "enum ToolFoldPlanner {"),
      let e = plannerSrc.range(of: "// END ToolFoldPlanner", range: s.upperBound..<plannerSrc.endIndex) else {
    print("❌ ToolFoldPlanner not found"); exit(1)
}
let planner = String(plannerSrc[s.lowerBound..<e.lowerBound])

// Block notation: T = succeeded tool, F = failed, C = cancelled, R = unfinished
// (running/streaming), K = thinking, t = non-empty multi-line text, o = non-empty
// ONE-line text, e = empty text, B = barrier (info / delegate). Output: one
// "lo-hi:tools/failed/cancelled" per group, or "none". Like the list, `show`
// runs `markingNotes` first ([T-fold-tool-notes]).
let harness = "import Foundation\n" + planner + #"""
func parse(_ s: String) -> [ToolFoldPlanner.Input] {
    s.map { c -> ToolFoldPlanner.Input in
        switch c {
        case "T": return .tool(.succeeded)
        case "F": return .tool(.failed)
        case "C": return .tool(.cancelled)
        case "R": return .tool(.unfinished)
        case "K": return .thinking
        case "t", "o": return .text(isEmpty: false)
        case "e": return .text(isEmpty: true)
        default: return .barrier
        }
    }
}
func show(_ s: String, enabled: Bool = true) -> String {
    let chars = Array(s)
    let inputs = ToolFoldPlanner.markingNotes(parse(s)) { chars[$0] == "o" }
    let g = ToolFoldPlanner.plan(inputs, enabled: enabled)
    if g.isEmpty { return "none" }
    return g.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.toolCount)/\($0.failedCount)/\($0.cancelledCount)" }
        .joined(separator: ",")
}
let cases: [(String, String)] = [
    ("three", "TTTt"),
    ("two", "TTt"),
    ("one", "Tt"),
    ("oneThink", "TKKt"),
    ("leadText", "tTTTTt"),
    ("interleaved", "KTKTTt"),
    ("thinkOnly", "TKKTt"),
    ("thinkMid", "TKTKTt"),
    ("emptyMid", "TTeTt"),
    ("infoMid", "TTBTTt"),
    ("delegateSplit", "TTTBTTTt"),
    ("noReply", "tTTTT"),
    ("noReplyEmpty", "TTTe"),
    ("running", "TTTRt"),
    ("runningFirst", "RTTTt"),
    ("failCancel", "TFCTt"),
    ("twoRuns", "TTTtTTTTt"),
    ("trailingThink", "TTTKt"),
    ("allThinking", "KKKt"),
    // [T-fold-tool-notes]
    ("noteExample", "ToTo"),
    ("noteThenReply", "ToTt"),
    ("notesLong", "ToToTTt"),
    ("multiLineMid", "TTtTTt"),
    ("noteLive", "TToR"),
    ("noteNoReply", "TToTT"),
    ("noteOneTool", "ToR"),
    ("noteLead", "oTTt"),
    ("noteBeforeBarrier", "TToBt"),
    ("noteThink", "TKoTt"),
    ("noteAfterSoftEnd", "TToTTR"),
    // [T-fold-lead-thinking]
    ("leadThink", "KTTt"),
    ("leadThinks", "KKeTTt"),
    ("leadThinkAfterText", "tKTTt"),
    ("leadThinkSecondRun", "TTtKTTt"),
    ("leadThinkOneTool", "KTt"),
    ("leadThinkNote", "KoTTt"),
    ("leadThinkBarrier", "KBTTt"),
    ("leadThinkRunning", "KRTTt"),
]
print("single1=\(ToolFoldPlanner.isSingleLine("  Now checking the logs.  \n"))")
print("single2=\(ToolFoldPlanner.isSingleLine("line one\nline two"))")
print("single3=\(ToolFoldPlanner.isSingleLine("\n\nOne line after blank lines\n\n"))")
print("single4=\(ToolFoldPlanner.isSingleLine(""))")
for (name, input) in cases { print("\(name)=\(show(input))") }
// [T-fold-at-request-end] Timing. `running(s, h)` is what the list folds in a
// message whose task is still running: only its first `h` blocks are planned
// (notes marked within them), h = foldHorizon. `show(s)` is the task-end view.
func running(_ s: String, _ horizon: Int) -> String {
    let chars = Array(s.prefix(horizon))
    let inputs = ToolFoldPlanner.markingNotes(parse(String(chars))) { chars[$0] == "o" }
    let g = ToolFoldPlanner.plan(inputs, enabled: true)
    if g.isEmpty { return "none" }
    return g.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.toolCount)/\($0.failedCount)/\($0.cancelledCount)" }
        .joined(separator: ",")
}
print("lines0=\(ToolFoldPlanner.nonEmptyLineCount(""))")
print("lines1=\(ToolFoldPlanner.nonEmptyLineCount("Checking the logs now."))")
print("lines1b=\(ToolFoldPlanner.nonEmptyLineCount("\n  \nOnly one line\n\n   \n"))")
print("lines2=\(ToolFoldPlanner.nonEmptyLineCount("First line\nSecond line"))")
print("lines2b=\(ToolFoldPlanner.nonEmptyLineCount("First\n\n\n   \nSecond\n"))")
print("lines2crlf=\(ToolFoldPlanner.nonEmptyLineCount("First\r\nSecond"))")
print("lines3=\(ToolFoldPlanner.nonEmptyLineCount("- a\n- b\n- c"))")
print("sep0=\(ToolFoldPlanner.isFoldSeparator(requestText: ""))")
print("sep1=\(ToolFoldPlanner.isFoldSeparator(requestText: "Now let me check the logs."))")
print("sep1blank=\(ToolFoldPlanner.isFoldSeparator(requestText: "One line\n\n   \n"))")
print("sep2=\(ToolFoldPlanner.isFoldSeparator(requestText: "Found it.\nThe config is wrong."))")
print("sep2blocks=\(ToolFoldPlanner.isFoldSeparator(requestText: ["First block", "Second block"].joined(separator: "\n")))")
print("minLines=\(ToolFoldPlanner.separatorMinimumLines)")
let ids = ["a", "b", "c", "d", "e"]
print("hNone=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: []))")
print("hOne=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["c"]))")
print("hLatest=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["b", "d"]))")
print("hGone=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["x"]))")
print("hGoneOne=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["b", "x"]))")
// One task, step by step: T T, then a request whose reply streams ("t"), then
// a call (R) that runs and finishes (T), then the final reply.
print("stStreaming=\(running("TTt", 0))")        // reply streaming, no request end yet
print("stShortEnd=\(running("TToR", 0))")        // that request ended on a 1-line remark: no separator
print("stLongEnd=\(running("TTtR", 4))")         // ended on >=2 lines: separator = its last block (R)
print("stToolRuns=\(running("TTtTT", 4))")       // the next calls finish: nothing new folds mid-task
print("stNextStream=\(running("TTtTTt", 4))")    // next reply streams: still only the first run
print("stTaskEnd=\(show("TTtTTt"))")             // task ends: whole message, no line limit
// Retry / resume: the message's existing 6 blocks are a separator (floor), the
// new request's call (R) is past it — the folds from the ended task stay as-is.
print("stResume=\(running("TTtTToR", 6))|\(show("TTtTTo"))")
// [T-fold-browse-hold] holdsBack(browsing, alreadyFolded, running, shownAsRows)
var probed = 0
func hb(_ b: Bool, _ f: Bool, _ r: Bool, _ shown: Bool) -> Bool {
    ToolFoldPlanner.holdsBack(browsing: b, alreadyFolded: f, inRunningMessage: r, shownAsRows: { probed += 1; return shown })
}
print("hbAtBottom=\(hb(false, false, true, true))")
print("hbFolded=\(hb(true, true, true, true))")
print("hbRunning=\(hb(true, false, true, false))")
print("hbShownRows=\(hb(true, false, false, true))")
print("hbFreshSession=\(hb(true, false, false, false))")
probed = 0; _ = hb(false, false, false, true); _ = hb(true, true, false, true); _ = hb(true, false, true, true)
print("hbLazy=\(probed)")
print("stShortOnly=\(running("TToTTo", 0)),\(show("TToTTo"))") // only short replies: open until the end
print("off=\(show("TTTTt", enabled: false))")
print("min=\(ToolFoldPlanner.minimumToolCount)")
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tfp-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("ToolFoldPlanner compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])
let lines = Set(o.split(separator: "\n").map(String.init))
func has(_ l: String) -> Bool { lines.contains(l) }

print("▶️  threshold")
check("3 tools + reply fold", has("three=0-2:3/0/0"))
check("2 tools + reply fold ([T-fold-tools-min2])", has("two=0-1:2/0/0"))
check("1 tool + reply stays unfolded", has("one=none"))
check("threshold is 2", has("min=2"))
check("text before the run is not part of it", has("leadText=1-4:4/0/0"))

print("▶️  thinking and empty text")
check("interleaved thinking folds along, counts only tools (K T K T T t -> 3 tools, leading K too)", has("interleaved=0-4:3/0/0"))
check("thinking between tools does not break the run", has("thinkMid=0-4:3/0/0"))
check("thinking between 2 tools folds along (T K K T t -> 2 tools)", has("thinkOnly=0-3:2/0/0"))
check("thinking does not count toward the threshold (1 tool + thinking)", has("oneThink=none"))
check("thinking alone never folds", has("allThinking=none"))
check("an empty text block does not break the run", has("emptyMid=0-3:3/0/0"))
check("thinking after the last tool stays outside the fold", has("trailingThink=0-2:3/0/0"))

print("▶️  barriers")
check("an info block breaks the run: the 2 before it have no reply, the 2 after it fold", has("infoMid=3-4:2/0/0"))
check("a delegate block breaks the run; the run after it folds alone", has("delegateSplit=4-6:3/0/0"))

print("▶️  needs a reply after it")
check("tools at the end of the message do not fold", has("noReply=none"))
check("an empty text after the tools is not a reply yet", has("noReplyEmpty=none"))

print("▶️  status")
check("an unfinished tool before the reply keeps the run open (no fold)", has("running=none"))
check("an unfinished tool ends the run; the finished ones after it fold", has("runningFirst=1-3:3/0/0"))
check("failed and cancelled tools fold, and are counted", has("failCancel=0-3:4/1/1"))

print("▶️  one-line remarks between tool calls [T-fold-tool-notes]")
check("the user's example: T, 1-line, T, 1-line reply -> T..T fold, the final line stays as the reply", has("noteExample=0-2:2/0/0"))
check("a remark between calls folds with them; a multi-line reply closes the run", has("noteThenReply=0-2:2/0/0"))
check("several remarks keep one run going (4 tools)", has("notesLong=0-5:4/0/0"))
check("a MULTI-line text between calls still ends the run (two runs)", has("multiLineMid=0-1:2/0/0,3-4:2/0/0"))
check("live: a remark then a running call -> the part up to the remark stays folded", has("noteLive=0-2:2/0/0"))
check("message ends on tools after a remark -> fold up to the remark only", has("noteNoReply=0-2:2/0/0"))
check("soft end still needs the threshold (1 tool + remark)", has("noteOneTool=none"))
check("a remark before the first call is not part of the run", has("noteLead=1-2:2/0/0"))
check("a one-line text with no call after it is the reply, not a remark", has("noteBeforeBarrier=0-1:2/0/0"))
check("thinking and a remark between calls both fold along", has("noteThink=0-3:2/0/0"))
check("tools after the soft end, then a running call -> only up to the remark folds", has("noteAfterSoftEnd=0-2:2/0/0"))
check("one line = no newline between first and last visible character",
      has("single1=true") && has("single2=false") && has("single3=true") && has("single4=true"))

print("▶️  thinking right before the run [T-fold-lead-thinking]")
check("thinking just before the first tool folds with the run", has("leadThink=0-2:2/0/0"))
check("a stretch of thinking (and empty text) before it folds whole", has("leadThinks=0-4:2/0/0"))
check("text before that thinking stays out", has("leadThinkAfterText=1-3:2/0/0"))
check("the second run takes its own leading thinking", has("leadThinkSecondRun=0-1:2/0/0,3-5:2/0/0"))
check("still needs the tool threshold", has("leadThinkOneTool=none"))
check("a remark between the thinking and the first tool keeps the thinking out", has("leadThinkNote=2-3:2/0/0"))
check("a barrier between them keeps the thinking out", has("leadThinkBarrier=2-3:2/0/0"))
check("an unfinished tool between them keeps the thinking out", has("leadThinkRunning=2-3:2/0/0"))

print("▶️  timing: fold at request end, not while streaming [T-fold-at-request-end]")
check("line count = lines with a visible character (0 / 1 / blank lines ignored / 2 / CRLF / 3)",
      has("lines0=0") && has("lines1=1") && has("lines1b=1") && has("lines2=2")
      && has("lines2b=2") && has("lines2crlf=2") && has("lines3=3"))
check("the threshold is a named constant, 2", has("minLines=2"))
check("separator: empty and 1-line replies are not; 1 line plus blank lines is not; 2 lines are",
      has("sep0=false") && has("sep1=false") && has("sep1blank=false") && has("sep2=true"))
check("separator: the whole request's text counts (two one-line blocks = 2 lines)", has("sep2blocks=true"))
check("horizon: none before the first separator; through its block; the latest wins; rolled-back ids ignored",
      has("hNone=0") && has("hOne=3") && has("hLatest=4") && has("hGone=0") && has("hGoneOne=2"))
check("streaming: a reply that is still streaming folds nothing (the task-end rule alone would)",
      has("stStreaming=none") && has("three=0-2:3/0/0"))
check("a request ending on a 1-line remark folds nothing mid-task", has("stShortEnd=none"))
check("a request ending on >=2 lines folds the run before it", has("stLongEnd=0-1:2/0/0"))
check("tools finishing after the separator do not fold mid-task", has("stToolRuns=0-1:2/0/0"))
check("the next reply streaming does not fold the next run yet", has("stNextStream=0-1:2/0/0"))
check("task end folds the whole message, the run before a short reply included", has("stTaskEnd=0-1:2/0/0,3-4:2/0/0"))
check("only short replies: nothing mid-task, all folded at task end",
      has("stShortOnly=none,0-4:4/0/0"))
check("retry/resume on an ended message keeps its folds (floor separator = its last block)",
      has("stResume=0-1:2/0/0,3-4:2/0/0|0-1:2/0/0,3-4:2/0/0"))
check("browse hold: never at the bottom, never for an already-folded run",
      has("hbAtBottom=false") && has("hbFolded=false"))
check("browse hold: the running message, or a run whose blocks are on the list as rows [T-fold-browse-hold]",
      has("hbRunning=true") && has("hbShownRows=true"))
check("browse hold: a session just opened (rows never shown) folds at once", has("hbFreshSession=false"))
check("browse hold: the row lookup runs only when the cheap conditions leave it open", has("hbLazy=0"))
check("a folded run stays the same group as the task goes on (no flip-flop)",
      has("stLongEnd=0-1:2/0/0") && has("stToolRuns=0-1:2/0/0") && has("stNextStream=0-1:2/0/0"))

print("▶️  several runs")
check("two runs in one message give two groups", has("twoRuns=0-2:3/0/0,4-7:4/0/0"))

print("▶️  setting off")
check("with the setting off nothing folds", has("off=none"))

// MARK: - Wiring

let v3 = messageListV3Source()
let infra = read("Agent/MessageList/MessageListInfrastructure.swift")
let content = contentViewSource()
let registry = read("Shared/Config/ConfigRegistry+Builtins.swift")
let catalog = read("Localizable.xcstrings")
let blockView = read("Views/Chat/AssistantBlockView.swift")

print("▶️  list wiring")
check("MessageListItem has a toolGroup case", infra.contains("case toolGroup(UUID, UUID)"))
let blockSwitches = v3.components(separatedBy: "case .assistantBlock").count - 1
let groupMentions = v3.components(separatedBy: ".toolGroup").count - 1
check("V3 handles .toolGroup wherever it switches over list items (\(groupMentions) mentions for \(blockSwitches) block cases)",
      groupMentions >= 10)
check("the group row's content key carries its expanded state",
      v3.contains("\"g:\\(mid.uuidString):\\(first.uuidString):")
      && v3.contains(":\\(expanded ? 1 : 0)\""))
check("both content-key sites (configureCell seed, snapshot seed loop) use itemContentKey",
      v3.components(separatedBy: "= itemContentKey(for: item, messages: messages)").count - 1 == 2)
func body(of fn: String) -> String {
    guard let r = v3.range(of: fn),
          let end = v3.range(of: "\n        }\n", range: r.upperBound..<v3.endIndex) else { return "" }
    return String(v3[r.lowerBound..<end.lowerBound])
}
func ordered(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for p in parts {
        guard let r = text.range(of: p, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
let toggle = body(of: "func toggleToolGroup(firstBlockId: UUID) {")
check("toggle follows the full invalidation: clearCachedHeight -> invalidateHeight -> reconfigure -> apply -> invalidateLayout",
      ordered(toggle, ["applySnapshot(messages: vm.messages, caller: \"toolGroupToggle\")",
                       ".clearCachedHeight()", "layout.invalidateHeight(at: idx)",
                       "snap.reconfigureItems([item])", "ds.apply(snap, animatingDifferences: false)",
                       "layout.invalidateLayout()"]))
check("toggle keeps the row where it was on screen",
      ordered(toggle, ["let anchorY =", "scrollMode = .userBrowsing", "newMinY - anchorY"]))
let plan = body(of: "func planToolFolds(messages: [ChatMessage])")
check("a first fold is held back through ToolFoldPlanner.holdsBack, rows looked up lazily [T-fold-browse-hold]",
      plan.contains("if ToolFoldPlanner.holdsBack(browsing: browsing,")
      && plan.contains("shownAsRows: { isShownUnfolded(message.id, run.firstBlockId) }) {")
      && plan.contains("if shownRows == nil { shownRows = Set(previousSnapshotIds) }"))
check("the plan runs before the snapshot ids are replaced (it compares with the rows on screen)",
      ordered(v3, ["let toolFolds = planToolFolds(messages: messages)", "previousSnapshotIds = newItems"]))
check("re-plan triggers: request end, turn end, back to bottom — no longer a filled text block [T-fold-at-request-end]",
      v3.contains("caller: \"toolFold-requestEnd\"") && v3.contains("caller: \"toolFold-turnEnd\"")
      && v3.contains("caller: \"toolFold-backToBottom\"") && !v3.contains("toolFold-textFilled"))
check("the request-end trigger is the vm's separator signal",
      ordered(v3, ["vm.toolFoldSeparatorSignal", "resnapshotIfToolFoldsChanged(caller: \"toolFold-requestEnd\")"]))
check("only the loop's running message is planned up to its fold horizon; every other message whole",
      plan.contains("let isRunning = message.id == runningId")
      && plan.contains("let runningId = vm.toolFoldRunningMessageId")
      // [T-share-fold-tools] The horizon rule moved into ToolFoldPlanner,
      // shared with the share export.
      && plan.contains("let horizon = ToolFoldPlanner.foldHorizon(for: message, runningMessageId: runningId,")
      && plan.contains("separators: vm.toolFoldSeparators)")
      && plannerSrc.contains("guard message.id == runningMessageId else { return message.blocks.count }")
      && plannerSrc.contains("return foldHorizon(blockIds: message.blocks.map(\\.id), separators: separators[message.id] ?? [])")
      && plan.contains("let folded = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)))"))
let vmSrc = chatViewModelSource()
check("the vm marks a request end once per request, after its stream result is final",
      ordered(vmSrc, ["let foldRequestStartBlockIds = Set(messages[msgIdx].blocks.map(\\.id))",
                      "let stopReason = streamResult.stopReason",
                      "noteToolFoldRequestEnded(messageId: runMsgId, startBlockIds: foldRequestStartBlockIds)"])
      && vmSrc.components(separatedBy: "noteToolFoldRequestEnded(messageId: runMsgId").count - 1 == 1)
check("the running message is set at a request start and cleared when the loop starts and ends",
      ordered(vmSrc, ["toolFoldRunningMessageId = nil\n        toolFoldSeparators.removeAll()\n        defer {\n            toolFoldRunningMessageId = nil"])
      && ordered(vmSrc, ["let foldRequestStartBlockIds", "noteToolFoldRequestStarting(messageId: runMsgId)"]))
check("a resumed/retried message's existing content counts as finished (its last block is a separator)",
      vmSrc.contains("if let last = messages.first(where: { $0.id == messageId })?.blocks.last {\n            toolFoldSeparators[messageId, default: []].insert(last.id)"))
check("the separator decision uses the request's whole text and the shared rule",
      vmSrc.contains(".filter { !startBlockIds.contains($0.id) && $0.kind == .text }")
      && vmSrc.contains("guard ToolFoldPlanner.isFoldSeparator(requestText: text) else { return }"))
check("re-plan only applies when the plan changed",
      body(of: "func resnapshotIfToolFoldsChanged(caller: String) {").contains("guard planned.runs != toolFoldRunsByMessage else {"))
check("the list plans from inputs(for:), so remarks become notes [T-fold-tool-notes]",
      plannerSrc.contains("plan(inputs(for: blocks), enabled: true).map { group in")
      && plannerSrc.contains("markingNotes(blocks.map(input(for:))) { isSingleLine(blocks[$0].content) }"))
check("a run that changed under the same row is reconfigured (skip path and full apply)",
      v3.contains("guard let old = previousFoldRuns[first], old != run else { return nil }")
      && v3.contains("snap.reconfigureItems(changedToolGroupItems.filter { snap.indexOfItem($0) != nil })")
      && v3.contains("if !regroupedRows.isEmpty { snapshot.reconfigureItems(regroupedRows) }"))
check("the fold key is the first TOOL's id, not a leading thinking block's [T-fold-lead-thinking]",
      plannerSrc.contains("let firstTool = members.first { $0.toolUseId != nil } ?? members[members.startIndex]")
      && plannerSrc.contains("return FoldedRun(key: firstTool.toolUseId ?? firstTool.id.uuidString,"))
check("the run sums its members' execution time [T-fold-tool-duration]",
      plannerSrc.contains("let durations = members.compactMap(\\.toolDuration)")
      && plannerSrc.contains("duration: durations.isEmpty ? nil : durations.reduce(0, +))")
      && plan.contains("duration: run.duration))"))
let row: String = {
    guard let r = blockView.range(of: "struct ToolGroupRowView: View {"),
          let end = blockView.range(of: "\n}\n", range: r.upperBound..<blockView.endIndex) else { return "" }
    return String(blockView[r.lowerBound..<end.lowerBound])
}()
check("the row shows the total time after the title, in the capsule's format",
      row.contains("Text(verbatim: durationText).monospacedDigit()")
      && row.contains("if dur < 1 { return String(format: \"%.1fs\", dur) }")
      && row.contains("if let durationText { parts.append(durationText) }"))
check("the setting is read with a default of OFF",
      plannerSrc.contains("(UserDefaults.standard.object(forKey: settingsKey) as? Bool) ?? false")
      && plannerSrc.contains("static let settingsKey = \"chat.foldConsecutiveTools\""))

print("▶️  settings")
check("Appearance has the toggle, default off",
      content.contains("@AppStorage(\"chat.foldConsecutiveTools\") private var foldConsecutiveTools: Bool = false"))
check("the toggle re-lays the open chat out",
      content.contains("NotificationCenter.default.post(name: .messageListNeedsResnapshot, object: nil)"))
check("ConfigRegistry registers it, default false",
      registry.contains("path: \"chat.foldTools\"") && registry.contains("userDefaultsKey: \"chat.foldConsecutiveTools\",\n            defaultValue: false"))

print("▶️  localization")
let keys = ["Fold Consecutive Tool Calls", "Tool Calls",
            "Consecutive tool calls are shown as one line. Tap it to see each call.",
            "Ran %lld tools", "%lld failed", "%lld cancelled", "Shows each tool call", "Hides the tool calls"]
let locales = ["de", "es", "fil", "fr", "hr", "id", "ja", "ko", "ms", "pl", "pt-BR", "ro", "ru", "th", "tr", "zh-Hans", "zh-Hant"]
for k in keys {
    guard let r = catalog.range(of: "\n    \"\(k)\" : {") else { check("xcstrings has \"\(k)\"", false); continue }
    let next = catalog.range(of: "\n    \"", range: r.upperBound..<catalog.endIndex)?.lowerBound ?? catalog.endIndex
    let entry = catalog[r.upperBound..<next]
    let missing = locales.filter { !entry.contains("\"\($0)\" : {") }
    check("xcstrings \"\(k)\" has all 18 locales\(missing.isEmpty ? "" : " — missing \(missing)")", missing.isEmpty)
}
check("the switch description never says 'default'",
      !keys[2].lowercased().contains("default"))
check("the group row uses the localized strings",
      blockView.contains("AppLocalized(\"Ran \\(toolCount) tools\")")
      && blockView.contains("AppLocalized(\"\\(failedCount) failed\")")
      && blockView.contains("AppLocalized(\"\\(cancelledCount) cancelled\")"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
