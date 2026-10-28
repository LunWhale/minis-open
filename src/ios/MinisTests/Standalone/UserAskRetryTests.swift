#!/usr/bin/env swift
// [T-user-ask-notsent-retry] A "Question not sent" row offers Retry: the app
// sends the model one hidden note asking it to call user_ask again, and the
// row turns into "Retried".
//
//   [1] the shipping UserAskRetryRule + UserAskRetryClaims (BEGIN/END block in
//       UserAskCardView.swift), compiled standalone: when Retry shows, and
//       that a run is claimed once
//   [2] the hidden note: wording (app, not user; not an answer; no approval),
//       hidden on reload, never rendered
//   [3] source guards: the retry path (persist the note, then the existing
//       unanswered-turn entry), the separate store keyed by toolUseId, no new
//       field on AssistantBlock, the compact button
//
// Run: swift UserAskRetryTests.swift   (needs swiftc)
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
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let card = source("Views/Chat/UserAskCardView.swift")
guard let block = between(card, "// BEGIN UserAskRetryRule", "// END UserAskRetryRule") else {
    print("❌ UserAskRetryRule block not found"); exit(1)
}

let harness = #"""
import Foundation
typealias I = UserAskRetryRule.Item
func lead(_ items: [I], running: Bool = false, retried: Set<String> = []) -> String {
    UserAskRetryRule.retryableLead(items, isProcessing: running, retried: retried) ?? "nil"
}
func R(_ k: String, _ v: String) { print("R \(k)=\(v)") }
R("lone", lead([.userTurn, .notSentLead("a")]))
R("running", lead([.userTurn, .notSentLead("a")], running: true))
R("asked_after", lead([.userTurn, .notSentLead("a"), .asked]))
R("user_after", lead([.userTurn, .notSentLead("a"), .userTurn]))
R("last_only", lead([.userTurn, .notSentLead("a"), .userTurn, .notSentLead("b")]))
R("earlier_superseded", lead([.notSentLead("a"), .asked, .userTurn]))
R("retried", lead([.userTurn, .notSentLead("a")], retried: ["a"]))
R("retried_then_new_run", lead([.notSentLead("a"), .notSentLead("b")], retried: ["a"]))
R("none", lead([.userTurn, .asked]))
R("empty_id", lead([.notSentLead("")]))
var c = UserAskRetryClaims(cap: 3)
let first = c.claim("a"), second = c.claim("a"), empty = c.claim("")
R("claims", "\(first),\(second),\(empty)")
_ = c.claim("b"); _ = c.claim("c"); _ = c.claim("d")
R("cap", c.ids.joined(separator: ","))
c.release("c")
R("release", "\(c.contains("c")),\(c.claim("c"))")
let restored = UserAskRetryClaims(ids: ["x", "y"], cap: 300)
R("restored", "\(restored.contains("x")),\(restored.contains("z"))")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-retry-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Rule.swift", "import Foundation\n" + block), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping UserAskRetryRule compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}

print("\n1. When Retry shows")
check("the session's only not-sent run, nothing running → Retry", r["lone"] == "a")
check("a run is in progress → no Retry", r["running"] == "nil")
check("an asked user_ask after it (the model retried by itself) → no Retry", r["asked_after"] == "nil")
check("a later user turn (the conversation moved on) → no Retry", r["user_after"] == "nil")
check("only the LAST not-sent run offers it", r["last_only"] == "b")
check("an earlier run superseded by an asked call → no Retry anywhere", r["earlier_superseded"] == "nil")
check("a run already retried → no Retry", r["retried"] == "nil")
check("a new not-sent run after a retried one offers it again", r["retried_then_new_run"] == "b")
check("no not-sent run → none", r["none"] == "nil")
check("a lead without a toolUseId is never offered", r["empty_id"] == "nil")

print("\n2. One tap, one retry")
check("first claim wins, a double tap is refused, an empty id is refused", r["claims"] == "true,false,false")
check("the retried list is capped (oldest fall off)", r["cap"] == "b,c,d")
check("a retry that could not start is released and can be claimed again", r["release"] == "false,true")
check("claims restore from the persisted list", r["restored"] == "true,false")

print("\n3. The hidden note")
let models = source("Agent/Chat/ChatStoreModels.swift")
let nudge = between(models, "static let userAskRetryNudgeText =\n        \"", "\"\n") ?? ""
check("found", !nudge.isEmpty)
check("system-reminder, from the app, not from the user",
      nudge.hasPrefix("<system-reminder>") && nudge.hasSuffix("</system-reminder>") && nudge.contains("from the app, not from the user"))
check("says what happened and what to do: call user_ask again with `questions` filled in",
      nudge.contains("was not sent") && nudge.contains("Call user_ask again") && nudge.contains("`questions` filled in completely"))
check("not an answer, approves / authorizes nothing",
      nudge.contains("not an answer to any question") && nudge.contains("does not approve or authorize any action"))
check("hidden: listed with the other internal user nudges (skipped on reload, never a bubble)",
      models.contains("static let internalUserNudgeTexts: [String] = [scheduledResumeNudgeText, userAskTextAskNudgeText, userAskRetryNudgeText")) // [T-subagent-termination] the list grew a helper closing nudge

print("\n4. Source guards")
let userAsk = source("Agent/Chat/AIChatViewModel+UserAsk.swift")
let retry = between(userAsk, "func retryNotSentUserAsk(leadToolUseId: String) async -> Bool {", "\n    }\n") ?? ""
check("refused while a run is going (and re-checked after the note is written)",
      retry.contains("guard !isProcessing, sessionId != nil") && retry.contains("guard !isProcessing else {"))
check("the note is persisted before the run starts, then appended to the history",
      retry.range(of: "await persistAgentMessage(nudge)").map { p in retry.range(of: "agentHistory.append(stored)").map { p.lowerBound < $0.lowerBound } ?? false } ?? false)
check("the reply starts through the existing unanswered-turn entry (a normal foreground run, any provider)",
      retry.contains("resumeUnansweredUserTurn(afterHiddenNudge: true)")
      && source("Agent/Chat/AIChatViewModel+Send.swift").contains("func resumeUnansweredUserTurn(afterHiddenNudge: Bool = false) {"))
check("no programmatic origin: user_ask stays interactive in the retried run",
      !retry.contains("programmaticTurnOrigin") && !retry.contains("submitProgrammaticPrompt"))
check("the retried mark lives in its own store keyed by toolUseId, persisted in UserDefaults",
      card.contains("static let retriedKey = \"agent.tools.userAsk.retriedNotSent\"") && card.contains("UserDefaults.standard.set(claims.ids, forKey: Self.retriedKey)"))
let chatModels = source("Agent/Chat/ChatModels.swift")
check("AssistantBlock gains no field (a new one crashed launch before)",
      !chatModels.contains("userAskNotSent") && !chatModels.contains("userAskRetr") && !chatModels.lowercased().contains("retried"))
check("the NotSent store is unchanged by this feature (still roles only)",
      (between(card, "final class UserAskNotSentStore: ObservableObject {", "\n}\n") ?? "x").contains("@Published private(set) var roles") && !(between(card, "final class UserAskNotSentStore: ObservableObject {", "\n}\n") ?? "").contains("retry"))
check("the tap claims first, then retries; a failed start releases the claim",
      card.contains("guard let vm = UserAskRetryStore.shared.claim(id) else { return }")
      && card.contains("if !(await vm.retryNotSentUserAsk(leadToolUseId: id)) {\n                        UserAskRetryStore.shared.release(id)"))
check("the button is compact (no 44pt minimum), so the row keeps its height", card.contains("Text(AppLocalized(\"Retry\"))") && card.contains(".contentShape(Rectangle().inset(by: -10))"))
check("Retry is offered after a load and whenever a run starts or ends",
      card.contains("let sub = vm.$isProcessing.removeDuplicates()") && userAsk.contains("UserAskRetryStore.shared.track(self)")
      && source("Agent/Chat/AIChatViewModel+Persistence.swift").contains("trackUserAskRetry()"))
// A nested class + static tuple dictionary on AIChatViewModel crashed launch
// (metadata stack overflow, Minis-2026-10-02-131633.ips); the state lives in
// UserAskRetryStore instead.
check("no nested type or static state added to AIChatViewModel for this",
      !userAsk.contains("class WeakBox") && !userAsk.contains("static var userAskRetryTracking"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
