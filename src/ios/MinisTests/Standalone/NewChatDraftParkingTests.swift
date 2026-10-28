#!/usr/bin/env swift
// [OpenMinis#433] Text typed in a NEW chat (never sent) vanished when the user
// went back and came in again, while an existing session kept its draft. A new
// chat's ViewModel was never cached (it has no session id), so `inputText`
// died with the view. Reproduced on iPad AND iPhone - not a platform split.
//
// The fix parks the unsent new chat's VM in ViewModelCache on leave and the
// next new chat for the same group resumes it. No session row is written, so
// abandoned drafts cannot pile up as empty sessions.
//
// A parked draft lives 15 minutes from the moment it is parked (follow-up to
// #433): taken within that time it comes back unchanged; after it, it is
// treated as absent and dropped, and other expired slots go with it.
//
//   [0] the shipping ParkedDrafts slots, compiled standalone and driven with
//       an injected clock (no sleeping): 14 min -> still there; just over
//       15 min -> gone and cleared; expired neighbours are purged
//   [1-3] source guards over the wiring (the cache and the view are
//       MainActor/SwiftUI types that cannot run in a standalone script)
//
// Run: swift NewChatDraftParkingTests.swift   (needs swiftc)
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

let cache = source("Agent/Chat/ChatLifecycleSupport.swift")
let vm = source("Agent/Chat/AIChatViewModel.swift")
let view = source("Views/Chat/AIChatView/AIChatView.swift")

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

print("[0] ParkedDrafts lifetime (injected clock)")
if let slotsBlock = between(cache, "// BEGIN ParkedDrafts", "// END ParkedDrafts") {
    let harness = "import Foundation\n" + slotsBlock + #"""

    var fails = 0
    func CHECK(_ label: String, _ ok: Bool) { print("  \(ok ? "PASS" : "FAIL") \(label)"); if !ok { fails += 1 } }
    final class Draft { let text: String; init(_ t: String) { text = t } }
    typealias Slots = ParkedDrafts<Draft>
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    CHECK("lifetime is 15 minutes, defined once", Slots.lifetime == 15 * 60)

    var s = Slots()
    let a = Draft("hello")
    s.park(a, key: "g1", now: t0)
    CHECK("taken 14 minutes later: the same draft comes back", s.take(key: "g1", now: at(14)) === a)
    CHECK("take empties the slot", s.count == 0 && s.take(key: "g1", now: at(14)) == nil)

    s.park(a, key: "g1", now: t0)
    CHECK("exactly 15 minutes is still inside the lifetime", s.take(key: "g1", now: at(15)) === a)

    s.park(a, key: "g1", now: t0)
    CHECK("just over 15 minutes: treated as absent", s.take(key: "g1", now: at(15).addingTimeInterval(1)) == nil)
    CHECK("…and the slot is cleared", s.count == 0)

    // Other groups' expired drafts are purged on take, park, clear and remove.
    let b = Draft("other group"), c = Draft("fresh")
    s.park(a, key: "g1", now: t0)
    s.park(b, key: "g2", now: at(1))
    CHECK("a miss on another key still purges the expired slots", s.take(key: "nope", now: at(20)) == nil && s.count == 0)
    s.park(a, key: "g1", now: t0)
    s.park(c, key: "g3", now: at(16))
    CHECK("parking purges expired neighbours and keeps the new one", s.count == 1 && s.take(key: "g3", now: at(17)) === c)
    s.park(a, key: "g1", now: t0)
    s.remove(c, now: at(16))
    CHECK("unpark of another draft purges too", s.count == 0)
    s.park(a, key: "g1", now: t0)
    CHECK("purgeExpired reports what it dropped", s.purgeExpired(now: at(10)) == 0 && s.purgeExpired(now: at(16)) == 1 && s.count == 0)

    // Lifetime counts from the LAST parking.
    s.park(a, key: "g1", now: t0)
    s.park(a, key: "g1", now: at(10))
    CHECK("parking again restarts the 15 minutes", s.take(key: "g1", now: at(24)) === a)

    // Unexpired behaviour is unchanged.
    s.park(a, key: "g1", now: t0)
    s.clear(key: "g1", ifHolding: b, now: at(1))
    CHECK("an emptied draft never clears another chat's slot", s.count == 1)
    s.clear(key: "g1", ifHolding: a, now: at(1))
    CHECK("an emptied draft clears its own slot", s.count == 0)
    s.park(a, key: "g1", now: t0); s.park(b, key: "g2", now: t0)
    s.remove(a, now: at(1))
    CHECK("unpark drops only that draft", s.count == 1 && s.take(key: "g2", now: at(2)) === b)
    s.park(a, key: "", now: t0)
    CHECK("the no-group slot works the same", s.take(key: "", now: at(5)) === a)
    exit(fails == 0 ? 0 : 1)
    """#
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("parked-drafts-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
    try? harness.write(to: src, atomically: true, encoding: .utf8)
    let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
    check("ParkedDrafts compiles standalone", cc == 0)
    if cc != 0 { print(ccOut) } else {
        let (status, out) = run(bin, [])
        print(out, terminator: "")
        check("lifetime checks all pass", status == 0 && !out.contains("FAIL "))
    }
} else {
    check("ParkedDrafts block found", false)
}

print("[1] ViewModelCache parking")
let park = between(cache, "func parkNewChatIfUnsent(", "func takeParkedNewChat(") ?? ""
check("park only a never-sent, local, idle chat",
      park.contains("vm.sessionId == nil") && park.contains("vm.remoteDeviceId == nil") && park.contains("!vm.isProcessing"))
check("park only when something was typed or attached", park.contains("if vm.hasUnsentDraft"))
check("one slot per model group, stamped with the injected clock",
      park.contains("let key = groupId ?? \"\"") && park.contains("let now = parkedDraftClock()")
      && park.contains("parkedNewChats.park(vm, key: key, now: now)"))
check("an emptied draft clears its own slot, never another chat's",
      park.contains("parkedNewChats.clear(key: key, ifHolding: vm, now: now)"))
let take = between(cache, "func takeParkedNewChat(", "func unparkNewChat(") ?? ""
check("take removes the VM (and drops an expired one) through the slots",
      take.contains("parkedNewChats.take(key: groupId ?? \"\", now: parkedDraftClock())"))
check("unpark drops a VM that is back on screen",
      (between(cache, "func unparkNewChat(", "func cacheDraft(") ?? "").contains("parkedNewChats.remove(vm, now: parkedDraftClock())"))
check("the clock is injectable and the lifetime is one constant",
      cache.contains("var parkedDraftClock: () -> Date = { Date() }")
      && cache.components(separatedBy: "15 * 60").count - 1 == 1
      && cache.contains("static var lifetime: TimeInterval { 15 * 60 }"))
check("no session row is created for a parked draft",
      !park.contains("ensureSession") && !park.contains("ChatStore") && !park.contains("cacheDraft("))

print("[2] what counts as a draft")
let has = between(vm, "var hasUnsentDraft: Bool {", "}") ?? ""
check("non-blank text", has.contains("inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
check("or an attachment", has.contains("!attachments.isEmpty"))

print("[3] AIChatView wiring")
let cvm = between(view, "init(sessionId: String?, initialGroupId: String? = nil) {", "// Forward VM's objectWillChange") ?? ""
check("a new chat resumes the parked VM for its group before creating one",
      { guard let t = cvm.range(of: "takeParkedNewChat(groupId: initialGroupId)"),
              let c = cvm.range(of: "createDraft()") else { return false }
        return t.lowerBound < c.lowerBound }())
check("existing sessions never consult the parking slot",
      { guard let g = cvm.range(of: "getOrCreate(for: sessionId)"),
              let t = cvm.range(of: "takeParkedNewChat") else { return false }
        return g.lowerBound < t.lowerBound && cvm.contains("} else if let parked") }())
check("AIChatView passes its group to CachedViewModel",
      view.contains("CachedViewModel(sessionId: sessionId, initialGroupId: initialGroupId)"))
let disappear = between(view, ".onDisappear {\n            isChatViewVisible = false", "🔑DRAFT AIChatView.onDisappear") ?? ""
check("leaving parks the chat", disappear.contains("ViewModelCache.shared.parkNewChatIfUnsent(vm, groupId: initialGroupId)"))
check("parking runs after the voice cleanup", { guard let v = disappear.range(of: "abandonFinishForSend"),
                                                      let p = disappear.range(of: "parkNewChatIfUnsent") else { return false }
                                                return v.lowerBound < p.lowerBound }())
let appear = between(view, ".onAppear {\n            wireComposerActions()", "AlwaysOnController.shared.chatAppeared") ?? ""
check("coming back on screen unparks it", appear.contains("ViewModelCache.shared.unparkNewChat(vm)"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
