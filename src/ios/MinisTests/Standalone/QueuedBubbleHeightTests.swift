#!/usr/bin/env swift
// [T-queued-bubble-height-after-drain] Session "查找远程 ISHM64 开发会话"
// (2026-10-08 08:03): a prompt sent while the agent was running was queued,
// then delivered at the next tool gap. While queued the bubble sits beside its
// withdraw button (22pt icon + 6pt spacing), so the 36-char text wrapped to
// 3 lines and the row was measured and memoized at 87.3pt
// (`MemoWrite key=w:68EEEF8E…:36:0 h=87.3`). After delivery the button is
// gone and the text needs 2 lines (~67pt), but the row kept 87.3pt: the
// hosting view centred the bubble in it, ~10pt of extra space above and
// below, until the session was reopened (fresh measure).
//   - `isQueued = false` re-renders the row in place: nothing re-measured it.
//   - the per-row (`w:`) and cross-load (`w|`) height keys did not include the
//     queued state, so even a reconfigure re-seeded the queued height.
//
// Source guards (layout needs a device):
//   - both keys carry the queued state
//   - both queue-drain sites post the targeted row invalidation
//   - that handler clears the cell cache, invalidates the layout height and
//     reconfigures the row
//
// Run: swift QueuedBubbleHeightTests.swift
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

let est = source("Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+HeightEstimation.swift")
let queue = source("Agent/Chat/AIChatViewModel+PromptQueue.swift")
let snap = source("Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Snapshot.swift")
let view = source("Views/Chat/ChatMessageViews.swift")
check("sources readable", !est.isEmpty && !queue.isEmpty && !snap.isEmpty && !view.isEmpty)

print("[1] Keys separate queued from sent")
let w = between(est, "static func contentKey(for item: MessageListItem", "case .assistantHeader(let id):") ?? ""
check("per-row key appends :q while queued",
      w.contains("let q = msg(id)?.isQueued == true ? \":q\" : \"\"")
      && w.contains("return \"w:\\(id.uuidString):\\(n):\\(a)\\(q)\""))
let stable = between(est, "func stableHeightKey(for item: MessageListItem", "case .assistantBlock(let mid, let bid):") ?? ""
check("cross-load key and its cache signature include the queued state",
      stable.contains("let queued = m.isQueued")
      && stable.contains("&* 2 &+ (queued ? 1 : 0)")
      && stable.contains("\"w|\\(queued ? \"q|\" : \"\")"))

print("[2] Both drain sites invalidate the row")
let drains = queue.components(separatedBy: "msg.isQueued = false").count - 1
check("two isQueued = false sites", drains == 2)
check("each is followed by the targeted row invalidation",
      queue.components(separatedBy: "msg.isQueued = false\n").dropFirst().allSatisfy { tail in
          let next = tail.prefix(700)
          return next.contains("NotificationCenter.default.post(name: .minisUserAttachmentsMounted, object: msg.id)")
      })

print("[3] The handler re-measures the row")
let handler = between(snap, "attachMountSub = NotificationCenter.default.publisher(for: .minisUserAttachmentsMounted)",
                      "if thinkingToggleSub == nil {") ?? ""
check("handler hops to main (runs after the flip)", handler.contains(".receive(on: DispatchQueue.main)"))
check("clears the cell cache, invalidates the layout height, reconfigures, re-lays out",
      ordered(handler, ["clearCachedHeight()", "layout.invalidateHeight(at: idx)", "snap.reconfigureItems([item])",
                        "ds.apply(snap, animatingDifferences: false)", "layout.invalidateLayout()"]))

print("[4] The cause is still what it was (so the guard stays meaningful)")
check("queued bubble still renders the withdraw button beside the text",
      view.contains("if message.isQueued {") && view.contains("Image(systemName: \"xmark.circle.fill\")"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
