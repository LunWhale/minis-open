#!/usr/bin/env swift
// [T-send-composer-shrink-absorb] After a voice message was sent, the
// conversation jumped up and then snapped back down (screen recording: up
// 48 pt for the sent bubble, up 70 pt for the "is thinking…" row, then DOWN
// 106 pt in a single frame; net move 12 pt).
//
// Root cause: the message list's bottom inset follows the composer's height
// through a 380 ms trailing debounce. Sending from the voice panel shrinks the
// composer twice inside that window (transcript cleared: -51 pt; panel
// collapses to compact: -57 pt), so both appended rows were pinned against the
// pre-send composer line, and when the debounce landed the whole shrink was
// applied at once, un-animated, while the panel was still collapsing.
//
// Fix: a pin that is about to scroll the content up first takes that many
// points out of the composer shrink that has been REPORTED but not committed
// (ComposerShrinkAbsorption). The new rows fill the space the composer gives
// up; the rows above stay put. A shrink nothing absorbed is glided, not
// snapped.
//
// [1] runs the shipping bookkeeping against a model of the list's pin.
// [2] pins the wiring in the shipping sources.
//
// Run: swift ComposerShrinkAbsorptionTests.swift
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
func code(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
func index(_ hay: String, _ needle: String) -> Int {
    hay.range(of: needle).map { hay.distance(from: hay.startIndex, to: $0.lowerBound) } ?? -1
}

let V3 = "Agent/MessageList/CollectionViewMessageListV3/"
let absorption = source(V3 + "Support/ComposerShrinkAbsorption.swift")

// MARK: - 1. The shipping bookkeeping against a model of the pinned list

let scenario = #"""

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

/// The parts of the message list that matter here: a long conversation pinned
/// to the bottom, a bottom inset built from the DEBOUNCED composer height, and
/// the pin every content growth runs.
struct PinnedList {
    var contentHeight: CGFloat = 5000
    let viewport: CGFloat = 874
    let floatingBar: CGFloat = 60
    var inset: CGFloat = 0
    var offset: CGFloat = 0
    var absorbing: Bool
    var shrink = ComposerShrinkAbsorption()
    let live = ComposerLiveHeight()
    /// Screen y of the bottom of the last row that was there before the send.
    let anchor: CGFloat = 5000
    var anchorOnScreen: CGFloat { anchor - offset }
    var trace: [CGFloat] = []

    init(composer: CGFloat, absorbing: Bool) {
        self.absorbing = absorbing
        live.report(composer)
        commit(composer)
        trace = []
    }
    /// updateUIViewController with the debounced height.
    mutating func commit(_ committedHeight: CGFloat) {
        shrink.noteCommitted(committedHeight)
        let base = committedHeight + floatingBar + 8 - shrink.absorbed
        if abs(base - inset) > 0.5 {
            inset = base
            offset = contentHeight - viewport + inset      // re-pin
        }
        trace.append(anchorOnScreen)
    }
    /// The composer reports a new height (not committed yet).
    mutating func report(_ height: CGFloat) {
        live.report(height)
        let give = shrink.release(live: live.value)
        if give > 0 { inset += give; offset = contentHeight - viewport + inset }
        trace.append(anchorOnScreen)
    }
    /// A row is appended and the list follows it.
    mutating func append(_ height: CGFloat) {
        contentHeight += height
        if absorbing {
            let reach = contentHeight - viewport + inset - offset
            inset -= shrink.absorb(live: live.value, reach: reach)
        }
        offset = max(offset, contentHeight - viewport + inset)
        trace.append(anchorOnScreen)
    }
    /// Largest distance the pre-send content was away from where it started.
    func excursion(from start: CGFloat) -> CGFloat { trace.map { abs($0 - start) }.max() ?? 0 }
    /// Largest single downward step.
    func largestDrop() -> CGFloat {
        var worst: CGFloat = 0, prev = trace.first ?? 0
        for y in trace { worst = max(worst, y - prev); prev = y }
        return worst
    }
}

// The recording: expanded voice panel with a transcript (H1), transcript
// cleared on send (H2 = H1 - 51), panel collapses to compact (H3 = H2 - 57).
let H1: CGFloat = 320, H2: CGFloat = 269, H3: CGFloat = 212
let bubble: CGFloat = 48, typingRow: CGFloat = 70

func voiceSend(absorbing: Bool) -> (PinnedList, CGFloat) {
    var list = PinnedList(composer: H1, absorbing: absorbing)
    let start = list.anchorOnScreen
    list.report(H2)            // 1.567 s  transcript cleared
    list.append(bubble)        // 1.733 s  the sent bubble
    list.report(H3)            // ~1.75 s  collapse to compact (model height)
    list.append(typingRow)     // 2.033 s  "is thinking…"
    list.commit(H3)            // ~2.15 s  the debounce lands
    return (list, start)
}

print("1a. The recorded sequence, as it was (no absorption)")
let (before, start0) = voiceSend(absorbing: false)
check("content went up by the bubble and the typing row (118 pt) …", near(before.excursion(from: start0), bubble + typingRow))
check("… then dropped by the whole composer shrink (108 pt) in one step", near(before.largestDrop(), H1 - H3))

print("1b. The same sequence with absorption")
let (after, start1) = voiceSend(absorbing: true)
check("the sent bubble lands without moving the conversation", near(after.trace[1], start1))
check("the typing row moves it by what the composer could not give (10 pt)", near(after.trace[3], start1 - 10))
check("the debounce's commit finds nothing left to apply", near(after.trace[4], after.trace[3]))
check("largest excursion 10 pt instead of 118", near(after.excursion(from: start1), 10))
check("the conversation never moves down", after.largestDrop() < 0.01)
check("both end at the same place", near(after.anchorOnScreen, before.anchorOnScreen))

print("1c. Never more than the pin's reach")
var list = PinnedList(composer: H1, absorbing: true)
let s = list.anchorOnScreen
list.report(H3)                          // the full 108 pt shrink is known first
list.append(bubble)                      // … and only 48 pt of rows arrive
check("48 of 108 absorbed: content does not move, and does not move DOWN", near(list.anchorOnScreen, s) && near(list.shrink.absorbed, 48))
check("the rest stays pending", near(list.shrink.pending(live: list.live.value), 60))
list.commit(H3)
check("the commit applies the remaining 60 pt (this is the part that is glided)", near(list.anchorOnScreen, s + 60))

print("1d. The composer grows back before the commit")
var regrow = PinnedList(composer: H1, absorbing: true)
let s2 = regrow.anchorOnScreen
regrow.report(H3)
regrow.append(100)                       // absorbs 100 of 108
check("absorbed 100", near(regrow.shrink.absorbed, 100) && near(regrow.anchorOnScreen, s2))
regrow.report(H2)                        // back up: only 51 may stay absorbed
check("the inset gets 49 pt back at once", near(regrow.shrink.absorbed, 51) && near(regrow.anchorOnScreen, s2 - 49))
regrow.report(H1)                        // fully back
check("fully back: nothing absorbed, rows sit above the tall composer", near(regrow.shrink.absorbed, 0) && near(regrow.anchorOnScreen, s2 - 100))
regrow.commit(H1)
check("an unchanged commit changes nothing", near(regrow.anchorOnScreen, s2 - 100))

print("1e. Bookkeeping edges")
var b = ComposerShrinkAbsorption()
b.noteCommitted(300)
check("no live height known: nothing pending, nothing absorbed", b.pending(live: 0) == 0 && b.absorb(live: 0, reach: 80) == 0)
check("live not smaller than committed: nothing pending", b.pending(live: 300) == 0 && b.pending(live: 340) == 0)
check("a pin with no reach absorbs nothing", b.absorb(live: 250, reach: 0) == 0 && b.absorbed == 0)
check("a negative reach absorbs nothing", b.absorb(live: 250, reach: -30) == 0)
check("absorb returns what it took", b.absorb(live: 250, reach: 30) == 30 && b.absorbed == 30 && b.pending(live: 250) == 20)
check("a second pin takes the rest, not more", b.absorb(live: 250, reach: 500) == 20 && b.absorbed == 50 && b.pending(live: 250) == 0)
b.noteCommitted(300)
check("re-noting the same committed height keeps the absorption", b.absorbed == 50)
b.noteCommitted(250)
check("a new committed height clears it", b.absorbed == 0 && b.committed == 250)
let box = ComposerLiveHeight()
var fired = 0
box.onChange = { fired += 1 }
box.report(0); box.report(200); box.report(200.3); box.report(180)
check("the live box ignores zero and sub-half-point noise, and reports real changes", fired == 2 && box.value == 180)

exit(failures == 0 ? 0 : 1)
"""#

print("1. The shipping bookkeeping against a model of the pinned list")
check("the bookkeeping source was found", absorption.contains("struct ComposerShrinkAbsorption {") && absorption.contains("final class ComposerLiveHeight {"))
if failures == 0 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ComposerShrinkAbsorption-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? ("import Foundation\n" + absorption + scenario).write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text, terminator: "")
    let passed = text.components(separatedBy: "✅").count - 1
    check("harness ran to the end (\(passed) checks) and exited 0", p.terminationStatus == 0 && passed >= 24)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 2. Wiring

print("\n2. Wiring in the shipping sources")
let scroll = source(V3 + "Coordinator/MessageListV3Coordinator+Scroll.swift")
let setup = source(V3 + "Coordinator/MessageListV3Coordinator+Setup.swift")
let snapshot = source(V3 + "Coordinator/MessageListV3Coordinator+Snapshot.swift")
let bindings = source(V3 + "Coordinator/MessageListV3Coordinator+Bindings.swift")
let representable = source(V3 + "CollectionViewMessageListV3.swift")
let inputBar = source("Views/Chat/AIChatView/AIChatView+InputBar.swift")
let messagesArea = source("Views/Chat/AIChatView/AIChatView+MessagesArea.swift")

check("the three pins that follow content growth absorb first: scrollToBottomNow …",
      index(scroll, "absorbPendingComposerShrink(caller: \"scrollToBottom\")") > index(scroll, "func scrollToBottomNow(animated: Bool = false) {")
      && index(scroll, "absorbPendingComposerShrink(caller: \"scrollToBottom\")") < index(scroll, "if applySubViewportCompensation(caller: \"scrollToBottom\") {"))
check("… the content-size observer, before it computes its target …",
      index(setup, "self.absorbPendingComposerShrink(caller: \"contentSizeKVO\")") > index(setup, "if delta > 0 && self.scrollMode == .autoScrolling {")
      && index(setup, "self.absorbPendingComposerShrink(caller: \"contentSizeKVO\")") < index(setup, "let maxOff = newH - cv.bounds.height + cv.adjustedContentInset.bottom"))
check("… and the snapshot flush, before its target, only when rows were not removed",
      snapshot.contains("if scrollMode == .autoScrolling && newItems.count >= oldCount {\n                    absorbPendingComposerShrink(caller: \"snapshot\")\n                }\n                let rawMaxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom"))
let absorbFn = scroll.components(separatedBy: "func absorbPendingComposerShrink(caller: String) {").dropFirst().first?
    .components(separatedBy: "\n        func ").first ?? ""
check("absorption is limited to the window after a send, to a pinned list, and to the plain (uninflated) inset",
      absorbFn.contains("CFAbsoluteTimeGetCurrent() < composerShrinkAbsorbDeadline")
      && absorbFn.contains("scrollMode == .autoScrolling")
      && absorbFn.contains("guard abs(cv.contentInset.bottom - baseBottomInset) <= 0.5 else { return }"))
check("the reach is how far the pin is about to scroll, and base and inset move together",
      absorbFn.contains("let reach = cv.contentSize.height - cv.bounds.height\n                + cv.adjustedContentInset.bottom - cv.contentOffset.y")
      && absorbFn.contains("baseBottomInset -= take\n            cv.contentInset.bottom = baseBottomInset"))
check("every send opens the window (the force-scroll signal)",
      bindings.contains("self.composerShrinkAbsorbDeadline = CFAbsoluteTimeGetCurrent() + 2.0\n")
      && index(bindings, "self.composerShrinkAbsorbDeadline = ") > index(bindings, "vm.forceScrollToBottom"))
check("the base inset has the absorbed part taken out, and the committed height is noted first",
      representable.contains("coord.composerShrink.noteCommitted(inputBarHeight)\n        let bottomPad: CGFloat = inputBarHeight + floatingBarHeight + 8 - coord.composerShrink.absorbed"))
check("a composer that grows back is given its space at once",
      representable.contains("composerLiveHeight?.onChange = { [weak coord] in coord?.composerLiveHeightDidChange() }")
      && scroll.contains("let give = composerShrink.release(live: live)"))
check("a pinned shrink is glided, a growth is not",
      representable.contains("if !wasSmaller {\n                    coord.glideContentDown(fromOffsetY: offsetBeforeBaseChange)\n                }")
      && representable.contains("let offsetBeforeBaseChange = cv.contentOffset.y"))
let glideFn = scroll.components(separatedBy: "func glideContentDown(fromOffsetY oldY: CGFloat) {").dropFirst().first?
    .components(separatedBy: "\n        func ").first ?? ""
check("the glide is additive, presentation-only and honours Reduce Motion",
      glideFn.contains("glide.isAdditive = true") && glideFn.contains("CABasicAnimation(keyPath: \"bounds.origin\")")
      && glideFn.contains("!UIAccessibility.isReduceMotionEnabled") && !code(glideFn).contains("layoutIfNeeded"))
check("the composer reports its undebounced height, on-screen samples only",
      inputBar.contains("if onscreen {\n                    latestInputBarFrameH = newH\n                    composerLiveHeight.report(newH)\n                }"))
check("the chat's list gets the live height; the debounce itself is untouched",
      messagesArea.contains("composerLiveHeight: composerLiveHeight")
      && inputBar.contains("try? await Task.sleep(for: .milliseconds(380))")
      && inputBar.contains("inputBarHeight = committed"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
