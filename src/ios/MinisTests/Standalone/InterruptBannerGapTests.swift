#!/usr/bin/env swift
// [T-interrupt-banner-gap] Session "产品官方X账号注册指南" (2026-10-08 11:11):
// after Stop, the "Interrupted — tap Resume" banner sat ~2pt under the
// next-step (user_ask) card above it; after reopening the session the gap was
// the normal ~10pt (8pt itemSpacing + the footer's 2pt padding), the same as
// every other pair of rows.
//
// The footer's "hug" policy (no itemSpacing above a quiet meta/usage footer,
// full itemSpacing above a prominent one — typing row, error, resume banner)
// was written only by the snapshot seed loop. The log shows the order:
//   11:11:36.161 footer-shape active true→false   (turn ends)
//   11:11:36.176 [footer] prominent=false + SKIP (items unchanged)
//   11:11:36.538 Case 1 (tool cancel) … canResume=true
//   11:11:36.570 footer-shape changed — height caches dropped, NO apply
// so the banner kept the quiet-footer policy until a fresh apply on reopen
// (`[footer] idx=136 seeded=48 prominent=true`).
//
// Source guards:
//   - one prominence function, used by the snapshot seed and updateBridge
//   - a footer shape flip re-applies the policy and re-lays out on change
//   - setFooterHug reports a change against the layout's default (hug)
//
// Run: swift InterruptBannerGapTests.swift
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

let V3 = "Agent/MessageList/CollectionViewMessageListV3/"
let footerHeight = source(V3 + "Coordinator/MessageListV3Coordinator+FooterHeight.swift")
let bridges = source(V3 + "Coordinator/MessageListV3Coordinator+BridgeUpdates.swift")
let snapshot = source(V3 + "Coordinator/MessageListV3Coordinator+Snapshot.swift")
let layout = source("Agent/MessageList/MessageListLayout.swift")
let view = source(V3 + "Cells/BridgedAssistantFooterV3.swift")
check("sources readable", ![footerHeight, bridges, snapshot, layout, view].contains(""))

print("[1] One prominence rule")
let prominent = between(footerHeight, "func isFooterProminent(", "func refreshFooterHug(") ?? ""
check("resume banner counts as prominent on the last message",
      prominent.contains("let showsResume = isLastMsg && !hasError\n                && vm.canResume && !vm.isProcessing")
      && prominent.contains("return hasError || showsResume || isActive"))
check("the snapshot seed uses it (no second copy)",
      snapshot.contains("footerProminent = isFooterProminent(footerMsgId, footerMessage: footerMsg,")
      && !snapshot.contains("let showsResume = isLastMsg"))
check("premise: the view shows the banner on the same condition",
      view.contains("if bridge.canResume && message.error == nil {\n                resumeBanner"))

print("[2] A shape flip re-applies the policy")
let flip = between(bridges, "if !isInitialBridgeSetup, afterShape != beforeShape {", "AppLogger(") ?? ""
check("updateBridge refreshes the hug next to the height invalidation",
      ordered(flip, ["invalidateFooterHeightCaches(messageId: message.id)",
                     "refreshFooterHug(messageId: message.id, message: message, in: messages)"]))
check("canResume is part of the footer shape",
      (between(bridges, "struct FooterHeightShape: Equatable {", "init(") ?? "").contains("let canResume: Bool"))
let refresh = between(footerHeight, "func refreshFooterHug(", "func invalidateFooterHeightCaches(") ?? ""
check("refresh: same rule, and invalidateLayout only when the policy changed",
      ordered(refresh, ["firstIndex(of: .assistantFooter(messageId))",
                        "isFooterProminent(messageId, footerMessage: message, messages: messages, vm: vm)",
                        "guard layout.setFooterHug(!prominent, at: idx) else { return }",
                        "layout.invalidateLayout()"]))

print("[3] Layout")
let setter = between(layout, "func setFooterHug(_ hug: Bool, at index: Int) -> Bool {", "}") ?? ""
check("setFooterHug reports a change against the default (hug)",
      setter.contains("let changed = (footerHugByIndex[index] ?? true) != hug") && setter.contains("return changed"))
check("prepare() still reads the policy with hug as the default",
      layout.contains("&& (footerHugByIndex[i + 1] ?? true)"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
