#!/usr/bin/env swift
// [GH#399] The read-replies capsule (pause / speed) vanished and stayed gone
// across relaunches and re-enables.
//
// Root cause: the drag clamp let the capsule's top reach the nav band
// (safeTop + 52) while the "no stable place" rule hid it (opacity 0, no hit
// testing) unless its top was ≥ 8 pt below that band (32 pt to come back).
// A capsule dragged to the top was persisted there → hidden forever.
//
// Compiles the shipping `SpeechCapsuleGeometry` block out of
// Views/Chat/Voice/SpeechPlayerControl.swift and checks the fixed rules, then
// pins the wiring.
//
// Run: swift SpeechCapsuleGeometryTests.swift   (needs swiftc)
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
let view = source("Views/Chat/Voice/SpeechPlayerControl.swift")
guard let a = view.range(of: "// BEGIN SpeechCapsuleGeometry"),
      let b = view.range(of: "// END SpeechCapsuleGeometry", range: a.upperBound..<view.endIndex) else {
    print("❌ geometry block not found"); exit(1)
}
let block = String(view[a.lowerBound..<b.upperBound])

let harness = #"""
import Foundation
import CoreGraphics
typealias G = SpeechCapsuleGeometry
func out(_ k: String, _ v: Any) { print("\(k)=\(v)") }

// iPhone 11 portrait: window 414×896, safe top 48, compact capsule 40×40 resting
// 16 pt from the right and 12 pt above the 34 pt home-indicator inset.
let window = CGRect(x: 0, y: 0, width: 414, height: 896)
let size = CGSize(width: 40, height: 40)
let restLeft: CGFloat = 414 - 16 - 40, restTop: CGFloat = 896 - 34 - 12 - 40
let limit = G.topLimit(safeTopInset: 48)
let bounds = G.offsetBounds(restLeft: restLeft, restTop: restTop, size: size, window: window,
                            topLimit: limit, bottomReserve: 40, edgeMargin: 16)
out("LIMIT", limit)
out("BOUNDS", "\(bounds.minX),\(bounds.maxX),\(bounds.minY),\(bounds.maxY)")

// ---- The #399 reproduction under the OLD rules.
let oldNavBottom: CGFloat = 48 + 44 + 8
let oldMinY = oldNavBottom - restTop                   // old clamp let the top reach the nav band
let oldTop = restTop + oldMinY
let oldHeadroom = oldTop - oldNavBottom                // old hide rule: headroom < 8 → hidden
out("OLD_DEADLOCK", "minY=\(oldMinY) headroom=\(oldHeadroom) hidden=\(oldHeadroom < 8)")

// ---- Restore decisions.
func d(_ o: CGSize, _ h: CGFloat?) -> String {
    switch G.restoreDecision(saved: o, savedWindowHeight: h, window: window, bounds: bounds) {
    case .apply(let c): return "apply \(Int(c.width)),\(Int(c.height))"
    case .discard(let r): return "discard \(r)"
    }
}
out("R_DEADLOCK_LEGACY", d(CGSize(width: 0, height: oldMinY), nil))
out("R_DEADLOCK_SAME", d(CGSize(width: 0, height: oldMinY), 896))
out("R_VALID", d(CGSize(width: -120, height: -300), 896))
out("R_ROTATED", d(CGSize(width: -120, height: oldMinY), 414))
out("R_SIDE_OUT", d(CGSize(width: -700, height: -300), 896))
out("R_NAN", d(CGSize(width: CGFloat.nan, height: 0), nil))
out("R_HUGE", d(CGSize(width: 0, height: -5000), nil))
let tiny = G.offsetBounds(restLeft: 0, restTop: 60, size: size, window: CGRect(x: 0, y: 0, width: 60, height: 100),
                          topLimit: limit, bottomReserve: 40, edgeMargin: 16)
out("R_TINY", { switch G.restoreDecision(saved: .zero, savedWindowHeight: nil, window: CGRect(x: 0, y: 0, width: 60, height: 100), bounds: tiny) {
    case .apply: return "apply"; case .discard(let r): return "discard \(r)" } }())
out("CLAMP_EMPTY_AXIS", "\(G.clamp(CGSize(width: 50, height: 50), into: tiny))")

// ---- Cramped placement (the tall voice panel + keyboard).
let rt = restTop
let p1 = G.placement(requiredLift: 300, restingTop: rt, topLimit: limit, wasCramped: false)
out("P_ROOM", "\(Int(p1.lift)) \(p1.cramped)")
let p2 = G.placement(requiredLift: 900, restingTop: rt, topLimit: limit, wasCramped: false)
out("P_CRAMPED", "\(Int(p2.lift)) \(p2.cramped) top=\(Int(rt - p2.lift))")
let maxLift = rt - limit
let p3 = G.placement(requiredLift: maxLift - 10, restingTop: rt, topLimit: limit, wasCramped: true)
out("P_HYST_HOLD", "\(p3.cramped)")
let p4 = G.placement(requiredLift: maxLift - 30, restingTop: rt, topLimit: limit, wasCramped: true)
out("P_HYST_RELEASE", "\(p4.cramped)")

// ---- Property: any clamped offset, at rest, is visible and never cramped.
var seed: UInt64 = 399
func rnd(_ lo: Double, _ hi: Double) -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(lo + (hi - lo) * Double(seed >> 11) / Double(1 << 53))
}
var badVisible = 0, badCramped = 0
for _ in 0..<10000 {
    let w = rnd(320, 1400), h = rnd(480, 1400), st = rnd(20, 60)
    let win = CGRect(x: 0, y: 0, width: w, height: h)
    let sz = CGSize(width: rnd(40, 280), height: 40)
    let rl = w - 16 - sz.width, rtop = h - 34 - 12 - sz.height
    let lim = G.topLimit(safeTopInset: st)
    let bb = G.offsetBounds(restLeft: rl, restTop: rtop, size: sz, window: win, topLimit: lim, bottomReserve: 40, edgeMargin: 16)
    if bb.isEmpty { continue }
    let o = G.clamp(CGSize(width: rnd(-3000, 3000), height: rnd(-3000, 3000)), into: bb)
    let left = rl + o.width, top = rtop + o.height
    if left < 16 - 0.01 || left + sz.width > w - 16 + 0.01 || top < lim - 0.01 || top + sz.height > h - 40 + 0.01 { badVisible += 1 }
    if G.placement(requiredLift: 0, restingTop: top, topLimit: lim, wasCramped: false).cramped { badCramped += 1 }
}
out("PROP", "\(badVisible),\(badCramped)")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("capsule-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = [("geo.swift", "import Foundation\nimport CoreGraphics\n" + block), ("main.swift", harness)]
for (n, t) in files { try t.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
check("shipping geometry block compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("harness ran", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") {
    let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("\n1. The #399 deadlock")
check("old rules: the top the clamp allowed was hidden (\(r["OLD_DEADLOCK"] ?? ""))", (r["OLD_DEADLOCK"] ?? "").hasSuffix("hidden=true"))
check("one top limit for clamp and cramped: safeTop + 52 + 8 = 108", r["LIMIT"] == "108.0")
check("drag bounds stop at that limit: minY = 108 − 810 = −702 (\(r["BOUNDS"] ?? ""))", (r["BOUNDS"] ?? "").contains(",-702.0,"))

print("\n2. Restoring a saved offset")
check("a pre-fix offset in the hidden band (no saved window) is discarded: \(r["R_DEADLOCK_LEGACY"] ?? "")", r["R_DEADLOCK_LEGACY"] == "discard above the top limit")
check("…also when saved in this same window", r["R_DEADLOCK_SAME"] == "discard above the top limit")
check("a valid offset is applied as saved", r["R_VALID"] == "apply -120,-300")
check("saved in another window size (rotation): clamped, NOT discarded: \(r["R_ROTATED"] ?? "")", r["R_ROTATED"] == "apply -120,-702")
check("off the side: clamped into the margins: \(r["R_SIDE_OUT"] ?? "")", r["R_SIDE_OUT"] == "apply -342,-300")
check("non-finite → discarded", r["R_NAN"] == "discard corrupt")
check("absurdly far → discarded", r["R_HUGE"] == "discard corrupt")
check("window too small for any legal place → discarded (resting corner)", r["R_TINY"] == "discard no legal position in this window")
check("clamp on an empty axis falls back to the resting corner (0)", r["CLAMP_EMPTY_AXIS"] == "(0.0, 0.0)")

print("\n3. Cramped: pinned and visible, never hidden")
check("room to lift → lifted in full, not cramped", r["P_ROOM"] == "300 false")
check("not enough room → capped: top pinned at the limit, cramped: \(r["P_CRAMPED"] ?? "")", r["P_CRAMPED"] == "702 true top=108")
check("hysteresis: just under the cap stays cramped", r["P_HYST_HOLD"] == "true")
check("…24 pt+ of room releases it", r["P_HYST_RELEASE"] == "false")

print("\n4. Property (10 000 random windows / capsules / offsets)")
check("every clamped offset is inside the window and below the top limit, and never cramped at rest: \(r["PROP"] ?? "")", r["PROP"] == "0,0")

print("\n5. Wiring")
check("no opacity-0 / hit-test hiding left", !view.contains(".opacity(spaceInsufficient ? 0 : 1)") && !view.contains(".allowsHitTesting(!spaceInsufficient)"))
check("recompute caps the lift and collapses to compact when cramped",
      view.contains("SpeechCapsuleGeometry.placement(") && view.contains("if cramped, expanded { setExpanded(false) }"))
check("clamp uses the shared bounds", view.contains("return SpeechCapsuleGeometry.clamp(proposed, into: b)"))
check("restore judges the saved value and can discard it", view.contains("SpeechCapsuleGeometry.restoreDecision(") && view.contains("resetPositionToDefault()"))
check("reset forgets the saved offset", view.contains("VoiceOutputPreferences.capsuleAnchorOffset = nil\n        withAnimation(.easeInOut(duration: 0.25)) { dragOffset = .zero }"))
check("enabling read-replies self-heals the position", view.contains("if enabled { healPositionIfNeeded(reason: \"enabled\") }"))
check("the window height is saved with the offset", view.contains("VoiceOutputPreferences.capsuleAnchorWindowHeight = Self.windowBounds().height"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
