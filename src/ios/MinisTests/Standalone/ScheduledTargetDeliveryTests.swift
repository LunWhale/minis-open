// [T-scheduled-default-follow-up] A task created from inside a chat without
// `--target` used to default to `new`. Its fires then opened separate
// "Scheduled · …" chats and never came back to the conversation that asked
// (device log 2026-09-27 20:21: jobs C606FAA9 / F8278E91 were created in
// session 91C75611 and fired into new sessions 5FBCF2F2 / 2DF2DF92). The
// default is now `follow-up` when a chat runs the command, and `create`
// states where the fires will land so a wrong target can be corrected at
// once.
//
//   A. ScheduledTargetDelivery.swift compiled as shipped:
//      - default resolution (explicit / --session / caller / none);
//      - the delivery sentence and structured summary for each destination
//        and for the defaulted/explicit cases.
//   B. Wiring:
//      - the bridge resolves the target through it;
//      - a missing explicit follow-up session is an error, while a defaulted
//        one falls back to new;
//      - `create` returns `delivery`;
//      - the CLI help and the system prompt state the new default and say
//        to read `delivery`.
//
// Standalone: `swift ScheduledTargetDeliveryTests.swift` (needs swiftc).

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
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = FileManager.default.currentDirectoryPath
func source(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: root)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent("src/ios/" + rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("source not found: \(rel)")
}

let model = source("Agent/Jobs/ScheduledTargetDelivery.swift")
let bridge = source("NativeOffloads/ScheduledOffloadBridge.swift")
let cli = source("NativeOffloads/ScheduledOffload.m")
let vm = chatViewModelSource()
let pbx = source("Minis.xcodeproj/project.pbxproj")

// MARK: - A. Compiled

print("A. ScheduledTargetDelivery (compiled as shipped)")
let harness = model + #"""

var hFailures = 0
func t(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { hFailures += 1 }
}
typealias D = ScheduledTargetDelivery

// Default resolution.
let r1 = D.resolveTarget(explicit: nil, session: nil, callerSession: "SID-CALLER")
t("inside a chat, no --target → follow-up (defaulted)", r1.target == "follow-up" && r1.defaulted)
let r2 = D.resolveTarget(explicit: nil, session: nil, callerSession: nil)
t("no chat behind the command → new (defaulted)", r2.target == "new" && r2.defaulted)
let r3 = D.resolveTarget(explicit: nil, session: "SID-OTHER", callerSession: nil)
t("--session without --target → follow-up (defaulted)", r3.target == "follow-up" && r3.defaulted)
let r4 = D.resolveTarget(explicit: "New", session: nil, callerSession: "SID-CALLER")
t("explicit --target new wins inside a chat (lower-cased, not defaulted)", r4.target == "new" && !r4.defaulted)
let r5 = D.resolveTarget(explicit: "  ", session: nil, callerSession: "SID-CALLER")
t("blank --target counts as omitted", r5.target == "follow-up" && r5.defaulted)
let r6 = D.resolveTarget(explicit: "child-of-current", session: nil, callerSession: "SID")
t("other explicit targets pass through", r6.target == "child-of-current" && !r6.defaulted)

// Sentences.
let here = D.sentence(.followUp(sessionId: "91C75611-AAAA", title: "定时任务分析", isCallerSession: true), defaulted: true)
t("follow-up here says IN THIS CHAT with id + title", here.contains("IN THIS CHAT") && here.contains("91C75611") && here.contains("定时任务分析"))
t("defaulted follow-up explains the default and how to get a separate chat", here.contains("defaulted to follow-up") && here.contains("--target new"))
let hereExplicit = D.sentence(.followUp(sessionId: "91C75611", title: nil, isCallerSession: true), defaulted: false)
t("explicit follow-up has no 'defaulted' remark", !hereExplicit.contains("defaulted"))
let other = D.sentence(.followUp(sessionId: "99A2E01E", title: "表格", isCallerSession: false), defaulted: false)
t("follow-up elsewhere says ANOTHER chat, NOT this conversation", other.contains("ANOTHER chat") && other.contains("NOT in this conversation"))
let newExplicit = D.sentence(.newChat(label: "prefill-test-1"), defaulted: false)
t("new says NEW separate chat, result NOT here, and how to fix", newExplicit.contains("NEW, separate chat") && newExplicit.contains("“Scheduled · prefill-test-1”") && newExplicit.contains("NOT appear in this conversation") && newExplicit.contains("--target follow-up"))
let newDefault = D.sentence(.newChat(label: nil), defaulted: true)
t("defaulted new explains why (no chat) and has no stray title", newDefault.contains("no chat was running") && !newDefault.contains("titled"))
let rerun = D.sentence(.rerun(sessionId: "S1234567", messageId: "M7654321-x", title: "t"), defaulted: false)
t("rerun says RE-RUNS the message", rerun.contains("RE-RUNS user message M7654321") && rerun.contains("no new prompt"))
let child = D.sentence(.childOfCurrent(parentSessionId: "P", isCallerSession: true), defaulted: false)
t("child-of-current says helper answer is posted back into this chat", child.contains("hidden helper") && child.contains("posted back into this chat"))
t("every sentence starts with 'Delivery:'", [here, other, newExplicit, rerun, child].allSatisfy { $0.hasPrefix("Delivery: ") })

// Summary.
let s1 = D.summary(.followUp(sessionId: "S", title: "T", isCallerSession: true), defaulted: true)
t("summary follow-up", s1["target"] as? String == "follow-up" && s1["defaulted"] as? Bool == true && s1["sessionId"] as? String == "S" && s1["isThisChat"] as? Bool == true && s1["sessionTitle"] as? String == "T")
let s2 = D.summary(.newChat(label: nil), defaulted: false)
t("summary new without label has no newChatTitle", s2["target"] as? String == "new" && s2["newChatTitle"] == nil)
t("summary is JSON-serialisable", JSONSerialization.isValidJSONObject(s1) && JSONSerialization.isValidJSONObject(s2))

print("HARNESS failures=\(hFailures)")
exit(hFailures == 0 ? 0 : 1)
"""#

do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("targetdelivery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let main = tmp.appendingPathComponent("main.swift")
    try harness.write(to: main, atomically: true, encoding: .utf8)
    let bin = tmp.appendingPathComponent("t")
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
    let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", main.path, "-o", bin.path])
    check("ScheduledTargetDelivery.swift compiles standalone", cc == 0)
    if cc != 0 { print(ccOut) }
    let (rc, out) = run(bin.path, [])
    print(out, terminator: "")
    check("delivery scenarios all pass", rc == 0 && out.contains("HARNESS failures=0"))
} catch {
    check("harness setup: \(error)", false)
}

// MARK: - B. Wiring

print("B. Wiring")
check("bridge resolves --target through ScheduledTargetDelivery.resolveTarget",
      bridge.contains("ScheduledTargetDelivery.resolveTarget(\n            explicit: str(\"target\"), session: str(\"session\"), callerSession: callerSid)"))
check("the old hard-coded default `?? \"new\"` is gone", !bridge.contains("(str(\"target\") ?? \"new\")"))
check("explicit follow-up to a missing session is an error at create time",
      bridge.contains("guard targetDefaulted else {") && bridge.contains("does not exist; follow-up needs an existing chat"))
check("a defaulted follow-up to a missing session falls back to new",
      bridge.contains("target = .new\n            }"))
check("create returns `delivery` and `deliveryTarget`",
      bridge.contains("\"delivery\": delivery,") && bridge.contains("\"deliveryTarget\": ScheduledTargetDelivery.summary("))
check("the job is registered with the resolved target", bridge.contains("origin: .cli, trigger: trigger, target: target, prompt: prompt)"))
check("CLI help states the new default", cli.contains("TARGET (default: follow-up when run inside a chat, new otherwise)"))
check("CLI help tells the model to read `delivery` and correct it", cli.contains("`create` answers with a `delivery` line"))
check("system prompt: follow-up is the DEFAULT and comes back here",
      vm.contains("`--target follow-up` (DEFAULT when you run it: each fire is a new turn in THIS chat"))
check("system prompt: new does NOT come back here", vm.contains("the result does NOT come back here"))
check("system prompt: read the delivery line", vm.contains("`create` prints a `delivery` line"))
check("new file is in the app target",
      pbx.split(separator: "\n").filter { $0.contains("ScheduledTargetDelivery.swift") }.count == 4)

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
