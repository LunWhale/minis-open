#!/usr/bin/env swift
// [T-user-ask-not-asked-row] A user_ask call that preflight rejected (empty or
// invalid arguments) never becomes a question. Its card used to fall through
// to the "Waiting for your answer…" placeholder and stay there, above the
// answered card of the model's retry, both live and after a reload.
//
//   [1] the shipping UserAskCardPhase (BEGIN/END block in UserAskCardView.swift)
//       compiled with the real UserAskParser (UserAskCore block) and the real
//       ToolBlockStatus (ChatModels.swift), driven by block states taken from
//       the live preflight path and from a reload of the stored rows
//   [2] source guards: the card body routes through the phase, the not-asked
//       row reuses existing 18-locale strings, the status the phase reads is
//       the one both paths set
//
// Run: swift UserAskCardPhaseTests.swift   (needs swiftc)
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
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}

let card = source("Views/Chat/UserAskCardView.swift")
let core = source("Agent/Chat/UserAskCore.swift")
let models = source("Agent/Chat/ChatModels.swift")
guard let phaseBlock = between(card, "// BEGIN UserAskCardPhase", "// END UserAskCardPhase"),
      let coreBlock = between(core, "// BEGIN UserAskCore", "// END UserAskCore"),
      let statusBody = between(models, "enum ToolBlockStatus: Equatable {", "\n}") else {
    print("❌ source blocks not found"); exit(1)
}

let harness = #"""
import Foundation

// What the card body computes, for one block.
func phase(args: String?, content: String, status: ToolBlockStatus?,
           livePending: Bool = false, liveTerminal: Bool = false) -> UserAskCardPhase {
    var parses = false
    if let args, let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any],
       case .success = UserAskParser.parse(obj) { parses = true }
    return UserAskCardPhase.resolve(livePending: livePending, liveTerminal: liveTerminal,
                                    hasContent: !content.isEmpty, requestParses: parses,
                                    callEnded: UserAskCardPhase.callEnded(status))
}
func R(_ k: String, _ v: Any) { print("R \(k)=\(v)") }

let valid = #"{"questions":[{"type":"options","header":"打包内容","question":"现在打包吗？","options":[{"label":"现在就打"},{"label":"等一下"}]}]}"#
let answered = #"{"results":[{"answer":"现在就打","i":0,"status":"answered"}]}"#
let liveBlocked = "Blocked invalid tool call"   // AppLocalized, as preflight writes it live
let storedBlocked = "Error: Tool call rejected before execution. Tool 'user_ask' was called with empty arguments {} but requires: questions."

// Rejected call — live (preflight sets .failed + the UI message) and reload
// (applyToolResults maps the stored error result to .failed).
R("rejected_live", phase(args: "{}", content: liveBlocked, status: .failed(message: liveBlocked)))
R("rejected_reload", phase(args: "{}", content: storedBlocked, status: .failed(message: "")))
R("rejected_empty_string_args", phase(args: "", content: storedBlocked, status: .failed(message: "")))
R("rejected_nil_args", phase(args: nil, content: storedBlocked, status: .failed(message: "")))
R("rejected_questions_empty", phase(args: #"{"questions":[]}"#, content: storedBlocked, status: .failed(message: "")))

// Still in flight: the stream placeholder content is non-empty and the
// arguments are partial, but nothing has ended — keep waiting.
R("streaming_partial", phase(args: #"{"questions":[{"ty"#, content: "Tool: user_ask", status: .streaming(bytes: 40)))
R("streaming_no_args", phase(args: nil, content: "Tool: user_ask", status: .streaming(bytes: 0)))
R("running_empty_content", phase(args: valid, content: "", status: .running))
// Cold start, before recovery has re-registered the ask: a reload seeds
// .running with empty content.
R("reload_before_recovery", phase(args: valid, content: "", status: .running))

// Asked and answered.
R("answered_reload", phase(args: valid, content: answered, status: .success))
R("answered_live_terminal", phase(args: valid, content: answered, status: .success, liveTerminal: true))
R("pending_live", phase(args: valid, content: "", status: .running, livePending: true))

// The two sessions from the report, as a reload rebuilds them.
let dupSession = [phase(args: "{}", content: storedBlocked, status: .failed(message: "")),
                  phase(args: valid, content: answered, status: .success)]
let normalSession = [phase(args: valid, content: answered, status: .success)]
func faces(_ s: [UserAskCardPhase]) -> String {
    "cards=\(s.filter { $0 == .resolvedStored || $0 == .resolvedLive }.count),notAsked=\(s.filter { $0 == .notAsked }.count),waiting=\(s.filter { $0 == .waiting }.count)"
}
R("dup_session", faces(dupSession))
R("normal_session", faces(normalSession))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-phase-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Core.swift", "import Foundation\n" + coreBlock),
             ("Status.swift", "enum ToolBlockStatus: Equatable {" + statusBody + "\n}\n"),
             ("Phase.swift", "import Foundation\n" + phaseBlock),
             ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("phase + UserAskParser + ToolBlockStatus compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}

print("\n1. A rejected call is not shown as waiting")
check("live: preflight-rejected {} → notAsked", r["rejected_live"] == "notAsked")
check("reload: stored rejection → notAsked", r["rejected_reload"] == "notAsked")
check("empty-string arguments → notAsked", r["rejected_empty_string_args"] == "notAsked")
check("no arguments at all → notAsked", r["rejected_nil_args"] == "notAsked")
check("an empty questions array → notAsked", r["rejected_questions_empty"] == "notAsked")

print("\n2. A call still in flight keeps the waiting placeholder")
check("streaming with partial arguments and the 'Tool: user_ask' placeholder → waiting", r["streaming_partial"] == "waiting")
check("streaming before any argument → waiting", r["streaming_no_args"] == "waiting")
check("running with empty content → waiting", r["running_empty_content"] == "waiting")
check("cold start before recovery re-registers the ask → waiting", r["reload_before_recovery"] == "waiting")

print("\n3. Asked calls are unchanged")
check("answered, reloaded → resolved card from the stored result", r["answered_reload"] == "resolvedStored")
check("answered, live → resolved card from the center", r["answered_live_terminal"] == "resolvedLive")
check("pending, live → pending card", r["pending_live"] == "pending")

print("\n4. The reported sessions after a reload")
check("rejected + retried-and-answered: one card, one not-asked row, no waiting",
      r["dup_session"] == "cards=1,notAsked=1,waiting=0")
check("a normally answered session: exactly one card", r["normal_session"] == "cards=1,notAsked=0,waiting=0")

print("\n5. Source guards")
let body = between(card, "struct UserAskCardView: View {", "/// No live state yet") ?? ""
check("the card body routes through UserAskCardPhase.resolve", body.contains("UserAskCardPhase.resolve("))
check("…fed by the parsed request and the block's tool status",
      body.contains("requestParses: request != nil") && body.contains("callEnded: UserAskCardPhase.callEnded(block.toolStatus)"))
check("notAsked renders its own row, waiting keeps the placeholder",
      body.contains("case .notAsked:\n                notAskedRow") && body.contains("case .waiting:\n                waitingPlaceholder"))
check("the row shows the not-sent title (with the run count) and the plain-words reason",
      body.contains("UserAskSummary.notSentTitle(count: notSent.role(block.id).count)")
      && body.contains("AppLocalized(\"Details missing; the assistant will retry or ask in text\")"))
let concurrent = source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let preflight = between(concurrent, "if let preflightError = Self.preflightValidateToolCall", "toolLoopDetector.record") ?? ""
check("live: preflight marks the block .failed", preflight.contains("toolStatus = .failed(message: uiMessage)"))
let conversion = source("Agent/Chat/RawMessage+Conversion.swift")
check("reload: a failed stored result maps to .failed",
      conversion.contains("default:          blocks[blockIdx].toolStatus = tr.success ? .success : .failed(message: \"\")"))
check("reload: a user_ask tool_use is seeded .running with empty content",
      conversion.contains("kind = .userAskTool\n                    content = \"\""))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
