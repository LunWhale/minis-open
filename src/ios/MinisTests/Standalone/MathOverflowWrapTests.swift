// [T-math-overflow-wrap] A formula wider than the line was clipped at the
// right edge (reported: the long "shaded area = ..." display formula inside a
// list item). It is now re-laid out to the line width: fallback (CJK) text
// wraps like text, SwiftMath formulas break into rows before top-level
// relations, and a row that still does not fit is scaled down.
//
// The split function below is copied from SwiftMathRenderer.swift; section 2
// fails if the shipping copy drifts from it.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift MathOverflowWrapTests.swift`

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
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

let renderer = src("Agent/Markdown/SwiftMathRenderer.swift")
let md = markdownModuleSource()
let thisFile = (try? String(contentsOfFile: #filePath, encoding: .utf8)) ?? ""
check("sources found", !renderer.isEmpty && !md.isEmpty)

// ---- copy of SwiftMathRenderer.splitAtTopLevelRelations ----
let breakRelations = ["\\Leftrightarrow", "\\Rightarrow", "\\approx", "\\equiv",
                                     "\\neq", "\\leq", "\\geq", "\\ne", "\\le", "\\ge",
                                     "=", "<", ">"]

/// Split `latex` before every relation that sits at brace depth 0 and
/// outside `\left…\right`. Environments are left whole: their `&` / `\\`
/// layout must not be cut apart.
func splitAtTopLevelRelations(_ latex: String) -> [String] {
    guard !latex.contains("\\begin") else { return [latex] }
    let chars = Array(latex)
    var pieces: [String] = []
    var current = ""
    var depth = 0, leftRight = 0
    var i = 0
    func matches(_ token: String, at index: Int) -> Bool {
        let t = Array(token)
        guard index + t.count <= chars.count, Array(chars[index..<index + t.count]) == t else { return false }
        if t.first == "\\", index + t.count < chars.count, chars[index + t.count].isLetter { return false }
        return true
    }
    while i < chars.count {
        let c = chars[i]
        if c == "\\" && i + 1 < chars.count && (chars[i + 1] == "{" || chars[i + 1] == "}") {
            current.append(c); current.append(chars[i + 1]); i += 2; continue
        }
        if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
        if matches("\\left", at: i) { leftRight += 1 } else if matches("\\right", at: i) { leftRight = max(0, leftRight - 1) }
        if depth == 0 && leftRight == 0 && !current.trimmingCharacters(in: .whitespaces).isEmpty,
           let token = breakRelations.first(where: { matches($0, at: i) }) {
            pieces.append(current)
            current = token
            i += token.count
            continue
        }
        current.append(c)
        i += 1
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
}

// ---- end copy ----

print("\n▶️  1. break points")
let f = #"\text{阴影面积} = 130 \times \frac{40}{169} = \frac{400}{13} \approx 30.77"#
let p = splitAtTopLevelRelations(f)
check("splits before each top-level relation", p.count == 4)
check("pieces rejoin to the original", p.joined() == f)
check("continuation rows start with the relation", p[1].hasPrefix("=") && p[3].hasPrefix(#"\approx"#))
check("no split inside braces", splitAtTopLevelRelations(#"\frac{a=b}{c}"#).count == 1)
check("no split inside \\left…\\right", splitAtTopLevelRelations(#"\left( x = 1 \right) = y"#).count == 2)
check("\\le does not match \\left", splitAtTopLevelRelations(#"\left[ a \right]"#).count == 1)
check("\\le as a relation does split", splitAtTopLevelRelations(#"a \le b"#).count == 2)
check("environments are left whole", splitAtTopLevelRelations(#"\begin{aligned} a &= b \end{aligned}"#).count == 1)
check("escaped braces don't unbalance depth", splitAtTopLevelRelations(#"\{ a \} = b"#).count == 2)
check("leading relation is not split into an empty piece", splitAtTopLevelRelations("= a").count == 1)

print("\n▶️  2. source invariants")
func fnBody(_ text: String) -> String {
    guard let a = text.range(of: "func splitAtTopLevelRelations"),
          let b = text.range(of: "return pieces\n", range: a.upperBound..<text.endIndex) else { return "" }
    return text[a.lowerBound..<b.upperBound].split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
}
check("test copy matches the shipping split function", !fnBody(renderer).isEmpty && fnBody(renderer) == fnBody(thisFile))
check("fallback path wraps at the line width",
      renderer.contains("let constraintWidth: CGFloat = wrapWidth.map { max(1, $0 - 4) } ?? (displayMode ? 600 : 2000)"))
check("formulas that fit are returned untouched", renderer.contains("if full.size.width <= width { return full }"))
check("SwiftMath rows only on main; off-main scales",
      renderer.contains("guard Thread.isMainThread else { return scaled(full, toWidth: width) }"))
check("attachment bounds use the fitted size", md.contains("let shown = fittedResult(forLineWidth: lineFrag.width)"))
check("overlay view shows the fitted image", md.contains("if let img = displayImage {"))
// [T-table-cell-math-fit] Table columns are capped now (TableColumnPlanner),
// so cell formulas fit their cell too — and TextKit draws the fitted bitmap.
check("table cells fit too (no inlineDrawable exemption)",
      md.contains("guard width > 0, let img = renderedImage, img.size.width > width + 0.5 else {")
      && !md.contains("guard !inlineDrawable, width > 0"))
check("a fitted cell formula is what TextKit draws", md.contains("if inlineDrawable { self.image = r.image }"))
check("dropping the fit restores the full image for cells", md.contains("if inlineDrawable { self.image = renderedImage }"))
check("the ~10M SwiftUI probe keeps the last real-width fit (T-math-fit-probe)",
      md.contains("if width >= 100_000 { return fitted?.result }"))
check("a new fit rebuilds the overlay view", md.contains("fitted = (width, r)\n            needsViewRebuild = true"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
