#!/usr/bin/env swift
// [T-user-ask] Tests for the shipping user_ask core (Agent/Chat/UserAskCore.swift,
// compiled standalone): request parsing/validation, the §19.8 timeout table,
// the state machine (first come first served, consume-once per toolCallId,
// interaction resets the countdown), result encoding, and the notification
// category plan + whole-set registry.
//
// Run: swift UserAskCoreTests.swift   (needs swiftc)
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
let core = source("Agent/Chat/UserAskCore.swift")
guard let b = core.range(of: "// BEGIN UserAskCore"), let e = core.range(of: "// END UserAskCore") else {
    print("❌ UserAskCore block not found"); exit(1)
}
let block = "import Foundation\n" + core[b.upperBound..<e.lowerBound]

let harness = #"""
import Foundation
var out: [String] = []
func R(_ k: String, _ v: Any) { out.append("R \(k)=\(v)") }

func q(_ dict: [String: Any]) -> UserAskQuestion? {
    if case .success(let r) = UserAskParser.parse(["questions": [dict]]) { return r.questions[0] }
    return nil
}
func err(_ args: [String: Any]) -> String {
    if case .failure(let e) = UserAskParser.parse(args) { return e.message }
    return "OK"
}

// --- parsing
R("emptyQuestions", err(["questions": []]).contains("call user_ask again with 1-4 question objects, each with `type` and `question`"))
R("fiveQuestions", err(["questions": Array(repeating: ["type": "options", "question": "x"], count: 5)]).contains("At most 4"))
R("badType", err(["questions": [["type": "choice", "question": "x"]]]).contains("\"options\" or \"confirm\""))
// [T-user-ask-infer-type] a missing / unknown type is inferred from fields only one type has
let twoOpts: [[String: Any]] = [["label": "我的 Mac", "description": "SSH"], ["label": "HubSign", "description": "3rd party"]]
let inferredOpt = q(["question": "用哪种方式签名？", "header": "签名方式", "options": twoOpts])
R("inferOptions", inferredOpt.map { "\($0.type.rawValue)|\($0.options?.count ?? 0)|\($0.options?[1].label ?? "-")" } ?? "nil")
R("inferOptionsUnknownType", q(["type": "single_choice", "question": "x", "options": twoOpts])?.type.rawValue ?? "nil")
R("inferOptionsFromDefault", q(["question": "x", "default": "0"]).map { _ in "parsed" } ?? err(["questions": [["question": "x", "default": "0"]]]))
R("inferOptionsMulti", q(["question": "x", "options": twoOpts, "multi_select": true]).map { "\($0.type.rawValue)|\($0.multiSelect)" } ?? "nil")
R("inferConfirm", q(["question": "rm -rf build", "impact": "deletes build output", "risk": "high"]).map { "\($0.type.rawValue)|\($0.risk.rawValue)|\($0.impact ?? "-")" } ?? "nil")
R("inferConfirmRiskOnly", q(["question": "git push", "risk": "medium"])?.type.rawValue ?? "nil")
R("bareNoType", err(["questions": [["question": "Name it?"]]]))
R("mixedNoType", err(["questions": [["question": "x", "options": twoOpts, "impact": "y"]]]))
R("explicitTypeWins", err(["questions": [["type": "confirm", "question": "x", "options": twoOpts]]]).contains("takes no `options`"))
R("singleOption", err(["questions": [["type": "options", "question": "x", "options": [["label": "A"]]]]]).contains("at least 2"))
R("fiveOptions", err(["questions": [["type": "options", "question": "x", "options": (0..<5).map { ["label": "L\($0)"] }]]]).contains("at most 4"))
R("confirmWithOptions", err(["questions": [["type": "confirm", "question": "rm x", "options": [["label": "Y"], ["label": "N"]]]]]).contains("takes no `options`"))
R("defaultOutOfRange", err(["questions": [["type": "options", "question": "x", "options": [["label": "A"], ["label": "B"]], "default": 5]]]).contains("0-based index"))
// [T-user-ask-no-policy] a confirm has no default and no scope_key: both are ignored, never an error
R("confirmDefaultIgnored", err(["questions": [["type": "confirm", "question": "rm x", "default": "approve", "scope_key": "rm"]]]))
let opt = q(["type": "options", "question": "Which?", "header": "Pick", "options": [["label": "A (Recommended)", "description": "first"], ["label": "B"]], "default": 0, "multi_select": false])!
R("stripRecommended", opt.options![0].label)
R("optDefault", opt.defaultValue == .option(0))
let open = q(["type": "options", "question": "Name it?"])!
R("openEnded", open.isOpenEnded)
let conf = q(["type": "confirm", "question": "git push --force", "impact": "rewrites remote", "risk": "high", "default": "approve", "scope_key": "git.push.force"])!
R("confirmParsed", "\(conf.risk.rawValue)|\(conf.defaultValue == nil)|\(conf.impact ?? "-")")
let confNoRisk = q(["type": "confirm", "question": "delete tmp", "default": "cancel"])!
R("confirmRiskDefaultsMedium", confNoRisk.risk.rawValue)
R("multiOnlyWithOptions", q(["type": "options", "question": "x", "multi_select": true])!.multiSelect)

// --- §20.4 timeout: no action, only a status (+ an options suggestion)
func to(_ question: UserAskQuestion) -> String { UserAskResolver.encode([UserAskResolver.timedOut(question, index: 0, timeoutMinutes: 5)]) }
let optNoDefault = q(["type": "options", "question": "x", "options": [["label": "A"], ["label": "B"]]])!
let optDefault1 = q(["type": "options", "question": "x", "options": [["label": "A"], ["label": "B"]], "default": 1])!
let medApprove = q(["type": "confirm", "question": "x", "risk": "medium", "default": "approve"])!
let medCancel = q(["type": "confirm", "question": "x", "risk": "medium", "default": "cancel"])!
let medNone = q(["type": "confirm", "question": "x", "risk": "medium"])!
let highApprove = q(["type": "confirm", "question": "x", "risk": "high", "default": "approve"])!
let highNone = q(["type": "confirm", "question": "x", "risk": "high"])!
R("to.optDefault0", to(opt))
R("to.optDefault1", to(optDefault1))
R("to.optNoDefault", to(optNoDefault))
R("to.open", to(open))
R("to.confirms", [medApprove, medCancel, medNone, highApprove, highNone].map(to).joined(separator: "‖"))
R("to.note", UserAskResolver.timedOut(medNone, index: 0, timeoutMinutes: 7).note ?? "-")
R("to.noteOpt", UserAskResolver.timedOut(opt, index: 0, timeoutMinutes: 5).note ?? "-")

// --- answered mapping
func a(_ question: UserAskQuestion, _ ans: UserAskAnswer) -> UserAskResultEntry { UserAskResolver.answered(question, index: 0, answer: ans) }
R("ans.picked", a(opt, UserAskAnswer(selected: [1], note: "not config.json")).jsonObject()["answer"] as? String ?? "-")
R("ans.note", a(opt, UserAskAnswer(selected: [1], note: "not config.json")).note ?? "-")
R("ans.other", a(opt, UserAskAnswer(otherText: "backup first")).status.rawValue)
R("ans.delegated", a(opt, UserAskAnswer(delegated: true)).status.rawValue)
R("ans.approve", a(medCancel, UserAskAnswer(confirmChoice: .approve)).status.rawValue)
// --- legacy records (§20.6): decode without crashing, map to today's values
let dec = JSONDecoder()
R("legacy.choice", (try? dec.decode(UserAskAnswer.self, from: Data(#"{"selected":[],"delegated":false,"confirmChoice":"approveAlways"}"#.utf8)))?.confirmChoice.map { "\($0)" } ?? "FAIL")
R("legacy.status", ["timeout_default", "timeout_abandoned", "timeout_cancelled", "timeout_approved", "approved_always", "timeout", "denied", "bogus"]
    .map { UserAskResultStatus.parse($0)?.rawValue ?? "nil" }.joined(separator: ","))
R("ans.deny", "\(a(medCancel, UserAskAnswer(note: "use revert", confirmChoice: .deny)).status.rawValue)|\(a(medCancel, UserAskAnswer(note: "use revert", confirmChoice: .deny)).note ?? "-")")
let multi = q(["type": "options", "question": "x", "multi_select": true, "options": [["label": "A"], ["label": "B"], ["label": "C"]]])!
R("ans.multi", (a(multi, UserAskAnswer(selected: [0, 2], otherText: "D")).jsonObject()["answer"] as? [String] ?? []).joined(separator: ","))
R("ans.clip", (a(opt, UserAskAnswer(otherText: String(repeating: "x", count: 5000))).answer?.first?.count ?? 0))
R("encode", UserAskResolver.encode([a(opt, UserAskAnswer(selected: [0]))]))

// --- state machine
let t0 = Date(timeIntervalSince1970: 1_000_000)
var p = PendingAsk(requestId: "r1", sessionId: "s", toolCallId: "tc1", questions: [opt, medCancel], createdAt: t0, timeoutMinutes: 5)
R("expiresAt", p.expiresAt!.timeIntervalSince(t0))
R("notExpired", p.isExpired(at: t0.addingTimeInterval(299)))
R("expired", p.isExpired(at: t0.addingTimeInterval(300)))
p.noteInteraction(at: t0.addingTimeInterval(200))
R("interactionResets", p.expiresAt!.timeIntervalSince(t0))
p.setAnswer(UserAskAnswer(selected: [1]), at: 0)
p.submitted.insert(0)
R("consumeBeforeResolve", p.consume() == nil)
R("resolveAnswered", p.resolveAnswered(source: .notification))
R("secondResolveLoses", p.resolveTimedOut() || p.resolveDismissed(.supersededByUserMessage))
R("stateAnswered", "\(p.state.rawValue)|\(p.source!.rawValue)")
R("consumeOnce", p.consume() != nil)
R("consumeTwice", p.consume() == nil)
p.setAnswer(UserAskAnswer(selected: [0]), at: 0)
R("draftIgnoredAfterResolve", p.answers[0].selected)

var p2 = PendingAsk(requestId: "r2", sessionId: "s", toolCallId: "tc2", questions: [opt, optNoDefault, medApprove], createdAt: t0, timeoutMinutes: 5)
p2.setAnswer(UserAskAnswer(selected: [1]), at: 0); p2.submitted.insert(0)
p2.setAnswer(UserAskAnswer(selected: [0]), at: 1)   // drafted but not submitted
R("partialTimeout", p2.resolveTimedOut())
R("partialStatuses", p2.resultStatuses.map(\.rawValue).joined(separator: ","))
R("partialAnswersKept", "\(p2.answers[0].selected)|\(p2.answers[1].selected)|\(p2.answers[2].confirmChoice.map { "\($0)" } ?? "nil")")
R("partialDraftNotSent", !(p2.resultJSON ?? "").contains(#""answer":"A""#))
// A record persisted by an older build.
var legacyObj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(p2)) as! [String: Any]
legacyObj["autoDefaultMode"] = "options_and_medium_confirm"
var lq = legacyObj["questions"] as! [[String: Any]]
lq[2]["scopeKey"] = "rm.cache"; lq[2]["defaultValue"] = ["kind": "approve"]
legacyObj["questions"] = lq
var la = legacyObj["answers"] as! [[String: Any]]
la[2]["confirmChoice"] = "approveAlways"
legacyObj["answers"] = la
legacyObj["resultJSON"] = #"{"results":[{"i":0,"status":"timeout_default"},{"i":1,"status":"timeout_abandoned"}]}"#
let legacyAsk = try? JSONDecoder().decode(PendingAsk.self, from: JSONSerialization.data(withJSONObject: legacyObj))
R("legacy.ask", legacyAsk.map { "ok|\($0.answers[2].confirmChoice.map { "\($0)" } ?? "nil")|\($0.questions[2].defaultValue == nil ? "nil" : "kept")|\($0.resultStatuses.map(\.rawValue).joined(separator: ","))" } ?? "FAIL")
R("dismissAfterTimeoutLoses", p2.resolveDismissed(.supersededByUserMessage))

var p3 = PendingAsk(requestId: "r3", sessionId: "s", toolCallId: "tc3", questions: [opt], createdAt: t0, timeoutMinutes: 5)
R("superseded", p3.resolveDismissed(.supersededByUserMessage))
R("supersededState", "\(p3.state.rawValue)|\(p3.dismissReason!.rawValue)|\(p3.resultStatuses.map(\.rawValue).joined())")
var p4 = PendingAsk(requestId: "r4", sessionId: "s", toolCallId: "tc4", questions: [opt], createdAt: t0, timeoutMinutes: 5)
R("stopped", "\(p4.resolveDismissed(.stopped))|\(p4.state.rawValue)")
var p5 = PendingAsk(requestId: "r5", sessionId: "s", toolCallId: "tc5", questions: [opt], createdAt: t0, timeoutMinutes: 0)
R("waitForever", "\(p5.expiresAt == nil)|\(p5.isExpired(at: t0.addingTimeInterval(1e7)))")
// Codable round trip (the store persists this JSON)
let data = try! JSONEncoder().encode(p2)
let back = try! JSONDecoder().decode(PendingAsk.self, from: data)
R("roundTrip", back == p2)

// --- notification plan
let single = PendingAsk(requestId: "abc", sessionId: "s", toolCallId: "t", questions: [opt], createdAt: t0, timeoutMinutes: 5)
let two = PendingAsk(requestId: "def", sessionId: "s", toolCallId: "t", questions: [opt, opt], createdAt: t0, timeoutMinutes: 5)
let multiAsk = PendingAsk(requestId: "ghi", sessionId: "s", toolCallId: "t", questions: [multi], createdAt: t0, timeoutMinutes: 5)
let cm = PendingAsk(requestId: "c1", sessionId: "s", toolCallId: "t", questions: [medCancel], createdAt: t0, timeoutMinutes: 5)
let ch = PendingAsk(requestId: "c2", sessionId: "s", toolCallId: "t", questions: [highNone], createdAt: t0, timeoutMinutes: 5)
R("cat.single", UserAskNotificationPlan.categoryId(for: single))
R("cat.two", UserAskNotificationPlan.categoryId(for: two))
R("cat.multi", UserAskNotificationPlan.categoryId(for: multiAsk))
R("cat.cm", UserAskNotificationPlan.categoryId(for: cm))
R("cat.ch", UserAskNotificationPlan.categoryId(for: ch))
let dyn = UserAskNotificationPlan.dynamicCategory(for: single, otherTitle: "Other…", sendTitle: "Send")!
R("dyn.actions", dyn.actions.map(\.id).joined(separator: ","))
R("dyn.textInput", dyn.actions.last!.kind == .textInput)
// [T-user-ask-notif-multi] Several questions: the notification shows the
// first unanswered one, "n/N · " in the body, its own category per question.
let opt2 = q(["type": "options", "question": "Then?", "options": [["label": "X"], ["label": "Y"], ["label": "Z"]]])!
var seq = PendingAsk(requestId: "seq", sessionId: "s", toolCallId: "t", questions: [opt, opt2, highNone, multi], createdAt: t0, timeoutMinutes: 5)
R("seq.all", UserAskNotificationPlan.dynamicCategories(for: seq, otherTitle: "o").map { "\($0.id)=\($0.actions.map(\.id).joined(separator: "+"))" }.joined(separator: ","))
func seqStep(_ a: PendingAsk) -> String {
    "\(UserAskNotificationPlan.notifiedIndex(a).map(String.init) ?? "nil")|\(UserAskNotificationPlan.categoryId(for: a))|\(UserAskNotificationPlan.body(a))"
}
R("seq.0", seqStep(seq))
seq.setAnswer(UserAskAnswer(selected: [1], otherText: nil, note: nil), at: 0)
R("seq.submit0", "\(seq.submit(0, now: t0))")
R("seq.1", seqStep(seq))
var a1 = UserAskAnswer(); a1.otherText = "typed"
seq.setAnswer(a1, at: 1); _ = seq.submit(1, now: t0)
R("seq.2", seqStep(seq))
var a2 = UserAskAnswer(); a2.confirmChoice = .approve
seq.setAnswer(a2, at: 2); _ = seq.submit(2, now: t0)
R("seq.3", seqStep(seq))
seq.setAnswer(UserAskAnswer(selected: [0, 2], otherText: nil, note: nil), at: 3)
R("seq.submit3", "\(seq.submit(3, now: t0))|\(UserAskNotificationPlan.notifiedIndex(seq).map(String.init) ?? "nil")")
R("seq.single.body", UserAskNotificationPlan.body(single))
R("seq.ids", UserAskNotificationPlan.dynamicCategoryIds(requestId: "seq", questionCount: 2).joined(separator: ","))
var regSeq = UserAskCategoryRegistry()
UserAskNotificationPlan.dynamicCategories(for: PendingAsk(requestId: "seq", sessionId: "s", toolCallId: "t", questions: [opt, opt2], createdAt: t0, timeoutMinutes: 5), otherTitle: "o").forEach { regSeq.add($0) }
UserAskNotificationPlan.dynamicCategories(for: PendingAsk(requestId: "seqX", sessionId: "s", toolCallId: "t", questions: [opt], createdAt: t0, timeoutMinutes: 5), otherTitle: "o").forEach { regSeq.add($0) }
regSeq.remove(requestId: "seq")
R("seq.regAfterRemove", regSeq.dynamic.keys.sorted().joined(separator: ","))
R("optIndex", "\(UserAskNotificationPlan.optionIndex(fromActionId: "opt:2") ?? -1)|\(UserAskNotificationPlan.optionIndex(fromActionId: "confirm.allow") ?? -1)")
// [T-user-ask-notif-next-id] one notification id per question
R("nid.q0", UserAskNotificationPlan.notificationId(requestId: "r1", index: 0))
R("nid.q1", UserAskNotificationPlan.notificationId(requestId: "r1", index: 1))
R("nid.all", UserAskNotificationPlan.allNotificationIds(requestId: "r1", questionCount: 3).joined(separator: ","))
R("nid.all0", UserAskNotificationPlan.allNotificationIds(requestId: "r1", questionCount: 0).joined(separator: ","))
let statics = UserAskNotificationPlan.staticCategories(titles: ("Cancel", "Allow once", "Open app"))
R("static.ids", statics.map(\.id).joined(separator: ","))
// The actions a confirm notification really gets: its category's actions.
func confirmActions(_ a: PendingAsk) -> String {
    let id = UserAskNotificationPlan.categoryId(for: a)
    return statics.first { $0.id == id }?.actions.map { "\($0.id):\($0.requiresAuthentication):\($0.opensApp)" }.joined(separator: ",") ?? "none"
}
R("actions.medium", confirmActions(cm))
R("actions.high", confirmActions(ch))
var reg = UserAskCategoryRegistry()
reg.add(dyn)
reg.add(UserAskNotificationPlan.dynamicCategory(for: PendingAsk(requestId: "zzz", sessionId: "s", toolCallId: "t", questions: [opt], createdAt: t0, timeoutMinutes: 5), otherTitle: "o", sendTitle: "s")!)
R("reg.full", reg.fullSet(static: statics, preserving: ["minis.turn.done"]).joined(separator: ","))
reg.remove(requestId: "abc")
R("reg.afterRemove", reg.fullSet(static: statics).joined(separator: ","))
// --- persistence and recovery (P2)
let suite = UserDefaults(suiteName: "user-ask-test-\(UUID().uuidString)")!
let store = UserAskRecordStore(defaults: suite)
var rec = UserAskRecord(ask: PendingAsk(requestId: "rA", sessionId: "s1", toolCallId: "tcA", questions: [opt], createdAt: t0, timeoutMinutes: 5),
                        assistantRawJSON: Data("{\"x\":1}".utf8), siblingToolUseIds: ["tcB"])
rec.ask.setAnswer(UserAskAnswer(selected: [1], otherText: nil, note: "draft note"), at: 0)
store.save(rec)
let reloaded = UserAskRecordStore(defaults: suite).record("rA")
R("store.roundTrip", reloaded == rec)
R("store.draftKept", reloaded?.ask.answers[0].note ?? "-")
R("rec.pendingInTime", UserAskRecovery.action(for: rec, now: t0.addingTimeInterval(60), toolResultInStore: false) == .awaitUser)
R("rec.pendingExpired", UserAskRecovery.action(for: rec, now: t0.addingTimeInterval(301), toolResultInStore: false) == .timeOutThenDeliver)
var answered = rec; answered.ask.submitted.insert(0); answered.ask.resolveAnswered(source: .notification)
R("rec.answered", UserAskRecovery.action(for: answered, now: t0.addingTimeInterval(9999), toolResultInStore: false) == .deliver)
R("rec.alreadyInStore", UserAskRecovery.action(for: answered, now: t0, toolResultInStore: true) == .alreadyDelivered)
var consumedRec = answered; _ = consumedRec.ask.consume()
R("rec.consumed", UserAskRecovery.action(for: consumedRec, now: t0, toolResultInStore: false) == .alreadyDelivered)
R("fallback", UserAskRecovery.plainTextFallback(answered.ask).contains("→ answered: B") && UserAskRecovery.plainTextFallback(answered.ask).contains("draft note"))
store.save(consumedRec)
store.purge(now: t0)
R("purge.dropsConsumed", store.record("rA") == nil)
// [T-user-ask-deferred]
let dJSON = UserAskDeferred.toolResult(questionCount: 2)
let dObj = (try? JSONSerialization.jsonObject(with: Data(dJSON.utf8))) as? [String: Any]
R("def.statuses", ((dObj?["results"] as? [[String: Any]]) ?? []).map { "\($0["i"] ?? "?"):\($0["status"] ?? "?")" }.joined(separator: ","))
R("def.note", (dObj?["note"] as? String) ?? "-")
var dRec = UserAskRecord(ask: PendingAsk(requestId: "rD", sessionId: "s1", toolCallId: "tcD", questions: [opt], createdAt: t0, timeoutMinutes: 0),
                         assistantRawJSON: Data("{\"x\":1}".utf8))
dRec.ask.deferred = true
// [T-user-ask-deferred-ttl] No countdown, but not forever: it closes after
// UserAskDeferred.lifetime (1 h) instead of being restored and re-notified
// for days (req F4BEDF2B, 2026-10-06).
R("def.noDeadline", dRec.ask.expiresAt == nil && !dRec.ask.isExpired(at: t0.addingTimeInterval(59 * 60))
  && dRec.ask.isExpired(at: t0.addingTimeInterval(61 * 60)))
R("def.pendingWithResultInStore", UserAskRecovery.action(for: dRec, now: t0.addingTimeInterval(30 * 60), toolResultInStore: true) == .awaitUser)
R("def.expiredTimesOut", UserAskRecovery.action(for: dRec, now: t0.addingTimeInterval(86_400), toolResultInStore: true) == .timeOutThenDeliver)
var dAnswered = dRec
dAnswered.ask.setAnswer(UserAskAnswer(selected: [1], otherText: nil, note: "after lunch"), at: 0)
dAnswered.ask.submitted.insert(0); _ = dAnswered.ask.resolveAnswered(source: .app)
R("def.answeredUndelivered", UserAskRecovery.action(for: dAnswered, now: t0, toolResultInStore: true) == .deliverDeferred)
var dConsumed = dAnswered; _ = dConsumed.ask.consume()
R("def.consumed", UserAskRecovery.action(for: dConsumed, now: t0, toolResultInStore: true) == .alreadyDelivered)
R("def.sendsAnswer", "\(UserAskDeferred.sendsAnswer(dAnswered.ask))|\(UserAskDeferred.sendsAnswer(dRec.ask))")
var dDismissed = dRec; _ = dDismissed.ask.resolveDismissed(.replacedByNewAsk)
R("def.dismissedSendsNothing", !UserAskDeferred.sendsAnswer(dDismissed.ask) && dDismissed.ask.dismissReason == .replacedByNewAsk)
R("def.message", UserAskDeferred.answerMessage(dAnswered.ask).replacingOccurrences(of: "\n", with: "⏎"))
var dDelegated = dRec
dDelegated.ask.setAnswer(UserAskAnswer(selected: [], otherText: nil, note: nil), at: 0)
dDelegated.ask.answers[0].delegated = true
R("def.delegatedLine", UserAskRecovery.answerLines(dDelegated.ask, withStatus: false).first ?? "-")
R("def.fallbackUnchanged", UserAskRecovery.answerLines(dDelegated.ask, withStatus: true).first ?? "-")
// A record saved before `deferred` existed still decodes (the key is optional).
let oldJSON = try! JSONEncoder().encode(rec)
var oldObj = try! JSONSerialization.jsonObject(with: oldJSON) as! [String: Any]
var oldAsk = oldObj["ask"] as! [String: Any]; oldAsk.removeValue(forKey: "deferred"); oldObj["ask"] = oldAsk
let oldDecoded = try? JSONDecoder().decode(UserAskRecord.self, from: JSONSerialization.data(withJSONObject: oldObj))
R("def.oldRecordDecodes", oldDecoded != nil && oldDecoded?.ask.isDeferred == false)
var old = rec; old.ask.requestId = "rOld"; store.save(old)
store.purge(now: t0.addingTimeInterval(8 * 24 * 3600))
R("purge.dropsOld", store.all().isEmpty)
store.save(rec); store.remove("rA")
R("store.remove", store.all().isEmpty && suite.object(forKey: UserAskRecordStore.key) == nil)
// --- [T-user-ask-confirm-previous] wizard navigation: options, options, confirm
func f(_ o: UserAskSubmitOutcome) -> String {
    switch o { case .rejected: return "rejected"; case .advanced(let i): return "adv\(i)"; case .complete: return "complete" }
}
var w = PendingAsk(requestId: "w", sessionId: "s", toolCallId: "tw", questions: [opt, optNoDefault, medApprove], createdAt: t0, timeoutMinutes: 5)
R("nav.prev", "\(PendingAsk.showsPrevious(at: 0))|\(PendingAsk.showsPrevious(at: 1))|\(PendingAsk.showsPrevious(at: 2))")
w.setAnswer(UserAskAnswer(selected: [0]), at: 0)
R("nav.s0", f(w.submit(0, now: t0.addingTimeInterval(10))))
R("nav.s1incomplete", f(w.submit(1, now: t0.addingTimeInterval(20))))
w.setAnswer(UserAskAnswer(selected: [1]), at: 1)
R("nav.s1", f(w.submit(1, now: t0.addingTimeInterval(30))) + "|cur=\(w.currentIndex)")
// On the confirm (3/3): go back to question 2.
let tBack = t0.addingTimeInterval(200)
let backOK = w.goTo(1, now: tBack)
R("nav.back", "\(backOK)|cur=\(w.currentIndex)|submitted=\(w.submitted.sorted())|q2=\(w.answers[1].selected)|confirm=\(w.answers[2].confirmChoice.map { "\($0)" } ?? "nil")|state=\(w.state.rawValue)")
R("nav.backCountdown", w.expiresAt!.timeIntervalSince(tBack))
// Change question 2, Next → back on the still-open confirm, which stays undecided.
w.setAnswer(UserAskAnswer(selected: [0]), at: 1)
R("nav.resubmit", f(w.submit(1, now: t0.addingTimeInterval(220))) + "|cur=\(w.currentIndex)|submitted=\(w.submitted.sorted())|q2=\(w.answers[1].selected)|confirm=\(w.answers[2].confirmChoice.map { "\($0)" } ?? "nil")")
// Confirm submits on one tap: unanswered is rejected, a choice completes the ask.
R("nav.confirmEmpty", f(w.submit(2, now: t0.addingTimeInterval(230))))
w.setAnswer(UserAskAnswer(confirmChoice: .approve), at: 2)
R("nav.confirm", f(w.submit(2, now: t0.addingTimeInterval(240))))
_ = w.resolveAnswered(source: .app)
R("nav.afterResolve", "\(w.goTo(0, now: t0.addingTimeInterval(250)))|cur=\(w.currentIndex)|\(f(w.submit(0, now: t0.addingTimeInterval(250))))")
// A confirm in the middle (options, confirm, options): going back to it keeps its decision.
var m = PendingAsk(requestId: "m", sessionId: "s", toolCallId: "tm", questions: [opt, medCancel, optNoDefault], createdAt: t0, timeoutMinutes: 5)
m.setAnswer(UserAskAnswer(selected: [0]), at: 0); _ = m.submit(0, now: t0)
m.setAnswer(UserAskAnswer(confirmChoice: .deny), at: 1)
R("nav.midConfirm", f(m.submit(1, now: t0)))
_ = m.goTo(1, now: t0.addingTimeInterval(5))
R("nav.midBack", "cur=\(m.currentIndex)|submitted=\(m.submitted.sorted())|choice=\(m.answers[1].confirmChoice.map { "\($0)" } ?? "nil")")
R("nav.badIndex", "\(m.goTo(7, now: t0))|cur=\(m.currentIndex)")
// [T-user-ask-next-in-order] Back two steps from the confirm (3/3) to 1/3, then Next:
// 2/3 (already answered) comes next, then the confirm - not straight to 3/3.
var b2 = PendingAsk(requestId: "b2", sessionId: "s", toolCallId: "tb2", questions: [opt, optNoDefault, medApprove], createdAt: t0, timeoutMinutes: 5)
b2.setAnswer(UserAskAnswer(selected: [0]), at: 0); _ = b2.submit(0, now: t0)
b2.setAnswer(UserAskAnswer(selected: [1]), at: 1); _ = b2.submit(1, now: t0)
_ = b2.goTo(1, now: t0); _ = b2.goTo(0, now: t0)
R("nav.backTwoNext", f(b2.submit(0, now: t0)) + "|cur=\(b2.currentIndex)")
R("nav.backTwoNext2", f(b2.submit(1, now: t0)) + "|cur=\(b2.currentIndex)")
// From the LAST question with an earlier one still open: back to that one.
var j = PendingAsk(requestId: "j", sessionId: "s", toolCallId: "tj", questions: [opt, optNoDefault, opt], createdAt: t0, timeoutMinutes: 5)
j.setAnswer(UserAskAnswer(selected: [0]), at: 0); _ = j.submit(0, now: t0)
_ = j.goTo(2, now: t0)
j.setAnswer(UserAskAnswer(selected: [0]), at: 2)
R("nav.lastWithOpen", f(j.submit(2, now: t0)) + "|cur=\(j.currentIndex)")
j.setAnswer(UserAskAnswer(selected: [0]), at: 1)
R("nav.lastOpenDone", f(j.submit(1, now: t0)))
// [T-user-ask-fallback] Text-ask detector, on replies from /tmp/ua_analysis/evidence.md (B).
let askSamples: [(String, String)] = [
    ("p.confirm", "…源码本身几乎不占空间，留着就行。\n\n要我现在删这两个 build 目录吗？"),
    ("p.either", "- 缺点是换设备或重装后，要在新设备上重新禁用一次。\n\n你想先做本地禁用，还是直接做同步？"),
    ("p.listAfter", "你想怎么继续？\n1. 我再重试一次对话内测试。\n2. 让 Worker 在真机上跑一轮完整回归。我推荐这个。"),
    ("p.shortClose", "要不要我让 worker 把这个动作也加进后面的负载里？注意这个动作会取消 iPhone 11 上的定时任务，所以我先问你。\n\n下一次跟进在 3 分钟后。"),
    ("p.header", "## 需要你决定\n- 能不能 push `feat/aot-family-match`？\n- IPA 826 还没在 iPhone 上验证。\n\n另外，它汇总里提到了写记忆，我没有核实它具体写了什么。"),
    ("p.headerList", "要不要我让两个 worker 按这个方案开工？开工前需要你先定三件事：\n- 快捷指令写入已禁用变量时的行为。\n- 状态是否跨设备同步。"),
    ("p.english", "Both fixes are in.\n\nShould I archive now, or wait until A is committed?"),
    ("p.persona", "我让它按\"保留现场\"没有清理。\n\n要我让它清理这些，还是继续做备份往返联调？Pika~"),
    ("n.progress", "第 22 次跟进：还是在等性能对比，没有新进展，Pika~\n- 确认和凭据：没有在等你，也没缺凭据。\n\n下一次跟进在 1 分钟后。"),
    ("n.conditional", "如果你想改用 OAuth 登录，需要先取消这个环境变量。要换的话告诉我一声，Pika~"),
    ("n.followUpOffer", "每批完成后它会汇报提交 hash、改动文件、测试结果。\n\n要不要我设一个定时任务跟进？"),
    ("n.monitorOffer", "它的任务仍是只分析和设计，不改代码。\n\n要不要我设一个定时任务，每隔几分钟看一次它的进展？"),
    ("n.questionMid", "你知道为什么吗？因为缓存失效了。\n\n我已经修好并提交了。"),
    ("n.rhetorical", "列表又卡住了。为什么会这样？"),
    ("n.empty", ""),
]
for (k, t) in askSamples { R("ask.\(k)", UserAskTextAsk.endsWithDecisionRequest(t)) }
// [T-user-ask-prompt-consolidated]
R("pt.off", UserAskPromptText.systemPromptText(exposed: false).isEmpty)
R("pt.on", UserAskPromptText.systemPromptText(exposed: true).replacingOccurrences(of: "\n", with: "⏎"))
func hasCJK(_ s: String) -> Bool { s.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) } }
let allText = UserAskPromptText.toolListLine + UserAskPromptText.toolDescription + UserAskDeferred.note
R("pt.noCJK", !hasCJK(allText))
R("pt.noScenario", !["report", "scheduled", "worker", "check-in", "Pending decisions", "要不要", "拍板"].contains { allText.localizedCaseInsensitiveContains($0) })
R("pt.tendencyOnce", allText.components(separatedBy: "prefer this over asking in plain text").count - 1)
R("pt.noDeferredInDescription", !UserAskPromptText.toolDescription.contains("deferred"))
print(out.joined(separator: "\n"))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = [("core.swift", block), ("main.swift", harness)]
for (n, t) in files { try t.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping UserAskCore compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
if rc != 0 { print(out) }
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}

print("\n1. Parsing and validation (errors tell the model how to fix the call)")
check("empty / >4 questions rejected", r["emptyQuestions"] == "true" && r["fiveQuestions"] == "true")
check("type must be options|confirm", r["badType"] == "true")
check("missing type + options → options (the 2026-10-07 deepseek-flash call)", r["inferOptions"] == "options|2|HubSign")
check("unknown type value + options → options", r["inferOptionsUnknownType"] == "options")
check("default without options still needs a valid index (inferred options, then validated)", r["inferOptionsFromDefault"]?.contains("0-based index") == true)
check("missing type + options + multi_select → options, multi kept", r["inferOptionsMulti"] == "options|true")
check("missing type + impact/risk → confirm", r["inferConfirm"] == "confirm|high|deletes build output")
check("missing type + risk only → confirm", r["inferConfirmRiskOnly"] == "confirm")
check("bare question without type is still rejected (open ask vs approval is ambiguous)",
      r["bareNoType"]?.contains("type must be \"options\" or \"confirm\"") == true)
check("options and confirm fields together without type are rejected", r["mixedNoType"]?.contains("type must be") == true)
check("an explicit type is never overridden by inference", r["explicitTypeWins"] == "true")
check("a single option is rejected (don't ask; take it)", r["singleOption"] == "true")
check("more than 4 options rejected", r["fiveOptions"] == "true")
check("confirm takes no options", r["confirmWithOptions"] == "true")
check("options default must be an in-range index", r["defaultOutOfRange"] == "true")
check("a confirm's default / scope_key are ignored, not errors", r["confirmDefaultIgnored"] == "OK")
check("\"(Recommended)\" is stripped from labels", r["stripRecommended"] == "A")
check("options default parsed", r["optDefault"] == "true")
check("omitting options = open-ended", r["openEnded"] == "true")
check("confirm: risk and impact parsed, no default kept", r["confirmParsed"] == "high|true|rewrites remote")
check("confirm risk defaults to medium", r["confirmRiskDefaultsMedium"] == "medium")
check("multi_select needs options", r["multiOnlyWithOptions"] == "false")

print("\n2. §20.4 timeout - the app takes no action")
// [T-user-ask-prompt-consolidated] The note states what happened; what to do
// on a timeout is in the tool description (said once).
let noteFor5 = "No answer within 5 min. Nothing was applied or approved."
check("options with default → timeout + that option's label as `default` (unconfirmed)",
      r["to.optDefault1"] == #"{"results":[{"default":"B","i":0,"note":"\#(noteFor5)","status":"timeout"}]}"#)
check("options with default 0 → its label", (r["to.optDefault0"] ?? "").contains(#""default":"A""#) && (r["to.optDefault0"] ?? "").contains(#""status":"timeout""#))
check("options without default → the recommended (first) option as `default`",
      (r["to.optNoDefault"] ?? "").contains(#""default":"A""#) && (r["to.optNoDefault"] ?? "").contains(#""status":"timeout""#))
check("the options note states what happened (the suggestion travels in `default`)", r["to.noteOpt"] == noteFor5)
check("open-ended → timeout, no default", !(r["to.open"] ?? "").contains("default") && (r["to.open"] ?? "").contains(#""status":"timeout""#))
check("every confirm (any risk, any default sent) → timeout, no default, no answer",
      (r["to.confirms"] ?? "").components(separatedBy: "‖").count == 5
      && (r["to.confirms"] ?? "").components(separatedBy: "‖").allSatisfy { $0.contains(#""status":"timeout""#) && !$0.contains(#""default""#) && !$0.contains(#""answer":"#) })
check("confirm note: nothing applied or approved, no suggestion",
      r["to.note"] == "No answer within 7 min. Nothing was applied or approved.")

print("\n2b. Text-ask detector [T-user-ask-fallback] (replies from the 24h evidence)")
for k in ["p.confirm", "p.either", "p.listAfter", "p.shortClose", "p.header", "p.headerList", "p.english", "p.persona"] {
    check("asks: \(k)", r["ask.\(k)"] == "true")
}
for k in ["n.progress", "n.conditional", "n.followUpOffer", "n.monitorOffer", "n.questionMid", "n.rhetorical", "n.empty"] {
    check("does not ask: \(k)", r["ask.\(k)"] == "false")
}

print("\n3. Answers → results")
check("picked option label", r["ans.picked"] == "B")
check("note travels with the answer", r["ans.note"] == "not config.json")
check("Other text → status other", r["ans.other"] == "other")
check("You decide → delegated", r["ans.delegated"] == "delegated")
check("confirm approve / deny(+note)", r["ans.approve"] == "approved" && r["ans.deny"] == "denied|use revert")
check("legacy: a stored approveAlways choice reads as approve", r["legacy.choice"] == "approve")
check("legacy: every timeout_* reads as timeout, approved_always as approved",
      r["legacy.status"] == "timeout,timeout,timeout,timeout,approved,timeout,denied,nil")
check("multi-select returns labels + typed extra", r["ans.multi"] == "A,C,D")
check("free text clipped to 1000 chars", r["ans.clip"] == "1000")
check("encoded as {\"results\":[{i,status,answer}]}", r["encode"] == #"{"results":[{"answer":"A","i":0,"status":"answered"}]}"#)

print("\n4. State machine and idempotency")
check("expires 5 min after creation (wall clock)", r["expiresAt"] == "300.0" && r["notExpired"] == "false" && r["expired"] == "true")
check("any interaction restarts the countdown", r["interactionResets"] == "500.0")
check("nothing to consume before it resolves", r["consumeBeforeResolve"] == "true")
check("first resolution wins; later ones are refused", r["resolveAnswered"] == "true" && r["secondResolveLoses"] == "false")
check("records answered + source", r["stateAnswered"] == "answered|notification")
check("tool_result is consumed exactly once", r["consumeOnce"] == "true" && r["consumeTwice"] == "true")
check("drafts cannot change a resolved ask", r["draftIgnoredAfterResolve"] == "[1]")
check("timeout keeps submitted answers; every other question is a plain timeout",
      r["partialTimeout"] == "true" && r["partialStatuses"] == "answered,timeout,timeout")
check("timeout changes no answer (the unsubmitted draft stays a draft, not an answer)",
      r["partialAnswersKept"] == "[1]|[0]|nil" && r["partialDraftNotSent"] == "true")
check("a legacy persisted ask (autoDefaultMode, scopeKey, confirm default, approveAlways, old statuses) still decodes",
      r["legacy.ask"] == "ok|approve|nil|timeout,timeout")
check("a dismiss after the timeout is refused", r["dismissAfterTimeoutLoses"] == "false")
check("superseded by a new message → dismissed with the reason",
      r["superseded"] == "true" && r["supersededState"] == "dismissed|superseded_by_user_message|dismissed")
check("Stop → cancelled", r["stopped"] == "true|cancelled")
check("timeoutMinutes 0 waits indefinitely", r["waitForever"] == "true|false")
check("PendingAsk survives a JSON round trip (persisted form)", r["roundTrip"] == "true")

print("\n4b. Wizard navigation - Previous on any question but the first (options AND confirm)")
check("Previous shows from question 2 on, never on the first (incl. a first-question confirm)", r["nav.prev"] == "false|true|true")
check("submit advances to the next unsubmitted question", r["nav.s0"] == "adv1")
check("an incomplete answer cannot be submitted", r["nav.s1incomplete"] == "rejected")
check("reaching the confirm (3/3)", r["nav.s1"] == "adv2|cur=2")
check("going back from the confirm: shows Q2, keeps every answer, submits nothing",
      r["nav.back"] == "true|cur=1|submitted=[0, 1]|q2=[1]|confirm=nil|state=pending")
check("going back restarts the countdown (5 min from the tap)", r["nav.backCountdown"] == "300.0")
check("changing Q2 and pressing Next returns to the still-open confirm, which stays undecided",
      r["nav.resubmit"] == "adv2|cur=2|submitted=[0, 1]|q2=[0]|confirm=nil")
check("the confirm still needs a choice; a choice completes the ask",
      r["nav.confirmEmpty"] == "rejected" && r["nav.confirm"] == "complete")
check("after resolve, navigation is inert", r["nav.afterResolve"] == "false|cur=2|rejected")
check("a confirm in the middle: going back to it keeps its decision and its submitted flag",
      r["nav.midConfirm"] == "adv2" && r["nav.midBack"] == "cur=1|submitted=[0, 1]|choice=deny")
check("an out-of-range index is ignored", r["nav.badIndex"] == "false|cur=1")
check("back from 3/3 to 1/3, Next goes to 2/3 (answered), not straight to 3/3",
      r["nav.backTwoNext"] == "adv1|cur=1" && r["nav.backTwoNext2"] == "adv2|cur=2")
check("Next on the last question with an earlier one open returns to it; then the ask completes",
      r["nav.lastWithOpen"] == "adv1|cur=1" && r["nav.lastOpenDone"] == "complete")
let cardSrc = source("Views/Chat/UserAskCardView.swift")
let centerSrc = source("Agent/Chat/UserAskCenter.swift")
check("card: confirm row - Previous on the left, Cancel + Allow once together on the right",
      cardSrc.contains("                    if showsPrevious {\n                        previousButton(fill: false)\n                    }\n                    Spacer(minLength: 12)\n                    cancelButton\n                    allowOnceButton"))
check("card: options and confirm share one Previous (same string, secondary style, only goTo)",
      cardSrc.contains("Button(AppLocalized(\"Previous\")) {\n            UserAskCenter.shared.goTo(requestId: ask.requestId, index: index - 1)\n        }")
      && cardSrc.components(separatedBy: "AppLocalized(\"Previous\")").count - 1 == 1
      && cardSrc.contains("if PendingAsk.showsPrevious(at: index) {\n                    previousButton(fill: true)"))
let beginBody: String = {
    guard let r0 = centerSrc.range(of: "func begin(_ record: UserAskRecord) {"),
          let r1 = centerSrc.range(of: "\n    }\n", range: r0.upperBound..<centerSrc.endIndex) else { return "" }
    return String(centerSrc[r0.upperBound..<r1.lowerBound])
}()
check("center: begin() settles nothing up front (no always-allow pre-answer)",
      !beginBody.isEmpty && !centerSrc.contains("isAlwaysAllowed") && !beginBody.contains("confirmChoice")
      && !beginBody.contains("resolveAnswered") && !beginBody.contains("submitted.insert"))
check("card: confirm shows Cancel and Allow once only - no Always allow, no 'on timeout' line",
      !cardSrc.contains("alwaysAllowButton") && !cardSrc.contains("Always allow") && !cardSrc.contains("timeoutHint")
      && cardSrc.contains("cancelButton\n                    allowOnceButton"))
check("center: goTo / submitQuestion go through the tested core rules",
      centerSrc.contains("mutate(requestId) { ask in ask.goTo(index, now: Date()) }")
      && centerSrc.contains("switch ask.submit(index, now: Date()) {"))

print("\n5. Notification categories")
check("single options question → its own dynamic category", r["cat.single"] == "minis.ask.abc")
check("actions are not switchable: categoryId has no on/off parameter",
      core.contains("static func categoryId(for ask: PendingAsk) -> String {") && !core.contains("actionsEnabled"))
check("several questions → the shown question's own category; multi-select → open-only",
      r["cat.two"] == "minis.ask.def.q0" && r["cat.multi"] == "minis.ask.open")
check("confirm medium and high → the same single category", r["cat.cm"] == "minis.confirm" && r["cat.ch"] == "minis.confirm")
check("option actions are opt:<index> (not labels) + Other text input",
      r["dyn.actions"] == "opt:0,opt:1,other" && r["dyn.textInput"] == "true")
print("\n5b. Several questions from the notification [T-user-ask-notif-multi]")
check("every single-choice question has its own category, registered up front (confirm / multi-select use the shared ones)",
      r["seq.all"] == "minis.ask.seq.q0=opt:0+opt:1+other,minis.ask.seq.q1=opt:0+opt:1+opt:2+other")
check("starts on question 1: its category, body '1/4 · …'", r["seq.0"] == "0|minis.ask.seq.q0|1/4 · Which?")
check("answering moves the notification to the next question", r["seq.submit0"] == "advanced(to: 1)" && r["seq.1"] == "1|minis.ask.seq.q1|2/4 · Then?")
check("a confirm in the sequence uses the confirm category", r["seq.2"] == "2|minis.confirm|3/4 · x")
check("a multi-select question is answered in the app (open-only)", r["seq.3"] == "3|minis.ask.open|4/4 · x")
check("the last answer completes the ask; nothing left to show", r["seq.submit3"] == "complete|nil")
check("a one-question ask: no 'n/N' prefix, plain per-request category (unchanged)", r["seq.single.body"] == "Which?" && r["cat.single"] == "minis.ask.abc")
check("cleanup covers the plain id and every per-question id", r["seq.ids"] == "minis.ask.seq,minis.ask.seq.q0,minis.ask.seq.q1")
check("removing an ask removes its per-question categories, never another ask's (seq vs seqX)", r["seq.regAfterRemove"] == "minis.ask.seqX")
check("action id → option index", r["optIndex"] == "2|-1")
check("one confirm category registered (no minis.confirm.high / .medium)", r["static.ids"] == "minis.confirm,minis.ask.open")
check("each question of a request has its own notification id (no in-place update of the answered one)",
      r["nid.q0"] == "user-ask-r1-q0" && r["nid.q1"] == "user-ask-r1-q1" && r["nid.q0"] != r["nid.q1"])
check("clearing covers every question plus the old per-request id",
      r["nid.all"] == "user-ask-r1,user-ask-r1-q0,user-ask-r1-q1,user-ask-r1-q2" && r["nid.all0"] == "user-ask-r1,user-ask-r1-q0")
let centerNotif = source("Agent/Chat/UserAskCenter.swift")
check("center posts under the question's id, clears the request's other ones, and clears all ids when done",
      centerNotif.contains("let identifier = UserAskNotificationPlan.notificationId(requestId: ask.requestId, index: index)")
      && centerNotif.contains("UNNotificationRequest(identifier: identifier, content: content, trigger: nil)")
      && centerNotif.contains(".filter { $0 != identifier }\n        center.removeDeliveredNotifications(withIdentifiers: others)")
      && centerNotif.contains("let ids = UserAskNotificationPlan.allNotificationIds(requestId: requestId, questionCount: count)")
      && !centerNotif.contains("Self.notificationId("))
check("medium confirm notification: Cancel + Allow once (Allow requires unlock)",
      r["actions.medium"] == "confirm.cancel:false:false,confirm.allow:true:false")
check("high and medium confirm notifications get the same action set", r["actions.high"] == r["actions.medium"])
check("the registry hands out the WHOLE set (statics + all live asks + others)",
      r["reg.full"] == "minis.confirm,minis.ask.open,minis.ask.abc,minis.ask.zzz,minis.turn.done")
check("removing one ask keeps the others", r["reg.afterRemove"] == "minis.confirm,minis.ask.open,minis.ask.zzz")

print("\n6a. Prompt text [T-user-ask-prompt-consolidated]")
check("system prompt: no user_ask text at all when the tool is not in the run", r["pt.off"] == "true")
check("system prompt when exposed: one neutral tool-list line", r["pt.on"] == "- user_ask: Ask the user questions on an in-chat card and wait for the answer.⏎")
check("all user_ask prompt text is English (no CJK)", r["pt.noCJK"] == "true")
check("no scenario words (report / scheduled / worker / check-in / Pending decisions)", r["pt.noScenario"] == "true")
check("the one tendency is stated exactly once", r["pt.tendencyOnce"] == "1")
check("deferred is explained only where it happens (the tool result), not in the description", r["pt.noDeferredInDescription"] == "true")

print("\n6b. Deferred asks [T-user-ask-deferred]")
check("deferred tool result: one `deferred` status per question", r["def.statuses"] == "0:deferred,1:deferred")
check("…with a one-sentence note: the answer comes as the next message, end the turn",
      r["def.note"] == "The card is shown; the answer will arrive as the user's next message. End your turn now.")
check("a deferred ask has no countdown, but expires after its 1 h lifetime", r["def.noDeadline"] == "true")
check("recovery: still pending and within its lifetime → card restored, even though its `deferred` result is in the store", r["def.pendingWithResultInStore"] == "true")
check("recovery: a deferred ask past its lifetime is timed out, not restored again", r["def.expiredTimesOut"] == "true")
check("recovery: answered but not handed on → deliverDeferred; handed on → done",
      r["def.answeredUndelivered"] == "true" && r["def.consumed"] == "true")
check("only a real answer becomes the next message (pending, dismissed or replaced send nothing)",
      r["def.sendsAnswer"] == "true|false" && r["def.dismissedSendsNothing"] == "true")
check("the answer message: what the user chose (their bubble), then a note for the model",
      r["def.message"] == "1. Which? → B (note: after lunch)⏎<system-reminder>The user's answers to your earlier question card.</system-reminder>")
check("\"you decide\" in the answer message; the recovery fallback keeps its status-only form",
      r["def.delegatedLine"] == "1. Which? → you decide" && r["def.fallbackUnchanged"] == "1. Which? → unanswered")
check("records saved before `deferred` existed still decode", r["def.oldRecordDecodes"] == "true")

print("\n6. Persistence and recovery (P2)")
check("record (ask + assistant snapshot + siblings) survives a reload", r["store.roundTrip"] == "true")
check("unsubmitted drafts are persisted", r["store.draftKept"] == "draft note")
check("still pending, in time → show the card again", r["rec.pendingInTime"] == "true")
check("still pending, past the wall-clock deadline → time out, then deliver", r["rec.pendingExpired"] == "true")
check("answered but not delivered (e.g. from a notification after a kill) → deliver", r["rec.answered"] == "true")
check("idempotent by toolCallId: a tool_result already in the transcript → nothing to do", r["rec.alreadyInStore"] == "true")
check("already consumed → nothing to do", r["rec.consumed"] == "true")
check("unreadable snapshot → answers kept as a plain message", r["fallback"] == "true")
check("purge drops delivered records", r["purge.dropsConsumed"] == "true")
check("purge drops records older than 7 days", r["purge.dropsOld"] == "true")
check("remove clears the store key when empty", r["store.remove"] == "true")

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
