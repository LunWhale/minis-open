#!/usr/bin/env swift
// [T-stop-confirm] The composer's stop button asks "Stop this task?" before
// stopping a running task, behind Settings > Appearance > Confirm Before
// Stopping (default ON). Users kept hitting it by accident one-handed and lost
// long runs.
//
//   [1] policy: confirm only from the busy stop button, setting OFF stops at
//       once, the scheduled-tasks warning still wins
//   [2] a dialog whose turn ended (even if a queued turn now runs) never stops
//   [3] source guards: the dialog lives on the composer stop button only;
//       programmatic cancels (debug RPC, New Chat's own alert) stay direct;
//       setting defaults ON in both places with one key; strings localized
//
// Run: swift StopConfirmTests.swift   (needs swiftc)
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

let button = source("Views/Chat/AIChatView/Composer/ChatSendButton.swift")
guard let block = between(button, "// BEGIN StopConfirmPolicy", "// END StopConfirmPolicy") else {
    print("❌ StopConfirmPolicy block not found"); exit(1)
}

let harness = """
import Foundation
\(block)
var fails = 0
func CHECK(_ label: String, _ ok: Bool) { print("  \\(ok ? "✅" : "❌") \\(label)"); if !ok { fails += 1 } }

print("[1] tap policy")
CHECK("setting ON: confirm first", StopConfirmPolicy.onTap(hasLiveScheduled: false, confirmEnabled: true) == .confirmStop)
CHECK("setting OFF: stop at once (old behaviour)", StopConfirmPolicy.onTap(hasLiveScheduled: false, confirmEnabled: false) == .stopNow)
CHECK("scheduled tasks: their warning wins, setting ON", StopConfirmPolicy.onTap(hasLiveScheduled: true, confirmEnabled: true) == .confirmScheduled)
CHECK("scheduled tasks: their warning stays, setting OFF", StopConfirmPolicy.onTap(hasLiveScheduled: true, confirmEnabled: false) == .confirmScheduled)
CHECK("default key", StopConfirmPolicy.settingsKey == "chat.confirmBeforeStopping")
CHECK("default OFF: stop immediately", StopConfirmPolicy.onTap(hasLiveScheduled: false, confirmEnabled: StopConfirmPolicy.defaultValue) == .stopNow)

print("[2] Stop in a stale dialog")
CHECK("same turn still running: stops", StopConfirmPolicy.confirmStillApplies(openedWhileProcessing: true, endCountAtOpen: 3, endCountNow: 3, isBusy: true))
CHECK("turn ended, nothing busy: no-op", !StopConfirmPolicy.confirmStillApplies(openedWhileProcessing: true, endCountAtOpen: 3, endCountNow: 4, isBusy: false))
CHECK("turn ended, queued turn now running: no-op", !StopConfirmPolicy.confirmStillApplies(openedWhileProcessing: true, endCountAtOpen: 3, endCountNow: 4, isBusy: true))
CHECK("opened for sub agents only, still busy: stops", StopConfirmPolicy.confirmStillApplies(openedWhileProcessing: false, endCountAtOpen: 3, endCountNow: 5, isBusy: true))
CHECK("opened for sub agents only, now idle: no-op", !StopConfirmPolicy.confirmStillApplies(openedWhileProcessing: false, endCountAtOpen: 3, endCountNow: 3, isBusy: false))
exit(fails == 0 ? 0 : 1)
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stop-confirm-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
check("policy block compiles standalone", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("policy checks all pass", status == 0 && !out.contains("❌"))
}

print("[3] source guards")
// The decision sits inside the busy stop-button branch only.
let stopBranch = between(button, "} else if isBusy && !canSend {", "// Typing while a sub agent runs") ?? ""
check("confirmation is decided inside the busy stop branch", stopBranch.contains("StopConfirmPolicy.onTap("))
check("the dialog is attached in that branch", stopBranch.contains(".alert(AppLocalized(\"Stop this task?\"), isPresented: $showStopConfirm)"))
check("dialog buttons: Stop (destructive) + Keep Running (cancel)",
      stopBranch.contains("Button(AppLocalized(\"Stop\"), role: .destructive)") && stopBranch.contains("Button(AppLocalized(\"Keep Running\"), role: .cancel) {}"))
check("dialog message", stopBranch.contains("Text(AppLocalized(\"The current reply and any running tools will be stopped.\"))"))
check("Stop re-checks the turn before stopping", stopBranch.contains("guard StopConfirmPolicy.confirmStillApplies("))
check("the queue / send branches never ask", !(between(button, "} else if vm.isProcessing && canEnqueue {", "} else if isBusy && !canSend {") ?? "x").contains("StopConfirmPolicy"))
check("busy branches stay inside body (other suites anchor there)", button.contains("    var body: some View {\n        Group {"))
check("dialog closes when its turn ends (publisher, not onChange)",
      button.contains(".onReceive(vm.$isProcessing)") && button.contains("processingEndCount &+= 1"))
check("dialog closes when the conversation goes idle", button.contains(".onChange(of: isBusy)") && button.contains("showStopConfirm = false"))
// [T-stop-mode-longpress] Default flipped to OFF (stop at once), one constant for every reader.
check("default is OFF (stop immediately)", button.contains("static let defaultValue = false"))
check("button reads the setting with the shared default",
      button.contains("@AppStorage(StopConfirmPolicy.settingsKey) private var confirmBeforeStopping: Bool = StopConfirmPolicy.defaultValue"))
check("stop button: tap through its own box, long-press = stop-mode menu",
      stopBranch.contains("stopModeMenu(primaryAction: {")
      && button.contains("stopActionBox.action = primaryAction\n        return Menu {")
      && button.contains("primaryAction: { [stopActionBox] in\n            stopActionBox.action()")
      && button.contains(".contextMenu { stopModePicker }"))
check("menu choices: Stop Immediately (false) / Confirm Before Stopping (true)",
      button.contains("AppLocalized(\"Stop Immediately\"), systemImage: \"stop.circle\").tag(false)")
      && button.contains("AppLocalized(\"Confirm Before Stopping\"), systemImage: \"questionmark.circle\").tag(true)"))
let builtins = source("Shared/Config/ConfigRegistry+Builtins.swift")
check("minis-config chat.confirmBeforeStopping, same key + default",
      builtins.contains("path: \"chat.confirmBeforeStopping\"")
      && builtins.contains("userDefaultsKey: StopConfirmPolicy.settingsKey,\n            defaultValue: StopConfirmPolicy.defaultValue"))

let settings = source("Views/Settings/AppearanceSettingsView.swift")
check("settings toggle, same key, shared default",
      settings.contains("@AppStorage(StopConfirmPolicy.settingsKey) private var confirmBeforeStopping: Bool = StopConfirmPolicy.defaultValue")
      && settings.contains("Toggle(AppLocalized(\"Confirm Before Stopping\"), isOn: $confirmBeforeStopping)"))

// Programmatic stops bypass the dialog: they call the VM directly.
let rpc = source("Debug/DebugRPCProviderChat.swift")
check("debug RPC cancel still calls stopByUser directly", rpc.contains("cachedVM?.stopByUser()") && !rpc.contains("StopConfirmPolicy"))
let chatView = source("Views/Chat/AIChatView/AIChatView.swift")
check("New Chat's Task Running alert keeps its own direct stop", chatView.contains("Button(AppLocalized(\"Stop & New Chat\"), role: .destructive) {\n                vm.stopByUser()"))
let runner = source("Agent/Jobs/HelperRunner.swift")
check("stopByUser itself has no confirmation", !runner.contains("StopConfirmPolicy") && !runner.contains("confirmBeforeStopping"))

let catalog = source("Localizable.xcstrings")
for key in ["Stop this task?", "The current reply and any running tools will be stopped.", "Keep Running", "Confirm Before Stopping",
            "Ask for confirmation when you tap the stop button while a task is running, so an accidental tap does not end a long run. Off by default. You can also long-press the stop button to switch.",
            "Stop Immediately", "Stop Button", "Stop button options"] {
    guard let entry = between(catalog, "\"\(key)\" : {", "\n    },") else { check("localized: \(key)", false); continue }
    check("localized zh-Hans + zh-Hant: \(key.prefix(40))", entry.contains("\"zh-Hans\"") && entry.contains("\"zh-Hant\""))
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
