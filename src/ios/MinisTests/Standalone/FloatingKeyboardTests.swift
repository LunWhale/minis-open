// Tests for [T-ipad-floating-keyboard] — on iPad, a floating / undocked
// keyboard must not lift the chat composer by a docked keyboard's height.
//
// Compiles the real KeyboardDockRules out of ChatInputBar.swift and checks it
// against iPad keyboard geometry (screen coordinates), then greps AIChatView
// for the wiring. Standalone: `swift FloatingKeyboardTests.swift` from this
// directory.
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
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func src(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let bar = src("Views/Chat/ChatInputBar.swift")
let view = chatViewSource()
check("sources readable", !bar.isEmpty && !view.isEmpty)

guard let r = bar.range(of: "enum KeyboardDockRules {") else { print("❌ KeyboardDockRules missing"); exit(1) }
let rules = String(bar[r.lowerBound...])

let harness = "import CoreGraphics\n" + rules + #"""

func u(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ s: CGRect) -> Bool {
    KeyboardDockRules.isUndocked(keyboardFrame: CGRect(x: x, y: y, width: w, height: h), screenBounds: s)
}
let p = CGRect(x: 0, y: 0, width: 1024, height: 1366)   // iPad Pro 12.9" portrait
let l = CGRect(x: 0, y: 0, width: 1366, height: 1024)   // landscape
var out: [String] = []
out.append("docked=\(u(0, 1366 - 400, 1024, 400, p))")
out.append("dockedLandscape=\(u(0, 1024 - 420, 1366, 420, l))")
out.append("hidden=\(u(0, 1366, 1024, 400, p))")
out.append("empty=\(u(0, 0, 0, 0, p))")
out.append("floatingMid=\(u(350, 600, 320, 260, p))")
out.append("floatingBottom=\(u(350, 1366 - 260, 320, 260, p))")
out.append("split=\(u(0, 700, 1024, 300, p))")
out.append("shortcutBarCorner=\(u(700, 1366 - 55, 300, 55, p))")
out.append("shortcutBarFull=\(u(0, 1366 - 55, 1024, 55, p))")
print(out.joined(separator: " "))
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kbd-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("KeyboardDockRules compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])

print("▶️  geometry")
check("docked keyboard (full width, at the bottom) → normal avoidance", o.contains("docked=false"))
check("docked keyboard in landscape → normal avoidance", o.contains("dockedLandscape=false"))
check("hidden / off-screen keyboard → not undocked", o.contains("hidden=false") && o.contains("empty=false"))
check("floating mini keyboard mid-screen → composer stays put", o.contains("floatingMid=true"))
check("floating keyboard dragged to the bottom edge → still floating", o.contains("floatingBottom=true"))
check("split / undocked keyboard (full width, above the bottom) → composer stays put", o.contains("split=true"))
check("hardware-keyboard shortcut bar (short, at the bottom) → keeps normal avoidance",
      o.contains("shortcutBarCorner=false") && o.contains("shortcutBarFull=false"))

print("▶️  wiring (AIChatView)")
check("one .ignoresSafeArea(.keyboard) covers the voice panel AND the undocked keyboard",
      view.contains("edges: ((voiceInputActive && !voiceVM.isEditingTranscript) || keyboardUndocked) ? .bottom : []"))
check("detection is iPad-only", view.contains("guard UIDevice.current.userInterfaceIdiom == .pad,"))
check("compares against the screen (Stage Manager windows are smaller)",
      view.contains("KeyboardDockRules.isUndocked(keyboardFrame: frame, screenBounds: bounds)"))
check("no keyboardWillHide reset (iPadOS posts a hide when the keyboard undocks)",
      !view.contains("keyboardWillHideNotification)) { _ in\n            if keyboardUndocked"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
