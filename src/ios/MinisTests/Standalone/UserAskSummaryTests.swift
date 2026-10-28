#!/usr/bin/env swift
// [T-user-ask-thumbnail] The mini preview tile above the composer (and the
// tool sheet behind it) showed a user_ask with no title and its raw output:
// "Tool: user_ask" while waiting, the result JSON once answered. It now shows
// "Question for you" and one readable row per question.
//
//   [1] the shipping UserAskSummary + UserAskTypography blocks
//       (UserAskCardView.swift), compiled with the real UserAskParser /
//       statuses (UserAskCore) and the six FontScaleLevel multipliers:
//       topics, values per status, pending / not-asked rows, row capacity
//       and "+N" overflow at every font step
//   [2] source guards: the tile and the sheet route user_ask to the summary
//       ahead of the snapshot branches; the other tools' tiles are untouched;
//       every string is an existing catalog key
//
// Run: swift UserAskSummaryTests.swift   (needs swiftc)
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

let card = source("Views/Chat/UserAskCardView.swift")
let core = source("Agent/Chat/UserAskCore.swift")
let sheet = source("Views/Chat/ToolLiveSheet.swift")
let fontSettings = source("Shared/FontSettings.swift")
guard let summaryBlock = between(card, "// BEGIN UserAskSummary", "// END UserAskSummary"),
      let typeBlock = between(card, "// BEGIN UserAskTypography", "// END UserAskTypography"),
      let coreBlock = between(core, "// BEGIN UserAskCore", "// END UserAskCore") else {
    print("❌ source blocks not found"); exit(1)
}
let multiplierBody = between(fontSettings, "var multiplier: CGFloat {", "\n    }\n") ?? ""
let multipliers: [String] = multiplierBody.split(separator: "\n").compactMap { line in
    guard let r = line.range(of: "return ") else { return nil }
    return line[r.upperBound...].split(separator: " ").first.map(String.init)
}

let harness = #"""
import Foundation
import CoreGraphics

func AppLocalized(_ key: String) -> String { key }
func R(_ k: String, _ v: Any) { print("R \(k)=\(v)") }
func rows(_ r: [UserAskSummaryRow]) -> String {
    r.map { "\($0.topic)|\($0.value)|\($0.muted ? "m" : "a")" }.joined(separator: ";")
}
func questions(_ json: String) -> [UserAskQuestion] {
    let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    if case .success(let r) = UserAskParser.parse(obj) { return r.questions }
    return []
}

let qs = questions(#"{"questions":[{"type":"options","header":"存活上限","question":"同时存活的上限设多少？","options":[{"label":"2 个"},{"label":"3 个"}]},{"type":"options","question":"How long should an idle stdio server stay alive\nbefore it is reclaimed?","options":[{"label":"5 min"},{"label":"10 min"}],"multi_select":true},{"type":"confirm","header":"推送","question":"git push origin v1.15"}]}"#)
R("q_count", qs.count)
R("topic_header", UserAskSummary.topic(qs[0]))
R("topic_question", UserAskSummary.topic(qs[1]))
R("topic_sheet", UserAskSummary.topic(qs[1], limit: UserAskSummary.sheetTopicLimit))
R("topic_command", UserAskSummary.topic(questions(#"{"questions":[{"type":"confirm","question":"rm -rf /var/minis/workspace/build-cache/"}]}"#)[0]))

R("pending", rows(UserAskSummary.pendingRows(qs)))
R("answered", rows(UserAskSummary.resolvedRows(qs, results: [(.answered, ["3 个"]), (.answered, ["5 min", "10 min"]), (.approved, [])])))
R("other_delegated_denied", rows(UserAskSummary.resolvedRows(qs, results: [(.other, ["随便"]), (.delegated, []), (.denied, [])])))
R("timeout", rows(UserAskSummary.resolvedRows(qs, results: [(.answered, ["2 个"]), (.timeout, []), (.timeout, [])])))
R("dismissed_short", rows(UserAskSummary.resolvedRows(qs, results: [(.dismissed, [])])))
R("unavailable", rows(UserAskSummary.resolvedRows([qs[2]], results: [(.unavailable, [])])))
// [T-user-ask-tile-rich]
func tile(_ c: UserAskTileContent) -> String {
    c.title + "|" + c.trailing + "|" + c.lines.map { l -> String in
        let k: String
        switch l.kind {
        case .question: k = "Q"; case .command: k = "C"; case .impact: k = "I"; case .topic: k = "T"
        case let .option(m, sel): k = "O" + m + (sel ? "*" : "")
        case let .answer(muted): k = muted ? "A-" : "A"
        }
        return "\(k):\(l.text)/\(l.maxLines)"
    }.joined(separator: ";")
}
let cq = questions(#"{"questions":[{"type":"confirm","header":"警告","question":"rm -rf /tmp/demo/*","impact":"删除 12 个临时文件\n可以重新生成","risk":"medium"},{"type":"confirm","header":"危险","question":"git push --force","risk":"high"}]}"#)
R("tile.confirm", tile(UserAskSummary.pendingTile(questions: cq, current: 0, answer: nil)))
R("tile.high", tile(UserAskSummary.pendingTile(questions: cq, current: 1, answer: nil)))
R("tile.single", tile(UserAskSummary.pendingTile(questions: [qs[0]], current: 0, answer: UserAskAnswer(selected: [1]))))
R("tile.multi", tile(UserAskSummary.pendingTile(questions: qs, current: 1, answer: UserAskAnswer(selected: [0], otherText: "15 min"))))
R("tile.bad", tile(UserAskSummary.pendingTile(questions: qs, current: 9, answer: nil)))
R("tile.resolved1", tile(UserAskSummary.resolvedTile([qs[0]], results: [(.answered, ["3 个"])])))
R("tile.resolvedN", tile(UserAskSummary.resolvedTile(qs, results: [(.answered, ["3 个"]), (.timeout, [])])))
let many = (0..<6).map { UserAskTileLine(kind: .option(marker: "○", selected: false), text: "o\($0)", maxLines: 1) }
let fitMany = UserAskSummary.fitTile([UserAskTileLine(kind: .question, text: "q", maxLines: 2)] + many, capacity: 5)
R("tile.fit", "\(fitMany.lines.map { "\($0.text)/\($0.maxLines)" }.joined(separator: ","))|+\(fitMany.more)")
let fitAll = UserAskSummary.fitTile(Array(many.prefix(3)), capacity: 5)
R("tile.fitAll", "\(fitAll.lines.count)|+\(fitAll.more)")
let squeeze = UserAskSummary.fitTile([UserAskTileLine(kind: .command, text: "c", maxLines: 2),
                                      UserAskTileLine(kind: .impact, text: "i", maxLines: 2),
                                      UserAskTileLine(kind: .option(marker: "○", selected: false), text: "x", maxLines: 1)], capacity: 4)
R("tile.squeeze", "\(squeeze.lines.map { "\($0.text)/\($0.maxLines)" }.joined(separator: ","))|+\(squeeze.more)")
R("answered_empty", rows(UserAskSummary.resolvedRows([qs[0]], results: [(.answered, [])])))
R("not_asked", rows(UserAskSummary.notAskedRows(title: "Question not sent")))

let levels: [CGFloat] = [\#(multipliers.joined(separator: ", "))]
for (i, m) in levels.enumerated() {
    let t = UserAskTypography(body: UserAskTypography.bodyReference * m)
    let cap = UserAskSummary.capacity(tileHeight: 65, titleSize: Double(t.thumbTitle), lineSize: Double(t.thumbLine))
    let used = 4 + 3 + (Double(t.thumbTitle) * 1.25 + 1) + Double(cap) * (Double(t.thumbLine) * 1.25 + 1)
    R("L\(i)", "\(t.thumbTitle),\(t.thumbLine),\(cap),\(used)")
}
let six = (0..<6).map { UserAskSummaryRow(topic: "t\($0)", value: "v", muted: false) }
let f1 = UserAskSummary.fit(Array(six.prefix(3)), capacity: 5)
let f2 = UserAskSummary.fit(six, capacity: 5)
R("fit_all", "\(f1.rows.count),\(f1.more)")
R("fit_overflow", "\(f2.rows.count),\(f2.more)")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-summary-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Core.swift", "import Foundation\n" + coreBlock),
             ("Typography.swift", "import Foundation\nimport CoreGraphics\n" + typeBlock),
             ("Summary.swift", "import Foundation\n" + summaryBlock),
             ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("FontScaleLevel multipliers read from FontSettings (6)", multipliers.count == 6)
check("summary + typography + parser compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}

print("\n1. Topics")
check("fixture parses into 3 questions", r["q_count"] == "3")
check("the header chip is the topic", r["topic_header"] == "存活上限")
check("no header: the question, newlines flattened, cut at 14 + … on the tile",
      r["topic_question"] == "How long shoul…")
check("…and kept whole (up to 80) in the sheet",
      r["topic_sheet"] == "How long should an idle stdio server stay alive before it is reclaimed?")
check("a confirm command is cut short enough to leave room for the answer", r["topic_command"] == "rm -rf /var/mi…")

print("\n2. One row per question, in the card's words")
check("pending: the waiting line, then each topic (muted)",
      r["pending"] == "Waiting for your answer…||a;存活上限||m;How long shoul…||m;推送||m")
check("answered: the answer; multi-select joined; confirm approved → Allow",
      r["answered"] == "存活上限|3 个|a;How long shoul…|5 min, 10 min|a;推送|Allow|a")
check("other → the user's words; delegated → Left to Minis; denied → Cancel (muted)",
      r["other_delegated_denied"] == "存活上限|随便|a;How long shoul…|Left to Minis|a;推送|Cancel|m")
check("timeout keeps a submitted answer, the rest read Timed out (muted)",
      r["timeout"] == "存活上限|2 个|a;How long shoul…|Timed out|m;推送|Timed out|m")
check("a question without a result entry reads Skipped",
      r["dismissed_short"] == "存活上限|Skipped|m;How long shoul…|Skipped|m;推送|Skipped|m")
check("unavailable → Could not ask", r["unavailable"] == "推送|Could not ask|m")
// [T-user-ask-tile-rich] the tile is a miniature of the card
check("tile, pending confirm: card title + header, progress, the command, the impact (newlines flattened)",
      r["tile.confirm"] == "Needs your approval · 警告|1/2|C:rm -rf /tmp/demo/*/2;I:删除 12 个临时文件 可以重新生成/2")
check("tile, pending high-risk confirm: its own title, no impact line when there is none",
      r["tile.high"] == "High-risk action · 危险|2/2|C:git push --force/2")
check("tile, single-select options: question, then each option, the picked one marked",
      r["tile.single"] == "Needs your answer · 存活上限||Q:同时存活的上限设多少？/2;O○:2 个/1;O●*:3 个/1")
check("tile, multi-select: checkboxes, and text typed into Other… as a picked line",
      r["tile.multi"] == "Needs your answer|2/3|Q:How long should an idle stdio server stay alive before it is reclaimed?/2;O☑*:5 min/1;O☐:10 min/1;O☑*:15 min/1")
check("tile, out-of-range question index: just the title", r["tile.bad"] == "Question for you||")
check("tile, resolved single question: the question (2 lines), then the answer",
      r["tile.resolved1"] == "Question for you||T:同时存活的上限设多少？/2;A:3 个/1")
check("tile, resolved several: question + answer per question; a missing result reads Skipped",
      r["tile.resolvedN"] == "Question for you||T:同时存活的上限设多少？/1;A:3 个/1;T:How long should an idle stdio server stay alive before it is reclaimed?/1;A-:Timed out/1;T:git push origin v1.15/1;A-:Skipped/1")
check("tile fit: two-line entries cost two, the rest becomes +N on its own line",
      r["tile.fit"] == "q/2,o0/1,o1/1|+4")
check("tile fit: everything shown when it fits", r["tile.fitAll"] == "3|+0")
check("tile fit: a two-line entry squeezed into the last free line keeps one",
      r["tile.squeeze"] == "c/2,i/1|+1")
check("an answered row with no text falls back to Answered", r["answered_empty"] == "存活上限|Answered|a")
check("a rejected call → one muted row with the not-sent title", r["not_asked"] == "Question not sent||m")

print("\n3. The fixed 100x65 tile at every Appearance step")
var steps: [[Double]] = []
for i in 0..<6 { steps.append((r["L\(i)"] ?? "").split(separator: ",").compactMap { Double($0) }) }
for (i, s) in steps.enumerated() { print("     L\(i): title / line / rows / used pt = \(s)") }
check("sizes stay in their band (title 6…8, line 5…6.5)",
      steps.allSatisfy { $0.count == 4 && (6...8).contains($0[0]) && (5...6.5).contains($0[1]) })
check("default step: title 7, line 5.5", steps.count == 6 && steps[2][0] == 7 && steps[2][1] == 5.5)
check("sizes follow the setting (never shrink as the step grows)",
      zip(steps, steps.dropFirst()).allSatisfy { $0[0] <= $1[0] && $0[1] <= $1[1] })
check("title stays larger than the rows", steps.allSatisfy { $0[0] > $0[1] })
check("at least 4 rows fit at every step (4 questions + title, or 3 + \"+N\")", steps.allSatisfy { $0[2] >= 4 })
check("the rows that fit never overflow 65pt", steps.allSatisfy { $0[3] <= 65 })
check("fit: 3 rows in 5 slots → all shown", r["fit_all"] == "3,0")
check("fit: 6 rows in 5 slots → 4 shown + \"+2\"", r["fit_overflow"] == "4,2")

print("\n4. Source guards")
let thumbBody = between(sheet, "private struct ToolPreviewThumbnail: View {", "/// Text preview from snapshot data") ?? ""
let askBranch = thumbBody.range(of: "} else if case .userAskTool = block.kind {")
let snapBranch = thumbBody.range(of: "} else if let snapshot, let snapshotImage = loadSnapshotImage(snapshot) {")
check("the tile routes user_ask to the summary, ahead of the snapshot branches",
      askBranch != nil && snapBranch != nil && askBranch!.lowerBound < snapBranch!.lowerBound
      && thumbBody.contains("UserAskSummaryView(block: block, compact: true)"))
check("previewHeader names user_ask \"Question for you\"",
      sheet.contains("case .userAskTool: return AppLocalized(\"Question for you\")"))
let live = between(sheet, "private var liveContent: some View {", "} else if isLive {") ?? ""
check("the tool sheet shows the same digest first",
      live.contains("if case .userAskTool = block.kind {") && live.contains("UserAskSummaryView(block: block, compact: false)"))
check("other tools keep their tiles (100x65 text / diff / browser previews unchanged)",
      thumbBody.contains("snapshotTextPreview(text)") && thumbBody.contains("case .browserTool:\n                    browserPreview")
      && thumbBody.contains("case .fileEditTool:\n                    diffPreview") && thumbBody.contains("textPreview"))
check("the summary tile has the same 100x65 frame as the others",
      card.contains("static let tileSize = CGSize(width: 100, height: 65)") && sheet.contains(".frame(width: 100, height: 65, alignment: .topLeading)"))
let summaryKeys = ["Answered", "Left to Minis", "Allow", "Cancel", "Timed out", "Skipped", "Could not ask",
                   "Waiting for your answer…", "Question for you", "Question not sent", "Question not sent (%lld times)",
                   "Details missing; the assistant will retry or ask in text"]
// The committed catalog: another session's uncommitted reformat of the
// working-tree file may predate these keys.
func committedCatalog() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", iosRoot.path, "show", "HEAD:src/ios/Localizable.xcstrings"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}
let catalog = committedCatalog()
check("every string it shows is an existing catalog key",
      summaryKeys.allSatisfy { catalog.contains("\"\($0)\" :") || catalog.contains("\"\($0)\":") })
check("no fixed point sizes in the summary view (all from UserAskTypography)",
      !(between(card, "struct UserAskSummaryView: View {", "// MARK: Sheet") ?? "x").contains(".font(.system(size: 1"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
