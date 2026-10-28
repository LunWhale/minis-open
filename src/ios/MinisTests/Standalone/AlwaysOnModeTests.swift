// Tests for [T-always-on]: Always On mode, part of Keep Screen Awake.
//
// While the chat on screen runs an agent task and its switch is on (the
// chat's … menu override, else Keep Screen Awake), hold the screen on from the
// start of the task; after 30 s without activity show a black overlay with
// the current step; any activity or tap hides it. Task end, leaving the
// chat, background or switching off hide it and release the lease.
//
//   [1] decision logic, ported from AlwaysOnController with a fake clock
//   [2] activity monitoring never interferes with gestures
//   [3] lifecycle and wiring (source guards)
//
// Standalone: `swift AlwaysOnModeTests.swift`.

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

/// The home screen sources - Views/ContentView/ plus Views/Settings/SettingsSheet.swift
/// and AppearanceSettingsView.swift, formerly the single file ContentView.swift -
/// read as one text with the files in path order.
func contentViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/ContentView")
    var files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    files += ["Views/Settings/SettingsSheet.swift", "Views/Settings/AppearanceSettingsView.swift"]
        .map { ios.appendingPathComponent($0) }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

// MARK: - [1] Port of the decision logic

struct Model {
    var global = false
    var overrides: [String: Bool] = [:]
    var visible: String?
    var active: Set<String> = []
    var aliases: [String: String] = [:]
    var background = false, locked = false, voiceOver = false, onMac = false
    var appActive = true
    var blocker: String?
    var lastActivity: Double = 0
    var showing = false
    var lease = false
    /// [T-always-on-idle-setting] Screen Saver: seconds, nil = off. Sections
    /// 2–4 run with it on at 30 s; section 10 covers the setting itself.
    var idle: Double? = 30

    /// [T-keep-awake-sticky-off] The override is found under the draft id and the real id alike.
    func override(_ k: String) -> Bool? {
        if let v = overrides[k] { return v }
        if let real = aliases[k], let v = overrides[real] { return v }
        return overrides.first { aliases[$0.key] == k }?.value
    }
    func effective(_ k: String?) -> Bool { guard let k else { return false }; return override(k) ?? global }
    func isActive(_ k: String) -> Bool { active.contains(k) || aliases[k].map { active.contains($0) } == true }
    var armed: Bool {
        !onMac && !voiceOver && !background && !locked && effective(visible)
            && (visible.map { isActive($0) } ?? false)
    }
    mutating func refresh() { lease = armed; if !armed || idle == nil { showing = false } }
    /// The idle timer firing at `now`.
    mutating func fire(at now: Double) {
        guard armed, appActive, !showing, let idle, now - lastActivity >= idle - 0.05 else { return }
        if blocker != nil { lastActivity = now; return }
        showing = true
    }
    mutating func activity(at now: Double) { lastActivity = now; showing = false }
    mutating func keyChanged(from old: String?, to new: String) {
        if let old, old != new, let v = overrides.removeValue(forKey: old) { overrides[new] = v }
        if visible == old || visible == nil { visible = new }
    }
    /// [T-keep-awake-sticky-off] Changing chats keeps every chat's saved choice.
    mutating func selectionChanged(to k: String?) { visible = k }
}

print("▶️  1. switch: override ?? Keep Screen Awake")
do {
    var m = Model(); m.visible = "A"
    check("both off → off", !m.effective("A"))
    m.global = true
    check("Keep Screen Awake on → on", m.effective("A"))
    m.overrides["A"] = false
    check("… menu off for this chat beats the global on", !m.effective("A"))
    m.global = false; m.overrides["A"] = true
    check("… menu on for this chat with the global off", m.effective("A"))
    check("another chat follows the global", !m.effective("B"))
    check("no chat on screen → off", !m.effective(nil))
}

print("\n▶️  2. lease: held from the START of the task, not after 30 s")
do {
    var m = Model(global: true, visible: "A")
    m.refresh()
    check("nothing running → no lease", !m.lease)
    m.active = ["A"]; m.refresh()
    check("task starts → lease at once (Auto-Lock can be 30 s)", m.lease && !m.showing)
    m.active = ["B"]; m.refresh()
    check("only another chat running → no lease (visible chat only)", !m.lease)
    m.active = ["A"]
    for (name, mutate) in [("background", { (x: inout Model) in x.background = true }),
                           ("app lock", { (x: inout Model) in x.locked = true }),
                           ("VoiceOver", { (x: inout Model) in x.voiceOver = true }),
                           ("iOS app on Mac", { (x: inout Model) in x.onMac = true })] {
        var n = m; mutate(&n); n.refresh()
        check("\(name) → no lease", !n.lease)
    }
    var d = Model(global: true, visible: "draft-1", active: ["real-1"], aliases: ["draft-1": "real-1"])
    d.refresh()
    check("a draft whose real session runs counts as running", d.lease)
}

print("\n▶️  3. black screen after 30 s idle; activity or task end hides it")
do {
    var m = Model(global: true, visible: "A", active: ["A"]); m.refresh()
    m.fire(at: 29)
    check("29 s → not yet", !m.showing)
    m.fire(at: 30)
    check("30 s → showing", m.showing)
    m.activity(at: 40)
    check("a tap hides it", !m.showing)
    m.fire(at: 60)
    check("…and restarts the 30 s", !m.showing)
    m.fire(at: 70)
    check("30 s after the tap → showing again", m.showing)
    m.active = []; m.refresh()
    check("task ends → hidden and the lease released", !m.showing && !m.lease)
}
do {
    var m = Model(global: true, visible: "A", active: ["A"]); m.refresh()
    m.blocker = "alert"; m.fire(at: 30)
    check("an alert on screen → not shown", !m.showing)
    check("…retried a full delay later, not polled", m.lastActivity == 30)
    m.blocker = nil; m.fire(at: 45)
    check("still inside the new delay", !m.showing)
    m.fire(at: 60)
    check("shown once the alert is gone and 30 s passed", m.showing)
    var r = Model(global: true, visible: "A", active: ["A"]); r.refresh(); r.appActive = false
    r.fire(at: 31)
    check("not while resigned active (Control Center, call)", !r.showing)
}

print("\n▶️  4. per-chat override")
do {
    var m = Model(visible: "draft-1"); m.overrides["draft-1"] = true
    m.keyChanged(from: "draft-1", to: "real-1")
    check("first send: override follows draft → real id", m.overrides == ["real-1": true] && m.visible == "real-1")
    m.overrides["other"] = false
    m.selectionChanged(to: "real-1")
    check("selection moved: every chat keeps its choice", m.overrides == ["real-1": true, "other": false])
    m.selectionChanged(to: nil)
    check("back to the list: still kept", m.overrides == ["real-1": true, "other": false])
}
print("\n▶️  4b. [T-keep-awake-sticky-off] a chat switched off stays off")
do {
    // The report: Keep Screen Awake on in Settings, "This Chat" off, and the
    // switch comes back on by itself.
    var m = Model(global: true, visible: "A"); m.overrides["A"] = false
    m.selectionChanged(to: "B")
    check("left for another chat: B follows Settings", m.effective("B"))
    m.selectionChanged(to: "A")
    check("…back in A: still off (was dropped on leaving before)", !m.effective("A"))
    m.selectionChanged(to: nil); m.selectionChanged(to: "A")
    check("…via the list: still off", !m.effective("A"))
    var d = Model(global: true, visible: "draft-1", aliases: ["draft-1": "real-1"])
    d.overrides["real-1"] = false
    check("override saved under the real id is found from the draft id (iPad selection)", !d.effective("draft-1"))
    var r = Model(global: true, visible: "real-1", aliases: ["draft-1": "real-1"])
    r.overrides["draft-1"] = false
    check("…and under the draft id from the real id", !r.effective("real-1"))
}

// MARK: - Sources

let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String {
    (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let ctl = read("Agent/Chat/AlwaysOnController.swift")
let mon = read("Agent/Chat/UserActivityMonitor.swift")
let chat = chatViewSource()
let app = read("MinisApp.swift")
let pbx = read("Minis.xcodeproj/project.pbxproj")

print("\n▶️  5. activity monitoring never interferes with gestures")
check("never cancels or delays touches",
      mon.contains("cancelsTouchesInView = false") && mon.contains("delaysTouchesBegan = false") && mon.contains("delaysTouchesEnded = false"))
check("recognizes simultaneously with every recognizer", mon.contains("shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {\n        true"))
check("never recognizes (fails when touches end)", mon.contains("state = .failed") && !mon.contains("state = .recognized") && !mon.contains("state = .began"))
check("the overlay window is not watched", mon.contains("guard !(window is AlwaysOnExcludedWindow)"))
check("typing counts (the keyboard is another process)",
      mon.contains("UITextView.textDidChangeNotification") && mon.contains("UIResponder.keyboardWillChangeFrameNotification"))

print("\n▶️  6. lifecycle and wiring")
check("global switch is Keep Screen Awake's key (no new setting)",
      ctl.contains("UserDefaults.standard.bool(forKey: KeepScreenAwakeController.userDefaultsKey)"))
check("switch rule is override ?? global", ctl.contains("return override(for: key) ?? Self.globalEnabled"))
check("[T-keep-awake-sticky-off] overrides are saved and loaded",
      ctl.contains("didSet { Self.saveOverrides(sessionOverrides) }") && ctl.contains("sessionOverrides = Self.loadOverrides()")
      && ctl.contains("static let sessionOverridesKey = \"alwaysOn.sessionOverrides\""))
check("[T-keep-awake-sticky-off] changing chats does not drop overrides",
      !ctl.contains("func clearSessionOverrides") && !ctl.contains("sessionOverrides = kept"))
check("[T-keep-awake-sticky-off] \"This Chat\" off ends Screen Saver Now for it",
      ctl.contains("if !on, isScreenSaverNow(key) { clearScreenSaverNow(reason: \"this chat off\") }"))
check("holds its own lease, from refresh()", ctl.contains("IdleTimerLease.set(.alwaysOn, held: armed, reason: reason)"))
check("background: synchronous release", ctl.contains("c.appInBackground = true\n                c.refresh(reason: \"background\")"))
check("becoming active: deferred off the notification",
      ctl.contains("Task { @MainActor in\n                await Task.yield()\n                let c = AlwaysOnController.shared\n                c.appActive = true"))
check("resign active: timer cleared so it can be rescheduled",
      ctl.contains("c.idleTask?.cancel()\n                c.idleTask = nil"))
check("didChangeNotification does not restart a pending timer", ctl.contains("if !isShowing, idleTask == nil { scheduleIdle() }"))
check("blockers: dictation and in-app alerts",
      ctl.contains("SpeechRecognitionManager.shared.state == .recording") && ctl.contains("if current is UIAlertController { return true }"))
check("an alert appearing under the overlay hides it (1 Hz tick)", ctl.contains("// An alert appeared under the overlay: get out of its way."))
check("AIChatView reports appear / disappear / draft→real",
      chat.contains("AlwaysOnController.shared.chatAppeared(key: vm.sessionId ?? vm.draftId)")
      && chat.contains("AlwaysOnController.shared.chatDisappeared(key: vm.sessionId ?? vm.draftId)")
      && chat.contains("AlwaysOnController.shared.chatKeyChanged(from: vm.draftId, to: newId)"))
check("started at launch with Keep Screen Awake",
      app.contains("KeepScreenAwakeController.shared.start()\n            // [T-always-on]") && app.contains("AlwaysOnController.shared.start()"))
check("new files are in the app target",
      pbx.contains("E5AON0001 /* AlwaysOnController.swift in Sources */,") && pbx.contains("E5UAM0001 /* UserActivityMonitor.swift in Sources */,"))

// MARK: - [4] Overlay: drift, elapsed, window

import CoreGraphics
/// Verbatim port of AlwaysOnDrift.next (checked against the source below).
enum Drift {
    static let radiusFraction: CGFloat = 0.15
    static let minStepFraction: CGFloat = 0.4
    static func next(from current: CGSize, bounds: CGSize, content: CGSize,
                     random: () -> CGFloat = { CGFloat.random(in: 0...1) }) -> CGSize {
        let R = min(bounds.width, bounds.height) * radiusFraction
        guard R > 0 else { return .zero }
        let maxX = max(0, (bounds.width - content.width) / 2)
        let maxY = max(0, (bounds.height - content.height) / 2)
        func clamp(_ p: CGSize) -> CGSize {
            CGSize(width: min(max(p.width, -maxX), maxX), height: min(max(p.height, -maxY), maxY))
        }
        func farEnough(_ p: CGSize) -> Bool {
            hypot(p.width - current.width, p.height - current.height) >= minStepFraction * R
        }
        // Judge the distance after clamping: near a narrow edge the clamp can
        // pull a candidate back next to where the content already is.
        for _ in 0..<8 {
            let theta = random() * 2 * .pi
            let r = R * random().squareRoot()
            let candidate = clamp(CGSize(width: r * cos(theta), height: r * sin(theta)))
            if farEnough(candidate) { return candidate }
        }
        // No luck: the point R away on the opposite side of the centre.
        let len = hypot(current.width, current.height)
        let dir = len > 0.001 ? CGSize(width: -current.width / len, height: -current.height / len) : CGSize(width: 1, height: 0)
        return clamp(CGSize(width: dir.width * R, height: dir.height * R))
    }
}

print("\n▶️  7. drift (every 15 s, near the centre, a real move, never off screen)")
let overlay = read("Views/Chat/AlwaysOnOverlay.swift")
func squash(_ x: String) -> String { x.filter { !$0.isWhitespace } }
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
func body(_ src: String) -> String {
    guard let a = src.range(of: "static func next(from current: CGSize"),
          let b = src.range(of: "return clamp(CGSize(width: dir.width * R, height: dir.height * R))", range: a.upperBound..<src.endIndex) else { return "" }
    return squash(String(src[a.lowerBound..<b.upperBound]))
}
check("port of AlwaysOnDrift.next is verbatim", !body(overlay).isEmpty && body(overlay) == body(me))
check("constants match (R = 15% of the shorter side, step ≥ 0.4·R, every 15 s)",
      overlay.contains("static let radiusFraction: CGFloat = 0.15") && overlay.contains("static let minStepFraction: CGFloat = 0.4")
      && overlay.contains("static let interval = 15"))
do {
    let screen = CGSize(width: 390, height: 844), block = CGSize(width: 300, height: 220)
    let R = min(screen.width, screen.height) * Drift.radiusFraction
    var cur = CGSize.zero, within = true, moved = true, inside = true
    var gen = SystemRandomNumberGenerator()
    for _ in 0..<2000 {
        let n = Drift.next(from: cur, bounds: screen, content: block) { CGFloat.random(in: 0...1, using: &gen) }
        if hypot(n.width, n.height) > R + 0.001 { within = false }
        if hypot(n.width - cur.width, n.height - cur.height) < Drift.minStepFraction * R - 0.001 { moved = false }
        if abs(n.width) > (screen.width - block.width) / 2 + 0.001 || abs(n.height) > (screen.height - block.height) / 2 + 0.001 { inside = false }
        cur = n
    }
    check("2000 moves: always within R of the centre", within)
    check("…each at least 0.4·R from the last (no jitter in place)", moved)
    check("…and the block never leaves the screen", inside)
    let tight = Drift.next(from: .zero, bounds: CGSize(width: 320, height: 240), content: CGSize(width: 320, height: 240))
    check("content as big as the screen → clamped to the centre", tight == .zero)
    check("zero-size bounds → centre, no crash", Drift.next(from: .zero, bounds: .zero, content: .zero) == .zero)
}

print("\n▶️  8. overlay window and view (source guards)")
check("own window above the app, alerts and sheets", overlay.contains("w.windowLevel = .alert + 1"))
check("never becomes key (first responder underneath untouched)", overlay.contains("w.isHidden = false") && !overlay.contains("makeKeyAndVisible") && !overlay.contains("makeKey()"))
check("the overlay window is excluded from activity monitoring", overlay.contains("final class AlwaysOnWindow: UIWindow, AlwaysOnExcludedWindow {}"))
check("status bar and home indicator hidden (fixed white shapes burn in)",
      overlay.contains("override var prefersStatusBarHidden: Bool { true }") && overlay.contains("override var prefersHomeIndicatorAutoHidden: Bool { true }")
      && overlay.contains(".persistentSystemOverlays(.hidden)"))
check("Q3: the keyboard is put away first", overlay.contains("UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)"))
check("any touch closes it and restarts the 30 s", overlay.contains(".gesture(DragGesture(minimumDistance: 0).onChanged { _ in onTouch() })")
      && overlay.contains("AlwaysOnController.shared.userActivity()   // hides the overlay"))
check("Q5: drift animates as a 1.5 s ease-in-out slide", overlay.contains(".animation(.easeInOut(duration: 1.5), value: offset)"))
check("no SwiftUI Timer.publish (graph-bound timer UAF); 1 Hz comes from the controller",
      !overlay.contains("Timer.publish") && ctl.contains("RunLoop.main.add(timer, forMode: .common)") && ctl.contains("tick += 1"))
check("pure black ground", overlay.contains("Color.black.ignoresSafeArea()") && overlay.contains("w.backgroundColor = .black"))
check("no pulse under Reduce Motion or Low Power Mode", overlay.contains("reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled"))
check("model writing text reads as Replying…, no title as Working…",
      overlay.contains("if s.toolName == \"text\" { return AppLocalized(\"Replying…\") }") && overlay.contains("AppLocalized(\"Working…\")"))
check("titles hold ≥ 2 s (no flicker)", ctl.contains("static let minTitleDuration: TimeInterval = 2"))
check("the presenter follows isShowing", overlay.contains("AlwaysOnController.shared.$isShowing") && ctl.contains("AlwaysOnWindowPresenter.shared.start()"))
check("overlay file is in the app target", pbx.contains("E5AOV0001 /* AlwaysOnOverlay.swift in Sources */,"))

/// Port of AlwaysOnOverlayView.elapsed.
func elapsed(_ since: Date, now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(since)))
    let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}
let t0 = Date(timeIntervalSince1970: 0)
check("elapsed: 03:12 / 1:02:03 / never negative",
      elapsed(t0, now: t0 + 192) == "03:12" && elapsed(t0, now: t0 + 3723) == "1:02:03" && elapsed(t0 + 5, now: t0) == "00:00")
check("elapsed port matches", overlay.contains("return h > 0 ? String(format: \"%d:%02d:%02d\", h, m, sec) : String(format: \"%02d:%02d\", m, sec)"))

print("\n▶️  9. entry points: … menu, Keep Screen Awake, minis-config (merged, Q8/Q9)")
/// Port of AlwaysOnController.isOverriddenOff + KeepScreenAwakeController's count.
func overriddenOff(_ sid: String, _ o: [String: Bool], _ aliases: [String: String]) -> Bool {
    if o[sid] == false { return true }
    return o.contains { $0.value == false && aliases[$0.key] == sid }
}
do {
    let running: Set<String> = ["A", "B"]
    let count = { (o: [String: Bool], al: [String: String]) in running.filter { !overriddenOff($0, o, al) }.count }
    check("no overrides → Keep Screen Awake counts every running chat", count([:], [:]) == 2)
    check("\"This Chat\" off → that chat no longer keeps the screen on", count(["A": false], [:]) == 1)
    check("…also when set while it was a draft", count(["draft-A": false], ["draft-A": "A"]) == 1)
    check("\"This Chat\" ON is not an off", count(["A": true], [:]) == 2)
}
let content = contentViewSource()
let keep = read("Agent/Chat/ChatLifecycleSupport.swift")
let cfg = read("Shared/Config/ConfigRegistry+Builtins.swift")
let xc = read("Localizable.xcstrings")
// [T-keepawake-submenu] The two rows became one "Keep Screen On" submenu.
check("live UIKit menu: submenu row with checkmark, sets the override",
      chat.contains("UIAction(title: AppLocalized(\"Keep Screen On\"),\n                             image: UIImage(systemName: \"sun.max\"),\n                             state: key.keepAwakeEnabled ? .on : .off) { _ in\n                        coordinator.parent.setKeepAwake(!key.keepAwakeEnabled)")
      && chat.contains("sessionGroup.append(keepAwakeMenu)")
      && !chat.contains("AppLocalized(\"Keep Screen Awake (This Chat)\")"))
check("menu rebuild keys carry the state (toolbar host key, UIKit Key, SwiftUI ==)",
      chat.contains("keepAwakeEnabled: keepAwakeThisChat,\n            screenSaverNowEnabled: screenSaverNowThisChat\n        )")
      && chat.contains("        let keepAwakeEnabled: Bool\n        let screenSaverNowEnabled: Bool")
      && chat.contains("&& lhs.keepAwakeEnabled == rhs.keepAwakeEnabled") && chat.contains("diffs.append(\"keepAwakeEnabled\")"))
check("SwiftUI fallback menu mirrors the submenu", chat.contains("Label(AppLocalized(\"Keep Screen On\"), systemImage: \"sun.max\")"))
check("the call site writes a per-chat override (memory only)",
      chat.contains("AlwaysOnController.shared.setSessionOverride(on, for: key)"))
check("AIChatView follows one de-duplicated Bool, not the whole controller",
      chat.contains(".onReceive(AlwaysOnController.shared.$visibleEffective.removeDuplicates()) { keepAwakeThisChat = $0 }")
      && !chat.contains("@ObservedObject private var alwaysOn") && !chat.contains("@StateObject private var alwaysOn"))
check("leaving the chat clears overrides (split selection, stack pop)",
      content.contains("AlwaysOnController.shared.chatSelectionChanged(to: newValue)")
      && content.contains("AlwaysOnController.shared.chatSelectionChanged(to: nil)"))
check("Keep Screen Awake skips chats switched off from the menu",
      keep.contains(".filter { !AlwaysOnController.shared.isOverriddenOff($0) }.count")
      && ctl.contains("KeepScreenAwakeController.shared.refresh(reason: \"override\")"))
check("one switch plus the Screen Saver sub-setting, nothing else",
      content.contains("Screen Saver: after the chosen time without a touch, the chat on screen turns black")
      && cfg.contains("path: \"chat.alwaysOnIdleSeconds\"")
      && !cfg.contains("background.alwaysOn") && !content.contains("alwaysOnMode"))
check("the Screen Saver footer names the new menu row",
      content.contains("Use “Keep Screen On” in a chat's … menu to turn it on or off for that chat only.")
      && !content.contains("Use “Keep Screen Awake (This Chat)”"))
check("the original footer sentence is kept (its translations)",
      content.contains("Text(\"Prevent the screen from sleeping while any session is running a task. May increase battery drain.\")"))
for key in ["\"Keep Screen On\" : {", "\"Use Screen Saver\" : {", "\"Replying…\" : {", "\"Running %@\" : {", "\"Screen Saver: after the chosen time without a touch",
            "\"Screen Saver\" : {", "\"After 30 Seconds\" : {", "\"After 1 Minute\" : {", "\"After 2 Minutes\" : {",
            "\"After 5 Minutes\" : {", "\"After %d Seconds\" : {"] {
    check("string catalog has \(key.prefix(40))", xc.contains(key))
}

print("\n▶️  10. Screen Saver sub-setting: Off by default, or 30 s / 1 / 2 / 5 min [T-always-on-idle-setting]")
do {
    var m = Model(); m.global = true; m.visible = "A"; m.active = ["A"]; m.idle = nil
    m.refresh()
    check("off: the screen is still held (Keep Screen Awake keeps working)", m.lease)
    m.fire(at: 600)
    check("off: never goes black, however long idle", !m.showing)
    m.overrides["A"] = true; m.global = false; m.refresh()
    check("off + chat switched on from its … menu: still held by this lease", m.lease && !m.showing)

    var n = Model(); n.global = true; n.visible = "A"; n.active = ["A"]; n.idle = 120; n.refresh()
    n.fire(at: 60)
    check("2 min: not black at 60 s", !n.showing)
    n.fire(at: 120)
    check("2 min: black at 120 s", n.showing)
    n.idle = nil; n.refresh()
    check("turned off while black → the black screen goes at once, lease kept", !n.showing && n.lease)
}
check("the idle time is read from the setting, not a constant",
      ctl.contains("static let idleSecondsKey = \"alwaysOnIdleSeconds\"")
      && ctl.contains("return seconds > 0 ? TimeInterval(seconds) : nil")
      && !ctl.contains("static let idleDelay: TimeInterval = 30"))
check("Settings offers Off / 30 s / 1 / 2 / 5 min", ctl.contains("static let idleChoices = [0, 30, 60, 120, 300]"))
check("default Off everywhere: unset key reads 0, Settings and minis-config default 0",
      content.contains("@AppStorage(AlwaysOnController.idleSecondsKey) private var alwaysOnIdleSeconds: Int = 0")
      && cfg.contains("userDefaultsKey: AlwaysOnController.idleSecondsKey,\n            defaultValue: 0,"))
check("off still arms (lease) — only the timer and overlay are skipped",
      ctl.contains("guard let idle = visibleIdleDelay else { return }   // Screen Saver off")
      && ctl.contains("if isShowing { hide(reason: \"screen saver off\") }"))
check("a changed idle time restarts the pending timer",
      ctl.contains("if idle != scheduledDelay {"))
check("the picker only shows with Keep Screen Awake on",
      content.contains("if keepScreenAwakeDuringTasks {\n                    Picker(AppLocalized(\"Screen Saver\"), selection: $alwaysOnIdleSeconds)"))

print("\n▶️  11. step icon in front of the title [T-always-on-step-icon]")
do {
    let overlay = read("Views/Chat/AlwaysOnOverlay.swift")
    let la = read("Agent/Background/AgentLiveActivityManager.swift")
    check("reuses the Live Activity tool → SF Symbol table, no second table",
          overlay.contains("AgentLiveActivityManager.sfSymbol(forTool: controller.snapshot.toolName)")
          && !overlay.contains("case \"shell_execute\"") && la.contains("static func sfSymbol(forTool toolName: String) -> String {"))
    check("that table covers shell, browser, text and has a generic fallback",
          la.contains("case \"shell\", \"shell_execute\":          return \"terminal\"")
          && la.contains("case \"browser\", \"browser_use\":          return \"globe\"")
          && la.contains("case \"text\":                            return \"bubble.left\"")
          && la.contains("default:                                return \"ellipsis.circle\""))
    check("left of the title, first-baseline aligned, dimmer than the title, not read aloud",
          overlay.contains("HStack(alignment: .firstTextBaseline, spacing: 8) {\n                Image(systemName: stepIcon)")
          && overlay.contains(".foregroundStyle(dim.opacity(0.4))\n                    .accessibilityHidden(true)"))
    check("no animation of its own (redrawn with the 1 Hz snapshot)",
          !overlay.contains("symbolEffect") && !overlay.contains(".animation(.default, value: stepIcon)"))
}

print("\n▶️  12. \"Use Screen Saver\" (… menu → Keep Screen On): any time, until off or leaving [T-always-on-now, T-keepawake-submenu]")
/// Port of the layering: Screen Saver Now over the per-chat override and the idle setting.
struct NowModel {
    var global = false
    var overrides: [String: Bool] = [:]
    var idleSetting: Double? = nil          // Settings: Off
    var now: String?
    var active: Set<String> = []
    var visible: String? = "A"
    var showing = false
    static let forced: Double = 30
    func effective(_ k: String?) -> Bool {
        guard let k else { return false }
        if k == now { return true }
        return overrides[k] ?? global
    }
    var idle: Double? { visible != nil && visible == now ? (idleSetting ?? Self.forced) : idleSetting }
    var armed: Bool { effective(visible) && (visible.map { active.contains($0) } ?? false) }
    /// [T-keepawake-submenu] Always usable: no "a task is running" condition.
    var menuEnabled: Bool { true }
    mutating func choose(_ k: String) { now = k; if armed { showing = true } }
    /// The idle timer firing while armed (a run in progress).
    mutating func idleFired() { if armed, idle != nil { showing = true } }
    mutating func refresh() {
        if !armed || idle == nil { showing = false }
    }
    mutating func leave(to k: String?) { if now != k { now = nil }; visible = k; refresh() }
    /// [T-keep-awake-sticky-off] "This Chat" off also ends Screen Saver Now there.
    mutating func setOverride(_ on: Bool, _ k: String) { overrides[k] = on; if !on, now == k { now = nil }; refresh() }
}
do {
    // [T-keepawake-submenu] REGRESSION: the row used to be disabled (and a
    // choice ignored) whenever no task was running in the chat.
    var i = NowModel(); i.overrides["A"] = false
    check("REGRESSION: no task running → the row is usable", i.menuEnabled)
    i.choose("A")
    check("…choosing it takes effect for this chat", i.now == "A" && i.effective("A"))
    check("…but no black screen with nothing running", !i.showing)
    i.active = ["A"]; i.refresh(); i.idleFired()
    check("…a task then starts: the idle timer turns it black", i.showing)
    i.active = []; i.refresh()
    check("…the task ends: the black screen goes, the choice stays", !i.showing && i.now == "A")

    var m = NowModel(); m.overrides["A"] = false
    m.active = ["A"]
    check("task running → usable", m.menuEnabled)
    m.choose("A")
    check("black at once, although Keep Screen Awake is off and \"This Chat\" was off", m.showing && m.effective("A"))
    check("Screen Saver Off in Settings → forced on (30 s after a tap-out)", m.idle == 30)
    m.idleSetting = 120
    check("…or Settings' own delay when it has one", m.idle == 120)
    m.active = []; m.refresh()
    check("task ends → black screen gone, the choice kept", m.now == "A" && !m.showing)
    m.setOverride(false, "A")
    check("unchecking Keep Screen On clears it; the override is off again", m.now == nil && m.effective("A") == false)

    var l = NowModel(); l.active = ["A"]; l.choose("A")
    l.leave(to: "B")
    check("leaving the chat clears it", l.now == nil && !l.showing)
    var o = NowModel(); o.active = ["A", "B"]; o.choose("A")
    check("only the chat it was chosen in", !o.effective("B"))
    // [T-keep-awake-sticky-off] The bounce: with Screen Saver Now on, unchecking
    // "This Chat" used to leave effective() true, so the checkmark came back.
    var b = NowModel(global: true); b.active = ["A"]; b.choose("A")
    b.setOverride(false, "A")
    check("\"This Chat\" off while Screen Saver Now runs → off (no bounce)", !b.effective("A") && b.now == nil && !b.showing)
}
do {
    let chatView = chatViewSource()
    check("controller: layered over, never written into, the override / setting",
          ctl.contains("@Published private(set) var screenSaverNowKey: String?")
          && ctl.contains("if isScreenSaverNow(key) { return true }\n        return override(for: key) ?? Self.globalEnabled")
          && ctl.contains("if isScreenSaverNow(visibleKey) { return Self.idleDelay ?? Self.forcedIdleDelay }")
          && !ctl.contains("sessionOverrides[key] = true // screen saver now"))
    check("NOT cleared when the task ends; cleared on leaving (chatSelectionChanged)",
          !ctl.contains("if let now = screenSaverNowKey, !SessionActivityTracker.shared.isActive(now) {")
          && !ctl.contains("reason=task ended")
          && ctl.contains("clearScreenSaverNow(reason: \"left chat\")"))
    check("REGRESSION: choosing it no longer requires a running task",
          !ctl.contains("guard SessionActivityTracker.shared.isActive(key) else {")
          && !ctl.contains("screen saver now ignored"))
    check("during a run: black right after the menu's touch (showNow is a no-op when not armed)",
          ctl.contains("try? await Task.sleep(nanoseconds: 400_000_000)") && ctl.contains("c.showNow()")
          && ctl.contains("guard isArmed, appActive, !isShowing else { return }"))
    check("Keep Screen Awake does not treat it as switched off", ctl.contains("if isScreenSaverNow(sessionId) { return false }"))
    check("draft → session id carries it over", ctl.contains("if let old, old != new, screenSaverNowKey == old { screenSaverNowKey = new }"))
    check("UIKit submenu row: checkmark, never disabled, toggles",
          chatView.contains("UIAction(title: AppLocalized(\"Use Screen Saver\"),\n                             image: UIImage(systemName: \"moon.stars\"),\n                             state: key.screenSaverNowEnabled ? .on : .off) { _ in\n                        coordinator.parent.setScreenSaverNow(!key.screenSaverNowEnabled)")
          && !chatView.contains(".disabled(!screenSaverNow") && !chatView.contains("key.screenSaverNowEnabled) ? [] : .disabled"))
    check("no availability flag left anywhere (UIKit, SwiftUI, toolbar key)",
          !chatView.contains("screenSaverNowAvailable") && !chatView.contains("runningThisChat")
          && !ctl.contains("visibleRunning"))
    check("the submenu shows a filled icon (+ \"On\" subtitle in UIKit) while either switch is on",
          chatView.contains("let keepAwakeOn = key.keepAwakeEnabled || key.screenSaverNowEnabled")
          && chatView.contains("image: UIImage(systemName: keepAwakeOn ? \"sun.max.fill\" : \"sun.max\")")
          && chatView.contains("if keepAwakeOn { keepAwakeMenu.subtitle = AppLocalized(\"On\") }")
          && chatView.contains("systemImage: keepAwakeEnabled || screenSaverNowEnabled ? \"sun.max.fill\" : \"sun.max\")"))
    check("SwiftUI fallback mirrors the submenu", chatView.contains("Label(AppLocalized(\"Use Screen Saver\"), systemImage: \"moon.stars\")")
          && chatView.contains("Menu {\n                    Toggle(isOn: Binding(\n                        get: { keepAwakeEnabled },"))
    check("menu rebuild keys carry the checkmark (toolbar host, UIKit Key, SwiftUI ==)",
          chatView.contains("diffs.append(\"screenSaverNowEnabled\")")
          && chatView.contains("        let keepAwakeEnabled: Bool\n        let screenSaverNowEnabled: Bool\n    }")
          && chatView.contains("&& lhs.screenSaverNowEnabled == rhs.screenSaverNowEnabled"))
    check("fed by a de-duplicated Bool, not by observing the controller",
          chatView.contains(".onReceive(AlwaysOnController.shared.$visibleScreenSaverNow.removeDuplicates()) { screenSaverNowThisChat = $0 }"))
    let strings = ((try? JSONSerialization.jsonObject(with: Data(xc.utf8))) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
    let allLocales = Set(((strings["Keep Screen Awake"] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]).keys)
    for (key, zh) in [("Keep Screen On", "保持屏幕常亮"), ("Use Screen Saver", "开启屏幕保护")] {
        let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        let hans = ((locs["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        check("string catalog: \(key) → \(zh), every language the app ships (\(locs.count)/\(allLocales.count))",
              hans == zh && allLocales.count >= 18 && allLocales.isSubset(of: Set(locs.keys)))
    }
}

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
