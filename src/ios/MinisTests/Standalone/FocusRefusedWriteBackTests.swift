#!/usr/bin/env swift
// [T-focus-refused-writes-back] The composer's focus sync is edge-triggered
// (it acts only when the requested value changes). When it refused a focus
// request because the page was being swiped/pushed away, it left
// lastRequestedFocus = true and the binding true while the text view stayed
// unfocused — so every later `inputFocused = true` changed nothing and never
// fired: tap-to-focus, the slash button, edit-message and swipe-up-to-focus
// were dead until the user tapped the text view itself.
//
// Run: swift FocusRefusedWriteBackTests.swift
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

// Model of the edge-triggered sync.
struct Sync {
    var binding = false, last: Bool? = nil, focused = false, leaving = false, writeBack: Bool
    mutating func update() {
        let changed = last != binding
        last = binding
        guard changed, binding != focused else { return }
        if binding {
            if leaving { if writeBack { binding = false; last = false }; return }
            focused = true
        }
    }
}
for writeBack in [false, true] {
    var s = Sync(writeBack: writeBack)
    s.leaving = true
    s.binding = true; s.update()            // post-reply autofocus fires mid-push → refused
    s.leaving = false                        // back on the chat
    s.binding = true; s.update()            // user taps the input area
    if writeBack { check("NEW: a later focus request works", s.focused) }
    else { check("OLD: reproduces — later focus request is a no-op", !s.focused && s.binding) }
}

print("\nsource")
let bar = source("Views/Chat/ChatInputBar.swift")
check("refusal writes the binding back",
      bar.contains("if coordinator.parent.isFocused { coordinator.parent.isFocused = false }\n                        coordinator.lastRequestedFocus = false"))
check("a cancelled swipe restores binding + request before refocusing",
      bar.contains("coordinator?.lastRequestedFocus = true\n                            coordinator?.parent.isFocused = true"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
