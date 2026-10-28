#!/usr/bin/env swift
// [T-ios-inline-code-pad-gap] Inline code in CJK prose sat in a too-wide
// gap: "目录枚举返回空：`ls /` 没输出，`echo /*` 不展开" showed ~3 spaces' worth
// of blank between each chip and the next word, while its left side looked
// normal (screenshot 2026-10-08).
//
// The renderer pads every span with U+200A on both sides. In Menlo, the
// inline code font, U+200A is a full 0.6em cell (~8.4pt), not a hair. The
// visible-glyph clamp (T-ios-inline-code-quote-band, 56e649620) stripped all
// trailing whitespace, U+200A included, so the pill stopped 2pt past the last
// glyph and the trailing pad was left outside it as bare space, on top of the
// source's own space. Only real break spaces are stripped now.
//
//   [1] the shipping trailingBreakWhitespaceCount (BEGIN/END block),
//       compiled standalone, on the slice shapes the clamp sees
//   [2] real TextKit (AppKit NSLayoutManager, same TextKit 1 engine) on the
//       reported sentence with the renderer's attributes: blank between the
//       pill and the next glyph before vs after; a wrapped span still has
//       its break space clamped
//   [3] source guards
//
// Run: swift InlineCodePadGapTests.swift   (needs swiftc)
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
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let lmSource = source("Views/Chat/Markdown/TextKit/MinisLayoutManager.swift")
let rendererSource = source("Views/Chat/Markdown/Rendering/MarkdownNSRenderer.swift")
let themeSource = source("Views/Chat/Markdown/Support/MarkdownTheme.swift")
guard let block = between(lmSource, "// BEGIN trailingBreakWhitespaceCount", "// END trailingBreakWhitespaceCount") else {
    print("❌ trailingBreakWhitespaceCount block not found"); exit(1)
}

let harness = #"""
import AppKit
enum S {
\#(block)
}
// The clamp as it was (56e649620): every trailing whitespace, U+200A included.
func oldCount(_ t: String) -> Int {
    t.count - t.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).count
}
let pad = "\u{200A}"
print("R slices=\(S.trailingBreakWhitespaceCount("ls /" + pad)),\(S.trailingBreakWhitespaceCount("foo/bar ")),\(S.trailingBreakWhitespaceCount("a" + pad + " ")),\(S.trailingBreakWhitespaceCount("x\t \n")),\(S.trailingBreakWhitespaceCount("")),\(S.trailingBreakWhitespaceCount(pad)),\(S.trailingBreakWhitespaceCount("abc"))")

// Renderer attributes: body 16.5pt system, code = Menlo at 0.845x padded with
// U+200A on both sides; `joiner` = the surrounding-font U+200A the renderer now
// puts in front of each span.
let base: CGFloat = 16.5
let body = NSFont.systemFont(ofSize: base)
let code = NSFont(name: "Menlo", size: base * 0.845)!
print(String(format: "R padWidth=%.2f", NSAttributedString(string: pad, attributes: [.font: code]).size().width))
print(String(format: "R space=%.2f", NSAttributedString(string: " ", attributes: [.font: body]).size().width))

func sentence(joiner: Bool) -> (NSAttributedString, [NSRange]) {
    let s = NSMutableAttributedString(); var spans: [NSRange] = []
    func t(_ x: String) { s.append(NSAttributedString(string: x, attributes: [.font: body])) }
    func c(_ x: String) {
        if joiner { t(pad) }
        let start = s.length
        s.append(NSAttributedString(string: pad + x + pad, attributes: [.font: code]))
        spans.append(NSRange(location: start, length: s.length - start))
    }
    // The reported line: chips after "：" / "，", and one at the start of a line.
    t("目录枚举返回空："); c("ls /"); t(" 没输出，"); c("echo /*"); t(" 不展开，"); c("PATH"); t(" 搜索\n")
    c("readdir"); t(" 路径的问题。")
    return (s, spans)
}
// The storage is returned too: a layout manager only holds it weakly.
func layout(_ str: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
    let ts = NSTextStorage(attributedString: str); let lm = NSLayoutManager(); ts.addLayoutManager(lm)
    let tc = NSTextContainer(size: CGSize(width: width, height: 1e6)); tc.lineFragmentPadding = 0
    lm.addTextContainer(tc); lm.ensureLayout(for: tc)
    return (ts, lm, tc)
}
// x where character `i` starts (glyph origin), on its own line.
func xAt(_ lm: NSLayoutManager, _ i: Int) -> CGFloat {
    let g = lm.glyphIndexForCharacter(at: i)
    return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x
}
// Pill right edge the way fillBackgroundRectArray computes it on a one-line
// span: TextKit's rect ends where the span's advance ends; the clamp shrinks it
// to the end of the last kept character + 2pt; the pill is then widened 0.5pt.
func pillMaxX(_ lm: NSLayoutManager, _ str: NSString, _ span: NSRange, trailing: (String) -> Int) -> CGFloat {
    let rawMaxX = xAt(lm, NSMaxRange(span))
    let kept = span.length - trailing(str.substring(with: span))
    let padded = xAt(lm, span.location + kept) + 2
    return (padded < rawMaxX ? padded : rawMaxX) + 0.5
}
func gaps(joiner: Bool, trailing: (String) -> Int) -> String {
    let (s, spans) = sentence(joiner: joiner)
    let (ts, lm, _) = layout(s, width: 1000)
    let str = s.string as NSString
    defer { withExtendedLifetime(ts) {} }
    return spans.map { r in
        // next visible glyph: skip the source's space after the chip
        String(format: "%.2f", xAt(lm, NSMaxRange(r) + 1) - pillMaxX(lm, str, r, trailing: trailing))
    }.joined(separator: ",")
}
func colonWidth(joiner: Bool) -> String {
    let (s, _) = sentence(joiner: joiner)
    let (ts, lm, _) = layout(s, width: 1000)
    defer { withExtendedLifetime(ts) {} }
    let i = (s.string as NSString).range(of: "：").location
    return String(format: "%.2f", xAt(lm, i + 1) - xAt(lm, i))
}
print("R oldGaps=\(gaps(joiner: false, trailing: oldCount))")
print("R newGaps=\(gaps(joiner: true, trailing: S.trailingBreakWhitespaceCount))")
print("R clampOnlyGaps=\(gaps(joiner: false, trailing: S.trailingBreakWhitespaceCount))")
print("R colonOld=\(colonWidth(joiner: false)) colonNew=\(colonWidth(joiner: true))")

// A span that wraps: its first line ends on the break space inside the code.
let w = NSMutableAttributedString(string: "看 ", attributes: [.font: body])
let longStart = w.length
w.append(NSAttributedString(string: pad + "alpha beta gamma delta epsilon zeta eta theta" + pad, attributes: [.font: code]))
let long = NSRange(location: longStart, length: w.length - longStart)
let (ts2, lm2, _) = layout(w, width: 220)
var firstLine = NSRange()
_ = lm2.lineFragmentRect(forGlyphAt: lm2.glyphIndexForCharacter(at: long.location), effectiveRange: &firstLine)
let lineChars = lm2.characterRange(forGlyphRange: NSIntersectionRange(firstLine, lm2.glyphRange(forCharacterRange: long, actualCharacterRange: nil)), actualGlyphRange: nil)
let slice = (w.string as NSString).substring(with: lineChars)
withExtendedLifetime(ts2) {}
print("R wrapEndsOnSpace=\(slice.hasSuffix(" ")) wrapTrim=\(S.trailingBreakWhitespaceCount(slice)) wrapOld=\(oldCount(slice))")
"""#

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inline_code_pad_gap_\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let src = dir.appendingPathComponent("h.swift"), exe = dir.appendingPathComponent("h")
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cs, cout) = run("/usr/bin/env", ["swiftc", "-O", src.path, "-o", exe.path])
let (rs, out) = cs == 0 ? run(exe.path, []) : (cs, cout)
try? FileManager.default.removeItem(at: dir)
func val(_ key: String) -> String {
    out.split(separator: "\n").first { $0.hasPrefix("R \(key)=") || $0.contains(" \(key)=") }
        .flatMap { line in line.components(separatedBy: " ").first { $0.hasPrefix("\(key)=") } }
        .map { String($0.dropFirst(key.count + 1)) } ?? ""
}

print("[1] trailingBreakWhitespaceCount")
check("harness built and ran", rs == 0)
if rs != 0 { print(out) }
// ls /+pad, "foo/bar ", a+pad+space, "x\t \n", "", pad only, "abc"
check("the span's U+200A pad is kept; break spaces are counted; stops at the pad",
      val("slices") == "0,1,1,3,0,0,0")

print("[2] TextKit, renderer attributes")
let padW = Double(val("padWidth")) ?? 0
let space = Double(val("space")) ?? 0
check("premise: Menlo's U+200A is a full cell (~8.4pt), not a hair", padW > 8 && padW < 9)
func nums(_ k: String) -> [Double] { val(k).split(separator: ",").compactMap { Double($0) } }
let oldG = nums("oldGaps"), newG = nums("newGaps"), clampG = nums("clampOnlyGaps")
print("      blank after each chip (ls / , echo /* , PATH , readdir), body space \(space)pt")
print("      before \(oldG)  after \(newG)  clamp fix alone \(clampG)")
print("      '：' width before \(val("colonOld"))  after \(val("colonNew"))")
check("before: the trailing pad was left outside the pill (> 8pt of blank after every chip)",
      oldG.count == 4 && oldG.allSatisfy { $0 > 8 })
check("after: only the source's space is left after every chip, the same for all four",
      newG.count == 4 && newG.allSatisfy { $0 > 0 && $0 < space + 0.6 }
      && (newG.max()! - newG.min()!) < 0.1)
check("after: '：' before a chip keeps its full width", (Double(val("colonNew")) ?? 0) > 16)
check("a wrapped line still ends on its break space and has it clamped (old and new agree)",
      out.contains("wrapEndsOnSpace=true wrapTrim=1 wrapOld=1"))

print("[3] Source guards")
let clamp = between(lmSource, "[T-ios-inline-code-quote-band] Measure out to the last", "let visibleCharRange") ?? ""
check("the clamp uses trailingBreakWhitespaceCount, not the \\s+$ regex",
      clamp.contains("let trailingWS = Self.trailingBreakWhitespaceCount(overlapText)") && !clamp.contains("\\\\s+$"))
check("premise: the renderer still pads spans with U+200A on both sides",
      rendererSource.contains("let span = NSAttributedString(string: \"\\u{200A}\\(Self.breakableInlineCode(code))\\u{200A}\","))
check("the renderer puts a surrounding-font U+200A in front of each span",
      rendererSource.contains("let joined = NSMutableAttributedString(string: \"\\u{200A}\", attributes: attrs)\n            joined.append(span)\n            return joined"))
check("premise: inline code is Menlo",
      themeSource.contains("if let menlo = UIFont(name: \"Menlo\", size: size)"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
