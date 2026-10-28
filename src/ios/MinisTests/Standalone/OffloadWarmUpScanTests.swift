#!/usr/bin/env swift
// [T-offload-warmup-scan] The context offload scan skipped the pre-anchor
// warm-up (5a9c5bfcd starts at anchor + 1), yet effectiveAgentHistory still
// sends up to three user turns before the anchor, pruning only tool_results
// over 1000 chars (and their calls). file_write arguments, 501–1000-char
// results and images there could no longer be offloaded. The scan now also
// covers exactly the warm-up messages that are sent, minus the pruned ids.
//
// Run: swift OffloadWarmUpScanTests.swift
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

// Model of the index mapping (mirrors offloadWarmUpScanPlan).
enum Part { case text, use(String), result(String, Int) }
struct M { let role: String; let parts: [Part] }
func plan(_ h: [M], prior: Int, anchor: Int, drop: Int?) -> (idx: [Int], pruned: Set<String>) {
    var pruned: Set<String> = []
    for i in prior...anchor { for p in h[i].parts { if case .result(let id, let n) = p, n > 1000 { pruned.insert(id) } } }
    var kept: [Int] = []
    for i in prior...anchor {
        let survives = h[i].parts.contains { p in
            switch p { case .use(let id): return !pruned.contains(id); case .result(let id, _): return !pruned.contains(id); case .text: return true }
        }
        if survives { kept.append(i) }
    }
    while let f = kept.first, h[f].role != "user" { kept.removeFirst() }
    if let drop { kept = Array(kept.dropFirst(min(drop, kept.count))) }
    return (kept, pruned)
}
let h: [M] = [
    M(role: "user", parts: [.text]),                  // 0
    M(role: "assistant", parts: [.use("big")]),        // 1  paired with a >1000 result → pruned, emptied
    M(role: "user", parts: [.result("big", 5000)]),    // 2  pruned, emptied
    M(role: "assistant", parts: [.use("fw")]),         // 3  file_write, small result → sent
    M(role: "user", parts: [.result("fw", 20)]),       // 4
    M(role: "user", parts: [.text]),                   // 5  anchor
]
let p0 = plan(h, prior: 0, anchor: 5, drop: nil)
check("pruned ids = the >1000 result's id", p0.pruned == ["big"])
check("emptied messages are skipped, sent ones kept: \(p0.idx)", p0.idx == [0, 3, 4, 5])
let p1 = plan(h, prior: 0, anchor: 5, drop: 1)
check("per-marker warm-up trim drops the oldest sent messages: \(p1.idx)", p1.idx == [3, 4, 5])
let p2 = plan(h, prior: 1, anchor: 5, drop: nil)
check("leading non-user messages are peeled (first must be user): \(p2.idx)", p2.idx == [4, 5])

print("\nsource")
let off = source("Agent/Chat/AIChatViewModel+Offloading.swift")
check("plan function exists", off.contains("func offloadWarmUpScanPlan() -> (indices: [Int], prunedToolIds: Set<String>) {"))
check("same >1000 prune rule as effectiveAgentHistory",
      off.contains("if case .toolResult(let id, _, let content, _, _, _, _, _, _) = part, content.count > 1000 {"))
check("same per-marker trim", off.contains("if let drop = warmUpDropByMarker[marker.id] {\n            kept = Array(kept.dropFirst(min(drop, kept.count)))"))
check("scan loop covers warm-up + post-anchor", off.contains("for msgIdx in warmUpIndices + Array(candidateRange) {"))
check("pruned warm-up parts are skipped", off.contains("if warmUp.prunedToolIds.contains(id) { continue }"))
check("answered-call collection starts at the warm-up", off.contains("for msg in agentHistory[answeredFrom...] {"))
let persist = source("Agent/Chat/AIChatViewModel+Persistence.swift")
check("effectiveAgentHistory still prunes > 1000 (the rule mirrored)", persist.contains("content.count > 1000 {"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
