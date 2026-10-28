#!/usr/bin/env swift
// [T-share-link-anchor-crash] Crash 2026-10-02 09:17 (iPhone 17 Pro, iOS 27.0, 1.15(1)):
// EXC_BREAKPOINT on the main thread in SwiftUI
//   SharingActivityPickerBridge.popoverSource(for:)
//   <- PopoverPresentationDelegate.updateAnchor(_:presentationController:)
//   <- SharingActivityPickerBridge.updateAnchor(deferred:)
// right after the app went to the background with the share preview's system share
// sheet up. The preview's ShareLink existed only while the CURRENT options had a
// finished render; going to the background, iOS re-renders the app in the other
// appearance for its snapshot, the preview followed that flip (dark = app appearance),
// its key changed, the ShareLink - the share sheet's popover anchor - left the
// hierarchy, and SwiftUI trapped re-anchoring the sheet. The log shows the flip as a
// background "[ChatExport] start format=image ... dark=true" right before the crash.
//
// 1. compiles the shipping ChatShareModel block and checks ChatShareLinkTarget /
//    ChatShareAppearance, replaying the crash sequence;
// 2. pins the preview's wiring in ChatShareSelectionView.swift.
//
// Run: swift ChatShareLinkAnchorTests.swift   (needs swiftc)
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

let model = source("Views/Chat/ChatShareModel.swift")
guard let b = model.range(of: "// [T-multi-select-share] BEGIN chat-share-model"),
      let e = model.range(of: "// [T-multi-select-share] END chat-share-model") else {
    print("❌ model block not found"); exit(1)
}
let block = String(model[b.lowerBound..<e.upperBound])

let tests = #"""
var fails = 0
func expect(_ label: String, _ cond: Bool) { print(cond ? "RESULT pass \(label)" : "RESULT fail \(label)"); if !cond { fails += 1 } }
let light = URL(fileURLWithPath: "/tmp/light.png"), dark = URL(fileURLWithPath: "/tmp/dark.png")

// ShareLinkTarget
expect("nothing rendered yet: no ShareLink", ChatShareLinkTarget.resolve(current: nil, last: nil) == nil)
expect("current render: offered and enabled",
       ChatShareLinkTarget.resolve(current: light, last: nil).map { $0.url == light && $0.enabled } == true)
expect("current render wins over the last one",
       ChatShareLinkTarget.resolve(current: dark, last: light).map { $0.url == dark && $0.enabled } == true)
expect("new options still rendering: ShareLink stays, disabled, on the last file",
       ChatShareLinkTarget.resolve(current: nil, last: light).map { $0.url == light && !$0.enabled } == true)

// Appearance followed by the preview
expect("first evaluation takes the app's appearance even when not active",
       ChatShareAppearance.followed(previous: nil, appDark: true, sceneActive: false) == true)
expect("active: follows the app",
       ChatShareAppearance.followed(previous: false, appDark: true, sceneActive: true) == true)
expect("not active (background snapshot): keeps what it had",
       ChatShareAppearance.followed(previous: false, appDark: true, sceneActive: false) == false)

// Replay of the crash: light app, render done, share sheet up, app backgrounds,
// iOS snapshots in dark, app comes back.
do {
    var followed: Bool? = nil
    var rendered: [Bool: URL] = [:]           // dark -> file, standing in for RenderKey
    var last: URL? = nil
    func key() -> Bool { followed ?? false }
    followed = ChatShareAppearance.followed(previous: followed, appDark: false, sceneActive: true)
    rendered[key()] = light; last = light
    let anchor = ChatShareLinkTarget.resolve(current: rendered[key()], last: last)
    expect("before backgrounding: ShareLink offers the light render", anchor?.url == light && anchor?.enabled == true)
    // Background: snapshot flips the trait to dark, then back.
    followed = ChatShareAppearance.followed(previous: followed, appDark: true, sceneActive: false)
    expect("snapshot flip does not change the render key", key() == false)
    expect("…so the ShareLink is untouched behind the share sheet",
           ChatShareLinkTarget.resolve(current: rendered[key()], last: last)?.url == light)
    followed = ChatShareAppearance.followed(previous: followed, appDark: false, sceneActive: false)
    followed = ChatShareAppearance.followed(previous: followed, appDark: false, sceneActive: true)
    expect("back in the foreground: still light", key() == false)
    // A real appearance change while the sheet is up (e.g. automatic dark mode):
    // the key changes, but the ShareLink must not disappear.
    followed = ChatShareAppearance.followed(previous: followed, appDark: true, sceneActive: true)
    expect("a real appearance change is followed", key() == true)
    expect("…and the ShareLink stays (disabled) until the dark render exists",
           ChatShareLinkTarget.resolve(current: rendered[key()], last: last).map { $0.url == light && !$0.enabled } == true)
    rendered[key()] = dark; last = dark
    expect("…then offers the dark render",
           ChatShareLinkTarget.resolve(current: rendered[key()], last: last).map { $0.url == dark && $0.enabled } == true)
}
if fails > 0 { print("RESULT fail \(fails) model check(s)") }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chat-share-anchor-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try ("import Foundation\nimport CoreGraphics\n" + block).write(to: tmp.appendingPathComponent("model.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\nimport CoreGraphics\n" + tests).write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t")

print("1. ShareLink target and followed appearance (shipping block)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", tmp.appendingPathComponent("model.swift").path,
                                         tmp.appendingPathComponent("main.swift").path, "-o", bin.path])
check("model block + tests compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (_, out) = run(bin.path, [])
for line in out.split(separator: "\n") where line.hasPrefix("RESULT") {
    let pass = line.hasPrefix("RESULT pass")
    check(String(line.dropFirst(12)), pass)
}

print("\n2. Preview wiring (ChatShareSelectionView.swift)")
let view = source("Views/Chat/ChatShareSelectionView.swift")
check("source readable", !view.isEmpty)
check("the ShareLink is built from ChatShareLinkTarget",
      view.contains("if let target = ChatShareLinkTarget.resolve(current: rendered[key]?.url, last: lastShareURL) {")
      && view.contains("ShareLink(item: target.url)") && view.contains(".disabled(!target.enabled)"))
check("no ShareLink tied to the current render alone",
      !view.contains("if let url = rendered[key]?.url {\n                        ShareLink"))
check("a finished render becomes the last shared file",
      view.contains("rendered[key] = Rendered(url: result.url, scale: result.scale)\n            lastShareURL = result.url"))
check("the followed appearance is part of `dark`",
      view.contains("private var dark: Bool { darkChoice ?? followedDark ?? (appScheme == .dark) }"))
check("it is updated through ChatShareAppearance with the scene phase",
      view.contains("ChatShareAppearance.followed(previous: followedDark, appDark: appScheme == .dark,")
      && view.contains("sceneActive: scenePhase == .active)"))
check("…on appear, on appearance change and on scene-phase change",
      view.contains(".onAppear {\n                followAppAppearance()")
      && view.contains(".onChange(of: appScheme) { _ in followAppAppearance() }")
      && view.contains(".onChange(of: scenePhase) { _ in followAppAppearance() }"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
