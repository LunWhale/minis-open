#!/usr/bin/env swift
// [T-user-ask-deferred-delivery] A deferred user_ask card showed "2/2 answered"
// while the model never got the choice: it saw the `deferred` tool result and
// then the user typing "I already chose", and had to ask again.
//
// The answer reaches the model two ways, and both could fail:
//   - the answer MESSAGE: deliverDeferred → submitProgrammaticPrompt → send().
//     Near the context threshold with auto-compact off (the default), send()
//     parked the text behind the "Context Near Capacity" alert; Cancel (or a
//     later loadSession, if the alert was never seen) dropped it, and the ask
//     was already consumed, so nothing retried. A running compaction rejected
//     it outright.
//   - the TOOL RESULT: rewritten in the database only. Mid-run there is no
//     reload, so the transcript in memory kept `deferred`.
//
// 1. compiles the shipping replaceUserAskResultInMemory against minimal stubs
//    and checks it rewrites exactly the matching tool result, in place;
// 2. pins the delivery wiring (patch when busy, wait out a compaction, skip the
//    alert) and the in-loop guard that makes skipping the alert safe.
//
// Run: swift UserAskDeferredDeliveryTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
func slice(_ s: String, from: String, through end: String) -> String? {
    guard let a = s.range(of: from), let b = s.range(of: end, range: a.upperBound..<s.endIndex) else { return nil }
    return String(s[a.lowerBound..<b.upperBound])
}

let userAsk = source("Agent/Chat/AIChatViewModel+UserAsk.swift")
let center = source("Agent/Chat/UserAskCenter.swift")
let programmatic = source("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
let send = source("Agent/Chat/AIChatViewModel+Send.swift")
let compaction = source("Agent/Chat/AIChatViewModel+Compaction.swift")
let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let provider = source("Providers/AgentProvider.swift")
let core = source("Agent/Chat/UserAskCore.swift")

guard let fn = slice(userAsk, from: "    @discardableResult\n    func replaceUserAskResultInMemory",
                     through: "        return replaced\n    }"),
      let toolResultCase = provider.components(separatedBy: "\n").first(where: { $0.contains("case toolResult(id: String") }),
      let imageCase = provider.components(separatedBy: "\n").first(where: { $0.contains("case imageData(data: Data") }) else {
    print("❌ sources not found"); exit(1)
}

// Stubs: the real enum cases (copied from AgentProvider.swift), the minimal vm.
let stubs = """
import Foundation
enum AgentContentPart {
    case text(String)
\(toolResultCase)
\(imageCase)
}
struct AgentMessage { var parts: [AgentContentPart] }
struct Block { var toolUseId: String?; var content: String }
final class ChatMessage { var blocks: [Block]; init(_ b: [Block]) { blocks = b } }
final class AIChatViewModel {
    var agentHistory: [AgentMessage] = []
    var messages: [ChatMessage] = []
}
extension AIChatViewModel {
\(fn)
}
"""

let tests = #"""
var fails = 0
func expect(_ label: String, _ cond: Bool) { print(cond ? "RESULT pass \(label)" : "RESULT fail \(label)"); if !cond { fails += 1 } }
func content(_ p: AgentContentPart) -> String? { if case .toolResult(_, _, let c, _, _, _, _, _, _) = p { return c }; return nil }

let deferred = #"{"note":"The card is shown; ...","results":[{"i":0,"status":"deferred"},{"i":1,"status":"deferred"}]}"#
let real = #"{"results":[{"answer":"Up to §5","i":0,"status":"answered"},{"i":1,"status":"approved"}]}"#
let img = Data([1, 2, 3])
let vm = AIChatViewModel()
vm.agentHistory = [
    AgentMessage(parts: [.text("go")]),
    AgentMessage(parts: [.toolResult(id: "call_other", name: "shell", content: "ls output", isError: false),
                         .toolResult(id: "call_ask", name: "user_ask", content: deferred, isError: false,
                                     imageData: img, imageMimeType: "image/png", pageURL: "u", imageLinuxPath: "/p",
                                     isOffloadReadback: true)]),
    AgentMessage(parts: [.text("waiting for your choice")]),
]
vm.messages = [ChatMessage([Block(toolUseId: "call_ask", content: deferred), Block(toolUseId: "call_other", content: "ls output")])]
let countBefore = vm.agentHistory.count

let ok = vm.replaceUserAskResultInMemory(toolUseId: "call_ask", output: real)
expect("reports that it replaced the result", ok)
expect("the user_ask result in memory now carries the choice", content(vm.agentHistory[1].parts[1]) == real)
expect("another tool's result in the same message is untouched", content(vm.agentHistory[1].parts[0]) == "ls output")
expect("in place: no message added or removed (indices stay valid mid-run)", vm.agentHistory.count == countBefore)
if case .toolResult(let id, let name, _, let isError, let d, let m, let page, let path, let ro) = vm.agentHistory[1].parts[1] {
    expect("every other field of the part is kept", id == "call_ask" && name == "user_ask" && !isError
           && d == img && m == "image/png" && page == "u" && path == "/p" && ro)
} else { expect("part is still a tool result", false) }
expect("the card block shows the real result too", vm.messages[0].blocks[0].content == real)
expect("another block is untouched", vm.messages[0].blocks[1].content == "ls output")
expect("an unknown tool call id changes nothing", !vm.replaceUserAskResultInMemory(toolUseId: "nope", output: "x")
       && content(vm.agentHistory[1].parts[1]) == real)
if fails > 0 { print("RESULT fail \(fails) check(s)") }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ua-deferred-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try stubs.write(to: tmp.appendingPathComponent("stubs.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\n" + tests).write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t")

print("1. In-memory result patch (shipping function)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + ["stubs.swift", "main.swift"]
                        .map { tmp.appendingPathComponent($0).path } + ["-o", bin.path])
check("function + stubs compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (_, out) = run(bin.path, [])
for line in out.split(separator: "\n") where line.hasPrefix("RESULT") {
    check(String(line.dropFirst(12)), line.hasPrefix("RESULT pass"))
}

print("\n2. Delivery wiring")
check("mid-run, deliverDeferred patches the transcript in memory (no reload happens then)",
      center.contains("if vm.isProcessing {\n")
      && center.contains("let patched = vm.replaceUserAskResultInMemory(toolUseId: ask.toolCallId, output: json)")
      && center.contains("} else {\n            await vm.loadSession()\n        }"))
check("a running compaction is waited out instead of rejecting the answer",
      center.contains("while vm.isCompacting, waitedTicks < UserAskDeferred.compactionWaitTicks {")
      && core.contains("static let compactionWaitTicks = 600"))
check("the answer is submitted past the Context Near Capacity alert",
      center.contains("origin: .userAskAnswer,\n                                                  silent: false, bypassContextPrompt: true)"))
check("a rejected answer is logged as an error, not as sent",
      center.contains("if case .rejected(let reason) = outcome {")
      && center.contains("answer NOT sent: \\(reason)"))
check("submitProgrammaticPrompt arms skipCompactCheck only for this send, then disarms it",
      programmatic.contains("bypassContextPrompt: Bool = false) -> ProgrammaticSubmitOutcome {")
      && programmatic.contains("if bypassContextPrompt { skipCompactCheck = true }\n        send(overrideText: text)")
      && programmatic.contains("if bypassContextPrompt { skipCompactCheck = false }"))
check("send() honours skipCompactCheck BEFORE it can park the text behind the alert",
      send.contains("if skipCompactCheck {\n            skipCompactCheck = false\n        } else {")
      && send.contains("replanTrim(site: \"pre-send\", allowCollapse: !contextPolicyAllowsAutoCompact())\n            switch checkContextBeforeSend() {"))

print("\n3. Why the alert had to be skipped, and why skipping it is safe")
check("hazard: Cancel drops a parked prompt that is not the user's own draft",
      compaction.contains("if pendingSendIsFromComposer {\n            inputText = pendingSendText ?? \"\"")
      && compaction.contains("pendingSendText = nil"))
check("safety: the in-loop guard compacts on its own when near capacity (no autoCompactEnabled check)",
      loop.contains("var inLoopVerdict = checkContextBeforeSend(site: \"in-loop\")")
      && loop.contains("switch inLoopVerdict {")
      && loop.contains("case .needsCompact:\n                let compactAnchorId"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
