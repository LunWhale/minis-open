#!/usr/bin/env swift
// [ISS-038] Duplicated sessions got the same title every time ("Foo (Copy)" x3)
// and a copy of a copy stacked ("Foo (Copy) (Copy)"); the suffix was hard-coded
// English in a Chinese UI. Reproduced on the vphone 2026-10-05.
//
//   [1] SessionDuplicateTitle (BEGIN/END block in SessionForkManager.swift),
//       compiled as shipped: numbering, smallest free number, no stacking,
//       look-alike titles, nil/blank, case / full-width / whitespace,
//       cross-language words, long titles, 1000 copies, pathological titles.
//   [2] Source guards: duplicateSession reads titles only, reserves its title
//       before suspending, keeps the category / compact-marker copy, the
//       suffix is a localized key of its own, forkSession is untouched.
//
// Run: swift SessionDuplicateTitleTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
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

let fork = source("Agent/Session/SessionForkManager.swift")
guard let block = between(fork, "// BEGIN SessionDuplicateTitle", "// END SessionDuplicateTitle") else {
    print("❌ SessionDuplicateTitle block not found"); exit(1)
}

let harness = #"""
import Foundation
\#(block)
var hFailures = 0
func t(_ label: String, _ got: String, _ want: String) {
    let ok = got == want
    print(ok ? "  ✅ \(label)" : "  ❌ \(label): got \"\(got)\", want \"\(want)\"")
    if !ok { hFailures += 1 }
}
func tb(_ label: String, _ ok: Bool) { print(ok ? "  ✅ \(label)" : "  ❌ \(label)"); if !ok { hFailures += 1 } }
let all = ["Copy", "副本"]          // what allCopySuffixWords yields for en / zh-Hans / zh-Hant
func en(_ src: String?, _ existing: [String] = []) -> String {
    SessionDuplicateTitle.make(sourceTitle: src, existingTitles: existing, suffixWord: "Copy",
                               knownSuffixWords: all, untitledTitle: "Untitled")
}
func zh(_ src: String?, _ existing: [String] = []) -> String {
    SessionDuplicateTitle.make(sourceTitle: src, existingTitles: existing, suffixWord: "副本",
                               knownSuffixWords: all, untitledTitle: "未命名")
}

print("— Numbering")
t("no copy yet → (Copy)", en("Foo"), "Foo (Copy)")
t("(Copy) exists → (Copy 2)", en("Foo", ["Foo", "Foo (Copy)"]), "Foo (Copy 2)")
t("(Copy) and (Copy 2) exist → (Copy 3)", en("Foo", ["Foo", "Foo (Copy)", "Foo (Copy 2)"]), "Foo (Copy 3)")
t("gap: (Copy) and (Copy 3) → smallest free number 2", en("Foo", ["Foo (Copy)", "Foo (Copy 3)"]), "Foo (Copy 2)")
t("gap: only (Copy 2) → 1 is free → (Copy)", en("Foo", ["Foo (Copy 2)"]), "Foo (Copy)")
t("other bases do not count", en("Foo", ["Bar (Copy)", "Foobar (Copy)", "Fo (Copy)"]), "Foo (Copy)")
t("the source title itself takes no number", en("Foo", ["Foo", "Foo"]), "Foo (Copy)")

print("— Copying a copy never stacks")
t("copy of (Copy) → base Foo", en("Foo (Copy)", ["Foo", "Foo (Copy)"]), "Foo (Copy 2)")
t("copy of (Copy 2) → base Foo, next free", en("Foo (Copy 2)", ["Foo", "Foo (Copy)", "Foo (Copy 2)"]), "Foo (Copy 3)")
t("only ONE trailing suffix is stripped", en("Foo (Copy) (Copy)", ["Foo (Copy) (Copy)"]), "Foo (Copy) (Copy 2)")

print("— Look-alikes are part of the title")
t("(draft)", en("Foo (draft)"), "Foo (draft) (Copy)")
t("suffix not at the end", en("Foo (Copy) notes"), "Foo (Copy) notes (Copy)")
t("(Copy 2x)", en("Foo (Copy 2x)"), "Foo (Copy 2x) (Copy)")
t("(Copy 0)", en("Foo (Copy 0)"), "Foo (Copy 0) (Copy)")
t("(Copy 1) is never produced → user text", en("Foo (Copy 1)"), "Foo (Copy 1) (Copy)")
t("(Copy 02) leading zero → user text", en("Foo (Copy 02)"), "Foo (Copy 02) (Copy)")
t("(Copyright)", en("Foo (Copyright)"), "Foo (Copyright) (Copy)")
t("existing look-alikes occupy nothing", en("Foo", ["Foo (Copy 0)", "Foo (Copy 1)", "Foo (draft)"]), "Foo (Copy)")

print("— nil / blank / case / full-width / whitespace")
t("nil title → localized Untitled", en(nil), "Untitled (Copy)")
t("blank title → Untitled", en("   "), "Untitled (Copy)")
t("nil title, Chinese", zh(nil), "未命名 (副本)")
t("nil twice → numbered", en(nil, ["Untitled (Copy)"]), "Untitled (Copy 2)")
t("lower-case (copy) recognized", en("Foo (copy)", ["Foo (copy)"]), "Foo (Copy 2)")
t("full-width （副本） recognized", zh("Foo（副本）", ["Foo（副本）"]), "Foo (副本 2)")
t("full-width parens around Copy 3", en("Foo（Copy 3）", ["Foo（Copy 3）"]), "Foo (Copy)")
t("surrounding spaces trimmed", en("  Foo  ", ["Foo (Copy)  "]), "Foo (Copy 2)")
t("inner spaces tolerated", en("Foo ( Copy 2 )", ["Foo ( Copy 2 )"]), "Foo (Copy)")

print("— Languages recognize each other")
t("Chinese word", zh("Foo"), "Foo (副本)")
t("Chinese numbering", zh("Foo", ["Foo (副本)", "Foo (副本 2)"]), "Foo (副本 3)")
t("English copy, then copied in Chinese → (副本 2)", zh("Foo (Copy)", ["Foo", "Foo (Copy)"]), "Foo (副本 2)")
t("Chinese copies, then copied in English → (Copy 3)", en("Foo (副本 2)", ["Foo (副本)", "Foo (副本 2)"]), "Foo (Copy 3)")
t("mixed languages share one numbering", zh("Foo", ["Foo (Copy)", "Foo (副本 2)", "Foo (Copy 3)"]), "Foo (副本 4)")
t("English 'Copy' recognized even if not passed as known",
  SessionDuplicateTitle.make(sourceTitle: "Foo (Copy)", existingTitles: ["Foo (Copy)"], suffixWord: "副本",
                             knownSuffixWords: [], untitledTitle: "未命名"), "Foo (副本 2)")
t("a Japanese word, when shipped, is recognized too",
  SessionDuplicateTitle.make(sourceTitle: "Foo (コピー)", existingTitles: ["Foo (コピー)"], suffixWord: "Copy",
                             knownSuffixWords: ["Copy", "副本", "コピー"], untitledTitle: "Untitled"), "Foo (Copy 2)")

print("— Long, many, pathological")
let long = String(repeating: "Very long session title ", count: 40)
let longTitle = long.trimmingCharacters(in: .whitespaces)
t("a long title keeps its whole text and the suffix", en(long), longTitle + " (Copy)")
var thousand = ["Foo (Copy)"] + (2...1000).map { "Foo (Copy \($0))" }
let start = Date()
let next = en("Foo (Copy 500)", thousand)
let elapsed = Date().timeIntervalSince(start)
t("1000 copies → (Copy 1001)", next, "Foo (Copy 1001)")
tb("…in well under a second (\(String(format: "%.3f", elapsed)) s)", elapsed < 0.5)
thousand.remove(at: 499)   // "Foo (Copy 500)" deleted
t("…and a deleted one in the middle is refilled", en("Foo", thousand), "Foo (Copy 500)")
t("a huge number in a title is user text, no overflow", en("Foo (Copy 99999999999999999999)"), "Foo (Copy 99999999999999999999) (Copy)")
t("source 'Copy'", en("Copy"), "Copy (Copy)")
t("source '(Copy)' keeps itself as the base", en("(Copy)"), "(Copy) (Copy)")
t("source '(副本)'", zh("(副本)"), "(副本) (副本)")

print("— parse")
tb("parse 'Foo (Copy 3)' = (Foo, 3)", SessionDuplicateTitle.parse("Foo (Copy 3)", words: ["Copy"]).map { $0.base == "Foo" && $0.number == 3 } == true)
tb("parse 'Foo' = nil", SessionDuplicateTitle.parse("Foo", words: ["Copy"]) == nil)
print("HARNESS failures=\(hFailures)")
exit(hFailures == 0 ? 0 : 1)
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("duptitle_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let mainFile = tmp.appendingPathComponent("main.swift")
try? harness.write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
print("1. SessionDuplicateTitle (compiled from SessionForkManager.swift)")
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", mainFile.path, "-o", exe])
check("block compiles standalone", cs == 0)
if cs != 0 { print(cout) }
let (rc, rout) = run(exe, [])
print(rout, terminator: "")
check("all naming scenarios pass", rc == 0 && rout.contains("HARNESS failures=0"))

print("\n2. Source guards")
let dup = between(fork, "func duplicateSession(sessionId: String) async -> ChatSession? {", "// [T-session-duplicate-compact-marker-ios] Track old→new") ?? ""
check("the hard-coded \" (Copy)\" append is gone", !fork.contains("+ \" (Copy)\""))
check("titles only: the cached session list, no message loads before the title is chosen",
      dup.contains("let existingTitles = await store.listSessions().compactMap(\\.title)")
      && (dup.range(of: "listSessions")?.lowerBound ?? dup.endIndex) < (dup.range(of: "loadMessages")?.lowerBound ?? dup.startIndex))
check("title chosen from existing + reserved titles, localized word, all languages, localized Untitled",
      dup.contains("existingTitles: existingTitles + reservedDuplicateTitles,")
      && dup.contains("suffixWord: Self.copySuffixWord(),") && dup.contains("knownSuffixWords: Self.allCopySuffixWords,")
      && dup.contains("untitledTitle: AppLocalized(\"Untitled\"))"))
let pick = dup.range(of: "let dupTitle = SessionDuplicateTitle.make(")
let reserve = dup.range(of: "reservedDuplicateTitles.insert(dupTitle)")
let create = dup.range(of: "await store.createSession(modelId: session.modelId, title: dupTitle)")
check("reserved before the next suspension point (createSession), released after it",
      pick != nil && reserve != nil && create != nil && pick!.upperBound < reserve!.lowerBound
      && reserve!.upperBound < create!.lowerBound
      && !String(dup[reserve!.upperBound..<create!.lowerBound]).contains("await store.createSession(modelId: session.modelId, title: dupTitle)\n        let")
      && dup.contains("reservedDuplicateTitles.remove(dupTitle)"))
check("no await between choosing and reserving",
      pick != nil && reserve != nil && !String(dup[pick!.upperBound..<reserve!.lowerBound]).contains("await"))
check("category still written with the final title",
      dup.contains("await store.updateSessionTitle(newSession.id, title: dupTitle, category: category)"))
check("compact-marker copy untouched", fork.contains("let markers = await store.compactMarkers(sessionId: sessionId)"))
check("forkSession (from another device) unchanged", fork.contains("let forkTitle = (remoteSession.title ?? \"Untitled\") + \" (Fork)\""))
check("own localization key (the plain \"Copy\" key is the verb)",
      fork.contains("AppLocalized(\"Copy (session duplicate suffix)\",") && fork.contains("String(localized: \"Copy (session duplicate suffix)\", bundle: bundle)"))
let xc = source("Localizable.xcstrings")
let entry = between(xc, "\"Copy (session duplicate suffix)\" : {", "\n    },\n") ?? ""
check("xcstrings: en Copy, zh-Hans 副本, zh-Hant 副本",
      entry.contains("\"value\" : \"Copy\"") && entry.contains("\"zh-Hans\"") && entry.contains("\"zh-Hant\"")
      && entry.components(separatedBy: "\"value\" : \"副本\"").count - 1 == 2)

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
