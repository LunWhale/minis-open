// Tests for [T-tool-preview-longpress-close] — long-pressing the tool status
// bar's preview thumbnail offers to close it, and a toast says where to turn
// it back on (Settings > Appearance > Tool Status Bar > Tool Preview Window).
//
// Source checks, standalone (`swift ToolPreviewCloseTests.swift`) like its
// neighbours: the app links device-only libraries, so no XCTest bundle runs.
import Foundation

var failures = 0
func check(_ l: String, _ a: Bool, _ e: Bool = true) {
    if a == e { print("  ✅ \(l)") } else { print("  ❌ \(l) — expected \(e), got \(a)"); failures += 1 }
}

let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }

let sheet = read("Views/Chat/ToolLiveSheet.swift")
let toast = read("Views/Chat/Markdown/Support/MinisToast.swift")
let settings = read("Views/Settings/AppearanceSettingsView.swift")

let mountStart = sheet.range(of: "private func collapsedBarContent(")
let mountEnd = mountStart.flatMap { sheet.range(of: "static func closeToolPreview()", range: $0.upperBound..<sheet.endIndex) }
let mount = (mountStart != nil && mountEnd != nil) ? String(sheet[mountStart!.lowerBound..<mountEnd!.lowerBound]) : ""

check("the menu is on the thumbnail mounted in the collapsed bar",
      mount.contains("ToolPreviewThumbnail(") && mount.contains(".contextMenu {") && mount.contains("Self.closeToolPreview()"))
check("the menu offers one destructive 'Close Preview Window' item",
      mount.contains("Button(role: .destructive)") && mount.contains("AppLocalized(\"Close Preview Window\")"))
check("the lift preview keeps the tile's rounded shape",
      mount.contains(".contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8))"))
check("the menu is NOT inside ToolPreviewThumbnail (it renders itself again for a sub agent)",
      {
          guard let s = sheet.range(of: "private struct ToolPreviewThumbnail: View {") else { return false }
          let tail = sheet[s.upperBound...]
          let end = tail.range(of: "\n}\n").map { tail[..<$0.lowerBound] } ?? tail
          return !end.contains(".contextMenu")
      }())

let closeFn: String = {
    guard let s = sheet.range(of: "static func closeToolPreview() {") else { return "" }
    let t = sheet[s.upperBound...]
    return String(t[..<(t.range(of: "\n    }\n")?.lowerBound ?? t.endIndex)])
}()
check("closing turns off the same key Settings > Appearance toggles",
      closeFn.contains("UserDefaults.standard.set(false, forKey: \"toolPreviewEnabled\")")
      && settings.contains("@AppStorage(\"toolPreviewEnabled\")"))
check("closing shows the where-to-re-enable toast",
      closeFn.contains("MinisToast.show(AppLocalized(\"Preview window closed. You can turn it back on in Settings > Appearance.\")"))
check("the menu action captures no view (static, no self)", !closeFn.contains("self"))
check("the toast wraps instead of truncating a long hint", toast.contains("label.numberOfLines = 0") && !toast.contains("label.numberOfLines = 1"))

// The status bar itself: long-press toggles the preview (the in-place way back).
let barBody: String = {
    guard let s = sheet.range(of: "private struct ToolStatusBar: View {") else { return "" }
    let t = sheet[s.upperBound...]
    return String(t[..<(t.range(of: "private func move(to idx: Int)")?.lowerBound ?? t.endIndex)])
}()
check("the status bar's long-press menu toggles the preview window",
      barBody.contains(".contextMenu {") && barBody.contains("Toggle(isOn: FloatingToolBar.toolPreviewBinding)")
      && barBody.contains("AppLocalized(\"Tool Preview Window\")"))
check("the menu sits on the status/title area, not over the pager arrows (their own long-press jumps)",
      {
          guard let menu = barBody.range(of: ".contextMenu {"),
                let pager = barBody.range(of: "if toolBlocks.count > 1 {") else { return false }
          return menu.lowerBound < pager.lowerBound
      }())
check("the lift shows an opaque card (glass does not survive the snapshot)",
      barBody.contains("MessageContextMenuPreview(text: title)"))
let binding: String = {
    guard let s = sheet.range(of: "static var toolPreviewBinding: Binding<Bool> {") else { return "" }
    let t = sheet[s.upperBound...]
    return String(t[..<(t.range(of: "static func closeToolPreview()")?.lowerBound ?? t.endIndex)])
}()
check("the toggle reads the setting when the menu opens and turns off through closeToolPreview (toast)",
      binding.contains(#"get: { (UserDefaults.standard.object(forKey: "toolPreviewEnabled") as? Bool) ?? true }"#)
      && binding.contains("} else { closeToolPreview() }")
      && binding.contains(#"UserDefaults.standard.set(true, forKey: "toolPreviewEnabled")"#))

// Both strings are in the catalog for every locale the setting itself has.
if let data = try? Data(contentsOf: ios.appendingPathComponent("Localizable.xcstrings")),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = json["strings"] as? [String: Any] {
    func locales(_ k: String) -> Set<String> {
        Set(((strings[k] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]).keys)
    }
    let reference = locales("Tool Preview Window")
    for key in ["Close Preview Window", "Preview window closed. You can turn it back on in Settings > Appearance."] {
        check("'\(key.prefix(32))…' is translated for all \(reference.count) locales of the setting",
              !reference.isEmpty && locales(key).isSuperset(of: reference))
    }
} else {
    check("Localizable.xcstrings parses", false)
}

print(failures == 0 ? "\n✅ All tool-preview close tests passed" : "\n❌ \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
