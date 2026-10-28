#!/usr/bin/env swift
// [T-error-banner-under-navbar] The chat's error banner and transient notice
// sit under the navigation bar, stacked with the scheduled-task banner, not
// at the top of the screen. On iOS 26 the chat content runs up behind the
// bar, and these two used to live in a top inset INSIDE that content, so they
// were drawn at y = 0 under the status bar's clock and battery, with the
// dismiss button beside the battery (device repro, iPhone 11).
//
// Source guards (SwiftUI layout; the list-inset maths is shared with
// ScheduledBannerTests).
//
// Run: swift TopBannersTests.swift
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
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let chat = chatViewSource()
check("AIChatView.swift readable", !chat.isEmpty)
func count(_ s: String) -> Int { chat.components(separatedBy: s).count - 1 }

print("▶️  one stack under the navigation bar")
let stack: String = {
    guard let a = chat.range(of: "var topBanners: some View {"),
          let b = chat.range(of: "\n    // MARK: - Error Banner", range: a.upperBound..<chat.endIndex) else { return "" }
    return String(chat[a.upperBound..<b.lowerBound])
}()
check("topBanners exists", !stack.isEmpty)
let iSched = stack.range(of: "ScheduledTaskBanner(sessionId: sid)")?.lowerBound
let iError = stack.range(of: "errorBanner(error)")?.lowerBound
let iNotice = stack.range(of: "if let notice = vm.transientNotice {")?.lowerBound
check("order: scheduled task, then error, then transient notice",
      iSched != nil && iError != nil && iNotice != nil && iSched! < iError! && iError! < iNotice!)
check("stacked with no gap, so they can never overlap", stack.contains("VStack(spacing: 0) {"))
check("mounted OUTSIDE NavBarStyleModifier (its top is the bar's bottom on every iOS)",
      chat.contains(".modifier(NavBarStyleModifier(topSafeAreaInset: $topSafeAreaInset))")
      && chat.contains(".safeAreaInset(edge: .top, spacing: 0) {\n            topBanners"))
check("ONE measured height for the whole stack drives the list's top inset",
      chat.contains("topBanners\n                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in\n                    if abs(height - topBannersHeight) > 0.5 { topBannersHeight = height }")
      && chat.contains("extraTopInset: Self.listTopInset(forTopBanners: topBannersHeight)"))

print("\n▶️  nothing left in the old place")
check("only one top inset in the chat page", count(".safeAreaInset(edge: .top, spacing: 0)") == 1)
check("errorBanner is called only from the stack", count("errorBanner(error)") == 1 && stack.contains("errorBanner(error)"))
check("the transient notice is rendered only from the stack", count("if let notice = vm.transientNotice {") == 1)

print("\n▶️  the error banner itself is unchanged, apart from an opaque base")
let banner: String = {
    guard let a = chat.range(of: "private func errorBanner(_ error: String) -> some View {"),
          let b = chat.range(of: "\n    }\n", range: a.upperBound..<chat.endIndex) else { return "" }
    return String(chat[a.upperBound..<b.lowerBound])
}()
check("same icon, red text, up to 8 lines, selectable", banner.contains("Image(systemName: \"exclamationmark.triangle.fill\")")
      && banner.contains(".lineLimit(8)") && banner.contains(".textSelection(.enabled)"))
check("same dismiss button and label", banner.contains("Button { vm.errorMessage = nil } label: {")
      && banner.contains("Text(\"Dismiss error\""))
check("same long-press copy", banner.contains("UIPasteboard.general.string = error"))
check("card like the scheduled banner: 14pt continuous corners, material + red wash, red hairline, soft shadow, 12pt margins",
      banner.contains("RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)")
      && banner.contains("RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.08))")
      && banner.contains(".strokeBorder(Color.red.opacity(0.28), lineWidth: 0.75)")
      && banner.contains(".shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)")
      && banner.contains(".padding(.horizontal, 12)\n        .padding(.top, 6)\n        .padding(.bottom, 4)"))
check("same outer margins and material as the scheduled pill it stacks with",
      (try? String(contentsOf: root.appendingPathComponent("Views/Chat/ScheduledTaskDetailView.swift"), encoding: .utf8))
        .map { $0.contains(".padding(.horizontal, 12)\n        .padding(.top, 6)\n        .padding(.bottom, 4)")
               && $0.contains("Capsule().fill(.regularMaterial)") } == true)
check("no full-width tint left", !banner.contains(".background(Color.red.opacity(0.12))"))
check("dismiss: hit shape >= 44 pt (glyph ~14 pt + 16 pt each side), look unchanged",
      banner.contains(".contentShape(Rectangle().inset(by: -16))")
      && banner.contains("Image(systemName: \"xmark\")\n                    .font(.caption)"))
check("notice keeps its look and its ~4 s auto-dismiss", stack.contains(".background(Color.black.opacity(0.75))")
      && stack.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 4)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
