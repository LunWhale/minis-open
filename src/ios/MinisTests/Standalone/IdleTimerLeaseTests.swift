// Tests for [T-idle-timer-lease]: UIApplication.isIdleTimerDisabled has one
// writer, IdleTimerLease, and each feature holds its own lease.
//
// Before: Keep Screen Awake, the backup's screen-awake, the iCloud migration
// sheet and the DEBUG menu each wrote the flag directly, so:
//   - the migration sheet wrote false when it had no work, turning off a lock
//     Keep Screen Awake held during a chat task;
//   - the end of a backup cleared the flag if it was on for ANY reason
//     (BackupRunController checked BackupScreenAwake.isEnabled, which read the
//     system flag);
//   - the backup toggle showed ON while a chat task held the flag.
//
// Standalone: `swift IdleTimerLeaseTests.swift`.

import Foundation

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

// MARK: - Port of the lease rule

enum Owner: String { case keepScreenAwake, alwaysOn, backup, syncMigration, debugMenu }
struct Lease {
    var holders: Set<Owner> = []
    var flag = false
    mutating func set(_ o: Owner, held: Bool) {
        if held { holders.insert(o) } else { holders.remove(o) }
        flag = !holders.isEmpty
    }
    func isHeld(_ o: Owner) -> Bool { holders.contains(o) }
}
/// The old world: every writer sets the one flag.
struct Direct { var flag = false; mutating func write(_ v: Bool) { flag = v } }

print("▶️  1. owners no longer undo each other")
do {
    var old = Direct(); var new = Lease()
    old.write(true); new.set(.keepScreenAwake, held: true)       // chat task running
    old.write(false); new.set(.syncMigration, held: false)       // migration sheet: no pending push
    check("OLD: the migration sheet turned the chat task's lock off", old.flag == false)
    check("NEW: the chat task's lock stays on", new.flag)
}
do {
    var old = Direct(); var new = Lease()
    old.write(true); new.set(.keepScreenAwake, held: true)       // chat task running
    // backup ends: `if BackupScreenAwake.isEnabled { set(false) }`
    let oldBackupOn = old.flag
    if oldBackupOn { old.write(false) }
    if new.isHeld(.backup) { new.set(.backup, held: false) }
    check("OLD: the backup looked ON (it read the system flag)", oldBackupOn)
    check("OLD: ending the backup cleared the chat task's lock", old.flag == false)
    check("NEW: the backup was never on, the lock stays", !new.isHeld(.backup) && new.flag)
}
do {
    var l = Lease()
    l.set(.backup, held: true); l.set(.keepScreenAwake, held: true)
    l.set(.backup, held: false)
    check("flag stays on while any owner holds it", l.flag)
    l.set(.keepScreenAwake, held: false)
    check("flag goes off when the last owner releases", !l.flag)
    l.set(.debugMenu, held: false)
    check("releasing an owner that holds nothing is a no-op", !l.flag && l.holders.isEmpty)
    l.set(.alwaysOn, held: true); l.set(.alwaysOn, held: true)
    l.set(.alwaysOn, held: false)
    check("acquire is idempotent (no counting per owner)", !l.flag)
}

// MARK: - Sources

let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String {
    (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let lease = read("Agent/Chat/IdleTimerLease.swift")
let keep = read("Agent/Chat/ChatLifecycleSupport.swift")
let backup = read("Agent/Backup/BackupKeepAlive.swift")
let migration = read("Views/Sync/SyncMigrationDetailView.swift")
let content = contentViewSource()
let pbx = read("Minis.xcodeproj/project.pbxproj")

print("\n▶️  2. sources")
check("sources found", !lease.isEmpty && !keep.isEmpty && !backup.isEmpty && !migration.isEmpty && !content.isEmpty)
// Every direct write in the app, outside the lease itself.
let fm = FileManager.default
var writers: [String] = []
if let e = fm.enumerator(at: ios, includingPropertiesForKeys: nil) {
    for case let u as URL in e where u.pathExtension == "swift" && !u.path.contains("/MinisTests/") && !u.path.contains("/build/") {
        let text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        if text.range(of: #"isIdleTimerDisabled\s*=[^=]"#, options: .regularExpression) != nil,
           u.lastPathComponent != "IdleTimerLease.swift" {
            writers.append(u.lastPathComponent)
        }
    }
}
check("only IdleTimerLease writes isIdleTimerDisabled (found: \(writers))", writers.isEmpty)
check("the lease writes the flag from the holder set",
      lease.contains("let want = !holders.isEmpty") && lease.contains("UIApplication.shared.isIdleTimerDisabled = want"))
check("the lease compares with the live system value (corrects a system reset)",
      lease.contains("guard UIApplication.shared.isIdleTimerDisabled != want else { return }"))
check("Keep Screen Awake holds its own lease",
      keep.contains("IdleTimerLease.set(.keepScreenAwake, held: shouldHoldLock, reason: reason)"))
check("leases are re-applied on foreground, in the deferred path",
      keep.contains("if !background { IdleTimerLease.reapply() }")
      && keep.contains("await Task.yield()\n                KeepScreenAwakeController.shared.onScenePhaseChanged(background: false)"))
check("backup: isEnabled is its own lease, set() holds it",
      backup.contains("static var isEnabled: Bool { IdleTimerLease.isHeld(.backup) }")
      && backup.contains("IdleTimerLease.set(.backup, held: on, reason: \"backup\")"))
check("migration sheet holds its own lease", migration.contains("IdleTimerLease.set(.syncMigration, held: disabled, reason: \"migration\")"))
check("DEBUG menu holds its own lease (toggle and foreground)",
      content.components(separatedBy: "IdleTimerLease.set(.debugMenu, held: keepScreenAwake").count - 1 == 2)
check("IdleTimerLease.swift is in the app target",
      pbx.contains("E5ITL0001 /* IdleTimerLease.swift in Sources */,") && pbx.contains("path = IdleTimerLease.swift;"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
