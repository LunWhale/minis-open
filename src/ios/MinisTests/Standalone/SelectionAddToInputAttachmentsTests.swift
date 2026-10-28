// [T-selection-add-to-input-attachments] "Add to Chat Input" dropped code
// blocks, tables and formulas from a selection.
//
// Those blocks are NSTextAttachments: the view's `text` holds a single U+FFFC
// for each, and addSelectionToChatInput read `text` directly, so the input bar
// got nothing for them. It now goes through SelectionTextExpander (shared with
// Copy / Read Selection), which also learned code blocks — Copy lost them too.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift SelectionAddToInputAttachmentsTests.swift`

import Foundation

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

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
let md = markdownModuleSource()
let vm = chatViewModelSource()
check("sources found", !md.isEmpty && !vm.isEmpty)

// MARK: - port of SelectionTextExpander over a run list

enum Run { case text(String), table(String), math(String, block: Bool), code(String, lang: String?), image }

func fenced(_ code: String, language: String?) -> String {
    var longest = 0, run = 0
    for ch in code { run = ch == "`" ? run + 1 : 0; longest = max(longest, run) }
    let fence = String(repeating: "`", count: max(3, longest + 1))
    let body = code.hasSuffix("\n") ? code : code + "\n"
    return "\(fence)\(language ?? "")\n\(body)\(fence)"
}
func expand(_ runs: [Run], includeCode: Bool = true) -> String {
    var out = ""
    var afterFence = false
    for r in runs {
        if afterFence {
            afterFence = false
            if case .text(let t) = r, t.hasPrefix("\n") {} else { out += "\n" }
        }
        switch r {
        case .table(let t): out += t
        case .math(let l, let b): out += b ? "$$\(l)$$" : "$\(l)$"
        case .code(let c, let lang):
            guard includeCode else { continue }
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += fenced(c, language: lang); afterFence = true
        case .image: continue
        case .text(let t): out += t
        }
    }
    return out.replacingOccurrences(of: "\u{FFFC}", with: "")
}

print("\n▶️  1. selection spanning special blocks")
let sel: [Run] = [.text("看这段：\n"), .code("print(1)", lang: "python"), .text("\n表格：\n"),
                  .table("a\tb\n1\t2"), .text("\n公式 "), .math("x^2", block: false), .text(" 结束")]
let out = expand(sel)
check("code block arrives fenced with its language", out.contains("```python\nprint(1)\n```"))
check("table arrives as cells", out.contains("a\tb\n1\t2"))
check("inline math arrives as $…$", out.contains("$x^2$"))
check("surrounding text kept", out.hasPrefix("看这段：\n") && out.hasSuffix(" 结束"))
check("no U+FFFC leaks", !out.contains("\u{FFFC}"))
check("text right after a fence goes to a new line",
      expand([.code("a", lang: nil), .text("next")]) == "```\na\n```\nnext")
check("text glued before a fence is broken onto its own line",
      expand([.text("see"), .code("a", lang: nil)]) == "see\n```\na\n```")
check("code containing ``` gets a longer fence",
      fenced("x ``` y", language: "md").hasPrefix("````md\n") && fenced("x ``` y", language: "md").hasSuffix("\n````"))
check("TTS path (includeCode=false) skips code, keeps the rest",
      expand(sel, includeCode: false).contains("$x^2$") && !expand(sel, includeCode: false).contains("print(1)"))
check("an image has no text form and is dropped", expand([.text("a"), .image, .text("b")]) == "ab")

print("\n▶️  2. appendToInputText keeps fences on their own lines")
func append(_ draft: String, _ snippet: String) -> String {
    let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return draft }
    let startsWithFence = trimmed.hasPrefix("```")
    let tail = trimmed.hasSuffix("```") ? "\n" : " "
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return trimmed + tail }
    let sep = startsWithFence ? (draft.hasSuffix("\n") ? "" : "\n")
                              : ((draft.last?.isWhitespace ?? false) ? "" : " ")
    return draft + sep + trimmed + tail
}
check("plain snippet unchanged: space separated", append("hi", "there") == "hi there ")
check("fenced snippet after a draft starts on a new line", append("look", "```\na\n```") == "look\n```\na\n```\n")
check("draft ending in newline gets no extra break", append("look\n", "```\na\n```") == "look\n```\na\n```\n")
check("empty draft: fence then newline so typing starts below it", append("", "```\na\n```") == "```\na\n```\n")

print("\n▶️  3. source invariants")
check("body add-to-input uses the expander, not `text`",
      md.contains("let snippet = plainTextWithTables(in: selectedRange)\n        NotificationCenter.default.post("))
check("table-cell add-to-input uses the expander",
      md.contains("let snippet = SelectionTextExpander.expand(attributedText ?? NSAttributedString(),"))
check("no add-to-input path slices `text` any more",
      !md.contains("let snippet = String(text[range])"))
check("expander handles CodeBlockAttachment", md.contains("} else if let code = value as? CodeBlockAttachment {"))
check("expander strips U+FFFC", md.contains(".replacingOccurrences(of: \"\\u{FFFC}\", with: \"\")"))
check("Read Selection keeps skipping code", md.contains("plainTextWithTables(in: selectedRange, includeCode: false)"))
check("appendToInputText is fence-aware", vm.contains("let tail = trimmed.hasSuffix(\"```\") ? \"\\n\" : \" \""))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
