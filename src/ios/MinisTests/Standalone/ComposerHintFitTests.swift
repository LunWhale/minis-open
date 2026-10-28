#!/usr/bin/env swift
// [T-composer-hint-fit] The composer's context/quota usage line is shrunk to
// fit ONE line of the text view, down to `hintMinimumScale` of the input font.
//
//   [1] fittedHintPointSize, extracted from ChatInputBar.swift between its
//       BEGIN/END markers and compiled here, so the shipped logic is what runs
//   [2] real measurements (system font via CoreText) of the lines users see
//   [3] source guards: only the usage line shrinks; the label's font is not
//       re-synced over it; the input font is restored when it is retired
//
// Run: swift ComposerHintFitTests.swift
import Foundation
import CoreText

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let root = here.deletingLastPathComponent().deletingLastPathComponent()
let bar = (try? String(contentsOf: root.appendingPathComponent("Views/Chat/ChatInputBar.swift"), encoding: .utf8)) ?? ""
check("ChatInputBar.swift readable", !bar.isEmpty)

// MARK: - [1] compile the shipped function

func block(_ name: String) -> String {
    guard let a = bar.range(of: "// BEGIN \(name)\n"), let b = bar.range(of: "// END \(name)", range: a.upperBound..<bar.endIndex)
    else { return "" }
    return String(bar[a.upperBound..<b.lowerBound])
}
let fn = block("fittedHintPointSize")
check("fittedHintPointSize block found", fn.contains("static func fittedHintPointSize("))
let minScale = bar.range(of: #"static let hintMinimumScale: CGFloat = ([0-9.]+)"#, options: .regularExpression)
    .map { String(bar[$0]).components(separatedBy: "= ").last ?? "" } ?? ""
check("hintMinimumScale is 0.75", minScale == "0.75")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hintfit-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let harness = """
import Foundation
import CoreText
enum Fit {
    static let hintMinimumScale: CGFloat = \(minScale)
\(fn)
}
func width(_ s: String, _ pt: CGFloat) -> CGFloat {
    let font = CTFontCreateUIFontForLanguage(.system, pt, nil)!
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}
var out: [String] = []
// synthetic: linear, already fits, unknown width, floor, non-linear overshoot
out.append("fits=\\(Fit.fittedHintPointSize(base: 16.5, width: 400) { $0 * 20 })")
out.append("nowidth=\\(Fit.fittedHintPointSize(base: 16.5, width: 0) { $0 * 100 })")
out.append("floor=\\(Fit.fittedHintPointSize(base: 16.5, width: 100) { $0 * 100 })")
let lin = Fit.fittedHintPointSize(base: 16.5, width: 300) { $0 * 20 }
out.append("linear=\\(lin) ok=\\(lin * 20 <= 300 && (lin + 0.25) * 20 > 300)")
let bumpy = Fit.fittedHintPointSize(base: 16.5, width: 300) { $0 * 20 + 12 }
out.append("bumpy=\\(bumpy) ok=\\(bumpy * 20 + 12 <= 300)")
// real lines, 344pt of text = a 402pt-wide phone
for (name, s) in [("zh", "上下文 3% · 34.0k/1000k · 额度 5h 4%/7d 29%"),
                  ("en", "Context 3% · 34.0k/1000k · Quota 5h 4%/7d 29%"),
                  ("enmax", "Context 100% · 999.9k/1000k · Quota 5h 100%/7d 100%"),
                  ("ctx", "Context 62% · 124k/200k")] {
    let pt = Fit.fittedHintPointSize(base: 16.5, width: 344) { width(s, $0) }
    out.append("\\(name)=\\(pt) w=\\(Int(width(s, pt)))")
}
print(out.joined(separator: "\\n"))
"""
let src = tmp.appendingPathComponent("main.swift")
try? harness.write(to: src, atomically: true, encoding: .utf8)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["swift", src.path]
let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
try? p.run(); p.waitUntilExit()
let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
var r: [String: String] = [:]
for line in result.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { r[parts[0]] = parts[1] }
}
check("shipped function compiles and runs", p.terminationStatus == 0 && !r.isEmpty)
if p.terminationStatus != 0 { print(result) }

print("\n▶️  1. fitting logic")
check("already fits → input font unchanged (16.5)", r["fits"] == "16.5")
check("no layout yet (width 0) → input font unchanged", r["nowidth"] == "16.5")
check("never below 0.75× (16.5 → 12.375), wraps there instead", r["floor"] == "12.375")
check("linear width: largest 0.25pt step that fits", r["linear"]?.hasSuffix("ok=true") == true)
check("guess overshoots (non-linear width): steps down until it fits", r["bumpy"]?.hasSuffix("ok=true") == true)

print("\n▶️  2. real lines at 344pt (402pt-wide phone)")
func pt(_ k: String) -> Double { Double(r[k]?.components(separatedBy: " ").first ?? "") ?? 0 }
func w(_ k: String) -> Int { Int(r[k]?.components(separatedBy: "w=").last ?? "") ?? 999 }
check("zh screenshot line (344pt at 16.5, wrapped) shrinks a hair and fits: \(r["zh"] ?? "")",
      pt("zh") < 16.5 && pt("zh") >= 16 && w("zh") <= 344)
check("en typical fits one line above 15pt: \(r["en"] ?? "")", pt("en") >= 15 && w("en") <= 344)
check("en worst realistic fits one line, above the floor: \(r["enmax"] ?? "")", pt("enmax") > 12.375 && w("enmax") <= 344)
check("context-only line keeps the input font: \(r["ctx"] ?? "")", pt("ctx") == 16.5)

// MARK: - [3] source guards

print("\n▶️  3. source guards")
check("usage line is applied through the fitted font (show + page turn + re-assert)",
      bar.components(separatedBy: "fittedHint(hint, in: textView, fallbackFont: label.font)").count - 1 == 3)
check("attributedHint is no longer applied at the raw label font",
      !bar.contains("Self.attributedHint(hint, font: label.font)"))
check("fit baseline is the text view's (input) font, not the possibly-shrunk label font",
      bar.contains("let font = textView.font ?? fallbackFont"))
check("updateUIView does not re-sync the label font over the usage line",
      bar.contains("if label.font != inputFont, !context.coordinator.isTransientHintOnLabel { label.font = inputFont }"))
check("re-fit on width or input-font change",
      bar.contains("abs(textView.bounds.width - transientHintFitWidth) > 0.5")
      && bar.contains("$0.pointSize != transientHintFitBase"))
check("both retire paths restore the input font before the pool text",
      bar.components(separatedBy: "if let font = textView.font { label.font = font }").count - 1 == 2)
check("the on-label flag is set on apply and cleared on both retire paths — not by a new generation",
      bar.components(separatedBy: "isTransientHintOnLabel = true").count - 1 == 1
      && bar.components(separatedBy: "\n            isTransientHintOnLabel = false").count - 1 == 1
      && bar.components(separatedBy: "\n                isTransientHintOnLabel = false").count - 1 == 1)
check("the ordinary placeholder is never shrunk (only the hint path calls the fit)",
      bar.components(separatedBy: "fittedHintPointSize(").count - 1 == 2)

try? FileManager.default.removeItem(at: tmp)
print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
