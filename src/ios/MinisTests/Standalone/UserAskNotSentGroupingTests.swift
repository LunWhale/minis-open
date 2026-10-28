#!/usr/bin/env swift
// [T-user-ask-notsent-merge] A model that sends user_ask with empty or invalid
// arguments tends to do it several times in a row. Each rejected call drew its
// own "could not ask" row; a run of them now shows as ONE row,
// "Question not sent (N times)".
//
//   [1] the shipping UserAskNotSentGrouping (BEGIN/END block in
//       UserAskCardView.swift), compiled standalone: runs of 1/2/3, a run
//       broken by an asked user_ask / real text / another tool, thinking and
//       empty text inside a run, several runs in one message
//   [2] the committed catalog: the three new keys in all 18 locales, the
//       count key as plural variants with every category each language uses
//   [3] source guards: display only (the list leaves members out, nothing
//       touches the stored blocks or the tool results), live / reload paths
//
// Run: swift UserAskNotSentGroupingTests.swift   (needs swiftc)
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

let card = source("Views/Chat/UserAskCardView.swift")
guard let block = between(card, "// BEGIN UserAskNotSentGrouping", "// END UserAskNotSentGrouping") else {
    print("❌ UserAskNotSentGrouping block not found"); exit(1)
}

let harness = #"""
import Foundation
typealias I = UserAskNotSentGrouping.Input
func show(_ inputs: [I]) -> String {
    UserAskNotSentGrouping.roles(inputs).map { r -> String in
        switch r {
        case .none: return "-"
        case .lead(let n): return "L\(n)"
        case .member(let n): return "m\(n)"
        }
    }.joined(separator: " ")
}
func R(_ k: String, _ v: String) { print("R \(k)=\(v)") }
R("one", show([.notSent]))
R("two", show([.notSent, .notSent]))
R("three", show([.notSent, .notSent, .notSent]))
R("three_then_asked", show([.notSent, .notSent, .notSent, .asked]))
R("split_by_asked", show([.notSent, .asked, .notSent]))
R("thinking_inside", show([.notSent, .transparent, .notSent, .transparent, .notSent]))
R("split_by_text", show([.notSent, .other, .notSent]))
R("asked_first", show([.asked, .notSent, .notSent, .other]))
R("two_runs", show([.notSent, .notSent, .asked, .transparent, .notSent, .notSent, .notSent]))
R("none", show([.asked, .other, .transparent]))
R("empty", show([]))
R("count", "\(UserAskNotSentRole.lead(count: 3).count),\(UserAskNotSentRole.member(count: 3).count),\(UserAskNotSentRole.none.count)")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-notsent-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Grouping.swift", "import Foundation\n" + block), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping UserAskNotSentGrouping compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}

print("\n1. Runs")
check("1 rejected call → its own row, no count (lead of 1)", r["one"] == "L1")
check("2 in a row → one row, count 2; the second is folded into it", r["two"] == "L2 m2")
check("3 in a row → one row, count 3", r["three"] == "L3 m3 m3")
check("…and the asked user_ask after them is not part of the run", r["three_then_asked"] == "L3 m3 m3 -")
check("rejected - asked - rejected → two separate rows (an asked call ends a run)", r["split_by_asked"] == "L1 - L1")
check("thinking between rejected calls does not end the run (and stays visible)",
      r["thinking_inside"] == "L3 - m3 - m3")
check("real text between them ends the run", r["split_by_text"] == "L1 - L1")
check("a run can start after an asked call", r["asked_first"] == "- L2 m2 -")
check("two runs in one message are counted separately", r["two_runs"] == "L2 m2 - - L3 m3 m3")
check("no rejected call → no roles", r["none"] == "- - -")
check("empty message", (r["empty"] ?? "") == "")
check("role.count: lead and member carry the run size, none is 0", r["count"] == "3,3,0")

print("\n2. Catalog (committed version)")
let (gc, committed) = run("/usr/bin/git", ["-C", iosRoot.path, "show", "HEAD:src/ios/Localizable.xcstrings"])
let strings = ((try? JSONSerialization.jsonObject(with: Data(committed.utf8))) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
check("committed catalog readable", gc == 0 && !strings.isEmpty)
let locales = ["de", "en", "es", "fil", "fr", "hr", "id", "ja", "ko", "ms", "pl", "pt-BR", "ro", "ru", "th", "tr", "zh-Hans", "zh-Hant"]
func locs(_ key: String) -> [String: Any] { ((strings[key] as? [String: Any])?["localizations"] as? [String: Any]) ?? [:] }
func value(_ key: String, _ l: String) -> String? {
    ((locs(key)[l] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
}
func plural(_ l: String) -> [String: String] {
    let p = (((locs("Question not sent (%lld times)")[l] as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any]) ?? [:]
    return p.compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
}
check("\"Question not sent\" in all 18 locales", locales.allSatisfy { value("Question not sent", $0)?.isEmpty == false })
check("the reason line in all 18 locales",
      locales.allSatisfy { value("Details missing; the assistant will retry or ask in text", $0)?.isEmpty == false })
check("zh-Hans wording: 提问未发出 / 内容缺失，助手会重试或改用文字",
      value("Question not sent", "zh-Hans") == "提问未发出"
      && value("Details missing; the assistant will retry or ask in text", "zh-Hans") == "内容缺失，助手会重试或改用文字")
check("the count key is plural variants in all 18 locales, every form keeps %lld",
      locales.allSatisfy { l in let p = plural(l); return p["other"] != nil && p.values.allSatisfy { $0.contains("%lld") } })
check("ru / pl carry one + few + many + other", ["ru", "pl"].allSatisfy { Set(plural($0).keys) == ["one", "few", "many", "other"] })
check("hr / ro carry one + few + other", ["hr", "ro"].allSatisfy { Set(plural($0).keys).isSuperset(of: ["one", "few", "other"]) })
check("en: 'time' / 'times'", plural("en")["one"] == "Question not sent (%lld time)" && plural("en")["other"] == "Question not sent (%lld times)")
check("the old strings stay in the catalog (other users / another session's edits)",
      strings["Could not ask"] != nil && strings["Blocked invalid tool call"] != nil)

print("\n3. Source guards")
let list = messageListV3Source()
check("the list leaves run members out (no zero-height rows)",
      list.contains("if case .member = UserAskNotSentStore.shared.role(blocks[bi].id) {\n                            bi += 1\n                            continue\n                        }"))
check("the list re-plans when a run changes", list.contains("NotificationCenter.default.publisher(for: .userAskNotSentRegrouped)"))
let concurrent = source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let userAsk = source("Agent/Chat/AIChatViewModel+UserAsk.swift")
check("live: a preflight-rejected user_ask regroups its message",
      concurrent.contains("if tu.name == UserAskTool.name { regroupUserAskNotSent(msgIdx: msgIdx) }"))
check("live: an unparseable request in executeUserAsk regroups too", userAsk.contains("regroupUserAskNotSent(msgIdx: msgIdx)\n            return (out, false)"))
check("live: the lead's cell is re-measured",
      userAsk.contains("if case .lead = UserAskNotSentStore.shared.role(b.id) { notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: i) }"))
check("reload: every loaded assistant message is grouped",
      source("Agent/Chat/AIChatViewModel+Persistence.swift").contains("for msg in loadedUIMessages where msg.role == .assistant {\n            UserAskNotSentGrouping.annotate(msg.blocks)"))
let models = source("Agent/Chat/ChatModels.swift")
check("the role lives in a side table, not on AssistantBlock (a new field there crashed launch: metadata stack overflow)",
      card.contains("final class UserAskNotSentStore: ObservableObject {") && !models.contains("userAskNotSent"))
let annotate = between(card, "static func annotate(_ blocks: [AssistantBlock]) -> Bool {", "\n    }\n}") ?? ""
check("annotate writes only the side table (no content / status / args)",
      annotate.contains("UserAskNotSentStore.shared.update(") && !annotate.contains(".content =")
      && !annotate.contains(".toolStatus =") && !annotate.contains("toolInputArgs ="))
check("card and tile show the count through the plural key, never concatenation",
      card.contains("String(localized: \"Question not sent (\\(count) times)\", bundle: bundle, locale: locale)")
      && card.contains("UserAskSummary.notSentTitle(count: notSent.role(block.id).count)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
