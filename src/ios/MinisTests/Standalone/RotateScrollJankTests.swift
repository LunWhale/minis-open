#!/usr/bin/env swift
// [T-rotate-scroll-jank] Scrolling up through "Minis 内置 Tailscale 可行性评估"
// jumped and stuttered. Device log 2026-10-06: the phone went portrait →
// landscape → portrait (09:00:10 / 09:00:15, [WatchdogProbe][cv-bounds]
// 402x840 → 750x382 → 402x840). Each settled width change ran
// MessageListLayout's width purge, which cleared every cached / precalc /
// estimated height and stopped there. Cell prefetch is disabled, so nothing
// re-seeded the off-screen rows: all sat at the flat 200pt default, and
// 13 rows were corrected mid-glide while scrolling up (+2225pt, +1778pt, …).
//
// Source guards (the path needs a live UICollectionView):
//   [1] the purge still clears everything, then calls the re-seed hook,
//       then invalidates - in that order
//   [2] the coordinator wires the hook and re-runs the snapshot pass, or
//       queues it for the resume flush while streaming UI is suspended
//   [3] the snapshot pass seeds BEFORE its unchanged-items skip (so a
//       re-seed with the same items still seeds) and consults the
//       width-keyed memo before the estimates
//   [4] diagnostics
//
// Run: swift RotateScrollJankTests.swift
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

let coordDir = "Agent/MessageList/CollectionViewMessageListV3/Coordinator/"
let layout = source("Agent/MessageList/MessageListLayout.swift")
let setup = source(coordDir + "MessageListV3Coordinator+Setup.swift")
let streaming = source(coordDir + "MessageListV3Coordinator+Streaming.swift")
let snapshot = source(coordDir + "MessageListV3Coordinator+Snapshot.swift")

print("[1] Width purge: clear → re-seed → invalidate")
let purge = between(layout, "private func scheduleWidthPurge(for targetWidth: CGFloat) {", "var onWidthCachesPurged: (() -> Void)?") ?? ""
check("purge body found", !purge.isEmpty)
check("all four width-dependent stores still cleared",
      purge.contains("self.heightCache.removeAll()") && purge.contains("self.precalcHeights.removeAll()")
      && purge.contains("self.estimatedHeights.removeAll()") && purge.contains("self.geometryReaderConfirmed.removeAll()"))
check("order: clear, settle width, hook, invalidate",
      ordered(purge, ["self.estimatedHeights.removeAll()", "self.lastSettledWidth = cv.bounds.width",
                      "self.onWidthCachesPurged?()", "self.invalidateLayout()"]))
check("debounce and settle guards unchanged",
      purge.contains("guard token == self.widthPurgeToken else { return }")
      && purge.contains("guard abs(cv.bounds.width - self.lastSettledWidth) >= 0.5 else { return }"))
check("hook declared on the layout", layout.contains("var onWidthCachesPurged: (() -> Void)?"))

print("[2] Coordinator re-seeds")
check("attach wires the hook (weak self)",
      setup.contains("vc.messageListLayout.onWidthCachesPurged = { [weak self] in\n                self?.reseedHeightsAfterWidthPurge()"))
check("prefetch still disabled (why the snapshot pass is the only estimate writer)",
      setup.contains("collectionView.isPrefetchingEnabled = false"))
let reseed = between(streaming, "func reseedHeightsAfterWidthPurge() {", "/// Flush any snapshot that was deferred") ?? ""
check("reseed function found", !reseed.isEmpty)
check("suspended → queued for the resume flush, no snapshot pass",
      ordered(reseed, ["if vm.streamingUIUpdatesSuspended {", "hasPendingSnapshot = true", "return", "applySnapshot("]))
check("otherwise runs the snapshot pass with a named caller",
      reseed.contains("applySnapshot(messages: vm.messages, caller: \"widthPurge-reseed\")"))
check("resume flush still runs applySnapshot",
      (between(streaming, "func flushPendingSnapshotIfNeeded(caller: String = \"?\") {", "private func flushStreamingLayout()") ?? "")
        .contains("applySnapshot(messages: msgs"))

print("[3] Snapshot pass seeds before its unchanged-items skip")
let apply = between(snapshot, "func applySnapshot(messages rawMessages: [ChatMessage], caller: String = \"?\") {",
                    "[SnapshotDiag] SKIP caller=") ?? ""
check("applySnapshot found up to the skip", !apply.isEmpty)
check("seeding loop runs before the skip",
      apply.contains("guard layout.cachedHeight(at: i) == nil else { continue }")
      && apply.contains("layout.setEstimatedHeight(layout.headerEstimate(width: cvWidth), at: i)"))
check("width-keyed memo consulted before the cross-load memo and the estimates",
      ordered(apply, ["layout.measuredHeight(forKey: contentKey, width: cvWidth)",
                      "CrossLoadHeightMemo.shared.height(for: stableKey, width: cvWidth)",
                      "case .assistantHeader:"]))
check("purge does not touch the width-keyed memo",
      !purge.contains("measuredHeightByContentKey"))

print("[4] Diagnostics")
check("purge logs widths, dropped counts and whether a re-seed is wired",
      purge.contains("[WidthPurge] width") && purge.contains("cleared cache=") && purge.contains("reseed=\\(self.onWidthCachesPurged != nil)"))
check("re-seed logs its cost, deferral logged",
      reseed.contains("[WidthPurge] reseeded") && reseed.contains("[WidthPurge] reseed deferred"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
