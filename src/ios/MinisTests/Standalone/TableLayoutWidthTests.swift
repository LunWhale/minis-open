#!/usr/bin/env swift
// [T-table-layout-true-width] A markdown table must be laid out for the width it
// renders at, and a cell height measured with one table layout must never be
// seeded onto another.
//
// Report (2026-09-29, session 7976E595): a reply with a 4-row, 3-column table
// had its last lines drawn under the next user bubble. The device log showed
// the cell self-size at 1690pt while the precalc for the same content read
// 1742pt, and the memo key ended in `:r0` (tables were not in the render
// signal). The screenshot's line breaks showed the table planned with 280pt
// columns, i.e. for ~401pt, although its text column is 369pt (258pt columns).
// SwiftUI measures every markdown cell at the inner 370pt and the outer 402pt
// width ([JitterFix]); the outer probe persisted a 401pt layout and the old
// "reuse any cached layout within 25%" rule served it at 369pt.
//
// [1] compiles the real `TableLayoutWidthCache` and `TableColumnPlanner` blocks
// out of Views/Chat/Markdown/Attachments/Table/TableLayoutPlanning.swift and
// checks the reuse rule, the per-width
// cache and why 32pt matters; [2] pins the wiring in the shipping sources.
//
// Run: swift TableLayoutWidthTests.swift   (needs swiftc)
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
guard let planner = between(view, "// BEGIN TableColumnPlanner", "// END TableColumnPlanner"),
      let cache = between(view, "// BEGIN TableLayoutWidthCache", "// END TableLayoutWidthCache") else {
    print("❌ planner / width-cache block not found"); exit(1)
}

let harness = #"""
func out(_ label: String, _ v: Any) { print("R \(label)=\(v)") }
let reuse = TableLayoutReuse.self
// Scroll-mode layouts are wider than their width (the incident table: 214+258+258).
out("incident401at369", reuse.canReuse(layoutWidth: 401, layoutTableWidth: 774, for: 369))
out("jitter369_5at369", reuse.canReuse(layoutWidth: 369.5, layoutTableWidth: 730, for: 369))
out("scroll371at369", reuse.canReuse(layoutWidth: 371, layoutTableWidth: 732, for: 369))
out("scroll370_5at369", reuse.canReuse(layoutWidth: 370.5, layoutTableWidth: 731, for: 369))
out("scroll372_5at369", reuse.canReuse(layoutWidth: 372.5, layoutTableWidth: 733, for: 369))
out("fit371at369", reuse.canReuse(layoutWidth: 371, layoutTableWidth: 371, for: 369))
out("fit369at371", reuse.canReuse(layoutWidth: 369, layoutTableWidth: 369, for: 371))
out("rotation397at899", reuse.canReuse(layoutWidth: 397, layoutTableWidth: 397, for: 899))

var c = TableWidthCache<String>(capacity: 3)
c.store(width: 369, tableWidth: 730, value: "L369")
c.store(width: 401, tableWidth: 774, value: "L401")
out("lookup369", c.lookup(369) ?? "nil")
out("lookup401", c.lookup(401) ?? "nil")
out("lookup370", c.lookup(370) ?? "nil")
out("lookup385", c.lookup(385) ?? "nil")
c.store(width: 369.2, tableWidth: 730, value: "L369b")
out("replacedSameWidth", "\(c.entries.count)|\(c.lookup(369) ?? "nil")")
c.store(width: 500, tableWidth: 900, value: "L500")
c.store(width: 600, tableWidth: 900, value: "L600")
out("evictsOldest", "\(c.entries.count)|\(c.lookup(401) ?? "nil")|\(c.lookup(600) ?? "nil")")
var nearest = TableWidthCache<String>(capacity: 4)
nearest.store(width: 367.5, tableWidth: 730, value: "far")
nearest.store(width: 369.5, tableWidth: 730, value: "near")
out("nearestWins", nearest.lookup(369) ?? "nil")
c.removeAll()
out("removeAll", c.lookup(600) ?? "nil")

// The incident table's columns (natural / widest unbreakable run, padding
// included), measured with the shipping rules: 32pt of width is a different plan.
let cols: [TableColumnPlanner.Column] = [
    .init(natural: 214, minUnbreakable: 41),
    .init(natural: 1773, minUnbreakable: 188),
    .init(natural: 841, minUnbreakable: 358),
]
let p369 = TableColumnPlanner.plan(columns: cols, availableWidth: 369)
let p401 = TableColumnPlanner.plan(columns: cols, availableWidth: 401)
out("plan369", p369.widths.map { Int($0.rounded()) })
out("plan401", p401.widths.map { Int($0.rounded()) })
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("table-width-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = [("blocks.swift", "import CoreGraphics\n" + planner + "\n" + cache), ("main.swift", "import CoreGraphics\n" + harness)]
for (name, text) in files { try text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
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

print("1. Reuse rule, per-width cache, and why 32pt matters (shipping blocks)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
check("TableLayoutWidthCache + TableColumnPlanner compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}
check("the incident: a 401pt layout is NOT served at 369pt", r["incident401at369"] == "false")
check("sub-point jitter shares a layout", r["jitter369_5at369"] == "true")
check("a scrolling table's layout is shared within 2pt", r["scroll371at369"] == "true" && r["scroll370_5at369"] == "true")
check("…but not beyond the tolerance", r["scroll372_5at369"] == "false")
check("a layout that fit its width is never reused narrower (columns would clip)", r["fit371at369"] == "false")
check("…but may be reused slightly wider", r["fit369at371"] == "true")
check("a rotation plans again", r["rotation397at899"] == "false")
check("the cache keeps a layout per width (369 and 401 side by side)", r["lookup369"] == "L369" && r["lookup401"] == "L401")
check("a jittered width finds its neighbour", r["lookup370"] == "L369")
check("a width between entries plans afresh", r["lookup385"] == "nil")
check("re-storing the same width replaces the entry", r["replacedSameWidth"] == "2|L369b")
check("capacity evicts the oldest entry", r["evictsOldest"] == "3|nil|L600")
check("the nearest reusable entry wins", r["nearestWins"] == "near")
check("removeAll empties the cache", r["removeAll"] == "nil")
check("the incident table plans 258pt columns at 369pt and 280pt at 401pt",
      r["plan369"] == "[214, 258, 258]" && r["plan401"] == "[214, 280, 280]")

print("\n2. Wiring")
let infra = source("Agent/MessageList/MessageListInfrastructure.swift")
let computeLayout = between(view, "func computeLayout(for width: CGFloat, persist: Bool = true) -> TableLayout {", "// MARK: - [T-ios-attachbounds-cold-cache] Shared layout cache helpers") ?? ""
check("the 25% near-width reuse is gone", !computeLayout.contains("relDelta < 0.25"))
check("computeLayout reuses the cached layout only per TableLayoutReuse",
      computeLayout.contains("TableLayoutReuse.canReuse(layoutWidth: cached.width, layoutTableWidth: cached.tableWidth, for: width)"))
check("…then the per-width cache, before the shared cache or a fresh plan",
      computeLayout.contains("if let kept = layoutsByWidth.lookup(width) {")
      && computeLayout.range(of: "layoutsByWidth.lookup(width)")!.lowerBound < computeLayout.range(of: "Self.sharedLayoutCache[sharedKey]")!.lowerBound)
check("shared-cache hits obey the same rule",
      computeLayout.contains("let shared = Self.sharedLayoutCache[sharedKey],\n           TableLayoutReuse.canReuse(layoutWidth: shared.width, layoutTableWidth: shared.tableWidth, for: width)"))
check("fresh and shared layouts are kept per width",
      computeLayout.contains("layoutsByWidth.store(width: width, tableWidth: tableWidth, value: layout)")
      && computeLayout.contains("layoutsByWidth.store(width: width, tableWidth: reused.tableWidth, value: reused)"))
check("changed content and a width change drop the per-width layouts",
      view.contains("refreshed row by row below and re-stored.\n        layoutsByWidth.removeAll()")
      && view.contains("cachedLayout = nil\n        layoutsByWidth.removeAll()\n        needsViewRebuild = true"))
check("SwiftUI measurements at a non-render width are flagged (nil proposal or width ≠ bounds)",
      view.contains("let isNonRenderWidth = proposal.width == nil\n            || (renderWidthNow > 0 && abs(width - renderWidthNow) >= 0.5)")
      && view.contains("if isNonRenderWidth { TableAttachment.nonRenderWidthMeasureDepth += 1 }\n        defer { if isNonRenderWidth { TableAttachment.nonRenderWidthMeasureDepth -= 1 } }"))
check("such a measurement is answered from the render-width layout, before any planning",
      computeLayout.contains("let isNonRenderWidthMeasure = !persist && Self.nonRenderWidthMeasureDepth > 0\n        if isNonRenderWidthMeasure, let cached = cachedLayout, !cached.columnWidths.isEmpty {")
      && computeLayout.range(of: "if isNonRenderWidthMeasure, let cached")!.lowerBound < computeLayout.range(of: "layoutsByWidth.lookup(width)")!.lowerBound)
check("…and whatever it does compute is never cached per width",
      computeLayout.components(separatedBy: "if !isNonRenderWidthMeasure {\n").count - 1 == 2)
check("attachmentBounds does not persist a layout during such a measurement",
      view.contains("let layout = computeLayout(for: heightWidth, persist: !isOversizedProbe && !isNonRenderWidth)"))
check("the memo key's render signal now includes each table's persisted layout height",
      view.contains("} else if let table = value as? TableAttachment {")
      && view.contains("total += table.persistedLayoutHeight")
      && view.contains("var persistedLayoutHeight: CGFloat { cachedLayout?.totalHeight ?? 0 }"))
check("[TableLayout] DEBUG log on every planned / shared layout",
      view.contains("\"[TableLayout] inst=") && view.contains("logTableLayout(layout, source: \"fresh\"")
      && view.contains("logTableLayout(reused, source: \"shared\""))
check("[TableCellShort] DEBUG check runs from the text view's layoutSubviews",
      view.contains("\"[TableCellShort] key=") && view.contains("#if DEBUG\n        reportTableCellShortIfNeeded()\n        #endif"))
check("[MemoSeed] DEBUG log where the seed skips the real measure",
      infra.contains("[MemoSeed] key=") && infra.contains("skipped systemLayoutSizeFitting"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
