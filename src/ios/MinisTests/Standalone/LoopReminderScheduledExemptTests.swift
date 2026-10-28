// Tests for [T-loop-reminder-scheduled-exempt] — a scheduled task that polls
// with the same call on every fire must not trip the loop detector's
// "identical arguments" warning (or its no-progress block); everything else
// keeps the old behaviour.
//
// Compiles the REAL ToolLoopDetector.swift (plus the ToolTitleReminder it
// references) and runs it, then checks the three fire entry points.
// Standalone: `swift LoopReminderScheduledExemptTests.swift` from this directory.
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
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func src(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let detector = src("Agent/ToolLoopDetector.swift")
let tools = src("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let vm = chatViewModelSource()
let prog = src("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
check("sources readable", !detector.isEmpty && !tools.isEmpty && !vm.isEmpty && !prog.isEmpty)
guard let s = tools.range(of: "enum ToolTitleReminder {"),
      let e = tools.range(of: "// END ToolTitleReminder", range: s.upperBound..<tools.endIndex) else {
    print("❌ ToolTitleReminder not found"); exit(1)
}
let harness = """
import Foundation
struct AppLogger {
    init(category: String) {}
    func info(_ s: String) {}; func warning(_ s: String) {}; func error(_ s: String) {}; func debug(_ s: String) {}
}

""" + String(tools[s.lowerBound..<e.lowerBound]) + "\n" + detector.replacingOccurrences(of: "import Foundation\n", with: "") + #"""

let poll: [String: Any] = ["command": "iterm2 read-screen", "tool_title": "Read iTerm2 screen"]
func p(_ k: String, _ v: Bool) { print("\(k)=\(v)") }

// 1. Scheduled polling: 30 fires, one identical call each, identical result.
let a = ToolLoopDetector()
var warned = false, blocked = false
for _ in 1...30 {
    a.exemptNextCallForScheduledFire()
    if a.check(toolName: "shell_execute", params: poll).level == .critical { blocked = true }
    if a.record(toolName: "shell_execute", params: poll, result: "same screen").level == .warning { warned = true }
}
p("scheduledNoWarning", !warned)
p("scheduledNoBlock", !blocked)

// 2. Ordinary repetition (no fires): unchanged — warns at 10.
let b = ToolLoopDetector()
var firstWarnAt = 0
for i in 1...12 where firstWarnAt == 0 {
    if b.record(toolName: "shell_execute", params: poll, result: "r\(i)").level == .warning { firstWarnAt = i }
}
print("ordinaryWarnAt=\(firstWarnAt)")

// 3. Only one call per fire is forgiven: a fire that loops within itself is
//    still caught (10 counted calls after the exempted one → warning).
let c = ToolLoopDetector()
c.exemptNextCallForScheduledFire()
var inFireWarnAt = 0
for i in 1...12 where inFireWarnAt == 0 {
    if c.record(toolName: "shell_execute", params: poll, result: "r\(i)").level == .warning { inFireWarnAt = i }
}
print("inFireWarnAt=\(inFireWarnAt)")

// 4. Does not stack (floor 0, cap 1): two fires with no call in between still
//    forgive only one call.
let d = ToolLoopDetector()
d.exemptNextCallForScheduledFire(); d.exemptNextCallForScheduledFire()
_ = d.record(toolName: "shell_execute", params: poll, result: "x")
_ = d.record(toolName: "shell_execute", params: poll, result: "x")
print("historyAfterTwoExemptsTwoCalls=\(d._historySnapshot().count)")

// 5. reset() clears a pending exemption.
let f = ToolLoopDetector()
f.exemptNextCallForScheduledFire(); f.reset()
_ = f.record(toolName: "shell_execute", params: poll, result: "x")
print("historyAfterReset=\(f._historySnapshot().count)")

// 6. Missing-title reminders are separate and unaffected.
let g = ToolLoopDetector()
g.exemptNextCallForScheduledFire()
p("titleReminderUnaffected", g.recordToolTitle(params: ["command": "ls"], titleDeclared: true) != nil)
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lse-\(UUID().uuidString)")
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
check("ToolLoopDetector compiles standalone", cs == 0)
if cs != 0 { print(cout.split(separator: "\n").filter { $0.contains("error") }.prefix(5).joined(separator: "\n")); exit(1) }
let (_, o) = run(bin, [])
func ok(_ k: String) -> Bool { o.contains("\(k)=true") }

print("▶️  behaviour (real ToolLoopDetector)")
check("30 scheduled fires of the same poll: no loop warning", ok("scheduledNoWarning"))
check("…and no no-progress block, even with an unchanged result", ok("scheduledNoBlock"))
check("ordinary repetition still warns at the 10th identical call", o.contains("ordinaryWarnAt=10\n"))
check("only ONE call per fire is forgiven: a fire looping within itself still warns (11th = 10 counted)",
      o.contains("inFireWarnAt=11\n"))
check("the exemption does not stack (cap 1, floor 0)", o.contains("historyAfterTwoExemptsTwoCalls=1\n"))
check("reset() clears a pending exemption", o.contains("historyAfterReset=1\n"))
check("missing-title reminders are unaffected", ok("titleReminderUnaffected"))

print("▶️  wiring: every way a scheduled fire starts a turn")
check("idle session: submitProgrammaticPrompt exempts a scheduled callback before send()",
      prog.contains("if Self.scheduledCallback(inQueuedText: text) != nil {\n            toolLoopDetector.exemptNextCallForScheduledFire()\n        }\n        if bypassContextPrompt { skipCompactCheck = true }\n        send(overrideText: text)"))
check("idle drain of a queued fire", vm.contains("if take.scheduledJobId != nil { self.toolLoopDetector.exemptNextCallForScheduledFire() }"))
check("fire injected into a running loop (tool gap / turn end)",
      vm.contains("if take.scheduledJobId != nil { toolLoopDetector.exemptNextCallForScheduledFire() }\n        return take.scheduledJobId != nil ? .scheduledFire : .prompts"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
