#!/usr/bin/env swift
// [T-stream-end-scroll-overlap] A reply that finished while the user was
// scrolling drew over its neighbouring cells for ~1s. The text view grew by
// hundreds of points (text held back during the scroll lands in one go) but
// invalidateCellSizeIfNeeded parked every height change while deferSelfSizing
// was open, so the cell kept its pre-scroll frame until settle. Device log
// 2026-10-05 22:37:32-34: cell held 2224.7pt, content 2680pt.
//
// Source guards (the path needs a live UICollectionView, so it is pinned by
// source, the way the other message-list sizing guards are):
//   [1] growth of a VISIBLE cell falls through to the normal commit path;
//       shrinks and off-screen growth still park the correction (debt + backstop)
//   [2] the media escape and the debt machinery are unchanged
//   [3] the decision is logged ([DeferGrowth] ALLOW / HOLD) and a turn ending
//       mid-scroll is logged once ([DeferGrowth] TURN-END)
//   [4] viewportPlacement classifies above / inside / below correctly,
//       compiled as shipped against stub geometry
//
// Run: swift StreamEndScrollOverlapTests.swift
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

let sizing = source("Views/Chat/Markdown/TextKit/SelectableMarkdownTextView+CellSizing.swift")
let bindings = source("Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Bindings.swift")

print("[1] Visible growth escapes the defer; everything else still parks")
let deferBranch = between(sizing, "if isDeferred {", "// Commit the measurement:") ?? ""
check("deferred branch found", !deferBranch.isEmpty)
let media = deferBranch.range(of: "if cellHasGrowableMediaAttachment && isLargeGrowth {")
let visible = deferBranch.range(of: "} else if delta > 0, placement.position == \"inside\" {")
let hold = deferBranch.range(of: "[DeferGrowth] HOLD")
check("order: media escape, then visible-growth escape, then hold",
      media != nil && visible != nil && hold != nil
      && media!.lowerBound < visible!.lowerBound && visible!.lowerBound < hold!.lowerBound)
if let v = visible, let h = hold {
    let escapeBody = String(deferBranch[v.upperBound..<h.lowerBound])
    check("visible-growth escape does not return (falls through to commit)", !escapeBody.contains("return"))
}
if let h = hold {
    let holdBody = String(deferBranch[h.lowerBound...])
    check("hold branch still owes the correction", holdBody.contains("deferredCorrectionPending = true"))
    check("hold branch still arms the backstop", holdBody.contains("armDeferredRemeasureBackstop()"))
    check("hold branch still returns before the commit", holdBody.contains("return\n"))
}
check("placement computed only inside the deferred branch",
      deferBranch.contains("let placement = Self.viewportPlacement(of: findCell(), in: cvOpt)")
      && sizing.components(separatedBy: "Self.viewportPlacement(").count == 2)
check("commit path still clears the cell cache and invalidates",
      sizing.contains("cell.clearCachedHeight()\n        }\n\n        cvOpt?.collectionViewLayout.invalidateLayout()"))

print("[2] Unchanged neighbours")
check("media escape threshold unchanged", deferBranch.contains("let isLargeGrowth = delta > 30"))
check("applyCellCorrection still refuses inside the window",
      sizing.contains("guard !deferred else { return false }"))
check("layout still lets growth through and defers shrink",
      source("Agent/MessageList/MessageListLayout.swift").contains("if preferred <= original + 0.5 {"))

print("[3] Diagnostics")
check("ALLOW line carries delta, placement and debt state",
      deferBranch.contains("[DeferGrowth] ALLOW visible growth through defer")
      && deferBranch.contains("\\(placement.summary) owedBefore="))
check("HOLD line names the reason",
      deferBranch.contains("reason=\\(delta > 0 ? \"growth-not-visible\" : \"shrink\")"))
check("turn-end mid-scroll line in the isProcessing→false sink",
      (between(bindings, ".filter { !$0 }", "resnapshotIfToolFoldsChanged(caller: \"toolFold-turnEnd\")") ?? "")
        .contains("[DeferGrowth] TURN-END mid-scroll"))

print("[4] viewportPlacement, compiled as shipped")
guard let fn = between(sizing, "    static func viewportPlacement(", "    /// Bound on `armDeferredRemeasureBackstop`") else {
    print("  ❌ viewportPlacement not found"); exit(1)
}
let driver = #"""
import Foundation
import CoreGraphics
class UICollectionViewCell { var frame: CGRect; init(_ f: CGRect) { frame = f } }
class UICollectionView {
    var bounds: CGRect; var isDecelerating = false; var isTracking = false
    init(_ b: CGRect) { bounds = b }
    func indexPath(for cell: UICollectionViewCell) -> StubIndexPath? { StubIndexPath(item: 7) }
}
struct StubIndexPath { let item: Int }  // UIKit's IndexPath.item is not in Foundation
enum T {
    static func viewportPlacement(
"""# + fn + #"""
}
let cv = UICollectionView(CGRect(x: 0, y: 1000, width: 400, height: 800))
func p(_ y: CGFloat, _ h: CGFloat) -> String { T.viewportPlacement(of: UICollectionViewCell(CGRect(x: 0, y: y, width: 400, height: h)), in: cv).position }
print("above=\(p(0, 1000))")          // ends exactly at the viewport top
print("insideTop=\(p(500, 600))")     // straddles the top edge
print("inside=\(p(1200, 100))")
print("tall=\(p(0, 5000))")           // taller than the viewport
print("below=\(p(1800, 50))")         // starts exactly at the viewport bottom
print("nil=\(T.viewportPlacement(of: nil, in: cv).position)")
cv.isDecelerating = true
print("summary=\(T.viewportPlacement(of: UICollectionViewCell(CGRect(x: 0, y: 1200, width: 400, height: 100)), in: cv).summary)")
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stream_overlap_\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let src = tmp.appendingPathComponent("main.swift"), exe = tmp.appendingPathComponent("t")
try! driver.write(to: src, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let (cc, cout) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", exe.path])
check("compiles standalone", cc == 0)
if cc != 0 { print(cout); exit(1) }
let out = run(exe.path, []).1
check("cell ending at the viewport top is above", out.contains("above=above"))
check("cell straddling the top edge is inside", out.contains("insideTop=inside"))
check("cell within the viewport is inside", out.contains("inside=inside"))
check("cell taller than the viewport is inside", out.contains("tall=inside"))
check("cell starting at the viewport bottom is below", out.contains("below=below"))
check("no cell → unknown (never escapes)", out.contains("nil=unknown"))
check("summary carries idx, phase and geometry",
      out.contains("summary=pos=inside idx=7 phase=decel cellY=1200 cellH=100.0 viewport=1000..1800"))
try? FileManager.default.removeItem(at: tmp)

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
