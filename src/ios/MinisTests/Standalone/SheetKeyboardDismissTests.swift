// Tests for [T-ipad-sheet-keyboard-crash] — no interactive keyboard dismissal
// in sheet-hosted editors.
//
// Field crash, iPadOS 27.0 (iPad13,4, Minis 1.15 build 5, 2026-09-30): editing
// a model's Context Window in the Model Details sheet and dragging the sheet
// down aborted inside UIKit (NSLayoutConstraint activation under
// UIInputWindowControllerHostingItem, reached from
// -[UIKeyboardImpl presentationControllerShouldDismiss:] re-maximizing a
// MINIMIZED keyboard). `.scrollDismissesKeyboard(.interactively)` is what leaves
// the keyboard minimized mid-drag, and inside a sheet that drag is also the
// sheet's drag-to-dismiss. Source-level guard: the modifier must not come back.
//
// Standalone: `swift SheetKeyboardDismissTests.swift` from this directory.
import Foundation

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func src(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let detail = src("Views/Providers/ProviderInstanceDetailView.swift")
let group = src("Views/Providers/ModelGroupDetailView.swift")
check("sources readable", !detail.isEmpty && !group.isEmpty)

check("Model Details sheet dismisses the keyboard immediately on scroll",
      detail.contains(".scrollDismissesKeyboard(.immediately)\n            .toolbar {"))
check("Model Group detail (inside the Settings sheet) too",
      group.contains(".scrollDismissesKeyboard(.immediately)\n        .environment(\\.editMode, $editMode)"))
check("Cancel / Save end editing before the sheet goes away",
      detail.contains("Self.endEditing()\n                        dismiss()")
      && detail.contains("Self.endEditing()\n                        save()"))

// Repo-wide: no view uses interactive keyboard dismissal (every one we had sat
// in a sheet; a new one should be a deliberate, reviewed exception).
let fm = FileManager.default
var offenders: [String] = []
for dir in ["Views", "Agent", "Shared"] {
    guard let e = fm.enumerator(atPath: root + dir) else { continue }
    for case let path as String in e where path.hasSuffix(".swift") {
        if src("\(dir)/\(path)").contains(".scrollDismissesKeyboard(.interactively)") { offenders.append("\(dir)/\(path)") }
    }
}
check("no `.scrollDismissesKeyboard(.interactively)` anywhere in the app (found: \(offenders))", offenders.isEmpty)

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
