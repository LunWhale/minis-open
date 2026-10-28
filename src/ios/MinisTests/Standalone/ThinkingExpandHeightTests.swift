#!/usr/bin/env swift
// [T-thinking-expand-stuck-height] A streaming thinking block that is
// expanded (automatically via "Expand Thinking While Streaming", or by hand)
// must grow its list cell as its text streams in.
//
// Field report (TestFlight): with the setting on, new thinking blocks looked
// collapsed — chevron up, no text — until collapsed and re-expanded.
// Reproduced on device with a slow reasoning mock: the auto-expand fired while
// the block's text was still empty, the cell measured 40pt (header only), and
// nothing re-measured it as text arrived (log: POST … frameH=40.0 delta=0.0).
// After the fix the same run grew 40 → 66 → 103 → … → 340 (header + 300 cap)
// with 8 re-measures, then collapsed to 40 at stream end.
//
//   [1] remeasureHeight — pure: when to ask the list to re-measure
//   [2] a streamed growth sequence: requests stay bounded, end at the cap
//   [3] source guards: wiring, gating on streaming, reset on collapse
//
// Run: swift ThinkingExpandHeightTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

// MARK: - Port (byte-identical with AssistantBlockView.swift, guarded in [3])

enum ThinkingBlockView {
    static let bodyMaxHeight: CGFloat = 300
    static let bodyRemeasureStep: CGFloat = 20

    // BEGIN remeasureHeight
    /// The capped body height to report, or nil when the cell need not be
    /// re-measured: the first visible height, each ~line of growth, and the
    /// moment the cap is reached — never again once capped.
    static func remeasureHeight(natural: CGFloat, lastReported: CGFloat,
                                cap: CGFloat = bodyMaxHeight, step: CGFloat = bodyRemeasureStep) -> CGFloat? {
        let shown = min(natural, cap)
        let firstReport = lastReported == 0 && shown > 0
        let grownALine = shown - lastReported >= step
        let reachedCap = shown >= cap && lastReported < cap
        return (firstReport || grownALine || reachedCap) ? shown : nil
    }
    // END remeasureHeight
}
let r = { (n: CGFloat, last: CGFloat) in ThinkingBlockView.remeasureHeight(natural: n, lastReported: last) }

// MARK: - [1] remeasureHeight

print("▶️  1. remeasureHeight — pure")
check("REGRESSION: the first visible body (text just arrived) is reported", r(26, 0) == 26)
check("a tiny first body (one short line) is still reported", r(5, 0) == 5)
check("nothing rendered yet (height 0) → no request", r(0, 0) == nil)
check("growth under a line → no request", r(40, 26) == nil)
check("growth of a line → reported", r(46, 26) == 46)
check("reaching the cap is reported even if < a line of growth", r(310, 290) == 300)
check("height is reported capped at 300", r(900, 100) == 300)
check("once capped, further growth never requests again", r(1200, 300) == nil && r(301, 300) == nil)
check("shrinking (e.g. window re-slice) → no request", r(120, 200) == nil)

// MARK: - [2] a streamed growth sequence

print("\n▶️  2. streamed growth sequence")
do {
    // Natural height after each flush: ~18.5pt per line, 1–3 lines per flush,
    // continuing well past the cap (a long reasoning stream).
    var natural: CGFloat = 0
    var last: CGFloat = 0
    var requests: [CGFloat] = []
    for i in 0..<120 {
        natural += CGFloat(1 + i % 3) * 18.5
        if let h = r(natural, last) { last = h; requests.append(h) }
    }
    check("ends reported at the cap", last == 300)
    check("bounded: at most ~cap/step requests (\(requests.count))", requests.count <= Int(300 / 20) + 2)
    check("strictly increasing", zip(requests, requests.dropFirst()).allSatisfy { $0 < $1 })
    check("no request after the cap", requests.last == 300)
    // Every rendered frame between requests lags the true height by < one
    // step + one flush, i.e. at most one line is clipped until the next one.
    var lastR: CGFloat = 0
    var worstLag: CGFloat = 0
    natural = 0
    for i in 0..<120 {
        natural += CGFloat(1 + i % 3) * 18.5
        if let h = r(natural, lastR) { lastR = h }
        worstLag = max(worstLag, min(natural, 300) - lastR)
    }
    check("never more than one step behind the true height (worst \(worstLag)pt)", worstLag < 20)
}

// MARK: - [3] source guards

print("\n▶️  3. source guards")
let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.upperBound..<r2.lowerBound])
}
let view = source("Views/Chat/AssistantBlockView.swift")
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
let appFn = between(view, "// BEGIN remeasureHeight", "// END remeasureHeight")
check("port is byte-identical with AssistantBlockView", !appFn.isEmpty && appFn == between(me, "// BEGIN remeasureHeight", "// END remeasureHeight"))
check("constants match (cap 300 = the ScrollView maxHeight, step 20)",
      view.contains("static let bodyMaxHeight: CGFloat = 300") && view.contains("static let bodyRemeasureStep: CGFloat = 20")
      && view.contains(".frame(maxHeight: Self.bodyMaxHeight)"))
check("the body reports its natural height from inside the ScrollView",
      view.contains("Color.clear.preference(key: ThinkingBodyHeightKey.self, value: g.size.height)")
      && view.contains(".onPreferenceChange(ThinkingBodyHeightKey.self) { height in\n                        remeasureIfGrown(height)"))
let fn = between(view, "func remeasureIfGrown(_ naturalHeight: CGFloat) {", "\n    }\n")
check("only while streaming and expanded (a finished block changes height only on toggle)",
      fn.contains("guard isStreaming, isExpanded.wrappedValue,"))
check("re-measure uses the existing toggle path (clears both height caches)",
      fn.contains("NotificationCenter.default.post(name: .thinkingBlockToggled, object: block.id)"))
check("collapsing re-arms reporting for the next expansion",
      view.contains("if !newValue { lastReportedBodyHeight = 0 }"))
// [T-thinking-autoexpand-toggle-longpress] The key and its default now live in
// ThinkingAutoExpand (shared with the thinking block's long-press toggle).
check("the auto-expand gate still honours the setting",
      view.contains("if ThinkingAutoExpand.isOn, isStreaming,")
      && view.contains(#"static let key = "chat.autoExpandThinking""#)
      && view.contains("static var isOn: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
