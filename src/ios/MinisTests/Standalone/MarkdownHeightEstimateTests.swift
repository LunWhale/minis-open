#!/usr/bin/env swift
// [T-scroll-estimate-fidelity] Scroll shake from estimate corrections.
//
// Rows on an estimate are measured as they scroll into view, and the list does
// not compensate a correction while it moves (no contentOffsetAdjustment during
// tracking / deceleration), so every point of error shows as content jumping
// mid-fling. Measured on device (2026-10-03, 348-row session):
//   - assistant headers: estimate 30, real 26 -> -4 pt on every header (48x);
//   - unrendered text blocks: +225 pt on average, up to +736 pt.
//
// 1. compiles the shipping MarkdownHeightEstimate with the real
//    TableColumnPlanner and checks it against the renderer's layout rules on
//    synthetic text (no user content in fixtures);
// 2. pins the wiring: learned header estimate, the cross-load memo used as an
//    estimate only (never a seed), and the cache-clearing rules.
//
// Run: swift MarkdownHeightEstimateTests.swift   (needs swiftc)
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

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
func block(_ src: String, _ name: String) -> String? {
    guard let b = src.range(of: "// BEGIN \(name)"), let e = src.range(of: "// END \(name)") else { return nil }
    return String(src[b.lowerBound..<e.upperBound])
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

let layoutSrc = source("Agent/MessageList/MessageListLayout.swift")
let listSrc = messageListV3Source()
let tableSrc = source("Views/Chat/Markdown/Attachments/Table/TableLayoutPlanning.swift")
guard let estimateBlock = block(layoutSrc, "MarkdownHeightEstimate"),
      let plannerBlock = block(tableSrc, "TableColumnPlanner") else {
    print("❌ sources not found"); exit(1)
}

let tests = #"""
import Foundation
var fails = 0
func expect(_ label: String, _ cond: Bool) { print(cond ? "RESULT pass \(label)" : "RESULT fail \(label)"); if !cond { fails += 1 } }
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.5) -> Bool { abs(a - b) <= tol }

// iPhone 17 Pro portrait: container 402 -> text width 370; base 16.5; line
// heights as the real fonts give them (system ~1.193 em, PingFang 1.4 em).
let base: CGFloat = 16.5, latinLH: CGFloat = 19.69, wideLH: CGFloat = 23.1
let e = MarkdownHeightEstimate(textWidth: 370, baseFontSize: base, latinLineHeight: latinLH, wideLineHeight: wideLH)
let ls = base * 0.25
func para(lines n: CGFloat, lh: CGFloat) -> CGFloat { n * lh + (n - 1) * ls }

expect("empty text renders nothing", e.height(of: "") == 0)

// One CJK line is a full em per glyph: 22 glyphs fit 370 pt, 23 do not.
let cjk22 = String(repeating: "中", count: 22), cjk23 = String(repeating: "中", count: 23)
expect("22 CJK glyphs: one line (+12 like the measured path)", near(e.height(of: cjk22), para(lines: 1, lh: wideLH) + 12))
expect("23 CJK glyphs wrap to two lines", near(e.height(of: cjk23), para(lines: 2, lh: wideLH) + 12))
// The old model fitted ~40 glyphs per line: 230 glyphs = 6 lines. Real: 11.
let cjk230 = String(repeating: "测", count: 230)
expect("230 CJK glyphs -> 11 lines with line spacing", near(e.height(of: cjk230), para(lines: 11, lh: wideLH) + 12))

// Latin: 0.56 em per character, 0.28 em per space, system line height.
let latin = String(repeating: "a", count: 40)   // 40 * 9.24 = 369.6 < 370
expect("40 Latin letters fit one line at the Latin line height", near(e.height(of: latin), para(lines: 1, lh: latinLH) + 12))
expect("41 wrap", near(e.height(of: latin + "a"), para(lines: 2, lh: latinLH) + 12))
expect("one wide glyph puts the line on the CJK line height", near(e.height(of: "abc中"), para(lines: 1, lh: wideLH) + 12))
expect("inline markers are not counted", e.height(of: "**" + cjk22 + "**") == e.height(of: cjk22)
       && e.height(of: "`" + cjk22 + "`") == e.height(of: cjk22))

// Blocks: spacing = max(top, previous bottom).
let twoParas = "第一段\n\n第二段"
expect("two paragraphs: 12 pt between them", near(e.height(of: twoParas), 2 * para(lines: 1, lh: wideLH) + 12 + 12))
let softBreak = "第一行\n第二行"
expect("a soft break is a new line in the same paragraph (line spacing, no paragraph gap)",
       near(e.height(of: softBreak), 2 * wideLH + ls + 12))
let heading = "## 标题\n正文"
expect("heading: 1.3x size, 1 em below", near(e.height(of: heading),
       para(lines: 1, lh: wideLH * 1.3) + base + para(lines: 1, lh: wideLH) + 12))
let list = "- 一\n- 二\n- 三"
expect("list: 0.25 em between items", near(e.height(of: list), 3 * wideLH + 2 * base * 0.25 + 12))
let listThenPara = "- 一\n\n正文"
expect("after a list: 16 pt", near(e.height(of: listThenPara), wideLH + 16 + wideLH + 12))
// Top level is already indented one level (346 pt): 20 glyphs (330) fit;
// the nested item (322 pt) does not.
let nested = "- " + String(repeating: "中", count: 20) + "\n  - " + String(repeating: "中", count: 20)
expect("indent narrows the line (24 pt per level): nested item wraps, top item does not",
       near(e.height(of: nested), para(lines: 1, lh: wideLH) + base * 0.25 + para(lines: 2, lh: wideLH) + 12))
let quote = "> " + String(repeating: "中", count: 22)
expect("quote: 13 pt indent makes 22 glyphs wrap", near(e.height(of: quote), para(lines: 2, lh: wideLH) + 12))
expect("code fence keeps its fixed rows", near(e.height(of: "```\na\nb\n```"), 32 + 2 * 18 + 24 + 12))

// Tables: planned by the real TableColumnPlanner, rows grow with wrapped cells.
let shortTable = "| A | B |\n|---|---|\n| 1 | 2 |"
expect("short table: rows at the 36 pt minimum", near(e.height(of: shortTable), 2 * 36 + 12))
let longCell = String(repeating: "长", count: 60)
let wideTable = "| 项 | 说明 |\n|---|---|\n| x | \(longCell) |"
let wide = e.height(of: wideTable)
expect("a long cell wraps: its row is taller than the 36 pt minimum", wide > 2 * 36 + 12 + 20)
expect("separator rows are not counted", MarkdownHeightEstimate.isTableSeparator("| :--- | ---: |")
       && !MarkdownHeightEstimate.isTableSeparator("| a | b |"))

// Parsing helpers.
expect("list markers: -, *, +, 1., 1)", ["- a", "* a", "+ a", "1. a", "12) a"].allSatisfy { MarkdownHeightEstimate.listItem(Substring($0)) != nil })
expect("not list markers: -a, 1.a, plain", ["-a", "1.a", "abc"].allSatisfy { MarkdownHeightEstimate.listItem(Substring($0)) == nil })
expect("heading needs a space", MarkdownHeightEstimate.heading("# a")?.level == 1 && MarkdownHeightEstimate.heading("#a") == nil
       && MarkdownHeightEstimate.heading("####### a") == nil)
if fails > 0 { print("RESULT fail \(fails) check(s)") }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("md-estimate-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try ("import Foundation\n" + plannerBlock).write(to: tmp.appendingPathComponent("planner.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\n" + estimateBlock).write(to: tmp.appendingPathComponent("estimate.swift"), atomically: true, encoding: .utf8)
try tests.write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t")

print("1. MarkdownHeightEstimate (shipping block + real TableColumnPlanner)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"]
                        + ["planner.swift", "estimate.swift", "main.swift"].map { tmp.appendingPathComponent($0).path }
                        + ["-o", bin.path])
check("estimate + planner compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (_, out) = run(bin.path, [])
for line in out.split(separator: "\n") where line.hasPrefix("RESULT") {
    check(String(line.dropFirst(12)), line.hasPrefix("RESULT pass"))
}

print("\n2. Wiring")
check("estimateTextBlockHeight follows the renderer basis (16.5 x scale, width - 32) through MarkdownHeightEstimate",
      listSrc.contains("let base = FontSettings.shared.scaledMessage(16.5)")
      && listSrc.contains("let textWidth = max(width - 32, 100)")
      && listSrc.contains("return estimate.height(of: content)"))
check("the old half-em line model is gone", !listSrc.contains("let cpl = tw / (scale * 0.5)"))
check("line heights come from the real fonts (system, PingFang), cached per size",
      listSrc.contains("let latin = UIFont.systemFont(ofSize: size).lineHeight")
      && listSrc.contains("UIFont(name: \"PingFangSC-Regular\", size: size)?.lineHeight"))
check("header seed: learned height, else the formula (no fixed 30 / 28)",
      listSrc.contains("layout.setEstimatedHeight(layout.headerEstimate(width: cvWidth), at: i)")
      && listSrc.contains("return AssistantHeaderMetrics.formulaHeight()")
      && !listSrc.contains("layout.setEstimatedHeight(30, at: i)"))
check("header formula mirrors the view: icon 22 vs semibold body line, + top padding 4",
      layoutSrc.contains("return ceil(max(22, name.lineHeight)) + 4")
      && listSrc.contains("size: 22,") && listSrc.contains(".padding(.top, 4)"))
check("a measured header teaches the estimate, keyed by width and font size",
      layoutSrc.contains("learnedHeaderHeight = (height, boundsWidth, AssistantHeaderMetrics.fontKey())")
      && layoutSrc.contains("learned.font == AssistantHeaderMetrics.fontKey()"))
check("cross-load memo is written from real self-sizes, via the content-hash link",
      layoutSrc.contains("if let stable = stableHeightKeyByContentKey[baseKey] {")
      && layoutSrc.contains("CrossLoadHeightMemo.shared.record(stable, width: boundsWidth, height: height)"))
check("…and read as PRECALC (an estimate), never as a seed that skips measuring",
      listSrc.contains("if !isGrowing, let stableKey, let remembered = CrossLoadHeightMemo.shared.height(for: stableKey, width: cvWidth) {\n                        layout.setPrecalcHeight(remembered, at: i)")
      && !listSrc.contains("seedMeasuredHeight(remembered"))
// [T-stream-precalc-freeze] A still-growing message's rows get no precalc at
// all: a content-hash hit gave a brand-new EMPTY text block the ~32 pt of an
// earlier empty block, and the streaming cell returned precalc unmeasured.
check("…and never for a row of a message that is still growing",
      listSrc.contains("let growingIds = Self.liveAssistantMessageIds(messages: messages, isProcessing: vm.isProcessing)")
      && listSrc.contains("if isGrowing { layout.clearPrecalcHeight(at: i) }")
      && listSrc.contains("if !isGrowing, let memo = layout.measuredHeight(forKey: contentKey, width: cvWidth) {")
      && listSrc.contains("if !isGrowing, let attrStr = block.cachedAttributedString {"))
check("only content-determined rows get a content-hash key (user messages, text, thinking)",
      listSrc.contains("guard let m = msg(id), m.role == .user else { return nil }")
      && listSrc.contains("case .text: expanded = false") && listSrc.contains("case .thinking: expanded = b.isThinkingExpanded"))
check("memo key carries width and message font size; bounded; dropped on memory warning",
      layoutSrc.contains("|w\\(Int(width.rounded()))|f\\(")
      && layoutSrc.contains("static let capacity = 20_000")
      && layoutSrc.contains("UIApplication.didReceiveMemoryWarningNotification"))
check("session switch clears the per-load links, not the learned header",
      layoutSrc.contains("stableHeightKeyByContentKey.removeAll()")
      && !layoutSrc.contains("learnedHeaderHeight = nil")
      && listSrc.contains("self.stableHeightKeyCache.removeAll()"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
