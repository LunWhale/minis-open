#!/usr/bin/env swift
// [T-ios-inline-code-multiline-rect] A long inline code span wrapping across
// many lines lost its background on the left half of lines 2-3 (session
// "整理OpenMins群近七天反馈", list item "#81037：`Provider error: [400] …`").
// TextKit passes fillBackgroundRectArray the first line's partial rect, ONE
// rect covering all full middle lines, and the last line's partial rect;
// MinisLayoutManager assumed one line per rect.
//
//   [1] the shipping MinisLayoutManager.splitRectsPerLine (BEGIN/END block),
//       compiled standalone: the measured 3-rect case, single-line and
//       two-line spans unchanged, rect edges kept, empty input
//   [2] real TextKit (AppKit NSLayoutManager, same TextKit 1 engine): the
//       rects it hands to fillBackgroundRectArray for that list item, split,
//       each cover exactly one line fragment
//   [3] source guards: fillBackgroundRectArray splits before its per-line pass
//
// Run: swift InlineCodeMultilineRectTests.swift   (needs swiftc)
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
guard let block = between(lmSource, "// BEGIN splitRectsPerLine", "// END splitRectsPerLine") else {
    print("❌ splitRectsPerLine block not found"); exit(1)
}

let harness = #"""
import AppKit
func f(_ r: CGRect) -> String { String(format: "%.0f,%.0f,%.0f,%.0f", r.minX, r.minY, r.width, r.height) }
func line(_ y: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 360, height: h) }

// Measured on TextKit for the reported list item at width 360.
let lines = [line(0, 24), line(24, 22), line(46, 22), line(68, 22), line(90, 22),
             line(112, 22), line(134, 22), line(156, 22), line(178, 18)]
let measured = [CGRect(x: 200, y: 0, width: 160, height: 24),
                CGRect(x: 0, y: 24, width: 360, height: 154),
                CGRect(x: 0, y: 178, width: 33.3, height: 18)]
let split = S.splitRectsPerLine(measured, lineFragments: lines)
print("R measured.count=\(split.count)")
print("R measured.first=\(f(split[0]))")
print("R measured.line2=\(f(split[1]))")
print("R measured.line8=\(f(split[7]))")
print("R measured.last=\(f(split[8]))")
let mids = split.map { $0.midY }
print("R measured.onePerLine=\(zip(split, lines).allSatisfy { abs($0.minY - $1.minY) < 0.01 && abs($0.height - $1.height) < 0.01 })")
print("R measured.sorted=\(mids == mids.sorted())")

// One-line span: one rect, one line -> untouched.
let single = CGRect(x: 40, y: 0, width: 80, height: 24)
print("R single.same=\(S.splitRectsPerLine([single], lineFragments: [line(0, 24)]) == [single])")
// Two-line span: two partial rects, each on its own line -> untouched.
let two = [CGRect(x: 200, y: 0, width: 160, height: 24), CGRect(x: 0, y: 24, width: 90, height: 22)]
print("R two.same=\(S.splitRectsPerLine(two, lineFragments: [line(0, 24), line(24, 22)]) == two)")
print("R empty=\(S.splitRectsPerLine([], lineFragments: lines).isEmpty)")

// Real TextKit: capture what fillBackgroundRectArray receives for the item.
final class LM: NSLayoutManager {
    var got: [[CGRect]] = []
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        got.append((0..<count).map { rectArray[$0] })
    }
}
let code = "Provider error: [400] input[0].image[0]: You have uploaded an unsupported image. Please make sure your image is valid and has one of the following formats: webp, png, jpeg, and gif. (request_id: ac4dcadf-85e7-4c37-8ba9-143d11de2849)"
let ps = NSMutableParagraphStyle(); ps.headIndent = 24; ps.lineSpacing = 4
let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17), .paragraphStyle: ps]
let text = NSMutableAttributedString(string: "•\t09-25 16:10 #81037：", attributes: body)
var codeAttrs = body
codeAttrs[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
codeAttrs[.backgroundColor] = NSColor.gray
text.append(NSAttributedString(string: code, attributes: codeAttrs))
let storage = NSTextStorage(attributedString: text)
let lm = LM(); storage.addLayoutManager(lm)
let tc = NSTextContainer(size: NSSize(width: 360, height: 10000)); tc.lineFragmentPadding = 0
lm.addTextContainer(tc)
let all = lm.glyphRange(for: tc)
let img = NSImage(size: NSSize(width: 400, height: 400))
img.lockFocus(); lm.drawBackground(forGlyphRange: all, at: .zero); img.unlockFocus()
let raw = lm.got.first ?? []
var frags: [CGRect] = []
let codeGlyphs = lm.glyphRange(forCharacterRange: NSRange(location: text.length - (code as NSString).length, length: (code as NSString).length), actualCharacterRange: nil)
lm.enumerateLineFragments(forGlyphRange: codeGlyphs) { r, _, _, _, _ in frags.append(r) }
let realSplit = S.splitRectsPerLine(raw, lineFragments: frags)
print("R real.rawHasMultiLineRect=\(raw.contains { r in frags.filter { $0.midY >= r.minY && $0.midY <= r.maxY }.count > 1 })")
print("R real.eachSplitOneLine=\(realSplit.allSatisfy { r in frags.filter { $0.midY >= r.minY && $0.midY <= r.maxY }.count == 1 })")
print("R real.coversAllLines=\(Set(realSplit.map { $0.minY }) == Set(frags.map { $0.minY }))")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inline-code-rects-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Split.swift", "import CoreGraphics\nenum S {\n" + block + "\n}\n"), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping splitRectsPerLine compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for l in out.split(separator: "\n") where l.hasPrefix("R ") {
    let body = l.dropFirst(2)
    guard let eq = body.firstIndex(of: "=") else { continue }
    r[String(body[..<eq])] = String(body[body.index(after: eq)...])
}

print("\n1. Splitting")
check("the measured 3 rects become 9, one per line", r["measured.count"] == "9")
check("line 1 keeps its partial extent (starts after the prefix)", r["measured.first"] == "200,0,160,24")
check("line 2 spans from the left edge - the half that went blank", r["measured.line2"] == "0,24,360,22")
check("line 8 (last full middle line) is its own rect", r["measured.line8"] == "0,156,360,22")
check("the last partial line is kept as is", r["measured.last"] == "0,178,33,18")
check("each split rect is exactly its line's band", r["measured.onePerLine"] == "true")
check("output stays in top-to-bottom order", r["measured.sorted"] == "true")
check("a one-line span is returned unchanged", r["single.same"] == "true")
check("a two-line span is returned unchanged", r["two.same"] == "true")
check("no rects in, none out", r["empty"] == "true")

print("\n2. Real TextKit")
check("TextKit really passes a rect covering several lines for this item", r["real.rawHasMultiLineRect"] == "true")
check("after the split every rect covers exactly one line", r["real.eachSplitOneLine"] == "true")
check("every line of the span still gets a rect", r["real.coversAllLines"] == "true")

print("\n3. Wired in")
check("fillBackgroundRectArray splits before the per-line pass",
      lmSource.contains("let perLineRects = Self.splitRectsPerLine(")
      && lmSource.contains("for var rawRect in perLineRects {"))
check("the old one-rect-per-iteration loop is gone", !lmSource.contains("var rawRect = rectArray[i]"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
