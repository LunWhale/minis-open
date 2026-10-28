#!/usr/bin/env swift
// [T-bg-idle-grace-cancel] A sub agent → parent handoff must not stop the
// background keep-alive 60 s later while the parent is still working.
//
// Field log 2026-09-26 (TestFlight 1.15, four terminations): the sub agent
// finishes → tracked set empty → 60 s idle grace armed; the parent is woken
// milliseconds later → decision NOOP(already playing); the grace was never
// cancelled because the only `cancelIdleGrace` for "work returned" sat in a
// trailing `else if shouldPlay` that the two branches above always shadow.
// 60 s later: IdleGrace expired … sessions=1 → keep-alive stopped →
// `remaining: 0.0s` → iOS terminated the app mid-task, no crash report.
//
// Run: swift KeepAliveIdleGraceCancelTests.swift
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

/// Model of evaluateSilentAudio's decision chain (bg, bgSpeak on, not suspended).
struct KA {
    var isActive = false, playing = false, graceArmed = false
    let fixed: Bool
    mutating func evaluate() {
        let shouldPlay = isActive
        if fixed, shouldPlay { graceArmed = false }                 // NEW: ahead of both branches
        if shouldPlay && !playing { playing = true; graceArmed = false }   // startSilentAudio cancels too
        else if shouldPlay && playing { /* cancelPendingSilentAudioStop only */ }
        else if !shouldPlay && playing { graceArmed = true }       // idle-only → grace
        else if shouldPlay { graceArmed = false }                  // OLD dead branch
    }
    mutating func graceExpires() { if graceArmed { playing = false; graceArmed = false } }
}
func handoff(fixed: Bool) -> Bool {
    var k = KA(fixed: fixed)
    k.isActive = true; k.evaluate()          // sub agent running in background
    k.isActive = false; k.evaluate()         // sub agent ends, set empty → grace
    k.isActive = true; k.evaluate()          // parent woken, set non-empty
    k.graceExpires()                         // 60 s later
    return k.playing                         // still keeping the app alive?
}

print("══ [1] sub agent → parent handoff in background ══")
check("OLD: keep-alive stopped 60 s after the handoff with the parent running (the field bug)", !handoff(fixed: false))
check("NEW: keep-alive still running after the grace would have expired", handoff(fixed: true))
do {
    var k = KA(fixed: true); k.isActive = true; k.evaluate(); k.isActive = false; k.evaluate(); k.graceExpires()
    check("NEW: a real idle still stops after the grace", !k.playing)
}

print("\n══ [2] source ══")
let src = source("Agent/Background/BackgroundKeepAliveManager.swift")
check("grace cancelled whenever shouldPlay, ahead of both play branches",
      src.contains("        if shouldPlay {\n") && src.contains("cancelIdleGrace(reason: \"work resumed (shouldPlay)\")"))
if let a = src.range(of: "cancelIdleGrace(reason: \"work resumed (shouldPlay)\")"),
   let b = src.range(of: "if shouldPlay && !silentAudioActive {") {
    check("…and it runs BEFORE the branch chain", a.lowerBound < b.lowerBound)
}
check("the unreachable trailing `else if shouldPlay` is gone",
      !src.contains("} else if shouldPlay {\n            // Work is back (or never left)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
