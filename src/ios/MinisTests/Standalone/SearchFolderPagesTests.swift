#!/usr/bin/env swift
// [T-search-folder-pages] A search-expanded folder shows its matches 20 at a
// time; "Show N more" adds the next 20 until all are shown.
//
//   [1] searchFolderPage — pure: shown / remaining per page count
//       (15, 20, 21, 45 matches and the edges)
//   [2] tap-through: repeated "Show more" until exhausted
//   [3] card segments: the last visible member closes the card only when
//       nothing is left behind "Show more"
//   [4] source guards: reset points, memo key, gating on search results,
//       both list layouts, localization
//
// Run: swift SearchFolderPagesTests.swift
import Foundation

/// The home screen sources - Views/ContentView/ plus Views/Settings/SettingsSheet.swift
/// and AppearanceSettingsView.swift, formerly the single file ContentView.swift -
/// read as one text with the files in path order.
func contentViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/ContentView")
    var files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    files += ["Views/Settings/SettingsSheet.swift", "Views/Settings/AppearanceSettingsView.swift"]
        .map { ios.appendingPathComponent($0) }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

// MARK: - Port (byte-identical with Views/ContentView/ContentView+SessionList.swift, guarded in [4])

enum ContentView {
    static let searchFolderPageSize = 20

    // BEGIN searchFolderPage
    static func searchFolderPage(total: Int, pages: Int, pageSize: Int = searchFolderPageSize)
        -> (shown: Int, remaining: Int) {
        let shown = min(max(0, total), max(1, pages) * max(1, pageSize))
        return (shown, max(0, total) - shown)
    }
    // END searchFolderPage
}
func page(_ total: Int, _ pages: Int = 1) -> (Int, Int) {
    let p = ContentView.searchFolderPage(total: total, pages: pages)
    return (p.shown, p.remaining)
}
func eq(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 == b.0 && a.1 == b.1 }

// MARK: - [1] searchFolderPage

print("▶️  1. searchFolderPage — pure")
check("15 matches: all 15 shown, no Show more", eq(page(15), (15, 0)))
check("20 matches: all 20 shown, no Show more (exactly one page)", eq(page(20), (20, 0)))
check("21 matches: 20 shown, Show more for 1", eq(page(21), (20, 1)))
check("45 matches, page 1: 20 shown, 25 left", eq(page(45), (20, 25)))
check("45 matches, page 2: 40 shown, 5 left", eq(page(45, 2), (40, 5)))
check("45 matches, page 3: all 45, no Show more", eq(page(45, 3), (45, 0)))
check("45 matches, extra pages never overshoot", eq(page(45, 9), (45, 0)))
check("1 match", eq(page(1), (1, 0)))
check("0 matches (folder-name hit on an empty folder): nothing, no Show more", eq(page(0), (0, 0)))
check("40 matches, page 2: exactly exhausted", eq(page(40, 2), (40, 0)))
check("pages 0 or negative count as the first page", eq(page(45, 0), (20, 25)) && eq(page(45, -3), (20, 25)))
check("negative total is treated as empty", eq(page(-5), (0, 0)))
check("custom page size", {
    let p = ContentView.searchFolderPage(total: 7, pages: 2, pageSize: 3)
    return p.shown == 6 && p.remaining == 1
}())
check("page size 0 is treated as 1 (never shows nothing forever)", {
    let p = ContentView.searchFolderPage(total: 3, pages: 1, pageSize: 0)
    return p.shown == 1 && p.remaining == 2
}())

// MARK: - [2] tap-through

print("\n▶️  2. repeated Show more until exhausted")
for total in [15, 20, 21, 45, 100, 101] {
    var pages = 1
    var trail: [Int] = []
    var steps = 0
    while true {
        let p = ContentView.searchFolderPage(total: total, pages: pages)
        trail.append(p.shown)
        if p.remaining == 0 { break }
        // The row's label: "Show \(min(remaining, pageSize)) more (\(remaining) left)"
        let next = min(p.remaining, ContentView.searchFolderPageSize)
        pages += 1
        steps += 1
        if ContentView.searchFolderPage(total: total, pages: pages).shown != p.shown + next { trail.append(-1); break }
        if steps > 100 { break }
    }
    let expectedSteps = max(0, (total + 19) / 20 - 1)
    check("\(total) matches: \(expectedSteps) tap(s), grows by 20 each time, ends at \(total) — \(trail)",
          trail.last == total && steps == expectedSteps && !trail.contains(-1))
}

// MARK: - [3] card segments

print("\n▶️  3. card bottom segment")
struct G { var ids: [String]; var hiddenMatchCount: Int
    func isLastMemberRow(_ id: String) -> Bool { hiddenMatchCount == 0 && id == ids.last } }
check("nothing hidden: the last member closes the card", G(ids: ["a", "b"], hiddenMatchCount: 0).isLastMemberRow("b"))
check("matches hidden: the last member is a middle segment (Show more closes the card)",
      !G(ids: ["a", "b"], hiddenMatchCount: 3).isLastMemberRow("b"))
check("a non-last member is never the bottom", !G(ids: ["a", "b"], hiddenMatchCount: 0).isLastMemberRow("a"))

// MARK: - [4] source guards

print("\n▶️  4. source guards")
let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.upperBound..<r2.lowerBound])
}
let view = contentViewSource()
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
let appFn = between(view, "// BEGIN searchFolderPage", "// END searchFolderPage")
check("port is byte-identical with ContentView", !appFn.isEmpty && appFn == between(me, "// BEGIN searchFolderPage", "// END searchFolderPage"))
check("page size is 20", view.contains("static let searchFolderPageSize = 20"))
check("isLastMemberRow matches the port",
      view.contains("func isLastMemberRow(_ id: String) -> Bool { hiddenMatchCount == 0 && id == ids.last }"))

// Reset: every new result set, empty query, and leaving search start at page 1.
let schedule = between(view, "func scheduleSearch() {", "\n    }\n")
check("reset when the query is cleared", schedule.contains("searchMatchedFolderIds = []\n            searchFolderPages = [:]\n            return"))
check("reset when a new result set arrives (e.g. another keyword)",
      schedule.contains("searchFolderPages = [:]\n                searchMatchedIds = ids"))
check("reset when search is dismissed", between(view, "func dismissSearch() {", "\n    }\n").contains("searchFolderPages = [:]"))

// Grouping.
check("paging applies only while search results are on screen",
      view.contains("if searchResultsActive {\n                let page = Self.searchFolderPage(total: displayOrdered.count, pages: searchFolderPages[fid] ?? 1)\n                g.ids = displayOrdered.prefix(page.shown).map(\\.id)\n                g.hiddenMatchCount = page.remaining"))
check("header count still reports every match, not just the page", view.contains("g.totalCount = m.count"))
check("memo key includes the page state (only while searching)",
      between(view, "struct SidebarGroupsMemoKey: Equatable {", "}").contains("let searchFolderPages: [String: Int]")
      && view.contains("searchFolderPages: searchResultsActive ? searchFolderPages : [:],"))

// Rendering.
check("Show more row rendered in both list layouts, not in select mode",
      view.components(separatedBy: "if group.hiddenMatchCount > 0, !isSelecting {\n                        searchFolderShowMoreRow(group)").count - 1 == 2)
check("both layouts close the card via isLastMemberRow",
      view.contains("FolderMemberRowBackground(isLast: group.isLastMemberRow(session.id))")
      && view.contains("let isLast = group.isLastMemberRow(sessionId)")
      && !view.contains("== group.ids.last"))
let row = between(view, "private func searchFolderShowMoreRow(_ group: SidebarGroup) -> some View {", "\n    }\n")
check("a tap adds one page to THIS folder only", row.contains("searchFolderPages[fid, default: 1] += 1"))
check("the row is the card's bottom segment", row.contains(".listRowBackground(FolderMemberRowBackground(isLast: true))"))
check("label names the next page and what is left",
      row.contains("Text(\"Show \\(min(group.hiddenMatchCount, Self.searchFolderPageSize)) more (\\(group.hiddenMatchCount) left)\")"))
check("\"Show %lld more (%lld left)\" is in the string catalog",
      source("Localizable.xcstrings").contains("\"Show %lld more (%lld left)\" : {"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
