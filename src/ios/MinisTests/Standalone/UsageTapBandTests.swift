#!/usr/bin/env swift
// [#414] A blank tap toggles a reply's token-usage capsule only inside the last
// 5 visual lines of the text block the capsule sits under. Anywhere else in the
// reply a blank tap does nothing (it used to toggle the capsule from any blank
// spot, so reading a long answer opened and closed it by accident).
//
//   [1] UsageTapBand (BEGIN/END block in SelectableMarkdownTextView.swift),
//       compiled and checked: inside / above the band, 1 pt either side of the
//       5-line boundary, fewer than 5 lines, exactly 5, mixed line heights,
//       not the anchor block, no lines, a line split into several fragments.
//   [2] The same function on REAL TextKit layout (NSLayoutManager, the API the
//       text view uses): the band is exactly the last 5 laid-out lines, and it
//       grows with the font size (Dynamic Type).
//   [3] BridgedAssistantBlockV3.isUsageAnchor, compiled against stub models:
//       only the message's last block, and only when it is text.
//   [4] Source guards: the text view gates both the tap and gestureRecognizerShouldBegin
//       on the band, no gate = old behaviour, the cell passes the gate, the
//       collapse path and capsule layout are untouched.
//
// Run: swift UsageTapBandTests.swift   (needs swiftc)
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

let textView = source("Views/Chat/Markdown/TextKit/SelectableMarkdownTextView.swift")
let cell = source("Agent/MessageList/CollectionViewMessageListV3/Cells/BridgedAssistantBlockV3.swift")
guard let bandBlock = between(textView, "// BEGIN UsageTapBand", "// END UsageTapBand"),
      let anchorBody = between(cell, "static func isUsageAnchor(block: AssistantBlock, in message: ChatMessage) -> Bool {", "\n    }\n") else {
    print("❌ UsageTapBand block or isUsageAnchor not found"); exit(1)
}

let harness = """
import Foundation
import AppKit
\(bandBlock)

// Stub models with the fields isUsageAnchor reads.
enum AssistantBlockKind { case text, thinking, shellTool(command: String) }
final class AssistantBlock { let id = UUID(); let kind: AssistantBlockKind; init(_ k: AssistantBlockKind) { kind = k } }
final class ChatMessage { var blocks: [AssistantBlock]; init(_ b: [AssistantBlock]) { blocks = b } }
enum Cell {
    static func isUsageAnchor(block: AssistantBlock, in message: ChatMessage) -> Bool {\(anchorBody)
    }
}

func out(_ k: String, _ v: Any) { print("R \\(k)=\\(v)") }
func lines(_ heights: [CGFloat], top: CGFloat = 8) -> [CGRect] {
    var y = top; var out: [CGRect] = []
    for h in heights { out.append(CGRect(x: 0, y: y, width: 300, height: h)); y += h }
    return out
}
func hit(_ y: CGFloat, _ rects: [CGRect], top: CGFloat = 0, bottom: CGFloat, last: Bool = true) -> Bool {
    UsageTapBand.contains(point: CGPoint(x: 10, y: y), lineRects: rects, blockTop: top, blockBottom: bottom, isLastTextBlock: last)
}

// 10 lines of 20 pt from y=8 (top inset 8): lines 8..208, block bottom 216.
let ten = lines(Array(repeating: 20, count: 10))
let b10 = UsageTapBand.band(lineRects: ten, blockTop: 0, blockBottom: 216)!
out("ten.band", "\\(b10.lowerBound)-\\(b10.upperBound)")
out("ten.inside", hit(150, ten, bottom: 216))
out("ten.belowLastLineInBlock", hit(212, ten, bottom: 216))
out("ten.boundary", hit(108, ten, bottom: 216))
out("ten.boundaryMinus1", hit(107, ten, bottom: 216))
out("ten.boundaryPlus1", hit(109, ten, bottom: 216))
out("ten.top", hit(20, ten, bottom: 216))
out("ten.notAnchor", hit(150, ten, bottom: 216, last: false))
// Fewer than 5 lines: the whole block, from its top.
let three = lines([20, 20, 20])
out("three.band", UsageTapBand.band(lineRects: three, blockTop: 0, blockBottom: 76).map { "\\($0.lowerBound)-\\($0.upperBound)" } ?? "nil")
out("three.topInset", hit(2, three, bottom: 76))
// Exactly 5: from the first line's top.
let five = lines([20, 20, 20, 20, 20])
out("five.band", UsageTapBand.band(lineRects: five, blockTop: 0, blockBottom: 116).map { "\\($0.lowerBound)-\\($0.upperBound)" } ?? "nil")
// Mixed heights: a 34 pt heading three lines from the end, then a 40 pt last line.
let mixed = lines([20, 20, 20, 20, 34, 20, 20, 40])
let bm = UsageTapBand.band(lineRects: mixed, blockTop: 0, blockBottom: 202)!
out("mixed.band", "\\(bm.lowerBound)-\\(bm.upperBound)")
// A visual line laid out as two fragments at the same y counts once.
var split = lines(Array(repeating: 20, count: 6))
split.append(CGRect(x: 150, y: split[5].minY, width: 100, height: 20))
out("split.band", UsageTapBand.band(lineRects: split, blockTop: 0, blockBottom: 128).map { "\\($0.lowerBound)-\\($0.upperBound)" } ?? "nil")
out("empty", UsageTapBand.band(lineRects: [], blockTop: 0, blockBottom: 0) == nil && !hit(0, [], bottom: 0))

// Real TextKit layout.
func realLines(fontSize: CGFloat, width: CGFloat = 320) -> [CGRect] {
    let text = String(repeating: "The quick brown fox jumps over the lazy dog, and then reads a very long reply. ", count: 12)
    let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
    let lm = NSLayoutManager()
    let tc = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    tc.lineFragmentPadding = 0
    lm.addTextContainer(tc); storage.addLayoutManager(lm)
    lm.ensureLayout(for: tc)
    var rects: [CGRect] = []
    lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { r, _, _, _, _ in rects.append(r) }
    return rects
}
for size in [17.0, 28.0] as [CGFloat] {
    let rs = realLines(fontSize: size)
    let bottom = rs.last!.maxY
    let band = UsageTapBand.band(lineRects: rs, blockTop: 0, blockBottom: bottom)!
    let lastFive = rs.suffix(5).reduce(0) { $0 + $1.height }
    out("real\\(Int(size)).lines", rs.count)
    out("real\\(Int(size)).bandHeight", String(format: "%.2f", band.upperBound - band.lowerBound))
    out("real\\(Int(size)).lastFive", String(format: "%.2f", lastFive))
    out("real\\(Int(size)).sixthFromEndOut", !UsageTapBand.contains(point: CGPoint(x: 5, y: rs[rs.count - 6].midY), lineRects: rs, blockTop: 0, blockBottom: bottom, isLastTextBlock: true))
    out("real\\(Int(size)).fifthFromEndIn", UsageTapBand.contains(point: CGPoint(x: 5, y: rs[rs.count - 5].midY), lineRects: rs, blockTop: 0, blockBottom: bottom, isLastTextBlock: true))
}

// isUsageAnchor
let t1 = AssistantBlock(.text), tool = AssistantBlock(.shellTool(command: "ls")), t2 = AssistantBlock(.text), think = AssistantBlock(.thinking)
out("anchor.lastText", Cell.isUsageAnchor(block: t2, in: ChatMessage([t1, tool, t2])))
out("anchor.earlierText", Cell.isUsageAnchor(block: t1, in: ChatMessage([t1, tool, t2])))
out("anchor.endsWithTool", Cell.isUsageAnchor(block: t1, in: ChatMessage([t1, tool])) || Cell.isUsageAnchor(block: tool, in: ChatMessage([t1, tool])))
out("anchor.endsWithThinking", Cell.isUsageAnchor(block: t1, in: ChatMessage([t1, think])))
let streaming = ChatMessage([t1])
let before = Cell.isUsageAnchor(block: t1, in: streaming)
streaming.blocks.append(tool); streaming.blocks.append(t2)
out("anchor.streamingMoves", before && !Cell.isUsageAnchor(block: t1, in: streaming) && Cell.isUsageAnchor(block: t2, in: streaming))
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("usageband_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try? harness.write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", mainFile.path, "-o", exe])
guard cs == 0 else { print("❌ compile failed\n\(cout)"); exit(1) }
let (_, rout) = run(exe, [])
var r: [String: String] = [:]
for line in rout.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("1. The band (10 lines of 20 pt, top inset 8, block bottom 216)")
check("band = top of the 5th line from the end .. block bottom", r["ten.band"] == "108.0-216.0")
check("a blank tap inside it responds", r["ten.inside"] == "true")
check("…including below the last line, down to the block bottom (the capsule)", r["ten.belowLastLineInBlock"] == "true")
check("on the boundary: in; 1 pt above: out; 1 pt below: in",
      r["ten.boundary"] == "true" && r["ten.boundaryMinus1"] == "false" && r["ten.boundaryPlus1"] == "true")
check("blank space higher up in the block does nothing", r["ten.top"] == "false")
check("a block that is not the capsule's anchor has no band", r["ten.notAnchor"] == "false")
check("fewer than 5 lines: the whole block, from its top (inset included)",
      r["three.band"] == "0.0-76.0" && r["three.topInset"] == "true")
check("exactly 5 lines: from the first line", r["five.band"] == "8.0-116.0")
check("mixed line heights: the real extent of the last 5 lines (heading + 40 pt last line)",
      r["mixed.band"] == "68.0-202.0")   // line tops 8,28,48,68,88,122,142,162; last 5 start at 68
check("one visual line in two fragments counts once", r["split.band"] == "28.0-128.0")
check("no lines: no band", r["empty"] == "true")

print("\n2. On real TextKit layout")
check("long reply wraps into many visual lines", (Int(r["real17.lines"] ?? "") ?? 0) > 10)
check("band height = the last 5 laid-out lines (17 pt)", r["real17.bandHeight"] == r["real17.lastFive"])
check("band height = the last 5 laid-out lines (28 pt, Dynamic Type)", r["real28.bandHeight"] == r["real28.lastFive"])
check("a larger font makes the band taller",
      (Double(r["real28.bandHeight"] ?? "") ?? 0) > (Double(r["real17.bandHeight"] ?? "") ?? 0) * 1.4)
check("the 5th line from the end is in, the 6th is out",
      r["real17.fifthFromEndIn"] == "true" && r["real17.sixthFromEndOut"] == "true"
      && r["real28.fifthFromEndIn"] == "true" && r["real28.sixthFromEndOut"] == "true")

print("\n3. Which block owns the band")
check("the message's last block, when it is text", r["anchor.lastText"] == "true")
check("an earlier text block does not", r["anchor.earlierText"] == "false")
check("a reply ending in a tool block has no anchor (no fallback to earlier text)", r["anchor.endsWithTool"] == "false")
check("…nor one ending in a thinking block", r["anchor.endsWithThinking"] == "false")
check("while streaming the anchor moves to the newest last text block", r["anchor.streamingMoves"] == "true")

print("\n4. Wiring")
let tap = between(textView, "@objc private func handleInlineCodeTap(_ gesture: UITapGestureRecognizer) {", "// Inline code: copy it") ?? ""
check("the blank tap checks the band before calling onTapBlank",
      tap.contains("guard blankTapPassesUsageBand(point) else {")
      && (tap.range(of: "guard blankTapPassesUsageBand(point)")?.lowerBound ?? tap.endIndex)
         < (tap.range(of: "onTapBlank(windowPoint)")?.lowerBound ?? tap.startIndex))
check("outside the band the gesture does not begin (same as no handler)",
      textView.contains("if isBlankArea { return onTapBlank != nil && blankTapPassesUsageBand(point) }"))
check("no gate set keeps the old rule; the gate uses this view's TextKit lines and bounds",
      textView.contains("guard let eligible = blankTapEligible else { return true }")
      && textView.contains("UsageTapBand.contains(point: point, lineRects: visualLineRects(),")
      && textView.contains("layoutManager.enumerateLineFragments(forGlyphRange: glyphs)"))
check("the cell passes the anchor test, evaluated at tap time",
      cell.contains("blankTapEligible: { [message, block] in\n                Self.isUsageAnchor(block: block, in: message)"))
check("the gate is plumbed through AssistantBlockView and SelectableMarkdownView (make + update)",
      source("Views/Chat/AssistantBlockView.swift").contains("blankTapEligible: blankTapEligible,")
      && source("Views/Chat/Markdown/Bridge/SelectableMarkdownView.swift").components(separatedBy: "textView.blankTapEligible = blankTapEligible").count - 1 == 2)
check("toggleUsage (expand / collapse, animation, re-snapshot) is unchanged",
      cell.contains("withAnimation(.easeInOut(duration: 0.15)) { bridge.usageContentVisible = false }")
      && cell.contains("withAnimation(.easeInOut(duration: 0.2)) { bridge.usageContentVisible = true }"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
