// Tests for [T-tool-title-reminder] — a model that skips `tool_title` gets a
// short soft <system-reminder> appended to the result of a titled tool, on the
// 1st, 11th, 21st… missing-title call. The counting lives in ToolLoopDetector
// (its lock, warning buckets and reset lifecycle); the note is model-facing
// only and never shown on the card.
//
// Compiles the REAL ToolTitleReminder and the REAL ToolLoopDetector.swift and
// runs them, then checks the wiring.
// Standalone: `swift ToolTitleReminderTests.swift` from this directory.
import Foundation

/// The sources that used to be the single file Agent/Chat/ChatStore.swift -
/// the actor plus the files it was split into - read as one text.
func chatStoreSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["ChatStore", "ChatStore+Schema", "ChatStore+SessionCRUD", "ChatStore+SessionList",
                 "ChatStore+Search", "ChatStore+SessionQueries", "ChatStore+Folders",
                 "ChatStore+SessionDeletion", "ChatStore+StoredPreview", "ChatStore+Messages",
                 "ChatStore+Media", "ChatStore+CompactMarkers", "ChatStore+Tombstones",
                 "ChatStore+WebAppShortcuts", "ChatStore+Maintenance", "ChatStore+Helpers",
                 "ChatStore+UsageStats", "ChatStoreModels", "ContentPart+ProviderConversion",
                 "RawMessage+Conversion", "ChatStore+SyncDirty", "ChatStore+SyncRemoteSessions",
                 "ChatStore+SyncRemoteRecords", "ChatStore+BackupRestore"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
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

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func src(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let tools = src("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let detector = src("Agent/ToolLoopDetector.swift")
let vm = chatViewModelSource()
let persistence = src("Agent/Chat/AIChatViewModel+Persistence.swift")
let store = chatStoreSource()
check("sources readable", !tools.isEmpty && !detector.isEmpty && !vm.isEmpty && !persistence.isEmpty && !store.isEmpty)

guard let s = tools.range(of: "enum ToolTitleReminder {"),
      let e = tools.range(of: "// END ToolTitleReminder", range: s.upperBound..<tools.endIndex) else {
    print("❌ ToolTitleReminder not found"); exit(1)
}
let reminder = String(tools[s.lowerBound..<e.lowerBound])
let harness = """
import Foundation
struct AppLogger {
    init(category: String) {}
    func info(_ s: String) {}; func warning(_ s: String) {}; func error(_ s: String) {}; func debug(_ s: String) {}
}
""" + "\n" + reminder + "\n" + detector.replacingOccurrences(of: "import Foundation\n", with: "") + #"""

func p(_ k: String, _ v: Bool) { print("\(k)=\(v)") }
p("missingAbsent", ToolTitleReminder.isMissingTitle(["command": "ls"]))
p("missingBlank", ToolTitleReminder.isMissingTitle(["tool_title": "  \n", "command": "ls"]))
p("missingNonString", ToolTitleReminder.isMissingTitle(["tool_title": 42]))
p("presentOK", !ToolTitleReminder.isMissingTitle(["tool_title": "List files", "command": "ls"]))
p("declares", ToolTitleReminder.declaresTitle(["tool_title", "command"]))
p("mcpNoTitle", !ToolTitleReminder.declaresTitle(["query", "limit"]))
p("exactText", ToolTitleReminder.text == "<system-reminder>[minis:tool-title-reminder] This is a soft reminder. This tool call has no `tool_title`; please include a short one next time.</system-reminder>")
let out = "total 3\nfoo\nbar"
let with = ToolTitleReminder.appending(to: out)
p("appendKeepsOutputFirst", with == out + "\n\n" + ToolTitleReminder.text)
p("appendEmpty", ToolTitleReminder.appending(to: "") == ToolTitleReminder.text)
p("stripRestoresOutput", ToolTitleReminder.stripForDisplay(with) == out)
let cancel = "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>\npartial"
p("stripKeepsOtherReminders", ToolTitleReminder.stripForDisplay(ToolTitleReminder.appending(to: cancel)) == cancel)

// Cadence through the real detector.
let d = ToolLoopDetector()
var fired: [Int] = []
var missing = 0
for i in 1...40 {
    // Interleave: every 4th call has a title, every 5th is an MCP tool.
    let titled = i % 4 == 0
    let declared = i % 5 != 0
    let args: [String: Any] = titled ? ["tool_title": "Step \(i)", "command": "ls"] : ["command": "ls"]
    if declared && !titled { missing += 1 }
    if d.recordToolTitle(params: args, titleDeclared: declared) != nil { fired.append(missing) }
}
print("fired=" + fired.map(String.init).joined(separator: ","))
print("missingTotal=\(missing)")
d.reset()
p("resetRestarts", d.recordToolTitle(params: [:], titleDeclared: true) != nil)
p("secondAfterResetQuiet", d.recordToolTitle(params: [:], titleDeclared: true) == nil)
let custom = ToolLoopDetector(config: ToolLoopConfig(toolTitleReminderEvery: 3))
var cf: [Int] = []
for i in 1...7 where custom.recordToolTitle(params: [:], titleDeclared: true) != nil { cf.append(i) }
print("customEvery3=" + cf.map(String.init).joined(separator: ","))
// Loop warnings still work alongside (shared buckets map, different keys).
let lw = ToolLoopDetector()
var warned = false
for _ in 1...10 {
    _ = lw.recordToolTitle(params: [:], titleDeclared: true)
    if lw.record(toolName: "shell_execute", params: ["command": "ls"], result: "same").level == .warning { warned = true }
}
p("loopWarningUnaffected", warned)
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ttr-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let pr = Process(); pr.executableURL = URL(fileURLWithPath: exe); pr.arguments = args
    let pipe = Pipe(); pr.standardOutput = pipe; pr.standardError = pipe
    try! pr.run(); pr.waitUntilExit()
    return (pr.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("ToolTitleReminder + ToolLoopDetector compile standalone", cs == 0)
if cs != 0 { print(cout.split(separator: "\n").filter { $0.contains("error") }.prefix(5).joined(separator: "\n")); exit(1) }
let (_, o) = run(bin, [])
func ok(_ k: String) -> Bool { o.contains("\(k)=true") }

print("▶️  detection and text")
check("missing: absent / blank / not a string; a real title is not missing",
      ok("missingAbsent") && ok("missingBlank") && ok("missingNonString") && ok("presentOK"))
check("only tools whose schema declares tool_title count (MCP tools do not)", ok("declares") && ok("mcpNoTitle"))
check("exact short wording", ok("exactText"))
check("appended after the real output (or alone when there is none)", ok("appendKeepsOutputFirst") && ok("appendEmpty"))
print("▶️  cadence (real ToolLoopDetector)")
check("fires on the 1st, 11th and 21st missing-title call only (titled / undeclared calls don't count)",
      o.contains("fired=1,11,21\n") && o.contains("missingTotal=24"))
check("reset() (session load / clear) restarts the count", ok("resetRestarts") && ok("secondAfterResetQuiet"))
check("the period is a ToolLoopConfig setting (every 3 → 1, 4, 7)", o.contains("customEvery3=1,4,7"))
check("loop warnings still fire alongside (shared bucket map, separate key)", ok("loopWarningUnaffected"))
print("▶️  never shown to the user")
check("stripping restores the exact output and leaves other reminders alone",
      ok("stripRestoresOutput") && ok("stripKeepsOtherReminders"))

print("▶️  wiring")
check("appended next to the loop warning, via the detector",
      tools.contains("if toolLoopDetector.recordToolTitle(params: toolArgs, titleDeclared: titleDeclared) != nil {")
      && tools.contains("finalOutput = ToolTitleReminder.appending(to: finalOutput)")
      && tools.range(of: "let postCheck = toolLoopDetector.record(")!.lowerBound
          < tools.range(of: "toolLoopDetector.recordToolTitle(")!.lowerBound)
check("counter lives in the detector, cleared by reset()",
      detector.contains("private var missingTitleCount = 0") && detector.contains("        warningBuckets.removeAll()\n        missingTitleCount = 0\n"))
check("no separate per-session state or stitch-loop injection left",
      !vm.contains("toolTitleReminderSent") && !tools.contains("toolTitleReminderAlreadySent")
      && !tools.contains("appendingToolTitleReminder") && vm.contains("toolResultParts.append(outcome.resultPart)"))
check("the live card never gets it (finalOutput is model-facing only)",
      !tools.contains("blocks[blockIdx].content = finalOutput"))
check("reload strips it from the card (both reload paths) and the list preview",
      persistence.contains("let visibleOutput = ToolTitleReminder.stripForDisplay(tr.output)")
      && store.contains("blocks[blockIdx].content = ToolTitleReminder.stripForDisplay(tr.output)")
      && store.contains("textContent += ToolTitleReminder.stripForDisplay(tr.output)")
      && store.contains("let preview = ToolTitleReminder.stripForDisplay(tr.output).prefix(200)"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
