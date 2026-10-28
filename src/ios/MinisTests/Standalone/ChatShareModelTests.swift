#!/usr/bin/env swift
// [T-multi-select-share] Tests the pure share model (Views/Chat/ChatShareModel.swift,
// the BEGIN/END chat-share-model block) without a simulator: unit grouping, markdown
// table chunking, PDF page breaks, the long-image budget and canvas widths. Also pins
// the wiring: every "Copy Screenshot" menu entry became "Share…" and opens the picker.
//
// Run: swift ChatShareModelTests.swift   (needs swiftc)
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
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
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

let model = source("Views/Chat/ChatShareModel.swift")
guard let b = model.range(of: "// [T-multi-select-share] BEGIN chat-share-model"),
      let e = model.range(of: "// [T-multi-select-share] END chat-share-model") else {
    print("❌ model block not found"); exit(1)
}
let block = String(model[b.lowerBound..<e.upperBound])
// [T-share-fold-tools] The chat's own fold rule (pure part of ToolFoldPlanner),
// compiled next to the share model so the share rows are checked against it.
let plannerSource = source("Agent/MessageList/ToolFoldPlanner.swift")
guard let pe = plannerSource.range(of: "// END ToolFoldPlanner") else { print("❌ planner block not found"); exit(1) }
let planner = String(plannerSource[..<pe.lowerBound])

let tests = #"""
var fails = 0
func expect(_ label: String, _ cond: Bool) { print(cond ? "RESULT pass \(label)" : "RESULT fail \(label)"); if !cond { fails += 1 } }
func src(_ role: ChatShareUnitSource.Role, callback: Bool = false, hidden: Bool = false) -> ChatShareUnitSource {
    ChatShareUnitSource(id: UUID(), role: role, isCallback: callback, isHidden: hidden)
}

// Grouping
do {
    let u1 = src(.user), a1 = src(.assistant), a2 = src(.assistant), cb = src(.user, callback: true)
    let a3 = src(.assistant), div = src(.other), a4 = src(.assistant), q = src(.user, hidden: true)
    let bridge = src(.assistant, hidden: true), a5 = src(.assistant)
    let units = ChatShareUnits.group([u1, a1, a2, cb, a3, div, a4, bridge, a5, q])
    expect("grouping: kinds", units.map(\.kind) == [.user, .reply, .callback, .reply, .reply])
    expect("grouping: a reply spans consecutive assistant messages", units[1].messageIds == [a1.id, a2.id])
    expect("grouping: a callback card ends the reply and is its own unit", units[2].messageIds == [cb.id] && units[3].messageIds == [a3.id])
    expect("grouping: a divider ends a reply and is not selectable", !units.flatMap(\.messageIds).contains(div.id))
    expect("grouping: a hidden bridge does not split the reply around it", units[4].messageIds == [a4.id, a5.id])
    expect("grouping: queued messages are not selectable", !units.flatMap(\.messageIds).contains(q.id))
    expect("grouping: lookup by any message of the unit", ChatShareUnits.unit(containing: a2.id, in: units)?.id == a1.id)
    expect("grouping: empty chat has no units", ChatShareUnits.group([]).isEmpty)
}

// Cells
do {
    let u = src(.user), a1 = src(.assistant), a2 = src(.assistant), cb = src(.user, callback: true)
    let units = ChatShareUnits.group([u, a1, a2, cb])
    let t1 = UUID(), tool = UUID(), info = UUID(), empty = UUID(), think = UUID(), t2 = UUID()
    let blocks: [UUID: [ChatShareBlockSource]] = [
        a1.id: [.init(id: t1, kind: .text, isEmpty: false), .init(id: tool, kind: .tool, isEmpty: false),
                .init(id: info, kind: .hidden, isEmpty: false), .init(id: empty, kind: .text, isEmpty: true)],
        a2.id: [.init(id: think, kind: .thinking, isEmpty: false), .init(id: t2, kind: .text, isEmpty: false)],
    ]
    let cells = ChatShareCells.cells(units: units, blocks: blocks, errors: [a2.id])
    expect("cells: one row per piece, in order", cells.map(\.kind) == [.user, .text, .tool, .thinking, .text, .note, .callback])
    expect("cells: info and empty blocks are not rows", !cells.contains { $0.blockId == info || $0.blockId == empty })
    expect("cells: a reply's cells share its unit", Set(cells[1...5].map(\.unitId)) == [a1.id])
    expect("cells: ids are unique", Set(cells.map(\.id)).count == cells.count)

    let round = ChatShareCells.roundSelection(unit: a1.id, in: cells)
    expect("round: long-pressing the reply selects everything in the round (text, tools, thinking, error, callback)",
           round == Set(cells.map(\.id)))
    expect("round: long-pressing the user message selects the same round",
           ChatShareCells.roundSelection(unit: u.id, in: cells) == round)
    expect("round: none without a message", ChatShareCells.roundSelection(unit: nil, in: cells).isEmpty)
    let u2 = src(.user), a3 = src(.assistant)
    let units2 = ChatShareUnits.group([u, a1, u2, a3])
    let blocks2: [UUID: [ChatShareBlockSource]] = [
        a1.id: [.init(id: UUID(), kind: .text, isEmpty: false)],
        a3.id: [.init(id: UUID(), kind: .text, isEmpty: false)],
    ]
    let cells2 = ChatShareCells.cells(units: units2, blocks: blocks2, errors: [])
    expect("round: stops at the next user message",
           ChatShareCells.roundSelection(unit: a1.id, in: cells2) == Set([cells2[0].id, cells2[1].id]))
    expect("round: a reply before any user message starts its own round",
           ChatShareCells.roundSelection(unit: units2[1].id, in: [cells2[1]]) == Set([cells2[1].id]))

    let below = ChatShareCells.setBelow(cells[3].id, in: cells, selected: [cells[0].id], on: true)
    expect("select below: that row and everything after, earlier picks kept",
           below == Set([cells[0].id] + cells[3...].map(\.id)))
    expect("deselect below", ChatShareCells.setBelow(cells[4].id, in: cells, selected: below, on: false)
           == Set([cells[0].id, cells[3].id]))

    let groups = ChatShareCells.renderGroups(cells, selected: [cells[0].id, cells[1].id, cells[4].id, cells[6].id])
    expect("groups: selected pieces of one reply render together, skipping unselected tool calls",
           groups.map { $0.map(\.kind) } == [[.user], [.text, .text], [.callback]])
}

// Chunking
do {
    let md = """
    Intro line.

    | Name | Count |
    | --- | ---: |
    | a | 1 |
    | b | 2 |

    Between.
    ```
    | not | a table |
    | --- | --- |
    ```
    Tail
    """
    let chunks = ChatShareMarkdownChunker.split(md)
    expect("chunk: prose / table / prose", chunks.map(\.isTable) == [false, true, false])
    expect("chunk: table keeps header, separator and rows", chunks[1].text.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 4)
    expect("chunk: a table chunk ends with a newline (its last row is not the document's last line)", chunks[1].text.hasSuffix("|\n"))
    expect("chunk: a table inside a code fence stays prose", chunks[2].text.contains("| not | a table |"))
    expect("chunk: no table, one chunk", ChatShareMarkdownChunker.split("just text\nmore").map(\.isTable) == [false])
    expect("chunk: separator forms", ChatShareMarkdownChunker.isSeparator("|:-:|--:|") && ChatShareMarkdownChunker.isSeparator("--- | ---")
        && !ChatShareMarkdownChunker.isSeparator("| a | b |") && !ChatShareMarkdownChunker.isSeparator("---x|---"))
    expect("chunk: leading table", ChatShareMarkdownChunker.split("|a|b|\n|-|-|\n|1|2|").map(\.isTable) == [true])
}

// Geometry (adaptive tables)
do {
    expect("geometry: table width = natural + 2, at least the reading width",
           ChatShareGeometry.tableWidth(natural: 900, contentWidth: 382, base: 414) == 902
           && ChatShareGeometry.tableWidth(natural: 200, contentWidth: 382, base: 414) == 382)
    expect("geometry: phone pages cap at 1000pt (row = table + padding)",
           ChatShareGeometry.tableWidth(natural: 9000, contentWidth: 382, base: 414) == 1000 - ChatShareGeometry.rowPadding
           && ChatShareGeometry.canvasWidth(base: 414, tableRowWidths: [934, 5000]) == 1000)
    expect("geometry: iPad pages get a proportionally wider cap",
           ChatShareGeometry.maxCanvasWidth(base: 1024) > 1024 && ChatShareGeometry.maxCanvasWidth(base: 1024) <= 1500)
    expect("geometry: no tables → reading width", ChatShareGeometry.canvasWidth(base: 414, tableRowWidths: []) == 414)
}

// Pagination
do {
    var c = ChatSharePagination.Cursor()
    let s1 = ChatSharePagination.place(height: 300, breaks: [], pageHeight: 1000, gap: 20, cursor: &c)
    expect("page: first unit at top", s1 == [.init(page: 0, unitY: 0, height: 300, pageY: 0)] && c.y == 300)
    let s2 = ChatSharePagination.place(height: 600, breaks: [], pageHeight: 1000, gap: 20, cursor: &c)
    expect("page: next unit after the gap", s2 == [.init(page: 0, unitY: 0, height: 600, pageY: 320)] && c.y == 920)
    let s3 = ChatSharePagination.place(height: 500, breaks: [], pageHeight: 1000, gap: 20, cursor: &c)
    expect("page: a unit that does not fit moves to a new page whole", s3 == [.init(page: 1, unitY: 0, height: 500, pageY: 0)])

    var t = ChatSharePagination.Cursor()
    let tall = ChatSharePagination.place(height: 2500, breaks: [400, 950, 1200, 1890, 2300], pageHeight: 1000, gap: 20, cursor: &t)
    expect("page: tall unit cut at the lowest break in each page",
           tall.map(\.unitY) == [0, 950, 1890] && tall.map(\.height) == [950, 940, 610] && tall.map(\.page) == [0, 1, 2])
    expect("page: cursor after a split is on the last page", t == .init(page: 2, y: 610))

    var h = ChatSharePagination.Cursor()
    let hard = ChatSharePagination.place(height: 2100, breaks: [100], pageHeight: 1000, gap: 0, cursor: &h)
    expect("page: no usable break → hard cut at the page edge", hard.map(\.height) == [1000, 1000, 100])

    var p = ChatSharePagination.Cursor(page: 0, y: 700)
    let rest = ChatSharePagination.place(height: 1800, breaks: [260, 1100, 1700], pageHeight: 1000, gap: 0, cursor: &p)
    expect("page: tall unit starts on the current page when a break fits the remainder",
           rest.first == .init(page: 0, unitY: 0, height: 260, pageY: 700))
    var q = ChatSharePagination.Cursor(page: 0, y: 700)
    let fresh = ChatSharePagination.place(height: 1800, breaks: [1000], pageHeight: 1000, gap: 0, cursor: &q)
    expect("page: without a break in the remainder, a tall unit starts on a new page",
           fresh.first == .init(page: 1, unitY: 0, height: 1000, pageY: 0))
    var big = ChatSharePagination.Cursor(page: 0, y: 250)
    let split = ChatSharePagination.place(height: 900, breaks: [300, 600, 700], pageHeight: 1000, gap: 0, cursor: &big)
    expect("page: with most of the page left, a unit that fits a page is split at a break, not moved",
           split.first == .init(page: 0, unitY: 0, height: 700, pageY: 250) && split.count == 2
           && split.reduce(0) { $0 + $1.height } == 900)
    var small = ChatSharePagination.Cursor(page: 0, y: 800)
    let moved = ChatSharePagination.place(height: 900, breaks: [100, 150], pageHeight: 1000, gap: 0, cursor: &small)
    expect("page: with little of the page left, it still moves whole", moved == [.init(page: 1, unitY: 0, height: 900, pageY: 0)])
    expect("page: slices cover the unit exactly once",
           tall.reduce(0) { $0 + $1.height } == 2500 && rest.reduce(0) { $0 + $1.height } == 1800)
}

// Height estimate
do {
    let short = [ChatShareEstimateInput(kind: .user, text: "你好"), ChatShareEstimateInput(kind: .text, text: "好的。")]
    let shortPts = ChatShareHeightEstimate.points(short, width: 414)
    expect("estimate: a short exchange is a few hundred points", shortPts > 100 && shortPts < 400)
    expect("estimate: a short exchange fits one image", !ChatShareHeightEstimate.tooTallForImage(points: shortPts))
    let para = String(repeating: "这是一段很长的中文回复内容。", count: 40)
    let long = Array(repeating: ChatShareEstimateInput(kind: .text, text: para), count: 60)
    let longPts = ChatShareHeightEstimate.points(long, width: 414)
    expect("estimate: 60 long CJK paragraphs pass 50,000 px at 3x", ChatShareHeightEstimate.tooTallForImage(points: longPts))
    expect("estimate: the iPad width wraps less", ChatShareHeightEstimate.points(long, width: 1024) < longPts)
    let table = (["| a | b |", "|---|---|"] + Array(repeating: "| x | y |", count: 10)).joined(separator: "\n")
    let tablePts = ChatShareHeightEstimate.height(of: .init(kind: .text, text: table), contentWidth: 382)
    expect("estimate: a table counts its rows (11 incl. header), not its separator", tablePts == 11 * 44)
    expect("estimate: tools and thinking are fixed rows",
           ChatShareHeightEstimate.height(of: .init(kind: .tool, text: String(repeating: "x", count: 5000)), contentWidth: 382) == 36)
}

// [T-share-fold-tools] Folded tool runs
do {
    let u = src(.user), a = src(.assistant)
    let units = ChatShareUnits.group([u, a])
    // think · t1 · note · t2 · reply · t3 (unfinished-looking: alone) · reply2
    let think = UUID(), t1 = UUID(), note = UUID(), t2 = UUID(), reply = UUID(), t3 = UUID(), reply2 = UUID()
    let ids = [think, t1, note, t2, reply, t3, reply2]
    let kinds: [ChatShareBlockSource.Kind] = [.thinking, .tool, .text, .tool, .text, .tool, .text]
    let blocks: [UUID: [ChatShareBlockSource]] = [a.id: zip(ids, kinds).map { .init(id: $0, kind: $1, isEmpty: false) }]
    // The chat's plan over the same message, mapped the way ChatExportContent maps it.
    let inputs: [ToolFoldPlanner.Input] = [.thinking, .tool(.succeeded), .text(isEmpty: false), .tool(.failed),
                                           .text(isEmpty: false), .tool(.succeeded), .text(isEmpty: false)]
    let marked = ToolFoldPlanner.markingNotes(inputs) { $0 == 2 }  // only the remark is one line
    let groups = ToolFoldPlanner.plan(marked, enabled: true)
    let folds = groups.map { g in
        ChatShareFold(memberIds: Array(ids[g.range]), toolCount: g.toolCount, failedCount: g.failedCount,
                      cancelledCount: g.cancelledCount, duration: 9)
    }
    expect("fold: the chat folds lead thinking + 2 tools + the remark between them (not the lone third tool)",
           groups.count == 1 && groups[0].range == 0...3 && groups[0].toolCount == 2 && groups[0].failedCount == 1)
    let plain = ChatShareCells.cells(units: units, blocks: blocks, errors: [])
    let folded = ChatShareCells.cells(units: units, blocks: blocks, errors: [], folds: [a.id: folds])
    expect("fold: unfolded, every block is its own row",
           plain.map(\.kind) == [.user, .thinking, .tool, .text, .tool, .text, .tool, .text])
    expect("fold: folded, the run is ONE row where the chat shows it, the rest unchanged",
           folded.map(\.kind) == [.user, .toolGroup, .text, .tool, .text])
    let row = folded[1]
    expect("fold: the row carries the chat's counts and summed time",
           row.fold?.toolCount == 2 && row.fold?.failedCount == 1 && row.fold?.duration == 9
           && row.blockId == think && row.unitId == a.id)
    expect("fold: ids stay unique and differ from a block row's", Set(folded.map(\.id)).count == folded.count
           && !plain.map(\.id).contains(row.id))
    expect("fold: the row covers exactly its blocks", row.coveredIds == [think, t1, note, t2].map { "\(a.id.uuidString)/\($0.uuidString)" })
    expect("fold: no fold for a message without runs", ChatShareCells.cells(units: units, blocks: blocks, errors: [], folds: [:]) == plain)

    // Selection survives folding / unfolding.
    let toolCell = plain[2].id, replyCell = plain[5].id
    let afterFold = ChatShareCells.remapSelection([plain[0].id, toolCell, replyCell], from: plain, to: folded)
    expect("remap: a selected tool selects its folded row; other rows keep theirs",
           afterFold == Set([folded[0].id, row.id, folded[2].id]))
    let afterUnfold = ChatShareCells.remapSelection([row.id], from: folded, to: plain)
    expect("remap: a selected folded row selects every block it stood for",
           afterUnfold == Set(plain[1...4].map(\.id)))
    expect("remap: nothing selected stays nothing", ChatShareCells.remapSelection([], from: folded, to: plain).isEmpty)
    let round = ChatShareCells.roundSelection(unit: a.id, in: folded)
    expect("round: opening on the reply selects the folded row with it", round.contains(row.id) && round.count == folded.count)
    expect("groups: a folded row renders in its reply's group",
           ChatShareCells.renderGroups(folded, selected: [row.id, folded[2].id]).map { $0.map(\.kind) } == [[.toolGroup, .text]])
    expect("estimate: a folded row is one short line",
           ChatShareHeightEstimate.height(of: .init(kind: .toolGroup, text: ""), contentWidth: 350) == 30)
}

// [T-share-hide-title] Long-image layout and height estimate with / without the title
do {
    let with = ChatShareImageLayout.place(header: 60, groups: [100, 200], margin: 8, headerGap: 8, unitGap: 18)
    expect("layout: header at the top margin, then 8pt, then groups 18pt apart",
           with.ys == [8, 76, 194] && with.height == 8 + 60 + 8 + 100 + 18 + 200 + 8)
    expect("layout: with the header it matches the old formula (2m + parts + gaps + 8)",
           with.height == 8 * 2 + (60 + 100 + 200) + 18 * CGFloat(max(3 - 2, 0)) + 8)
    let without = ChatShareImageLayout.place(header: nil, groups: [100, 200], margin: 8, headerGap: 8, unitGap: 18)
    expect("layout: hidden title — the first group starts at the top margin, no header gap",
           without.ys == [8, 126] && without.height == 8 + 100 + 18 + 200 + 8)
    expect("layout: hiding the title saves exactly the header and its gap",
           with.height - without.height == 60 + 8)
    let one = ChatShareImageLayout.place(header: nil, groups: [50], margin: 8, headerGap: 8, unitGap: 18)
    expect("layout: one group, no header: margin + group + margin", one.ys == [8] && one.height == 66)
    let inputs = [ChatShareEstimateInput(kind: .user, text: "hi"), ChatShareEstimateInput(kind: .tool, text: "")]
    let est = ChatShareHeightEstimate.points(inputs, width: 390)
    let estNo = ChatShareHeightEstimate.points(inputs, width: 390, includesHeader: false)
    expect("estimate: the default still counts the header (callers unchanged)",
           est == ChatShareHeightEstimate.points(inputs, width: 390, includesHeader: true))
    expect("estimate: without the title it drops the header allowance, keeps the margins",
           abs((est - estNo) - (ChatShareHeightEstimate.headerHeight - ChatShareHeightEstimate.marginsHeight)) < 0.001 && estNo > 0)
    expect("estimate: rows are estimated the same either way",
           ChatShareHeightEstimate.points([], width: 390, includesHeader: false) == ChatShareHeightEstimate.marginsHeight)
}

// Image budget
do {
    expect("budget: normal image at 3x", ChatShareImageBudget.scale(width: 470, height: 10_000) == 3)
    let s = ChatShareImageBudget.scale(width: 470, height: 20_000)
    expect("budget: long image steps down but stays >= 1x", s != nil && s! < 3 && s! >= 1)
    expect("budget: beyond 1x → nil (share as PDF)", ChatShareImageBudget.scale(width: 470, height: 200_000) == nil)
    expect("budget: never taller than 50,000 px", ChatShareImageBudget.scale(width: 400, height: 30_000).map { $0 * 30_000 <= 50_000 } ?? true
           && ChatShareImageBudget.scale(width: 400, height: 60_000) == nil)
}
exit(fails == 0 ? 0 : 1)
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chat-share-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try ("import Foundation\nimport CoreGraphics\n" + block + "\n" + planner).write(to: tmp.appendingPathComponent("model.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\nimport CoreGraphics\n" + tests).write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
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

print("1. Share model (shipping block)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", tmp.appendingPathComponent("model.swift").path,
                                         tmp.appendingPathComponent("main.swift").path, "-o", bin.path])
check("model block + tests compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (_, out) = run(bin.path, [])
for line in out.split(separator: "\n") where line.hasPrefix("RESULT") {
    let pass = line.hasPrefix("RESULT pass")
    check(String(line.dropFirst(pass ? 12 : 12)), pass)
}

print("\n2. Wiring")
let menus = (["Views/Chat/ChatMessageViews.swift"]
             .map(source) + [messageListV3Source(), markdownModuleSource()]).joined()
check("no menu still offers Copy Screenshot", !menus.contains("AppLocalized(\"Copy Screenshot\")"))
check("user, reply, footer and selection menus offer Share Chat…",
      menus.components(separatedBy: "Label(AppLocalized(\"Share Chat…\"), systemImage: \"square.and.arrow.up\")").count - 1 >= 4
      && menus.contains("title: AppLocalized(\"Share Chat…\"),"))
let list = messageListV3Source()
check("the list's Share… opens the picker for that message",
      list.contains("self?.onShareMessages?(message.id)"))
let chat = chatViewSource()
check("long-press and the … menu open the same picker",
      chat.contains("onShareMessages: { messageId in openSharePicker(selecting: messageId) }")
      && chat.contains("onShare: { openSharePicker(selecting: nil) }")
      && chat.contains("coordinator.parent.onShare()"))
check("the picker is built from the grouping above",
      chat.contains("ChatShareUnits.group(messages.map(ChatShareUnitSource.init(message:)))"))
let renderer = source("Views/Chat/ChatExportRenderer.swift")
check("text is drawn under the export's own appearance (dark app, light export)",
      renderer.contains("root.traitCollection.performAsCurrent"))
check("adaptive tables use the measured natural width, not a probe",
      renderer.contains(".naturalTableWidth()") && markdownModuleSource().contains("func naturalTableWidth() -> CGFloat"))
check("the long image draws text as glyphs too (sharp at 3x), not the views' 2x bitmaps",
      renderer.components(separatedBy: "drawVector(laid.host.view, in:").count - 1 >= 2)

// [T-share-fold-tools]
let picker = source("Views/Chat/ChatShareSelectionView.swift")
// [T-share-hide-title] [T-share-title-toggle] The title on/off is an option of the
// rendered result: it sits in the preview's control strip, not in the picker.
// [T-share-opts-not-remembered] Like width / tables / appearance, not remembered:
// every share opens with the title shown; earlier builds' stored keys are purged.
check("Title toggle: in the preview's control strip (Title: Shown / Hidden), not remembered, default shown",
      picker.contains("@State private var hideHeader = false")
      && !picker.contains("@AppStorage(\"chatShare.hideTitle\")")
      && picker.contains("let titleLabel = String(format: AppLocalized(\"Title: %@\"),")
      && picker.contains("hideHeader ? AppLocalized(\"Hidden\") : AppLocalized(\"Shown\"))")
      && picker.contains("controlItem(icon: hideHeader ? \"rectangle\" : \"rectangle.topthird.inset.filled\","))
check("…and no longer in the message picker",
      !picker.contains("AppLocalized(\"Hide Title\")") && !picker.contains("private var hideTitle")
      && !picker.contains("hideHeader: hideTitle,"))
check("…reaches the render key, export options and the per-title height estimate",
      picker.contains("adaptiveTables: key.adaptiveTables, hideHeader: key.hideHeader)")
      && picker.contains("includesHeader: !hidden)")
      && picker.contains("estimatedTooTall[EstimateKey(wide: wideLayout, hideHeader: hideHeader)]"))
check("the renderer skips the header in both formats and lays the image out with ChatShareImageLayout",
      renderer.contains("let header = options.hideHeader ? nil")
      && renderer.contains("if let header { try await renderPart(header, sink: nil) }")
      && renderer.contains("if let header {\n            let head = await layOut(header, width: canvas, sink: nil)")
      && renderer.contains("let placement = ChatShareImageLayout.place(")
      && !renderer.contains("+ Self.unitGap * CGFloat(max(parts.count - 2, 0)) + 8"))
check("a hidden title stays out of the file: name, PDF metadata and page footer",
      renderer.contains("let fileTitle = options.hideHeader ? \"\" : title")
      && renderer.contains("if !title.isEmpty { infoDict[kCGPDFContextTitle as String] = title }")
      && renderer.contains("(title.isEmpty ? \"\\(openPage + 1)\" : \"\\(title) · \\(openPage + 1)\")"))
let shareModelSrc = source("Views/Chat/ChatShareModel.swift")
check("none of the four preview options (width / tables / appearance / title) is stored",
      !picker.contains("@AppStorage(\"chatShare.wideLayout\")") && !picker.contains("@AppStorage(\"chatShare.hideTitle\")")
      && picker.contains("@State private var wideLayout = ChatShareDefaults.wideLayoutForDevice") && picker.contains("@State private var adaptiveTables = false")
      && picker.contains("@State private var darkChoice: Bool?"))
check("width starts at the device's own: iPad width on iPad / Mac, phone width on iPhone",
      picker.contains("static var wideLayoutForDevice: Bool {\n        let idiom = UIDevice.current.userInterfaceIdiom\n        return idiom == .pad || idiom == .mac\n    }"))
check("keys earlier builds stored for share options are purged when the preview opens",
      shareModelSrc.contains("static let keys = [\"chatShare.hideTitle\", \"chatShare.wideLayout\", \"chatShare.fullWidthTables\",")
      && shareModelSrc.contains("\"chatShare.hideTools\", \"chatShare.includeToolCalls\", \"chatShare.includeThinking\"]")
      && picker.contains("// [T-share-opts-not-remembered] Drop values earlier builds stored.\n                ChatShareLegacyKeys.purge()"))
check("debug render accepts hideHeader", renderer.contains("options.hideHeader = params[\"hideHeader\"] as? Bool ?? false"))
let plannerFile = source("Agent/MessageList/ToolFoldPlanner.swift")
check("ONE fold rule: the chat list and the share export both use ToolFoldPlanner.foldedRuns",
      list.contains("let folded = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)))")
      && renderer.contains("let runs = ToolFoldPlanner.foldedRuns(in: Array(m.blocks.prefix(horizon)))")
      && plannerFile.contains("static func foldedRuns(in blocks: [AssistantBlock]) -> [FoldedRun] {\n        plan(inputs(for: blocks), enabled: true)"))
check("…with the same fold horizon for a reply still being written",
      list.contains("ToolFoldPlanner.foldHorizon(for: message, runningMessageId: runningId,")
      && renderer.contains("ToolFoldPlanner.foldHorizon(for: m, runningMessageId: runningMessageId,")
      && chat.contains("runningMessageId: vm.toolFoldRunningMessageId,\n                                             separators: vm.toolFoldSeparators)"))
check("the folded row is drawn with the chat's own ToolGroupRowView, closed",
      renderer.contains("ToolGroupRowView(firstBlockId: first, toolCount: fold.toolCount,")
      && renderer.contains("duration: fold.duration, isExpanded: false)"))
check("\"Hide Tools\" is gone; \"Fold Tools\" / \"Expand Tools\" toggles folding, starting as the chat does",
      !picker.contains("Hide Tools") && !picker.contains("hideTools")
      && picker.contains("floatingLabel(foldTools ? AppLocalized(\"Expand Tools\") : AppLocalized(\"Fold Tools\"),")
      && chat.contains("let startsFolded = ToolFoldPlanner.isEnabled"))
check("folding keeps the selection; Hide Thinking unchanged",
      picker.contains("selection = ChatShareCells.remapSelection(selection, from: before, to: allCells)")
      && picker.contains("floatingLabel(hideThinking ? AppLocalized(\"Show Thinking\") : AppLocalized(\"Hide Thinking\"),"))
check("the preview renders the rows of the current fold state",
      picker.contains("groups: ChatShareCells.renderGroups(allCells, selected: selection),"))
let catalog = source("Localizable.xcstrings")
for key in ["Fold Tools", "Expand Tools", "Folded", "Expanded"] {
    let entry = catalog.range(of: "\n    \"\(key)\" : {").map { r -> Substring in
        let next = catalog.range(of: "\n    \"", range: r.upperBound..<catalog.endIndex)?.lowerBound ?? catalog.endIndex
        return catalog[r.upperBound..<next]
    } ?? ""
    let locales = ["de", "es", "fil", "fr", "hr", "id", "ja", "ko", "ms", "pl", "pt-BR", "ro", "ru", "th", "tr", "zh-Hans", "zh-Hant"]
    check("\"\(key)\" in all 18 locales", !entry.isEmpty && locales.allSatisfy { entry.contains("\"\($0)\" : {") })
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
