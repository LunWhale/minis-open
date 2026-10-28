#!/usr/bin/env swift
// [T-table-width-by-content] Markdown table column widths follow content.
//
// User-decided design (replaces T-table-two-plus-peek, whose equal per-column
// cap made a column with 3× the text as narrow as its neighbour): each column
// gets a hard minimum (floor 80 / longest Latin word), a comfortable width
// (35% of the viewport, or its content if shorter) and its natural one-line
// width. Fits on one line → spread in proportion to content; comfortable
// widths fit → CSS auto-layout split filling the viewport; otherwise scroll
// with each column ≤ 70% of the viewport and the next column peeking in.
// Invariant: a column with more text is never narrower. Cells are top-aligned;
// widths only grow while a table streams.
//
// Compiles the real `TableColumnPlanner` block out of the markdown module
// (Views/Chat/Markdown/Attachments/Table/TableLayoutPlanning.swift)
// (between `// BEGIN TableColumnPlanner` and `// END TableColumnPlanner`) with a
// harness, so the shipping code is what's tested.
//
// Run: swift TableColumnPlannerTests.swift   (needs swiftc)
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
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

/// The markdown renderer module (Views/Chat/Markdown/, formerly the single file
/// SelectableMarkdownView.swift), read as one text with its files in path order.
func markdownModuleSource() -> String {
    let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Views/Chat/Markdown")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}
let view = markdownModuleSource()
guard let planner = between(view, "// BEGIN TableColumnPlanner", "// END TableColumnPlanner") else {
    print("❌ planner block not found"); exit(1)
}

// Column measurements mirror computeLayout: natural = text + 16 padding (2 × cellPaddingH 8) + 12,
// minUnbreakable = longest Latin word + 16 + 4. The planner itself is padding-agnostic. Values are realistic for the
// 17pt system font (≈17pt per CJK glyph, ≈8.5pt per Latin char).
let harness = """
import Foundation
import CoreGraphics
func cols(_ pairs: [(CGFloat, CGFloat)]) -> [TableColumnPlanner.Column] {
    pairs.map { TableColumnPlanner.Column(natural: $0.0, minUnbreakable: $0.1) }
}
func show(_ name: String, _ p: TableColumnPlanner.Plan) {
    let w = p.widths.map { String(Int($0.rounded())) }.joined(separator: ",")
    print("\\(name)=\\(w)|\\(Int(p.tableWidth.rounded()))|\\(p.mode.rawValue)")
}
// Table A: short-ish label column + two long CJK prose columns.
let tableA = cols([(180, 0), (1000, 0), (950, 0)])
// Table B: 2 columns, one short, one extremely long.
let tableB = cols([(120, 0), (3400, 0)])
// Table C: tiny cells.
let tableC = cols([(78, 0), (78, 0), (78, 0)])
// Table D: English prose with long words.
let tableD = cols([(180, 120), (900, 140), (860, 110)])
// 5-column table.
let wide5 = cols([(90, 0), (400, 0), (400, 0), (500, 0), (500, 0)])
// One-word first column.
let oneWord = cols([(60, 0), (700, 0), (700, 0)])
// The 2026-09-27 screenshot: "项目 | 状态", short item names vs long status text.
let shot = cols([(232, 80), (600, 115)])
for (label, width) in [("se1", CGFloat(287)), ("se3", 343), ("shot", 369), ("i11", 381), ("promax", 398), ("land", 760), ("ipad", 1050)] {
    show("A.\\(label)", TableColumnPlanner.plan(columns: tableA, availableWidth: width))
    show("B.\\(label)", TableColumnPlanner.plan(columns: tableB, availableWidth: width))
    show("C.\\(label)", TableColumnPlanner.plan(columns: tableC, availableWidth: width))
    show("D.\\(label)", TableColumnPlanner.plan(columns: tableD, availableWidth: width))
    show("W5.\\(label)", TableColumnPlanner.plan(columns: wide5, availableWidth: width))
    show("OW.\\(label)", TableColumnPlanner.plan(columns: oneWord, availableWidth: width))
    show("SHOT.\\(label)", TableColumnPlanner.plan(columns: shot, availableWidth: width))
}
// Property test: random tables at random widths (deterministic LCG).
var seed: UInt64 = 0x5eed
func rnd(_ lo: Double, _ hi: Double) -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(lo + (hi - lo) * Double(seed >> 11) / Double(1 << 53))
}
var monotonic = 0, fills = 0, bounds = 0, peek = 0, total = 0, fitCases = 0, scrollCases = 0
var firstFail = ""
for _ in 0..<20000 {
    let n = Int(rnd(1, 7))
    let w = rnd(260, 1200)
    let c: [TableColumnPlanner.Column] = (0..<n).map { _ in
        let natural = rnd(40, rnd(0, 1) < 0.5 ? 400 : 3000)
        let word = rnd(0, 1) < 0.3 ? min(natural, rnd(40, 400)) : 0
        return .init(natural: natural, minUnbreakable: word)
    }
    let p = TableColumnPlanner.plan(columns: c, availableWidth: w)
    total += 1
    let nat = c.map { max(min(80, w), $0.natural.rounded(.up)) }
    let hard = c.map { max(min(80, w), min($0.minUnbreakable.rounded(.up), (w * 0.7).rounded(.down))) }
    // Invariant, except where a long word forces a minimum on the narrower-text column.
    for i in 0..<n { for j in 0..<n where nat[i] >= nat[j] && p.widths[i] < p.widths[j] - 0.01 && p.widths[j] > hard[j] + 0.01 {
        monotonic += 1
        if firstFail.isEmpty { firstFail = "n=\\(nat) w=\\(w) -> \\(p.widths)" }
    } }
    // Each column within [min(natural, hardMin), max(hardMin, natural)] (fit mode may spread spare room).
    for i in 0..<n where p.widths[i] < min(nat[i], hard[i]) - 0.01 || (p.mode == .scrolls && p.widths[i] > max(nat[i], hard[i]) + 0.01) { bounds += 1 }
    let sum = p.widths.reduce(0, +)
    if p.mode != .scrolls {
        fitCases += 1
        if abs(sum - w) > 0.01 { fills += 1 }
    } else {
        scrollCases += 1
        // The column crossing the right edge shows ≥ 24pt, or the one before it is already at its floor.
        var x: CGFloat = 0
        for k in 0..<n {
            if x + p.widths[k] > w + 0.01 { if w - x < 23.99 && k > 0 && p.widths[k-1] > max(min(nat[k-1], max(hard[k-1], (w * 0.35).rounded(.down))), p.widths.enumerated().filter { $0.offset != k-1 && nat[$0.offset] <= nat[k-1] }.map { $0.element }.max() ?? 0) + 0.01 { peek += 1 }; break }
            x += p.widths[k]
        }
    }
}
print("PROP=\\(total),\\(monotonic),\\(fills),\\(bounds),\\(peek),\\(fitCases),\\(scrollCases)|0|x")
print("FIRSTFAIL: \\(firstFail)")
// Streaming: header only → a long row arrives → the row grows further.
let s1 = TableColumnPlanner.plan(columns: cols([(90, 0), (90, 0), (90, 0)]), availableWidth: 381)
let s2raw = TableColumnPlanner.plan(columns: cols([(200, 0), (500, 0), (300, 0)]), availableWidth: 381)
let s2 = TableColumnPlanner.applyingStreamingFloor(s2raw, previous: s1.widths, availableWidth: 381)
let s3raw = TableColumnPlanner.plan(columns: cols([(200, 0), (520, 0), (600, 0)]), availableWidth: 381)
let s3 = TableColumnPlanner.applyingStreamingFloor(s3raw, previous: s2.widths, availableWidth: 381)
show("S1", s1); show("S2raw", s2raw); show("S2", s2); show("S3raw", s3raw); show("S3", s3)
// Streaming within one viewport: a lifted column gives back to fit.
let t1 = TableColumnPlanner.plan(columns: cols([(100, 0), (300, 0), (90, 0)]), availableWidth: 381)
let t2raw = TableColumnPlanner.plan(columns: cols([(100, 0), (300, 0), (240, 0)]), availableWidth: 381)
let t2 = TableColumnPlanner.applyingStreamingFloor(t2raw, previous: t1.widths, availableWidth: 381)
show("T1", t1); show("T2raw", t2raw); show("T2", t2)
// Scrolling table: widths never shrink across updates.
let u1 = TableColumnPlanner.plan(columns: cols([(500, 0), (500, 0), (500, 0)]), availableWidth: 381)
let u2raw = TableColumnPlanner.plan(columns: cols([(500, 0), (200, 0), (900, 0)]), availableWidth: 381)
let u2 = TableColumnPlanner.applyingStreamingFloor(u2raw, previous: u1.widths, availableWidth: 381)
show("U1", u1); show("U2", u2)
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("table-planner-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let plannerFile = tmp.appendingPathComponent("planner.swift")
let mainFile = tmp.appendingPathComponent("main.swift")
try ("import Foundation\nimport CoreGraphics\n" + planner).write(to: plannerFile, atomically: true, encoding: .utf8)
try harness.write(to: mainFile, atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t")

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
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", plannerFile.path, mainFile.path, "-o", bin.path])
check("shipping planner compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("harness ran", rc == 0)

struct P { let widths: [Int]; let table: Int; let mode: String }
var plans: [String: P] = [:]
for line in out.split(separator: "\n") {
    let kv = line.split(separator: "=", maxSplits: 1)
    guard kv.count == 2 else { continue }
    let f = kv[1].split(separator: "|")
    guard f.count == 3 else { continue }
    plans[String(kv[0])] = P(widths: f[0].split(separator: ",").compactMap { Int($0) },
                             table: Int(f[1]) ?? -1, mode: String(f[2]))
}
func p(_ k: String) -> P { plans[k] ?? P(widths: [], table: -1, mode: "?") }
let widths: [(String, Int)] = [("se1", 287), ("se3", 343), ("shot", 369), ("i11", 381), ("promax", 398), ("land", 760), ("ipad", 1050)]
if let ff = out.split(separator: "\n").first(where: { $0.hasPrefix("FIRSTFAIL: ") && $0.count > 11 }) { print("  \(ff)") }

print("\n1. The screenshot table: the column with more text is wider")
for (label, w) in widths {
    let x = p("SHOT.\(label)").widths
    check("@\(w)pt: 项目 | 状态 = \(x)", x.count == 2 && x[1] > x[0])
}
let shot = p("SHOT.shot")
check("@369pt the table fits (no scroll) and fills the width: \(shot.widths) \(shot.mode)",
      shot.mode == "wrapped" && abs(shot.widths.reduce(0, +) - 369) <= 1)
check("…status column clearly wider (≥ 1.3× the item column)", Double(shot.widths[1]) >= 1.3 * Double(shot.widths[0]))
check("…item column stays readable (≥ 35% of 369 = 129)", shot.widths[0] >= 129)
check("landscape: wraps, the status column takes most of the room \(p("SHOT.land").widths)",
      p("SHOT.land").mode == "wrapped" && p("SHOT.land").widths[0] == 232 && p("SHOT.land").widths[1] == 528)
check("iPad: both fit on one line, spare width split 232:600 \(p("SHOT.ipad").widths)",
      p("SHOT.ipad").mode == "natural" && abs(Double(p("SHOT.ipad").widths[1]) / Double(p("SHOT.ipad").widths[0]) - 600.0 / 232.0) < 0.02)

print("\n2. Property test: 20 000 random tables × widths")
let prop = (out.split(separator: "\n").first { $0.hasPrefix("PROP=") } ?? "").dropFirst(5).split(separator: "|")[0].split(separator: ",").compactMap { Int($0) }
if prop.count == 7 {
    check("more text ⇒ never narrower (except a long word's minimum): \(prop[1]) violations", prop[1] == 0)
    check("non-scrolling tables fill the viewport exactly: \(prop[2]) violations in \(prop[5])", prop[2] == 0)
    check("widths within [hard min, natural]: \(prop[3]) violations", prop[3] == 0)
    check("the column at the right edge peeks ≥ 24pt when the column before can give: \(prop[4]) violations in \(prop[6])", prop[4] == 0)
    check("both regimes exercised (fit \(prop[5]), scroll \(prop[6]))", prop[5] > 1000 && prop[6] > 1000)
} else { check("property test output parsed", false) }

print("\n3. Regimes on the existing cases")
for (label, w) in widths {
    for t in ["A", "B", "C", "D", "W5", "OW"] {
        let x = p("\(t).\(label)")
        if x.mode != "scrolls" { check("\(t) @\(w)pt fits: sum \(x.widths.reduce(0, +)) ≈ \(w)", abs(x.widths.reduce(0, +) - w) <= x.widths.count) }
        else { check("\(t) @\(w)pt scrolls: every column ≤ 70% (\(Int(Double(w) * 0.7))) \(x.widths)", x.widths.allSatisfy { Double($0) <= Double(w) * 0.7 + 0.5 } && x.table > w) }
    }
}
check("Table A (3 prose columns) scrolls on a phone instead of three ~115pt columns", p("A.i11").mode == "scrolls")
check("…and its label column (180) is narrower than the prose columns \(p("A.i11").widths)", p("A.i11").widths[0] < p("A.i11").widths[1])
check("Table B on a phone: the short column keeps its content, the long one gets the rest \(p("B.i11").widths)",
      p("B.i11").widths[0] == 120 && p("B.i11").widths[1] == 261 && p("B.i11").mode == "wrapped")
check("Table C (tiny, equal cells) = equal thirds \(p("C.i11").widths)", Set(p("C.i11").widths).count == 1 && p("C.i11").mode == "natural")
check("Table D keeps its long words whole (col widths ≥ word) \(p("D.promax").widths)",
      p("D.promax").widths[0] >= 120 && p("D.promax").widths[1] >= 140 && p("D.promax").widths[2] >= 110)
check("one-word first column stays narrow \(p("OW.i11").widths)", p("OW.i11").widths[0] <= 90)
check("5 columns on a phone scroll with the next column peeking ≥ 24pt \(p("W5.i11").widths)", {
    let x = p("W5.i11").widths; var acc = 0
    for v in x { if acc + v > 381 { return 381 - acc >= 24 }; acc += v }
    return true
}())
check("iPad: Table A fits, prose columns wrap side by side \(p("A.ipad").widths)", p("A.ipad").mode == "wrapped")

print("\n4. Streaming: widths only grow; a table that fits stays within the viewport")
let s1 = p("S1").widths, s2 = p("S2").widths, s3 = p("S3").widths
check("header-only table fills the width \(s1)", s1.reduce(0, +) == 381)
check("row growth never shrinks a column \(s2) → \(s3)", zip(s2, s3).allSatisfy { $1 >= $0 })
let t2 = p("T2").widths
check("fit regime: floored widths still fit the viewport \(p("T1").widths) → \(t2)", t2.reduce(0, +) <= 382)
check("…and equal the fresh plan there \(p("T2raw").widths)", t2 == p("T2raw").widths)
check("scroll regime: no column shrinks \(p("U1").widths) → \(p("U2").widths)", zip(p("U1").widths, p("U2").widths).allSatisfy { $1 >= $0 })

print("\n5. Wiring in the shipping code")
check("computeLayout uses the planner", view.contains("var plan = TableColumnPlanner.plan(columns: measured, availableWidth: width)"))
check("old 5× cap is gone", !view.contains("min(width * 5, max(columnWidths[colIdx], requested))"))
check("streaming floor applied only to persisted, streamed layouts",
      view.contains("if persist, hasStreamingUpdates {") && view.contains("self.hasStreamingUpdates = true"))
check("streamed tables bypass the shared layout cache both ways",
      view.contains("if !hasStreamingUpdates, let shared = Self.sharedLayoutCache[sharedKey]")
      && view.contains("if !hasStreamingUpdates { Self.storeSharedLayout(layout, key: sharedKey) }"))
// [T-table-layout-true-width] The 25% HangFix reuse is gone; cross-width reuse
// now goes through TableLayoutReuse (see TableLayoutWidthTests), which keeps
// this guarantee.
check("layout reuse never makes a fitting table overflow",
      view.contains("return !(fitItsWidth && layoutTableWidth > width + 0.5)")
      && view.contains("TableLayoutReuse.canReuse(layoutWidth: cached.width, layoutTableWidth: cached.tableWidth, for: width)"))
check("cells are top-aligned (no centering left)", !view.contains("(rowHeight - textSize.height) / 2") && !view.contains("(rowHeight - ts.height) / 2"))
// [T-table-stream-row-height] The streaming row re-measures its own height.
check("update() re-measures rows whose text changed at the cached widths",
      view.contains("where rowIdx >= cachedCellChars.count || cachedCellChars[rowIdx] != current[rowIdx] {")
      && view.contains("let h = measuredRowHeight(rowIdx: rowIdx, row: row, columnWidths: cached.columnWidths)"))
check("a changed row height invalidates the attachment's layout",
      view.contains("self.needsLayoutInvalidation = structureChanged || contentGrew || rowHeightsChanged"))
check("computeLayout and update() share one row-height measurement",
      view.contains("measuredRowHeight(rowIdx: rowIdx, row: row, columnWidths: columnWidths)"))
check("the cell char snapshot is taken with the persisted layout",
      view.contains("cachedCellChars = Self.cellCharCounts(rows, colCount: colCount)"))
check("cell horizontal padding is 8pt (T-table-cell-padding-half), vertical stays 8pt",
      view.contains("static let cellPaddingH: CGFloat = 8\n    static let cellPaddingV: CGFloat = 8"))
check("link text view sized to its text", view.contains("tv.frame.size.height = min(textSize.height, max(0, rowHeight - Self.cellPaddingV))"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
