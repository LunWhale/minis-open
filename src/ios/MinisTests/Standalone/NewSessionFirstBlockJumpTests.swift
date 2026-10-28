#!/usr/bin/env swift
// [T-new-session-first-block-jump] New session, first message (screen
// recording 2026-10-08 14:05-14:06, session D058EF2D): ~5 s after the user
// bubble appeared, when the first reply block (the thinking chip) replaced the
// "Pikachu is thinking..." row, the whole list (user bubble + reply header)
// jumped UP 18pt for exactly one frame (frame 346 of the 60 fps recording: rows
// at y 360/593 px -> 344/539 px, back on the next frame). The log caught the
// offset of that frame: `[SCR] offset=-98 ... cs=132 mode=auto`, against the
// resting -116 (the top limit).
//
// MessageListLayout.invalidationContext glues the content's bottom to the
// composer while auto-scroll is pinned: a streaming row that grows by delta
// moves the offset by delta in the same layout pass. That assumes the content
// already reaches the composer. A new session's content (132pt in a ~630pt
// viewport) sits at the top instead, so the adjustment just pushed it up by the
// growth until the bottom pin clamped the offset back to the top limit on the
// next frame.
//
// Now only the part of the growth that pushes the content's bottom past the
// pin line moves the offset (StreamGrowthPin).
//
//   [1] the rule, compiled from the shipping source, on the device numbers
//   [2] source guards: the branch uses it with the right inputs
//
// Run: swift NewSessionFirstBlockJumpTests.swift
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
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let layout = source("Agent/MessageList/MessageListLayout.swift")
check("source readable", !layout.isEmpty)

print("[1] The rule, on the device numbers")
let rule = between(layout, "// BEGIN StreamGrowthPin", "// END StreamGrowthPin") ?? ""
check("StreamGrowthPin block found", rule.contains("enum StreamGrowthPin"))

// Device: bounds 874pt, top limit -116, composer inset ~126, content 132pt.
let harness = """
import CoreGraphics
\(rule)
func adj(_ d: CGFloat, _ bottomAfter: CGFloat, _ pin: CGFloat) -> CGFloat {
    StreamGrowthPin.offsetAdjustment(delta: d, contentBottomAfter: bottomAfter, pinLine: pin)
}
let offset: CGFloat = -116, bounds: CGFloat = 874, bottomInset: CGFloat = 126
let pin = offset + bounds - bottomInset          // 632
var out: [String] = []
// new session: 132pt of content grows by 18 -> no scroll (was +18: the jump)
out.append("short=\\(adj(18, 132 + 18, pin))")
// pinned, overflowing: content bottom on the pin line, grows by 18 -> +18
out.append("pinned=\\(adj(18, pin + 18, pin))")
// crossing: content ends 10pt above the line, grows by 18 -> +8
out.append("crossing=\\(adj(18, pin - 10 + 18, pin))")
// content lagging past the line: capped at the growth
out.append("lagging=\\(adj(18, pin + 60, pin))")
// shrink never scrolls here
out.append("shrink=\\(adj(-18, pin + 40, pin))")
print(out.joined(separator: " "))
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stream_growth_pin_\(getpid()).swift")
try? harness.write(to: tmp, atomically: true, encoding: .utf8)
let (status, output) = run("/usr/bin/env", ["swift", tmp.path])
try? FileManager.default.removeItem(at: tmp)
print("      \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
check("harness ran", status == 0)
check("new session (content above the composer): growth does not scroll", output.contains("short=0.0"))
check("pinned at the composer: scrolls by the whole growth, as before", output.contains("pinned=18.0"))
check("crossing the composer: scrolls by the overshoot only", output.contains("crossing=8.0"))
check("never more than the growth", output.contains("lagging=18.0"))
check("a shrink does not scroll through this rule", output.contains("shrink=0.0"))

print("[2] Wiring")
let branch = between(layout, "} else if isStreamingCell(index) && isAutoScrollPinning && delta > 0 {", "// [T-ios-footer-float-firstlayout]") ?? ""
check("the pinned-streaming branch uses the rule",
      branch.contains("StreamGrowthPin.offsetAdjustment(")
      && branch.contains("contentBottomAfter: totalHeight + heightDeltaSincePrepare, pinLine: pinLine)")
      && branch.contains("if glue > 0 {\n                    ctx.contentOffsetAdjustment = CGPoint(x: 0, y: glue)"))
check("pin line = viewport bottom above the composer (same inset the pin uses)",
      branch.contains("let pinLine = viewportTop + cv.bounds.height - cv.adjustedContentInset.bottom"))
check("the branch no longer moves by the raw delta",
      !branch.contains("ctx.contentOffsetAdjustment = CGPoint(x: 0, y: delta)"))
check("pending growth is counted between re-flows and reset by prepare()",
      layout.contains("heightCache[index] = newHeight\n        heightDeltaSincePrepare += delta")
      && layout.contains("totalHeight = y\n        heightDeltaSincePrepare = 0"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
