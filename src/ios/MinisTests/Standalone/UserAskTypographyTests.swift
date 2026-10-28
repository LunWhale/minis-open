#!/usr/bin/env swift
// [T-user-ask-font-scale] The user_ask card's text follows the chat font
// setting (Settings › Appearance, FontSettings.messageBaseScale) instead of
// fixed points, keeps its hierarchy at every step, and keeps ≥44pt targets.
//
//   [1] UserAskTypography (shipping code, compiled standalone) at all six
//       FontScaleLevel multipliers (read from FontSettings.swift)
//   [2] source guards: the base is the chat body size, no fixed text sizes
//       left on the card, views observe FontSettings, tap targets
//
// Run: swift UserAskTypographyTests.swift   (needs swiftc)
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
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}
let card = source("Views/Chat/UserAskCardView.swift")
let fontSettings = source("Shared/FontSettings.swift")
guard let block = between(card, "// BEGIN UserAskTypography", "// END UserAskTypography") else {
    print("❌ UserAskTypography block not found"); exit(1)
}
// The six multipliers, in display order, straight from FontScaleLevel.
let multiplierBody = between(fontSettings, "var multiplier: CGFloat {", "\n    }\n") ?? ""
let multipliers: [String] = multiplierBody.split(separator: "\n").compactMap { line in
    guard let r = line.range(of: "return ") else { return nil }
    return line[r.upperBound...].split(separator: " ").first.map(String.init)
}

let harness = """
import Foundation
import CoreGraphics
var out: [String] = []
func R(_ k: String, _ v: Any) { out.append("R \\(k)=\\(v)") }
let levels: [CGFloat] = [\(multipliers.joined(separator: ", "))]
for (i, m) in levels.enumerated() {
    let t = UserAskTypography(body: UserAskTypography.bodyReference * m)
    R("L\\(i)", [t.question, t.optionTitle, t.optionDetail, t.secondary, t.title, t.meta, t.chip, t.button, t.icon, t.resolvedTopic, t.resolvedDetail].map { String(format: "%.1f", Double($0)) }.joined(separator: ","))
}
R("tap", UserAskTypography.minTapHeight)
R("ref", UserAskTypography.bodyReference)
print(out.joined(separator: "\\n"))
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-type-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Typography.swift", "import Foundation\nimport CoreGraphics\n" + block), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("FontScaleLevel multipliers read from FontSettings (6)", multipliers.count == 6)
check("shipping UserAskTypography compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}
// question, optionTitle, optionDetail, secondary, title, meta, chip, button, icon, resolvedTopic, resolvedDetail
let rows: [[Double]] = (0..<6).map { i in (r["L\(i)"] ?? "").split(separator: ",").compactMap { Double($0) } }

print("\n1. Sizes per Appearance step (XS … Extra Large)")
for (i, row) in rows.enumerated() { print("     L\(i): \(row)") }
let def = rows.count == 6 ? rows[2] : []
check("Default step: question = chat body (16.5), options/buttons 16, descriptions 13.5",
      def.count == 11 && def[0] == 16.5 && def[1] == 16 && def[7] == 16 && def[2] == 13.5)
check("bigger than the old fixed card sizes at Default (15 / 14 / 12 / 14)",
      def.count == 11 && def[0] > 15 && def[1] > 14 && def[2] > 12 && def[7] > 14)
check("every size grows (or holds at its floor) from XS to Extra Large",
      rows.allSatisfy { $0.count == 11 } && (0..<11).allSatisfy { k in zip(rows, rows.dropFirst()).allSatisfy { $0[k] <= $1[k] } })
check("the largest step really is larger than the default",
      rows.count == 6 && (0..<11).allSatisfy { rows[5][$0] >= rows[2][$0] } && rows[5][0] > rows[2][0])
check("hierarchy at every step: question ≥ option title ≥ secondary ≥ description ≥ meta ≥ chip",
      rows.allSatisfy { $0.count == 11 && $0[0] >= $0[1] && $0[1] >= $0[3] && $0[3] >= $0[2] && $0[2] >= $0[5] && $0[5] >= $0[6] })
check("buttons ≈ option titles (same size) at every step", rows.allSatisfy { $0.count == 11 && $0[7] == $0[1] })
check("descriptions never below the previous fixed 12pt", rows.allSatisfy { $0.count == 11 && $0[2] >= 12 })
check("half-point rounding (no 16.005-style sizes)", rows.joined().allSatisfy { ($0 * 2).rounded() == $0 * 2 })
check("tap targets ≥ 44pt", r["tap"] == "44.0")

print("\n2. Source guards")
check("the base is the chat body size: bubbles use scaledMessage(16.5) and so does the card",
      r["ref"] == "16.5" && source("Views/Chat/ChatMessageViews.swift").contains("FontSettings.shared.scaledMessage(16.5)")
      && card.contains("UserAskTypography(body: FontSettings.shared.scaledMessage(bodyReference))"))
// Only icon glyphs (header badge, resolved badge) and the chevron keep a fixed size.
let fixed = card.split(separator: "\n").filter { $0.contains(".font(.system(size: ") && $0.contains(".font(.system(size: 1") }
check("no fixed text sizes left on the card (only the 3 icon/chevron glyphs)", fixed.count == 3)
let observers = card.components(separatedBy: "@ObservedObject private var fonts = FontSettings.shared").count - 1
check("card, pending card, resolved card, answer sheet and summary tile observe FontSettings (re-render on change)", observers == 5)
check("buttons get the derived size and a 44pt minimum height",
      card.contains("minHeight: UserAskTypography.minTapHeight)") && card.contains(".font(.system(size: fontSize, weight: .semibold))")
      && card.components(separatedBy: "fontSize: t.button)").count - 1 == 4)   // Previous, Next/Submit, Cancel, Allow once
check("tappable rows (options, Other, You decide, note, cancel reason) are ≥44pt",
      card.components(separatedBy: ".frame(minHeight: UserAskTypography.minTapHeight)").count - 1 == 4)
check("the list re-measures every cell when the message font changes",
      messageListV3Source().contains("NotificationCenter.default.publisher(for: .fontSettingsMessageBaseChanged)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
