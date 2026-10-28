#!/usr/bin/env swift
// [T-ctx-trim-collapse-first] [T-ctx-trim-trigger-margin] Where the trim
// ladder is wired into the agent loop and the re-plan. Source-level: the pure
// parts are covered by MinisTests/ContextTrimPlannerTests and
// ContextCollapseFirstTests; this pins the ORDER the loop does things in.
//
// Android replay 2026-10-07: two in-loop compactions cost a model call each
// and took the history only 244K -> 226K (one long user turn is itself the
// slice a compaction keeps), and an after-compact plan that had collapsed 26
// iterations was rebuilt without collapse by the next in-loop re-plan.
//
// Run: swift ContextTrimWiringTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
/// Position of `needle` in `text`, or nil.
func at(_ needle: String, in text: String) -> String.Index? { text.range(of: needle)?.lowerBound }
func ordered(_ needles: [String], in text: String) -> Bool {
    var last = text.startIndex
    for n in needles {
        guard let r = text.range(of: n, range: last..<text.endIndex) else { return false }
        last = r.upperBound
    }
    return true
}

let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let compaction = source("Agent/Chat/AIChatViewModel+Compaction.swift")
let send = source("Agent/Chat/AIChatViewModel+Send.swift")
let policy = source("Agent/Chat/ContextPolicy.swift")

print("══ [1] sources found ══")
check("agent loop", loop.contains("switch inLoopVerdict {"))
check("compaction extension", compaction.contains("func replanTrim(site: String, allowCollapse: Bool)"))

print("\n══ [2] the loop trims before it judges, and judges before it compacts ══")
check("in-loop: re-plan, then the verdict, then the switch",
      ordered(["replanTrim(site: \"in-loop\", allowCollapse: !inLoopCompactAvailable)",
               "var inLoopVerdict = checkContextBeforeSend(site: \"in-loop\")",
               "switch inLoopVerdict {"], in: loop))
check("pre-send: re-plan before the check",
      ordered(["replanTrim(site: \"pre-send\"", "switch checkContextBeforeSend() {"], in: send))

print("\n══ [2b] a plan that recovers too little escalates ══")
check("the re-plan records whether it escalates, only when it could not collapse",
      compaction.contains("lastTrimPlanEscalates = !collapse && ContextTrimPlanner.shouldEscalate(after: result.after, target: wm.target, trigger: trigger)"))
check("a re-plan that did not run clears the flag",
      ordered(["lastTrimPlanEscalates = false", "if !tight, !trimReplanPending, size <= trigger { return nil }"], in: compaction))
check("the loop turns an ok verdict into the compaction branch, only while a compaction is available",
      ordered(["var inLoopVerdict = checkContextBeforeSend(site: \"in-loop\")",
               "if inLoopVerdict == .ok, inLoopCompactAvailable, lastTrimPlanEscalates {",
               "inLoopVerdict = .needsCompact", "lastTrimPlanEscalates = false", "switch inLoopVerdict {"], in: loop))
check("the bar is the midpoint between target and trigger", policy.contains("after > target && after > (target + trigger) / 2"))

print("\n══ [2c] a plan belongs to the window it was made for ══")
check("a plan for another window is dropped before anything is measured",
      ordered(["guard let wm = currentWatermarks() else { return nil }",
               "if trimState != nil, !ContextTrimPlanner.planFitsWindow(planWindow: trimStateWindow, window: wm.window) {",
               "trimState = nil", "trimCollapseUnlock = nil", "trimReplanPending = true",
               "let size = measure(applyFrozenTrim(compacted))"], in: compaction))
check("every plan records its window", compaction.contains("trimStateWindow = wm.window"))

print("\n══ [3] collapse-first sits in front of the model summary ══")
check("the summary is simulated before the compaction call",
      ordered(["case .needsCompact:",
               "if summaryWouldFreeLittle(measured: measureOutboundContextTokens()) {",
               "replanTrim(site: \"collapse-first\", allowCollapse: true)",
               "if checkContextBeforeSend(site: \"collapse-first\") == .ok {",
               "compactionsThisLoop += 1",
               "await compactBefore(anchorId, allowDuringProcessing: true)"], in: loop))
check("a collapse that is enough leaves the switch without compacting",
      ordered(["if checkContextBeforeSend(site: \"collapse-first\") == .ok {", "break", "compactionsThisLoop += 1"], in: loop))
check("...and does not spend one of the loop's compactions",
      at("replanTrim(site: \"collapse-first\"", in: loop)! < at("compactionsThisLoop += 1", in: loop)!)
check("a collapse that is NOT enough still reaches the compaction",
      !loop.contains("replanTrim(site: \"collapse-first\", allowCollapse: true)\n                        continue"))
check("after the compaction the plan is rebuilt with collapse allowed",
      ordered(["await compactBefore(anchorId, allowDuringProcessing: true)", "trimReplanPending = true",
               "\"compact-failed\" : \"after-compact\"", "allowCollapse: true)"], in: loop))

print("\n══ [4] the simulation and its decision ══")
check("simulated on the stored history with the current marker, no model call",
      compaction.contains("Self.simulatedSummaryGain(history: agentHistory, current: cachedLatestMarker,"))
check("anchor = the newest message; none -> no simulation",
      compaction.contains("guard let anchorId = history.last?.dbMessageId else { return nil }"))
check("same slicing as a real compaction",
      compaction.contains("let after = effectiveHistory(history, marker: simulated, warmUpDrop: &dropAfter, helpers: helpers)"))
check("the gain is calibrated before it is compared",
      compaction.contains("let gain = ContextSizeMeter.calibrated(raw, ratio: contextCalibrationRatio())"))
check("nothing to simulate -> compact as before",
      compaction.contains("summaryTokens: ContextTrimPlanner.simulatedSummaryTokens) else { return false }"))
check("half of what is needed is the bar", policy.contains("gain < (measured - target) / 2"))
check("logged", compaction.contains("[ctx-trim] summary would free ~\\(gain) of \\(needed) needed - \\(little ? \"collapse first\" : \"compact\")"))

print("\n══ [5] sticky collapse ══")
check("the re-plan asks the unlock",
      compaction.contains("ContextTrimPlanner.collapseAllowed(requested: allowCollapse, tight: tight, unlock: trimCollapseUnlock,"))
check("an allowed collapse records the session and marker",
      compaction.contains("if collapse { trimCollapseUnlock = .init(sessionId: sessionId, markerId: cachedLatestMarker?.id) }"))
check("the plan uses the sticky value, not the argument", compaction.contains("allowCollapse: collapse)"))

print("\n══ [6] the trigger keeps a margin ══")
check("the re-plan takes its trigger from the planner",
      compaction.contains("let trigger = ContextTrimPlanner.trigger(policyLine: policyLine, watermarks: wm)"))
check("never above the watermark trigger", policy.contains("return min(policyLine, wm.trigger)"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
