#!/usr/bin/env swift
// [T-mac-dock-badge] On a Mac (iPad app), the Dock badge showed the running
// task count and vanished when the task ended.
//
// Two causes:
//   - an iPad app on a Mac stays `.active` while another app is frontmost, so
//     "task finished while you were away" never fired: no notification, no +1;
//   - the badge was SET to the running count by one path and INCREMENTED by
//     notifications on another, so the next refresh wiped the increments.
//
// 1. compiles the shipping UserAttention / AppBadge block and checks it;
// 2. pins the wiring: one ledger for every badge writer, "away" from
//    userIsAway, Mac frontmost from the AppKit notifications, clear on return.
//
// Run: swift MacDockBadgeTests.swift   (needs swiftc)
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
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let bka = source("Agent/Background/BackgroundKeepAliveManager.swift")
guard let b = bka.range(of: "// [T-mac-dock-badge] BEGIN user-attention-badge"),
      let e = bka.range(of: "// [T-mac-dock-badge] END user-attention-badge") else {
    print("❌ block not found"); exit(1)
}
let block = String(bka[b.lowerBound..<e.upperBound])

// UIApplication.State stand-in: the block only reads the type and `.active`.
let stubs = """
import Foundation
enum UIApplication { enum State { case active, inactive, background } }
"""

let tests = #"""
var fails = 0
func expect(_ label: String, _ cond: Bool) { print(cond ? "RESULT pass \(label)" : "RESULT fail \(label)"); if !cond { fails += 1 } }

// Away
expect("iPhone, app in front: not away", !UserAttention.isAway(appState: .active, onMac: false, macAppIsFrontmost: false))
expect("iPhone, backgrounded: away", UserAttention.isAway(appState: .background, onMac: false, macAppIsFrontmost: true))
expect("iPhone, inactive (switcher / lock): away, as before", UserAttention.isAway(appState: .inactive, onMac: false, macAppIsFrontmost: true))
expect("Mac, Minis frontmost: not away", !UserAttention.isAway(appState: .active, onMac: true, macAppIsFrontmost: true))
expect("Mac, another app in front while UIKit still says .active: away",
       UserAttention.isAway(appState: .active, onMac: true, macAppIsFrontmost: false))
expect("Mac, hidden / minimised: away", UserAttention.isAway(appState: .background, onMac: true, macAppIsFrontmost: true))
expect("the AppKit names are the app-level activate/resign ones",
       UserAttention.macDidBecomeActive.rawValue == "NSApplicationDidBecomeActiveNotification"
       && UserAttention.macDidResignActive.rawValue == "NSApplicationDidResignActiveNotification")

// Badge
expect("running only", AppBadge.total(runningSessions: 2, notificationsEnabled: true, unseenNotifications: 0) == 2)
expect("the reported case: the task ends while away -> 0 running + 1 unseen = 1, not 0",
       AppBadge.total(runningSessions: 0, notificationsEnabled: true, unseenNotifications: 1) == 1)
expect("one of two tasks ends while away -> 1 running + 1 unseen = 2",
       AppBadge.total(runningSessions: 1, notificationsEnabled: true, unseenNotifications: 1) == 2)
expect("two finished while away keep counting (no refresh overwrites them)",
       AppBadge.total(runningSessions: 0, notificationsEnabled: true, unseenNotifications: 2) == 2)
expect("back in the app: unseen cleared, running count stays",
       AppBadge.total(runningSessions: 1, notificationsEnabled: true, unseenNotifications: 0) == 1)
expect("notifications off: running tasks not counted",
       AppBadge.total(runningSessions: 3, notificationsEnabled: false, unseenNotifications: 0) == 0)
expect("…but a notification that was posted anyway still counts",
       AppBadge.total(runningSessions: 3, notificationsEnabled: false, unseenNotifications: 1) == 1)
expect("a bad stored value never goes negative",
       AppBadge.total(runningSessions: 1, notificationsEnabled: true, unseenNotifications: -4) == 1)
if fails > 0 { print("RESULT fail \(fails) check(s)") }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mac-dock-badge-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try stubs.write(to: tmp.appendingPathComponent("stubs.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\n" + block).write(to: tmp.appendingPathComponent("block.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\n" + tests).write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t")

print("1. Away + badge math (shipping block)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + ["stubs.swift", "block.swift", "main.swift"]
                        .map { tmp.appendingPathComponent($0).path } + ["-o", bin.path])
check("block + tests compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (_, out) = run(bin.path, [])
for line in out.split(separator: "\n") where line.hasPrefix("RESULT") {
    check(String(line.dropFirst(12)), line.hasPrefix("RESULT pass"))
}

print("\n2. Wiring")
let bgTask = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
let app = source("MinisApp.swift")
let gate = source("Shared/Config/Confirm/ConfigConfirmationGate.swift")
let shortcut = source("Agent/Intents/SendPromptIntent.swift")
let badgeWriters = [("BackgroundKeepAliveManager", bka), ("ConfigConfirmationGate", gate), ("SendPromptIntent", shortcut), ("MinisApp", app)]
check("no badge writer does \"icon + 1\" any more",
      badgeWriters.allSatisfy { !$0.1.contains("applicationIconBadgeNumber") })
check("the only setBadgeCount is the ledger's refresh",
      badgeWriters.map { $0.1.components(separatedBy: "setBadgeCount(").count - 1 }.reduce(0, +) == 1
      && bka.contains("UNUserNotificationCenter.current().setBadgeCount(total)"))
check("the refresh sets running + unseen",
      bka.contains("let total = AppBadge.total(runningSessions: sessions.count, notificationsEnabled: enabled,\n                                   unseenNotifications: unseenBadgeCount)"))
check("unseen count is persisted",
      bka.contains("get { UserDefaults.standard.integer(forKey: Self.unseenBadgeKey) }"))
check("completion, config-approval and shortcut notifications all count through the ledger",
      bka.contains("content.badge = NSNumber(value: noteUnseenNotification())")
      && gate.contains("content.badge = NSNumber(value: BackgroundKeepAliveManager.shared.noteUnseenNotification())")
      && shortcut.contains("content.badge = NSNumber(value: BackgroundKeepAliveManager.shared.noteUnseenNotification())"))
check("a scheduled task's in-place update still does not count again",
      bka.contains("if isNewEntry {\n            // [T-mac-dock-badge]"))
check("task completion decides \"away\" with userIsAway, not applicationState",
      bgTask.contains("let wasBackground = BackgroundKeepAliveManager.shared.userIsAway")
      && bka.contains("let isBackground = wasBackground ?? userIsAway"))
check("userIsAway combines app state with the Mac frontmost flag",
      bka.contains("UserAttention.isAway(appState: UIApplication.shared.applicationState,\n                             onMac: ProcessInfo.processInfo.isiOSAppOnMac,\n                             macAppIsFrontmost: macAppIsFrontmost)"))
check("Mac frontmost is observed (Mac only) from setup",
      bka.contains("observeMacFrontmost()\n")
      && bka.contains("guard ProcessInfo.processInfo.isiOSAppOnMac else { return }")
      && bka.contains("(UserAttention.macDidBecomeActive, true), (UserAttention.macDidResignActive, false)"))
check("Mac: coming back to the window clears the unseen part",
      bka.contains("if frontmost { clearUnseenBadge() }"))
check("iPhone/iPad: foregrounding clears the unseen part (instead of zeroing everything)",
      app.contains("BackgroundKeepAliveManager.shared.clearUnseenBadge()")
      && !app.contains("setBadgeCount(0)"))

let askCenter = source("Agent/Chat/UserAskCenter.swift")
check("user_ask notifications post when away (incl. a Mac with another app in front)",
      askCenter.contains("if BackgroundKeepAliveManager.shared.userIsAway { postNotification(for: r.ask) }")
      && askCenter.components(separatedBy: "if BackgroundKeepAliveManager.shared.userIsAway { postNotification(for: ask, sound: false) }").count == 3
      && !askCenter.contains("applicationState != .active"))
check("…and are presented on a Mac when away, hidden when the card is on screen",
      shortcut.contains("let away = MainActor.assumeIsolated { BackgroundKeepAliveManager.shared.userIsAway }\n                completionHandler(away ? [.banner, .sound] : [])")
      && shortcut.contains("DispatchQueue.main.async {\n                let away"))
check("config-approval notification gates on userIsAway",
      gate.contains("guard BackgroundKeepAliveManager.shared.userIsAway else { return }")
      && !gate.contains("applicationState != .active"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
