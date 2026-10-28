#!/usr/bin/env swift
// [T-user-ask-notify-once] [T-user-ask-deferred-ttl] One unanswered deferred
// user_ask (req F4BEDF2B, scheduled-job run) kept posting "Needs your answer"
// with sound on every trip to the background (20:45:51, 20:46:09, 20:46:30,
// 20:47:33, 20:57:49 on 2026-10-06) and was restored on every activation
// ("RECOVER awaiting"), long after the conversation had moved on: a deferred
// ask had no expiry at all, and nothing remembered that its question had
// already been notified.
//
// Source guards (the timing rules themselves are compiled and exercised in
// UserAskCoreTests 6b):
//   - postNotification skips an expired ask and a question already notified,
//     reading the live ask; records the notified index after posting
//   - notifiedIndex is optional (old records decode)
//   - deferred asks expire after UserAskDeferred.lifetime; recovery times an
//     expired one out instead of restoring it
//
// Run: swift UserAskNotifyOnceTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
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
func ordered(_ s: String, _ parts: [String]) -> Bool {
    var from = s.startIndex
    for p in parts {
        guard let r = s.range(of: p, range: from..<s.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}

let center = source("Agent/Chat/UserAskCenter.swift")
let core = source("Agent/Chat/UserAskCore.swift")
let post = between(center, "private func postNotification(for ask: PendingAsk, sound: Bool = true) {",
                   "static func notificationBody(") ?? ""
check("postNotification found", !post.isEmpty)
check("an expired ask is never notified", post.contains("ask.state == .pending, !ask.isExpired(at: Date()),"))
check("the already-notified check reads the live ask, not the caller's copy",
      post.contains("let latest = asks[ask.requestId] ?? ask") && post.contains("if latest.notifiedIndex == index {"))
check("a skipped repeat is logged", post.contains("[UserAsk] NOTIFY skipped req="))
check("order: skip check before the post, notified index recorded after it",
      ordered(post, ["if latest.notifiedIndex == index {", "center.add(request)", "[UserAsk] NOTIFY req=",
                     "mutate(ask.requestId) { $0.notifiedIndex = index }"]))
check("background still posts for pending asks (now deduplicated inside postNotification)",
      center.contains("for ask in asks.values where ask.state == .pending { postNotification(for: ask) }"))
check("notifiedIndex is optional so records saved before it decode",
      (between(core, "struct PendingAsk: Codable, Equatable {", "init(requestId:") ?? "").contains("var notifiedIndex: Int?"))
let expired = between(core, "func isExpired(at now: Date) -> Bool {", "mutating func noteInteraction") ?? ""
check("deferred asks expire after UserAskDeferred.lifetime",
      expired.contains("if isDeferred { return now >= createdAt.addingTimeInterval(UserAskDeferred.lifetime) }"))
check("an explicit deadline still wins", ordered(expired, ["if let expiresAt { return now >= expiresAt }", "if isDeferred {"]))
check("lifetime is one hour", core.contains("static let lifetime: TimeInterval = 60 * 60"))
let recovery = between(core, "if r.ask.isDeferred {", "if r.ask.consumed || toolResultInStore") ?? ""
check("recovery: deferred past its lifetime → timed out, else restored",
      ordered(recovery, ["if r.ask.consumed { return .alreadyDelivered }", "if r.ask.state.isTerminal { return .deliverDeferred }",
                         "return r.ask.isExpired(at: now) ? .timeOutThenDeliver : .awaitUser"]))
check("a timed-out deferred ask sends no message (only an answered one does)",
      core.contains("ask.isDeferred && ask.state == .answered"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
