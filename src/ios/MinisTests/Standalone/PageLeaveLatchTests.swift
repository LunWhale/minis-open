#!/usr/bin/env swift
// [T-pop-keyboard-late-autofocus] New chat, Back within ~0.66 s: the draft's
// delayed autofocus (asyncAfter 0.6 s) fired AFTER the pop had finished but
// BEFORE onDisappear cleared isChatViewVisible, so the keyboard rose over the
// home screen (iPhone 11 / iOS 27.2: 9/9 at Back 360-630 ms after appear).
//
//   [1] PageLeaveLatch (BEGIN/END block in ViewWillDisappearHook.swift),
//       compiled and driven through device-measured timelines: quick Back is
//       refused, a normal stay still focuses, Back after focus is unchanged,
//       a cancelled swipe keeps the focus, a cover clears the latch on return,
//       the latch never carries into the next entry.
//   [2] Source guards: the hook latches on the COMMITTED path only, clears on
//       viewWillAppear and onAppear, and all four delayed composer focus
//       timers go through canRunDelayedComposerFocus.
//
// Run: swift PageLeaveLatchTests.swift   (needs swiftc)
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

let hookFile = source("Views/Chat/AIChatView/Support/ViewWillDisappearHook.swift")
let chat = source("Views/Chat/AIChatView/AIChatView.swift")
let share = source("Views/Chat/AIChatView/AIChatView+ShareInjection.swift")
guard let latchBlock = between(hookFile, "// BEGIN PageLeaveLatch", "// END PageLeaveLatch") else {
    print("❌ PageLeaveLatch block not found"); exit(1)
}

// The harness replays a page's life as timed events (ms after the page
// appeared), the way the device log showed them, and records whether the
// delayed focus timer would raise the keyboard.
let harness = """
import Foundation
\(latchBlock)

enum Event { case appear, hookWillAppear, commitLeave, onDisappear, timer }
/// Replays events in time order. `isVisible` mirrors isChatViewVisible
/// (true from onAppear until onDisappear). Returns whether the timer focused.
func replay(_ events: [(Int, Event)], latch: PageLeaveLatch = PageLeaveLatch(), useLatch: Bool = true) -> Bool {
    var visible = false, focused = false
    for (_, e) in events.sorted(by: { $0.0 < $1.0 }) {
        switch e {
        case .appear: visible = true; latch.markAppeared()
        case .hookWillAppear: latch.markAppeared()
        case .commitLeave: latch.markLeaving()
        case .onDisappear: visible = false
        case .timer: focused = useLatch ? latch.allowsDelayedFocus(isVisible: visible) : visible
        }
    }
    return focused
}
func out(_ k: String, _ v: Any) { print("R \\(k)=\\(v)") }

// Device timeline (iPhone 11, iOS 27.2): Back 360 ms, focus timer 665 ms,
// onDisappear 920 ms.
let quickBack: [(Int, Event)] = [(0, .appear), (0, .hookWillAppear), (360, .commitLeave), (665, .timer), (920, .onDisappear)]
out("quickBack.before", replay(quickBack, useLatch: false))
out("quickBack.after", replay(quickBack))
// Edges of the measured window: Back at 30 ms and at 630 ms.
out("veryQuickBack", replay([(0, .appear), (30, .commitLeave), (665, .timer), (590, .onDisappear)]))
out("lateEdgeBack", replay([(0, .appear), (630, .commitLeave), (724, .timer), (1218, .onDisappear)]))
// No Back: the timer focuses as before.
out("stay", replay([(0, .appear), (0, .hookWillAppear), (665, .timer)]))
// Back after the focus landed (>= 850 ms): the timer already ran with the
// page visible - unchanged; the hook's releaseFocus handles that keyboard.
out("backAfterFocus", replay([(0, .appear), (665, .timer), (850, .commitLeave), (1380, .onDisappear)]))
// Interactive swipe cancelled: the hook never commits, UIKit sends
// viewWillAppear back to the page; a timer after it still focuses.
out("swipeCancelled", replay([(0, .appear), (300, .hookWillAppear), (665, .timer)]))
// Swipe committed (finger lifted) before the timer: refused.
out("swipeCommitted", replay([(0, .appear), (500, .commitLeave), (665, .timer), (1100, .onDisappear)]))
// Full-screen cover over the chat: hook fires on present, viewWillAppear on
// dismiss; a later delayed focus (e.g. after-reply) still works.
out("coverReturn", replay([(0, .appear), (100, .commitLeave), (900, .hookWillAppear), (1500, .timer)]))
// The latch never carries over: a page that left, shown again (same state
// object), focuses normally on the next timer.
let shared = PageLeaveLatch()
_ = replay(quickBack, latch: shared)
let leftAfterQuickBack = shared.isLeaving
out("noLinger", leftAfterQuickBack && replay([(0, .appear), (0, .hookWillAppear), (665, .timer)], latch: shared))
// Repeated new -> quick back -> new -> wait: every new page has a fresh latch.
var seq: [Bool] = []
for i in 0..<6 {
    let l = PageLeaveLatch()
    seq.append(i % 2 == 0 ? replay(quickBack, latch: l) : replay([(0, .appear), (665, .timer)], latch: l))
}
out("alternating", seq.map { $0 ? "F" : "-" }.joined())
// Not visible at all (onDisappear already ran) is still refused.
out("afterOnDisappear", replay([(0, .appear), (300, .onDisappear), (665, .timer)]))
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pageleave_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try? harness.write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", mainFile.path, "-o", exe])
guard cs == 0 else { print("❌ compile failed\n\(cout)"); exit(1) }
let (_, rout) = run(exe, [])
var r: [String: String] = [:]
for line in rout.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("1. PageLeaveLatch on device-measured timelines")
check("old guard (isChatViewVisible only) focused after a quick Back - the bug", r["quickBack.before"] == "true")
check("quick Back (360 ms) now refuses the late focus", r["quickBack.after"] == "false")
check("Back at the window's edges (30 ms, 630 ms) refused", r["veryQuickBack"] == "false" && r["lateEdgeBack"] == "false")
check("no Back: the 0.6 s autofocus still focuses", r["stay"] == "true")
check("Back after focus landed: unchanged", r["backAfterFocus"] == "true")
check("cancelled back swipe: the page keeps its delayed focus", r["swipeCancelled"] == "true")
check("committed back swipe before the timer: refused", r["swipeCommitted"] == "false")
check("full-screen cover: cleared on return, later focus works", r["coverReturn"] == "true")
check("latch cleared when the page shows again (no lingering)", r["noLinger"] == "true")
check("new/quick-back/new/wait x3: only the waited pages focus", r["alternating"] == "-F-F-F")
check("after onDisappear still refused", r["afterOnDisappear"] == "false")

print("\n2. Wiring")
let controller = between(hookFile, "final class Controller: UIViewController {", "// BEGIN PageLeaveLatch") ?? ""
check("hook controller calls onWillAppear from viewWillAppear",
      controller.contains("override func viewWillAppear(_ animated: Bool) {\n            super.viewWillAppear(animated)\n            onWillAppear()"))
check("hook action still runs only for committed leaves (cancelled swipe skipped)",
      controller.contains("guard !context.isCancelled else { return }\n                self?.action()"))
check("hook refreshes both closures on update",
      hookFile.contains("controller.action = action\n        controller.onWillAppear = onWillAppear"))
check("chat latches leaving first, then releases focus as before (8bb07702c kept)",
      chat.contains("ViewWillDisappearHook(action: { [composerActions, pageLeaveLatch] in\n            pageLeaveLatch.markLeaving()\n            _ = composerActions.send(.releaseFocus)")
      && chat.contains("released the keyboard before the transition"))
check("hook closures capture the latch, not the view",
      chat.contains("}, onWillAppear: { [pageLeaveLatch] in\n            pageLeaveLatch.markAppeared()"))
check("onAppear clears the latch too",
      chat.contains("isChatViewVisible = true\n            pageLeaveLatch.markAppeared()"))
check("draft 0.6 s autofocus uses the guard",
      chat.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {\n                    guard !hasOverlayPresented, canRunDelayedComposerFocus(\"draft\") else { return }"))
check("after-reply 1.5 s autofocus uses the guard",
      chat.contains("guard !hasOverlayPresented, canRunDelayedComposerFocus(\"after-reply\") else { return }"))
check("share 0.3 s and transfer 0.6 s use the guard",
      share.contains("guard self.canRunDelayedComposerFocus(\"share\") else { return }")
      && share.contains("guard self.canRunDelayedComposerFocus(\"transfer\") else { return }"))
check("no delayed timer still guards on isChatViewVisible alone",
      !chat.contains("guard !hasOverlayPresented, isChatViewVisible else { return }")
      && !share.contains("guard self.isChatViewVisible else { return }\n                inputFocused = true")
      && !share.contains("guard self.isChatViewVisible else { return }\n            inputFocused = true"))
check("guard = visible AND not leaving, and logs a refusal",
      share.contains("guard pageLeaveLatch.allowsDelayedFocus(isVisible: isChatViewVisible) else {")
      && share.contains("skipped — the page is leaving"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
