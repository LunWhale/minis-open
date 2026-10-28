#!/usr/bin/env swift
// [T-input-attachment-preview-index] With several images in the composer's
// attachment strip, tapping any thumbnail was reported to open the LAST one.
// Each chip owned its own `.sheet(isPresented:)`, one sheet per sibling;
// which sibling's content a shared presentation shows is not something the
// code controlled. The strip now owns one `.sheet(item:)` keyed by the
// tapped attachment's id, and the preview holds every loaded attachment,
// opening on the tapped one.
//
//   [1] the shipping previewStartIndex (BEGIN/END block), compiled standalone
//   [2] source guards on the wiring
//
// Run: swift InputAttachmentPreviewIndexTests.swift   (needs swiftc)
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

let bar = source("Views/Chat/ChatInputBar.swift")
guard let block = between(bar, "// BEGIN previewStartIndex", "// END previewStartIndex") else {
    print("❌ previewStartIndex block not found"); exit(1)
}

print("[1] previewStartIndex")
let harness = """
import Foundation
enum S {
\(block)
}
let a = UUID(), b = UUID(), c = UUID(), gone = UUID()
let ids = [a, b, c]
print("first=\\(S.previewStartIndex(of: a, in: ids)) middle=\\(S.previewStartIndex(of: b, in: ids)) last=\\(S.previewStartIndex(of: c, in: ids)) gone=\\(S.previewStartIndex(of: gone, in: ids)) empty=\\(S.previewStartIndex(of: a, in: []))")
// after removing the middle one, the remaining two keep their own positions
print("afterRemove=\\(S.previewStartIndex(of: a, in: [a, c])),\\(S.previewStartIndex(of: c, in: [a, c]))")
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("preview_index_\(getpid()).swift")
try? harness.write(to: tmp, atomically: true, encoding: .utf8)
let (status, out) = run("/usr/bin/env", ["swift", tmp.path])
try? FileManager.default.removeItem(at: tmp)
print("      \(out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "  "))")
check("harness ran", status == 0)
check("each tapped attachment opens at its own position, not the last",
      out.contains("first=0 middle=1 last=2"))
check("a tapped attachment that is gone falls back to the first; empty list is safe",
      out.contains("gone=0 empty=0"))
check("after a removal the remaining ones open at their new positions", out.contains("afterRemove=0,1"))

print("[2] Wiring")
// Code only: comments here mention the old `.sheet(isPresented:)` on purpose.
func code(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
let chip = code(between(bar, "private struct AttachmentChip: View {", "// MARK: - Pasted-text chips") ?? "")
check("a chip no longer presents its own sheet", !chip.isEmpty && !chip.contains(".sheet(") && !chip.contains("showPreview"))
check("a loaded chip's tap reports up", chip.contains(".onTapGesture { onPreview() }"))
let grid = code(between(bar, "struct InputAttachmentGridView: View {", "struct AttachmentPreviewTarget") ?? "")
check("the strip records the tapped attachment's id",
      grid.contains("previewTarget = AttachmentPreviewTarget(id: attachment.id)"))
check("the strip owns exactly one sheet, keyed by that id",
      grid.components(separatedBy: ".sheet(").count - 1 == 1 && grid.contains(".sheet(item: $previewTarget) { target in"))
check("the preview gets every loaded attachment and the tapped id",
      grid.contains("attachments: attachments.filter { $0.loadState == .ready },\n                initialID: target.id,"))
let preview = between(bar, "private struct AttachmentPreviewView: UIViewControllerRepresentable {", "// MARK: - Video File Transferable") ?? ""
check("QuickLook opens on the tapped item (index set before it is shown)",
      preview.contains("controller.dataSource = context.coordinator\n        // Set before the controller is shown, so it opens on the tapped item.\n        controller.currentPreviewItemIndex = initialIndex"))
check("QuickLook lists all of them", preview.contains("func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }"))
check("the title follows the item on screen",
      preview.contains("controller.observe(\\.currentPreviewItemIndex") && bar.contains("onIndexChange: { index = $0 })"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
