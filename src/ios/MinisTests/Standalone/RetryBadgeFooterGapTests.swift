#!/usr/bin/env swift
// [T-retry-badge-footer-gap] → [T-retry-log-sheet]
//
// History: during an automatic retry the "↻ N" stream-interrupt badge row
// appeared under "<name> is thinking…" with nothing re-measuring the footer,
// so SwiftUI centred the taller content in the stale 22pt cell and the
// indicator rode ~15pt up into the name row (iPhone 11, mock endpoint). That
// was fixed by observing `streamInterruptCount` and re-measuring.
//
// [T-retry-log-sheet] replaces the badge: a yellow retry marker sits IN the
// typing row, in front of the indicator, only while a retry is under way, and
// opens the run's retry log. Being on the same line it adds no height, so the
// badge's re-measure machinery is gone with the badge. This test pins that:
//   [1] why a same-line marker cannot reintroduce the stale-height shift
//   [2] the badge, its height-shape field, its subscription and its
//       re-measure helper are gone; the marker is wired as designed
//
// Run: swift RetryBadgeFooterGapTests.swift
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

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
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

print("1. A marker on the indicator's own line adds no height")
do {
    // Footer: VStack(spacing: 8) { typing row } + .padding(.vertical, 2).
    let typingLine: Double = 18, pad: Double = 2
    let markerHeight: Double = 11 + 2 * 2          // 11pt glyph + 2pt vertical padding
    let before = typingLine + 2 * pad
    let after = max(typingLine, markerHeight) + 2 * pad
    check("indicator-only footer ≈ 22pt", before == 22)
    check("with the marker beside it, still 22pt (no overflow, no shift)", after == before)
    let oldBadgeRow = typingLine + 8 + 22 + 2 * pad
    check("the old badge row made it 52pt - the overflow that shifted the indicator", oldBadgeRow == 52)
}

print("\n2. Wiring")
let list = messageListV3Source()
let legacy = source("Views/Chat/ChatMessageViews.swift")
check("no \"↻ N\" badge in the V3 footer or the legacy footer",
      !list.contains("streamInterruptBadge") && !legacy.contains("streamInterruptBadge"))
check("no footer row depends on streamInterruptCount any more",
      !list.contains("streamInterruptCount") && !legacy.contains("streamInterruptCount > 0"))
let shape = between(list, "struct FooterHeightShape: Equatable {", "\n        }\n") ?? ""
check("FooterHeightShape no longer carries the badge field",
      !shape.isEmpty && !shape.contains("showsInterruptBadge"))
check("the badge's subscription and re-measure helper are gone",
      !list.contains("lastMessageInterruptBadgeSub") && !list.contains("func remeasureFooter("))
let typingRow = between(list, "if showsTypingIndicator {", "TypingIndicator()") ?? ""
check("the marker is in the typing row, in front of the indicator",
      typingRow.contains("HStack(spacing: 6)") && typingRow.contains("RetryMarkerButton"))
check("…shown only while a retry is under way",
      typingRow.contains("if retryLog.isRetrying(key: retryLogKey) {"))
let overlay = between(list, ".accessibilityIdentifier(\"assistantFooter\")", ".contextMenu {") ?? ""
check("the details sheet hangs off the footer's zero-size overlay (no self-sizing inflation)",
      overlay.contains("Color.clear.frame(width: 0, height: 0)")
      && overlay.contains(".sheet(isPresented: $showRetryLog)")
      && overlay.contains("RetryLogSheet(key: retryLogKey)"))
check("the footer is handed the conversation's retry-log key",
      list.contains("retryLogKey: vm.retryLogKey"))
check("the iOS countdown pill and red error box are untouched",
      list.contains("Text(\"Retry in \\(bridge.autoRetryCountdown)s (\\(bridge.autoRetryAttempt)/\\(AIChatViewModel.retryDelays.count))\")"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
