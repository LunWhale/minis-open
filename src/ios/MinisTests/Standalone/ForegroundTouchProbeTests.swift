#!/usr/bin/env swift
// [T-fg-touch-probe] Field report (iOS 26.6): after switching away and back,
// long-press text selection and markdown-table horizontal scroll sometimes stop
// working while the list still scrolls. Not reproduced on the vphone, so the
// list now logs, ~1 s after every foreground return, where a touch on each
// visible text block / table would land. These checks pin that diagnostic.
//
//   [1] the shipping ForegroundTouchProbe block, compiled standalone: an "ok"
//       line when every target takes its own touch; one WARN per blocked
//       target naming the view that took it, a stuck recognizer, an ancestor
//       with interaction off, overflow below the cell, a presented sheet
//   [2] source guards: wired to didBecomeActive, deferred off the
//       notification, read-only (never changes view / gesture state), and
//       not reporting recognizers UIKit disables by design
//
// Run: swift ForegroundTouchProbeTests.swift   (needs swiftc)
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
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let bindings = source("Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Bindings.swift")
guard let block = between(bindings, "// BEGIN ForegroundTouchProbe", "// END ForegroundTouchProbe") else {
    print("❌ ForegroundTouchProbe block not found"); exit(1)
}

let harness = """
import Foundation
import CoreGraphics
\(block)
var fails = 0
func CHECK(_ label: String, _ ok: Bool) { print("  \\(ok ? "PASS" : "FAIL") \\(label)"); if !ok { fails += 1 } }
typealias S = ForegroundTouchProbe.Sample
func ok(_ k: ForegroundTouchProbe.Kind) -> S {
    S(kind: k, hitInsideTarget: true, hitChain: [], nonInteractiveAncestor: nil, activeRecognizers: [], overflowBelowCell: 0)
}

print("[1] summary lines")
var lines = ForegroundTouchProbe.summarize(samples: [ok(.text), ok(.table)], windowRecognizers: [], firstResponder: nil)
CHECK("healthy return: one ok line with counts", lines.count == 1
      && lines[0].hasPrefix("[FGTouch] foreground probe: 2 target(s) (text=1 table=1), blocked=0, firstResponder=none")
      && lines[0].hasSuffix(" - ok"))

let covered = S(kind: .table, hitInsideTarget: false, hitChain: ["UIView", "SheetHost", "UIWindow"],
                nonInteractiveAncestor: nil, activeRecognizers: [], overflowBelowCell: 0)
lines = ForegroundTouchProbe.summarize(samples: [ok(.text), covered], windowRecognizers: [], firstResponder: "TableCellTextView",
                                       presented: "UIHostingController<EditSheet>")
CHECK("a covered table is counted as blocked, no ok", lines[0].contains("blocked=1") && !lines[0].hasSuffix(" - ok"))
CHECK("headline names the first responder and the presented sheet",
      lines[0].contains("firstResponder=TableCellTextView") && lines[0].contains("presented=UIHostingController<EditSheet>"))
CHECK("WARN names what took the touch, innermost first", lines.count == 2 && lines[1] == "[FGTouch] WARN table hit=UIView<SheetHost<UIWindow")

let stuck = S(kind: .text, hitInsideTarget: true, hitChain: [], nonInteractiveAncestor: "CellContentView",
              activeRecognizers: ["SelectableMarkdownTextView.UILongPressGestureRecognizer:state=2"], overflowBelowCell: 37.6)
lines = ForegroundTouchProbe.summarize(samples: [stuck], windowRecognizers: ["ActivityObservingGestureRecognizer:state=1"], firstResponder: nil)
CHECK("interaction off counts as blocked even when the hit lands inside", lines[0].contains("blocked=1"))
CHECK("window-level stuck recognizers go in the headline", lines[0].contains("windowRecognizers=[ActivityObservingGestureRecognizer:state=1]"))
CHECK("WARN lists interaction-off, stuck recognizer and overflow",
      lines.count == 2 && lines[1].contains("interactionOff=CellContentView")
      && lines[1].contains("recognizers=[SelectableMarkdownTextView.UILongPressGestureRecognizer:state=2]")
      && lines[1].contains("overflowBelowCell=37pt") && !lines[1].contains("hit="))
let nilHit = S(kind: .text, hitInsideTarget: false, hitChain: [], nonInteractiveAncestor: nil, activeRecognizers: [], overflowBelowCell: 0.4)
lines = ForegroundTouchProbe.summarize(samples: [nilHit], windowRecognizers: [], firstResponder: nil)
CHECK("a nil hit says so; sub-point overflow is not noise", lines.count == 2 && lines[1] == "[FGTouch] WARN text hit=nil")
lines = ForegroundTouchProbe.summarize(samples: [], windowRecognizers: [], firstResponder: nil)
CHECK("no visible targets: still one line, ok", lines.count == 1 && lines[0].contains("0 target(s)") && lines[0].hasSuffix(" - ok"))
CHECK("sample cap is bounded", ForegroundTouchProbe.maxSamples > 0 && ForegroundTouchProbe.maxSamples <= 20)
exit(fails == 0 ? 0 : 1)
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fg-touch-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
check("probe block compiles standalone", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("summary checks all pass", status == 0 && !out.contains("FAIL "))
}

print("[2] source guards")
let probe = between(bindings, "func probeTouchTargetsAfterForeground() {", "// BEGIN ForegroundTouchProbe") ?? ""
check("runs on didBecomeActive, deferred off the notification",
      bindings.contains("NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)")
      && bindings.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in\n                        self?.probeTouchTargetsAfterForeground()"))
check("only while active, and only for the list on screen",
      probe.contains("guard UIApplication.shared.applicationState == .active,")
      && probe.contains("let cv = viewController?.collectionView, let window = cv.window"))
check("probes the message text views and the table scroll views",
      probe.contains("if v is SelectableMarkdownTextView { found.append((.text, v)) }")
      && probe.contains("if v is TableScrollView { found.append((.table, v)) }"))
check("hit test from the window at the visible middle",
      probe.contains("let hit = window.hitTest(point, with: nil)")
      && probe.contains("$0 === target || $0.isDescendant(of: target)"))
check("read-only: never writes view or gesture state",
      !probe.contains("isEnabled =") && !probe.contains("isUserInteractionEnabled =")
      && !probe.contains("removeFromSuperview") && !probe.contains("resignFirstResponder"))
check("recognizers UIKit disables by design are not reported",
      probe.contains("!$0.isScrollEnabled && ($0.panGestureRecognizer === gr")
      && probe.contains("let disabledHere = !gr.isEnabled && cur === view && !byDesign"))
check("logs through AppLogger under FGTouch", probe.contains("AppLogger(category: \"FGTouch\").info(line)"))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
