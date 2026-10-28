// [T-pop-keyboard-flash-home] iOS 16: leaving a chat with the keyboard up
// flashed a keyboard fragment in the middle of the home list after the pop.
//
// The keyboard was only released in onDisappear, which fires after the
// navigation transition finishes, so its dismiss animation played over the
// home screen. A child view controller now releases it from viewWillDisappear,
// when the pop starts. onDisappear keeps its own release as the backstop.
// Round 2 (device log, iOS 16.1): ending editing alone was undone mid-pop —
// `inputFocused` stayed true and the composer's focus sync re-called
// becomeFirstResponder. The hook now clears the focus state too, and the focus
// sync refuses to re-focus while the page is being popped / dismissed.
// Round 3: timing now matches iMessage (see the timing model below).
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift PopKeyboardReleaseTests.swift`

import Foundation

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let chat = chatViewSource()
let bar = (try? String(contentsOf: root.appendingPathComponent("Views/Chat/ChatInputBar.swift"), encoding: .utf8)) ?? ""
check("source found", !chat.isEmpty)

// Round 3 (screen recording vs iMessage): iMessage keeps the keyboard still
// while the back swipe drags and dismisses it only once the pop commits.
print("\n▶️  timing model")
enum Pop { case button, swipe(committed: Bool) }
func releases(_ p: Pop) -> (atStart: Bool, atLift: Bool) {
    switch p {
    case .button: return (true, false)
    case .swipe(let committed): return (false, committed)
    }
}
check("back button: released at transition start", releases(.button) == (true, false))
check("swipe committed: released when the finger lifts", releases(.swipe(committed: true)) == (false, true))
check("swipe cancelled: keyboard untouched", releases(.swipe(committed: false)) == (false, false))
check("source: non-interactive runs immediately",
      chat.contains("guard let coordinator = transitionCoordinator, coordinator.isInteractive else {\n                action()\n                return\n            }"))
check("source: interactive waits for the lift and skips a cancel",
      chat.contains("coordinator.notifyWhenInteractionChanges { [weak self] context in\n                guard !context.isCancelled else { return }\n                self?.action()"))
check("hook view never takes touches", chat.contains("v.isUserInteractionEnabled = false"))
check("hook refreshes its action on update", chat.contains("controller.action = action"))
check("chat attaches the hook, which ends editing",
      chat.contains(".background(ViewWillDisappearHook(action: {") && chat.contains("released the keyboard before the transition"))
guard let hook = chat.range(of: ".background(ViewWillDisappearHook(action: {"),
      let disappear = chat.range(of: ".onDisappear {\n            isChatViewVisible = false") else {
    check("hook and onDisappear located", false); exit(1)
}
check("hook sits on the same chain, just before onDisappear", hook.lowerBound < disappear.lowerBound
      && chat.distance(from: hook.upperBound, to: disappear.lowerBound) < 800)
check("onDisappear keeps its own release as the backstop",
      chat.contains("chat onDisappear — released a lingering first responder"))

check("hook clears the focus state through the channel (no view capture)",
      // [T-pop-keyboard-late-autofocus] The hook now also latches the page as
      // leaving (PageLeaveLatch) before releasing focus.
      chat.contains(".background(ViewWillDisappearHook(action: { [composerActions, pageLeaveLatch] in\n            pageLeaveLatch.markLeaving()\n            _ = composerActions.send(.releaseFocus)"))
check("channel handles releaseFocus", chat.contains("case .releaseFocus: inputFocused = false; return true"))
check("focus sync skips re-focus while the page is leaving",
      bar.contains("if w.isMovingFromParent || w.isBeingDismissed { return (true, w.transitionCoordinator) }")
      && bar.contains("skipping becomeFirstResponder — page is leaving"))

// Round 4 (device log 21:52:40): UIKit resigns the text view when a back
// swipe STARTS; isMovingFromParent is still false during the drag, so the
// focus sync re-focused → keyboard down/up on every swipe.
// Round 6 (lldb): the controller-chain test returned false mid-swipe on
// iOS 16.1, so the refocus still went through; the check is view-based now.
check("focus sync skips the page the transition is leaving (view-based)",
      bar.contains("for tc in [w.transitionCoordinator, w.navigationController?.transitionCoordinator].compactMap({ $0 }) {")
      && bar.contains("view.isDescendant(of: from)"))
check("refocus decision is logged", bar.contains("[updateUIView] refocus check leaving="))

// Round 7 (device log 22:49:20): at the resign leaving=true, but 100 ms later
// the binding was true again and a fresh leaving check in the async refocus
// said false. The decision is latched at resign time instead.
print("\n▶️  latched hold model")
final class Hold {
    var hold = false, focused = true, restored = false
    func externalResign(leaving: Bool) { focused = false; if leaving { hold = true } }
    func asyncRefocus(leavingNow: Bool) { if !(leavingNow || hold) { focused = true } }
    func transitionEnded(cancelled: Bool) { hold = false; if cancelled { focused = true; restored = true } }
}
do {
    let h = Hold()
    h.externalResign(leaving: true)
    h.asyncRefocus(leavingNow: false)      // the case the device hit
    check("hold blocks the refocus even when the late check says 'not leaving'", !h.focused)
    h.transitionEnded(cancelled: true)
    check("a cancelled swipe restores focus and drops the hold", h.focused && h.restored && !h.hold)
    let c = Hold(); c.externalResign(leaving: true); c.transitionEnded(cancelled: false)
    check("a committed pop drops the hold without refocusing", !c.focused && !c.hold)
    let o = Hold(); o.externalResign(leaving: false); o.asyncRefocus(leavingNow: false)
    check("a resign that is not a page leaving holds nothing", !o.hold)
}
check("source: hold latched at resign time", bar.contains("if isLeaving { holdFocusForTransition = true }"))
check("source: transition completion releases the hold", bar.contains("self?.holdFocusForTransition = false"))
check("source: refocus honours the hold", bar.contains("let leaving = leavingNow || coordinator.holdFocusForTransition"))
check("source: focus gained clears the hold", bar.contains("// Focus is back (user tap or restore): no transition hold applies.\n            holdFocusForTransition = false"))
check("a cancelled swipe gets its focus back",
      bar.contains("guard context.isCancelled, let tv, tv.window != nil, !tv.isFirstResponder else { return }"))

// Round 5 (lldb, iOS 16.1): SwiftUI's hosting controller resigns the text view
// from viewWillDisappear at swipe start, and the LEVEL-triggered focus sync
// (`closure #1 in updateUIView` → becomeFirstResponder ×2) forced it back.
print("\n▶️  edge-triggered focus sync model")
final class Sync {
    var binding = true, focused = true, last: Bool? = true, becomeCalls = 0
    func update() {
        let changed = last != binding; last = binding
        if changed && binding != focused { focused = binding; if binding { becomeCalls += 1 } }
    }
    func externalResign() { focused = false; binding = false; last = false }
}
do {
    let s = Sync()
    s.focused = false          // SwiftUI resigns at swipe start
    s.update()                 // binding still true, unchanged → no fight
    check("resign by someone else is not reverted by the next update", !s.focused && s.becomeCalls == 0)
    let t = Sync(); t.externalResign(); t.update()
    check("external resign is written back to the binding", !t.binding && !t.focused)
    t.binding = true; t.update()
    check("a later inputFocused = true still focuses (binding was not stale)", t.focused && t.becomeCalls == 1)
}
check("source: sync acts only when the request changed",
      bar.contains("let requestChanged = context.coordinator.lastRequestedFocus != wantsFocus")
      && bar.contains("if requestChanged && wantsFocus != hasFocus {"))
check("source: external resign writes the binding back",
      bar.contains("if !isResigningForSync {\n                if parent.isFocused { parent.isFocused = false }"))
check("source: own resign is marked", bar.contains("coordinator.isResigningForSync = true\n                    tv.resignFirstResponder()"))
check("source: modal-blocked focus retries later", bar.contains("coordinator.lastRequestedFocus = nil"))
check("source: cancelled swipe restores focus after an external resign",
      bar.contains("pasteLog.debug(\"[Coordinator] swipe cancelled — restoring focus\")"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
