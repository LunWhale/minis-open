#!/usr/bin/env swift
// [T-stream-precalc-freeze] While a long turn streamed, its newest text block
// stayed ~32 pt tall while its text grew to ~1850 pt and drew over the rows
// around it (2026-10-04 11:02 and 11:07, session "GitHub Issue 回复与分类处理";
// log: [TableCellShort] cellH=32.0 contentBottom=944.3 tvH=1856.3, 0.3 s after
// the screenshot).
//
// Two changes met:
//   - 81e43b588 (July): SelfSizingCell returned the layout's PRECALC for the
//     streaming cell without measuring, on the premise that precalc is
//     "reseeded on every chunk". It is not: precalc is only written when a
//     snapshot applies (block-count changes). Inert while growing text blocks
//     had no precalc.
//   - 358818abd (10-03): the cross-load memo seeds precalc from a
//     content-hash key (`b|t|0|<bytes>|<hash>`), so a brand-new EMPTY text
//     block matched every earlier empty block's ~32 pt - the streaming block's
//     first precalc, which the short-circuit then returned for the whole turn.
//
// Pinned here:
//   [1] the streaming cell is measured live - no precalc short-circuit in
//       preferredLayoutAttributesFitting
//   [2] rows of a still-growing message get no precalc at snapshot time (no
//       memo, no cross-load memo, no attributed-string precalc) and lose any
//       an earlier snapshot left
//   [3] the growing rule is the same function configureCell's seed exclusion
//       uses, and the content-hash key really is content-only (why an empty
//       block collides)
//
// Run: swift StreamPrecalcFreezeTests.swift
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

let infra = source("Agent/MessageList/MessageListInfrastructure.swift")
let layout = source("Agent/MessageList/MessageListLayout.swift")
let coord = "Agent/MessageList/CollectionViewMessageListV3/Coordinator/"
let snapshot = source(coord + "MessageListV3Coordinator+Snapshot.swift")
let config = source(coord + "MessageListV3Coordinator+CellConfiguration.swift")
let estimation = source(coord + "MessageListV3Coordinator+HeightEstimation.swift")
guard !infra.isEmpty, !layout.isEmpty, !snapshot.isEmpty, !config.isEmpty, !estimation.isEmpty else {
    print("❌ sources not found"); exit(1)
}

print("1. The streaming cell is measured live")
let plaf = between(infra, "override func preferredLayoutAttributesFitting(", "// [T-ios-scroll-decel-height-drift] Seed short-circuit") ?? ""
check("found the interaction-window guard in preferredLayoutAttributesFitting", !plaf.isEmpty && plaf.contains("isStreamingItem"))
check("no branch returns the layout's precalc for the streaming cell",
      !plaf.contains("layout.precalcHeight(at: item)") && !infra.contains("copy.size.height = precalc"))
check("non-streaming cells still short-circuit to their cached height while streaming (crash-window lever kept)",
      plaf.contains("if layout.deferSelfSizing || streamingActive,") && plaf.contains("!isStreamingItem,"))
check("the removal is documented where the branch was", infra.contains("(REMOVED, [T-stream-precalc-freeze])"))

print("\n2. No precalc for a still-growing message's rows")
check("the snapshot computes the growing set once per pass",
      snapshot.contains("let growingIds = Self.liveAssistantMessageIds(messages: messages, isProcessing: vm.isProcessing)"))
check("a growing row drops any precalc an earlier snapshot left",
      snapshot.contains("let isGrowing = Self.messageId(of: item).map { growingIds.contains($0) } ?? false")
      && snapshot.contains("if isGrowing { layout.clearPrecalcHeight(at: i) }")
      && layout.contains("func clearPrecalcHeight(at index: Int) {\n        precalcHeights.removeValue(forKey: index)"))
check("…and gets neither the in-session memo nor the cross-load memo as precalc",
      snapshot.contains("if !isGrowing, let memo = layout.measuredHeight(forKey: contentKey, width: cvWidth) {")
      && snapshot.contains("if !isGrowing, let stableKey, let remembered = CrossLoadHeightMemo.shared.height(for: stableKey, width: cvWidth) {"))
check("…nor an attributed-string precalc (falls through to the estimate)",
      snapshot.contains("if !isGrowing, let attrStr = block.cachedAttributedString {"))
check("every unguarded precalc write left is for rows that cannot be growing (user bubbles)",
      snapshot.components(separatedBy: "layout.setPrecalcHeight(").count - 1 == 4
      && snapshot.contains("layout.setPrecalcHeight(h, at: i)") && snapshot.contains("msg.role == .user"))

print("\n3. Why it collided, and that both sides agree on \"growing\"")
check("configureCell's seed exclusion uses the same live-message rule",
      config.contains("liveAssistantIds(in: messages, isProcessing: vm.isProcessing).contains($0)")
      && config.contains("let ids = Self.liveAssistantMessageIds(messages: messages, isProcessing: isProcessing)"))
// [T-queued-candidate-spacing] "Last" is the live tail: the last message that
// is not a queued candidate bubble (see QueuedCandidateSpacingTests).
check("the live set is the last assistant turn plus turns with a running tool",
      estimation.contains("let tail = liveTailMessage(in: messages)\n            if let tail, tail.role == .assistant {")
      && estimation.contains("case .running, .streaming: return true"))
check("the cross-load key for a text block is content-only, so every empty block shares one",
      estimation.contains("build = { \"b|\\(kind)|\\(expanded ? 1 : 0)|\\(content.utf8.count)|\\(content.hashValue)\" }"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
