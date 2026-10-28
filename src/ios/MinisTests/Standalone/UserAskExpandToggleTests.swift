#!/usr/bin/env swift
// [T-user-ask-expand-measured] The pending user_ask card folds its question to
// 3 lines. The Show more / Show less toggle appeared only for
// `question.count > 140`, so a confirm question of ~61-140 characters
// (monospaced, in a padded box: ~60 mixed CJK/Latin chars fill 3 lines) was
// cut to "…" with no way to open it; and the toggle was a bare ~26x15pt label
// in the smallest font. Device screenshot 2026-10-06 15:06 ("高风险操作").
//
// Source guards (SwiftUI layout needs a device to run):
//   - no character-count rule; the toggle depends on measured overflow
//   - two hidden probes (3-line and full) share the visible text's font
//   - the measurement does not depend on the expanded state (Show less stays)
//   - the toggle is a full-height (minTapHeight) row with a hit shape and
//     the secondary font; expand state is still cached per question
//
// Run: swift UserAskExpandToggleTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let card = (try? String(contentsOf: iosRoot.appendingPathComponent("Views/Chat/UserAskCardView.swift"), encoding: .utf8)) ?? ""
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}
func ordered(_ s: String, _ parts: [String]) -> Bool {
    var from = s.startIndex
    for p in parts {
        guard let r = s.range(of: p, range: from..<s.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}

check("source readable", !card.isEmpty)
check("no character-count rule left", !card.contains("q.question.count > 140"))

let content = between(card, "private var content: some View {", "private var optionsBody: some View {") ?? ""
check("content found", !content.isEmpty)
check("visible text keeps the 3-line fold and its expanded state",
      content.contains(".lineLimit(questionExpanded ? nil : 3)"))
check("probes: a 3-line copy and a full copy, both from questionText, hidden",
      ordered(content, ["questionText\n                            .lineLimit(3)", "UserAskQuestionClampedHeightKey",
                        "questionText\n                            .fixedSize(horizontal: false, vertical: true)", "UserAskQuestionFullHeightKey",
                        ".hidden()"]))
check("probes sit in a background (never change the layout)",
      content.contains(".background(alignment: .topLeading) {"))
check("both heights land in @State",
      content.contains("questionClampedHeight = h") && content.contains("questionFullHeight = h"))
check("the toggle exists only when the text really overflows", content.contains("if questionOverflows {"))
check("overflow does not depend on questionExpanded (Show less survives expanding)",
      (between(card, "private var questionOverflows: Bool {", "}") ?? "x").contains("questionFullHeight > questionClampedHeight + 1")
      && !(between(card, "private var questionOverflows: Bool {", "}") ?? "questionExpanded").contains("questionExpanded"))
check("visible text and probes share one font definition",
      card.contains("private var questionText: Text {")
      && (between(card, "private var questionText: Text {", "}") ?? "").contains("design: .monospaced"))

let toggle = between(content, "if questionOverflows {", ".buttonStyle(.plain)") ?? ""
check("toggle flips state, caches it per question, notes the interaction",
      ordered(toggle, ["questionExpanded.toggle()", "UserAskPendingLayoutCache.setExpanded(questionExpanded, layoutKey)",
                       "UserAskCenter.shared.noteInteraction(requestId: ask.requestId)"]))
check("toggle reads Show more / Show less", toggle.contains("AppLocalized(\"Show less\") : AppLocalized(\"Show more\")"))
check("toggle uses the secondary font, not the smallest",
      toggle.contains(".font(.system(size: t.secondary, weight: .medium))") && !toggle.contains("t.meta"))
check("toggle is a 44pt row with a hit shape and horizontal padding",
      toggle.contains(".frame(minHeight: UserAskTypography.minTapHeight, alignment: .leading)")
      && toggle.contains(".contentShape(Rectangle())") && toggle.contains(".padding(.trailing, 16)"))
check("text selection on the question is untouched", content.contains(".textSelection(.enabled)"))
check("preference keys declared",
      card.contains("private struct UserAskQuestionClampedHeightKey: PreferenceKey")
      && card.contains("private struct UserAskQuestionFullHeightKey: PreferenceKey"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
