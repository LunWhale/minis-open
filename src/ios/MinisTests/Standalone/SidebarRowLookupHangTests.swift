#!/usr/bin/env swift
// [T-sidebar-row-lookup-miss] + [T-hang-suspend-gap] + [T-home-list-perf-diag] + [T-main-stall-diag]
//
// Field hang reports 2026-10-03 (1.15 (8), iPhone18,4, ~4,700 sessions):
//   - 04:46:24, 2 s after launch: main thread 2-3 s in ContentView.sessionForRow
//     → ChatSession initializeWithCopy / destroy. Rows that missed the id cache
//     (rebuilt only in `.onChange(of: sessions)`, after the first render pass)
//     re-derived and scanned the whole list per row.
//   - "1095217ms" / "55848ms" hangs whose span covered the app being suspended:
//     HangDetector measured with mach_continuous_time and counted suspension.
//
// Compiles the shipped SessionRowLookupMemo + HomeListPerf out of
// Views/ContentView/ContentView+SidebarGrouping.swift with a stub ChatSession,
// SidebarGroup and AppLogger.
//
// Run: swift SidebarRowLookupHangTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let grouping = source("Views/ContentView/ContentView+SidebarGrouping.swift")
let contentView = source("Views/ContentView/ContentView.swift")
let hang = source("Debug/HangDetector.m")
let sessionList = source("Views/ContentView/ContentView+SessionList.swift")
let rowsFile = source("Views/ContentView/Sidebar/SessionListRows.swift")
let layout = source("Views/ContentView/ContentView+Layout.swift")

guard let start = grouping.range(of: "final class SessionRowLookupMemo {") else {
    print("❌ SessionRowLookupMemo not found"); exit(1)
}
let memoSource = String(grouping[start.lowerBound...])

let harness = """
import Foundation
struct ChatSession { var id: String; var title: String; var lastMessage: String?; var modelId: String; var category: String?; var updatedAt: Date }
struct SidebarGroup { var ids: [String] }
struct AppLogger { let category: String; func info(_ m: String) {} }
enum HangDetector { static var marks: [String] = []; static func mark(_ s: String) { marks.append(s) } }
\(memoSource)
func R(_ k: String, _ v: Any) { print("R \\(k)=\\(v)") }
// Hooks first: the memo checks below already feed HomeListPerf.
var lines: [String] = []
var timers: [() -> Void] = []
HomeListPerf.emit = { lines.append($0) }
HomeListPerf.schedule = { _, work in timers.append(work) }
func make(_ n: Int) -> [ChatSession] {
    (0..<n).map { ChatSession(id: "S\\($0)", title: "title \\($0) " + String(repeating: "x", count: 40), lastMessage: "last message " + String(repeating: "y", count: 120), modelId: "m", category: nil, updatedAt: Date()) }
}
var sessions = make(4713)
let memo = SessionRowLookupMemo()
R("found", memo.session("S42", in: sessions)?.title.hasPrefix("title 42") ?? false)
R("missing", memo.session("nope", in: sessions) == nil)
// New array (refresh) -> re-indexed.
sessions = make(10)
R("afterReplaceOld", memo.session("S42", in: sessions) == nil)
R("afterReplaceNew", memo.session("S3", in: sessions)?.id ?? "nil")
// In-place edit keeps count/storage: still returns the CURRENT value.
sessions[3].title = "edited"
R("inPlaceEdit", memo.session("S3", in: sessions)?.title ?? "nil")
// Reorder without count change (new storage) -> correct element.
sessions.swapAt(0, 9)
R("afterSwap", memo.session("S0", in: sessions)?.id ?? "nil")
// Duplicate ids: first wins (same as Dictionary(uniquingKeysWith: first)).
var dup = make(3); dup.append(ChatSession(id: "S1", title: "second", lastMessage: nil, modelId: "", category: nil, updatedAt: Date()))
R("dupFirst", memo.session("S1", in: dup)?.title.hasPrefix("title 1") ?? false)

// Cost of one render pass where every row misses: old per-row scan vs memo.
let big = make(4713)
let rows = Array(big.prefix(60)).map(\\.id)   // rows the List materialises for one screen + prefetch
var t0 = Date()
var hits = 0
for id in rows { if big.filter({ _ in true }).first(where: { $0.id == id }) != nil { hits += 1 } }
let oldMs = Date().timeIntervalSince(t0) * 1000
let memo2 = SessionRowLookupMemo()
t0 = Date()
var hits2 = 0
for id in rows { if memo2.session(id, in: big) != nil { hits2 += 1 } }
let newMs = Date().timeIntervalSince(t0) * 1000
R("oldMs", Int(oldMs)); R("newMs", Int(newMs)); R("hits", hits == rows.count && hits2 == rows.count)

// HomeListPerf aggregation: lines captured, the window timer held by the test.
// Let the window the memo checks opened run out, as its timer would.
while !timers.isEmpty { timers.removeFirst()() }
lines.removeAll()
let ids = big.map(\\.id)
let groups = [SidebarGroup(ids: Array(ids.prefix(13))), SidebarGroup(ids: Array(ids.dropFirst(13)))]
// A pass that walks every row through the memo (launch: cache empty).
let walkMemo = SessionRowLookupMemo()
var start = HomeListPerf.passBegin()
HomeListPerf.passEnd(site: "sidebar", start: start, groups: groups, sessions: big.count)
for id in ids {
    let t = HomeListPerf.clock()
    let hit = walkMemo.session(id, in: big)
    HomeListPerf.row(hit == nil ? .missing : .memo, since: t)
}
// A second pass that resolves 12 visible rows from the cache.
start = HomeListPerf.passBegin()
HomeListPerf.passEnd(site: "sidebar", start: start, groups: groups, sessions: big.count)
for _ in 0..<12 { HomeListPerf.row(.cache, since: HomeListPerf.clock()) }
R("timerScheduledOnce", timers.count == 1)
R("walkOutlier", lines.contains { $0.contains("⚠️ row walk sidebar: one pass resolved 4713 of 4713 rows") })
timers.removeFirst()()
let summary = lines.last ?? ""
R("summaryPasses", summary.contains("sidebar passes=2 sessions=4713 rows=4713 sections=2"))
R("summaryResolved", summary.contains("resolved 4725 in ") && summary.contains("(cache 12, memo 4713), per pass max 4713, while scrolling 0"))
R("summaryRebuilds", summary.contains("memo rebuilds 1 "))
// Nav: closes the window, then the next pass reports its delay.
lines.removeAll()
HomeListPerf.row(.cache, since: HomeListPerf.clock())
HomeListPerf.nav("depth=0")
R("quietSkipped", lines.count == 1)
R("navLine", lines.last == "[HomeListPerf] nav depth=0")
start = HomeListPerf.passBegin()
HomeListPerf.passEnd(site: "sidebar", start: start, groups: groups, sessions: big.count)
HomeListPerf.flush()
R("afterNav", (lines.last?.contains("ms after nav") ?? false) && (lines.last?.contains("1 quiet windows before") ?? false))
// Empty window: nothing logged.
let before = lines.count
HomeListPerf.flush()
R("emptySilent", lines.count == before)

// [T-home-list-lazy-rows] Row bodies per pass; [T-home-list-pass-trigger] triggers.
lines.removeAll()
func inputs(_ v: [Int]) -> HomeListPassInputs { HomeListPassInputs(values: v) }
let base = [1, 2, 0, 0, 0, 0, 0, 0, 0, 3]
var running = base; running[1] = 9
var navAndHeaders = running; navAndHeaders[2] = 1; navAndHeaders[6] = 5
start = HomeListPerf.passBegin()
HomeListPerf.passEnd(site: "sidebar", start: start, groups: groups, sessions: big.count, inputs: inputs(base))
for _ in 0..<60 { HomeListPerf.rowBuilt() }
start = HomeListPerf.passBegin()
HomeListPerf.passEnd(site: "sidebar", start: start, groups: groups, sessions: big.count, inputs: inputs(running))
for _ in 0..<20 { HomeListPerf.rowBuilt() }
start = HomeListPerf.passBegin()
HomeListPerf.passEnd(site: "sidebar", start: start, groups: groups, sessions: big.count, inputs: inputs(running))
start = HomeListPerf.passBegin()
HomeListPerf.passEnd(site: "sidebar", start: start, groups: groups, sessions: big.count, inputs: inputs(navAndHeaders))
HomeListPerf.flush()
let w2 = lines.last ?? ""
R("rowBodies", w2.contains("row bodies 80, per pass max 60"))
R("triggers", w2.contains("changed: ") && w2.contains("first 1") && w2.contains("other 1") && w2.contains("running 1")
  && w2.contains("nav 1") && w2.contains("folderHeaders 1"))
R("noWalkWarning", !lines.contains { $0.contains("row walk") })
R("passMarks", HangDetector.marks.contains("list pass sidebar") && HangDetector.marks.contains("nav depth=0"))
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rowlookup-\(UUID().uuidString).swift")
try? harness.write(to: tmp, atomically: true, encoding: .utf8)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["swiftc", "-O", tmp.path, "-o", tmp.path + ".bin"]
let errPipe = Pipe(); p.standardError = errPipe
try? p.run(); p.waitUntilExit()
var r: [String: String] = [:]
if p.terminationStatus == 0 {
    let run = Process(); run.executableURL = URL(fileURLWithPath: tmp.path + ".bin")
    let out = Pipe(); run.standardOutput = out
    try? run.run(); run.waitUntilExit()
    for line in (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n") where line.hasPrefix("R ") {
        let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
        if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
    }
} else {
    print(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

print("▶️  1. SessionRowLookupMemo (shipped code, compiled -O)")
check("finds a session, nil for an unknown id", r["found"] == "true" && r["missing"] == "true")
check("a replaced list is re-indexed", r["afterReplaceOld"] == "true" && r["afterReplaceNew"] == "S3")
check("an in-place edit returns the current value", r["inPlaceEdit"] == "edited")
check("a reorder resolves the right element", r["afterSwap"] == "S0")
check("duplicate ids: the first wins (as the cache)", r["dupFirst"] == "true")
check("one all-miss render pass (60 rows × 4,713 sessions) is far cheaper than the per-row scan (old \(r["oldMs"] ?? "?") ms, new \(r["newMs"] ?? "?") ms)",
      r["hits"] == "true" && (Int(r["newMs"] ?? "") ?? 9999) * 5 < max(5, Int(r["oldMs"] ?? "") ?? 0))

check("HomeListPerf: one window timer for a burst of activity", r["timerScheduledOnce"] == "true")
check("HomeListPerf: a pass that resolves every row gets its own ⚠️ line", r["walkOutlier"] == "true")
check("HomeListPerf: the window line carries passes / sessions / rows / sections", r["summaryPasses"] == "true")
check("HomeListPerf: resolved rows split by source, per-pass max, scroll rows", r["summaryResolved"] == "true")
check("HomeListPerf: memo re-index counted once for a whole walk", r["summaryRebuilds"] == "true")
check("HomeListPerf: a cheap window (one cached row) is counted, not logged", r["quietSkipped"] == "true")
check("HomeListPerf: nav gets its own line", r["navLine"] == "true")
check("HomeListPerf: the first pass after nav is always logged, with its delay and the quiet count", r["afterNav"] == "true")
check("HomeListPerf: an idle window logs nothing", r["emptySilent"] == "true")

check("HomeListPerf: row bodies counted per window with the per-pass max", r["rowBodies"] == "true")
check("HomeListPerf: each pass names the inputs that changed (first / other / running / nav / folderHeaders)", r["triggers"] == "true")
check("HomeListPerf: a pass that builds only visible rows raises no row-walk warning", r["noWalkWarning"] == "true")
check("HomeListPerf: passes and nav leave HangDetector marks", r["passMarks"] == "true")

print("\n▶️  2. sessionForRow wiring")
check("a cache miss goes to the memo, not displaySessions",
      grouping.contains("let hit = sessionRowLookupMemo.session(id, in: sessions)"))
check("displaySessions is only scanned for the selected iPad draft placeholder (checked before the memo)",
      grouping.contains("if isWideLayout, id == selectedSessionId, Self.isNewSessionId(id) {\n            let draft = displaySessions.first(where: { $0.id == id })")
      && grouping.contains("let hit = sessionRowLookupMemo.session(id, in: sessions)"))
check("every sessionForRow exit is counted (cache / draft / memo or nil)",
      grouping.contains("HomeListPerf.row(.cache, since: perfStart)")
      && grouping.contains("HomeListPerf.row(.draft, since: perfStart)")
      && grouping.contains("HomeListPerf.row(hit == nil ? .missing : .memo, since: perfStart)"))
check("both list bodies time their grouping as a pass, with the pass inputs",
      sessionList.contains("let _ = HomeListPerf.passEnd(site: \"sidebar\", start: perfStart, groups: groups, sessions: sessions.count,\n                                        inputs: homeListPassInputs)")
      && sessionList.contains("let _ = HomeListPerf.passEnd(site: \"selection\", start: perfStart, groups: groups, sessions: sessions.count,\n                                        inputs: homeListPassInputs)"))

print("\n▶️  2b. [T-home-list-lazy-rows] one fixed-type view per row id")
check("no row is conditional on the lookup any more (no `if let session = sessionForRow`)",
      !sessionList.contains("if let session = sessionForRow"))
check("no AnyView-erased session row left",
      !sessionList.contains("erasedSessionRow") && !sessionList.contains("-> AnyView {\n        AnyView(\n            SessionRow("))
check("iPhone rows are SessionStackRow, iPad rows SessionSplitRow, each from its own ForEach",
      sessionList.contains("ForEach(group.ids, id: \\.self) { sessionId in\n                            stackRow(sessionId, group: group)\n                        }")
      && sessionList.contains("ForEach(group.ids, id: \\.self) { sessionId in\n                            splitRow(sessionId, group: group)\n                        }")
      && sessionList.contains("private func stackRow(_ sessionId: String, group: SidebarGroup) -> SessionStackRow {")
      && sessionList.contains("private func splitRow(_ sessionId: String, group: SidebarGroup) -> SessionSplitRow {"))
check("select mode is chosen once per section, rows fall back to a placeholder instead of disappearing",
      sessionList.components(separatedBy: "selectableRow(sessionForRow(sessionId) ?? .missingRowPlaceholder(sessionId))").count == 3)
let stackBody = rowsFile.components(separatedBy: "struct SessionStackRow: View {").last?.components(separatedBy: "struct SessionSplitRow").first ?? ""
let splitBody = rowsFile.components(separatedBy: "struct SessionSplitRow: View {").last ?? ""
check("iPhone row keeps navigation, drag, regen overlay, folder background and the value-only menu",
      ["NavigationLink(value: session.id)", ".draggable(session.id)", "if isRegeneratingTitle {",
       "FolderMemberRowBackground(isLast: isLastInFolder)", "SessionContextMenu(", ".equatable()",
       ".listRowInsets(EdgeInsets())", ".listRowSeparator(.hidden)", "HomeListPerf.rowBuilt()"].allSatisfy(stackBody.contains))
check("iPad row keeps selection tag, highlight band, draft menu id, drag, regen overlay",
      [".tag(session.id)", "if let menuSid {", "UnevenRoundedRectangle(", "isHighlighted ? Self.highlightFill",
       ".draggable(session.id)", "if isRegeneratingTitle {", "HomeListPerf.rowBuilt()"].allSatisfy(splitBody.contains)
      && sessionList.contains("let menuSid = Self.isNewSessionId(session.id) ? newSessionRealId : session.id"))
check("row structs hold values only - no closures capturing ContentView",
      !stackBody.contains("->") && !splitBody.contains("-> Void") && !splitBody.contains("@escaping"))
check("chat appear / disappear leave HangDetector marks",
      layout.contains("HangDetector.mark(\"chat appear\")") && layout.contains("HangDetector.mark(\"chat disappear\")"))
check("navigation is marked on iPhone (path) and iPad (selection)",
      contentView.contains("HomeListPerf.nav(\"depth=\\(navigationPath.count)\")")
      && contentView.contains("if isWideLayout { HomeListPerf.nav("))
check("the memo is held in @State (a reference, so filling it in body is not a state write)",
      contentView.contains("@State var sessionRowLookupMemo = SessionRowLookupMemo()"))

print("\n▶️  3. HangDetector excludes suspension")
check("a monitor poll more than 1 s late is treated as the process being frozen",
      hang.contains("static const double kSuspendGapMs = 1000.0;")
      && hang.contains("if (gapMs > kSuspendGapMs) {"))
check("frozen time is tied to the current beat and subtracted from busyMs",
      hang.contains("if (beat != suspendedBeat) { suspendedBeat = beat; suspendedTicks = 0; }")
      && hang.contains("uint64_t frozen = (lastBeat == suspendedBeat) ? suspendedTicks : 0;")
      && hang.contains("double busyMs = ticksToMs(span - frozen);"))
check("a stall that was all suspension is not reported", hang.contains("if (frozen >= span) continue;"))

print("\n▶️  4. [MainStall] sub-threshold awake spans")
check("a span opens on wake-up (AfterWaiting / Entry), first opener wins",
      hang.contains("if ((activity == kCFRunLoopAfterWaiting || activity == kCFRunLoopEntry) && g_awakeStart == 0) {"))
check("the closing observer runs after Core Animation's commit (order LONG_MAX, BeforeWaiting)",
      hang.contains("NULL, kCFRunLoopBeforeWaiting, true, LONG_MAX, lateBeforeWaitingCallback, &ctx);"))
check("the late observer is removed on stop and on a failed start",
      hang.components(separatedBy: "CFRunLoopRemoveObserver(CFRunLoopGetMain(), g_lateObserver, kCFRunLoopCommonModes);").count == 3)
check("spans of 5 s or more are left to the hang path (suspension / nested loops)",
      hang.contains("if (ms < kStallBucketMs[0] || ms >= kStallIgnoreMs) return;"))
check("the monitor thread reports stalls each poll, summary only when something was slow",
      hang.contains("hd_reportStalls(); // [T-main-stall-diag]") && hang.contains("if (c25 == 0) return;"))
check("no display link in the stall path", !hang.contains("displayLinkWithTarget"))
check("[T-main-stall-marks] detail threshold 100 ms; marks are main-only and listed in the detail line",
      hang.contains("static const double kStallDetailMs = 100.0;")
      && hang.contains("+ (void)mark:(NSString *)label {\n    if (!pthread_main_np()) return;")
      && hang.contains("| during: %s") && hang.contains("\"(after %s -%.0fms)\""))

try? FileManager.default.removeItem(at: tmp)
try? FileManager.default.removeItem(atPath: tmp.path + ".bin")
print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
