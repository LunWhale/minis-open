#!/usr/bin/env swift
// [T-gpt61-sol] GPT-6.1 Sol (OpenAI DevDay 2026-09-29), registered from
// CLIProxyAPI PR #6207 "register GPT-6.1 Sol and client capabilities":
//
//   gpt-6.1-sol   GPT-6.1 Sol   OpenAI Codex OAuth   272000 ctx / 128000 out
//   thinking levels low / medium / high / xhigh / max
//   minimal_client_version 0.155.0 · Team / Plus / Pro (not Free)
//
// Standalone half, like GPT6SolLunaOpus55CatalogTests: it re-reads the shipping
// sources, because the XCTest half (MinisTests/GPT6SolLunaOpus55Tests.swift)
// links `deps/libs/libish_emu.a`, which is device-arm64 only.
//
//   [1] static entry: id, name, reasoning flag, context / output limits
//   [2] offered over Codex OAuth, next to the other GPT-6 flagships
//   [3] thinking ceiling. The catalog rules are evaluated from the source in
//       their real order, so a rule that silently fails to match is caught:
//       "gpt-6-sol" is NOT a prefix of "gpt-6.1-sol", so without its own rule
//       the model had no declared ceiling at all.
//   [4] context window: the static value wins over the id heuristic, which has
//       no gpt-6 branch and would say 128K
//   [5] client version already clears the 0.155.0 gate
//
// Run: swift GPT61SolCatalogTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func codeOnly(_ src: String) -> String {
    src.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        .joined(separator: "\n")
}
func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

let types = codeOnly(source("Providers/LLMTypes.swift"))
let catalog = codeOnly(source("Providers/ThinkingLevelCatalog.swift"))
let openai = codeOnly(source("Providers/OpenAI/OpenAIProvider.swift"))

// MARK: - [1] static entry

print("▶️  1. static entry")
let entry = matches(#"static let gpt61Sol = LLMModel\(([^)]*)\)"#, in: types).first?[1] ?? ""
check("LLMModel.gpt61Sol exists", !entry.isEmpty)
check("id gpt-6.1-sol", entry.contains(#"id: "gpt-6.1-sol""#))
check("display name GPT-6.1 Sol", entry.contains(#"displayName: "GPT-6.1 Sol""#))
check("provider OpenAI", entry.contains(#"provider: "OpenAI""#))
check("REGRESSION hazard: supportsReasoning is explicit (not in models.dev → nil → effort collapses to \"low\")",
      entry.contains("supportsReasoning: true"))
check("context 272000, max output 128000 (registry values)",
      entry.contains("contextWindow: 272_000") && entry.contains("maxOutputTokens: 128_000"))

// MARK: - [2] Codex OAuth list

print("\n▶️  2. offered over Codex OAuth")
let list = matches(#"static let allOpenAICodexOAuth: \[LLMModel\] = \[([^\]]*)\]"#, in: types).first?[1] ?? ""
check("in allOpenAICodexOAuth", list.contains(".gpt61Sol"))
check("placed after gpt-6-astra and before gpt-6-sol",
      list.contains(".gpt6Astra, .gpt61Sol, .gpt6Sol, .gpt6Luna,"))
check("not in the API-key list (Codex OAuth only, like the other GPT-6 ids)",
      !(matches(#"static let allOpenAI: \[LLMModel\] = \[([^\]]*)\]"#, in: types).first?[1] ?? "").contains(".gpt61Sol"))

// MARK: - [3] thinking ceiling, evaluated from the source in rule order

print("\n▶️  3. thinking ceiling")
// Each rule: `({ <predicate> }, .<level>),` — collect the prefixes / substrings
// its predicate tests and evaluate them the way the closure does (lowercased
// id, first matching rule wins). Only the simple hasPrefix/contains shapes are
// modelled; the rules this test cares about use nothing else.
struct Rule { var prefixes: [String]; var contains: [String]; var dashPrefixes: [String]; var level: String }
let rulesBlock = catalog.components(separatedBy: "private static let rules")[safe: 1] ?? ""
var rules: [Rule] = []
for m in matches(#"\(\{ ([^}]*) \}, \.(\w+)\)"#, in: rulesBlock) {
    let pred = m[1]
    rules.append(Rule(prefixes: matches(#"\$0\.hasPrefix\("([^"]+)"\)"#, in: pred).map { $0[1] },
                      contains: matches(#"\$0\.contains\("([^"]+)"\)"#, in: pred).map { $0[1] },
                      dashPrefixes: matches(#"normalizedHasPrefix\(\$0, "([^"]+)"\)"#, in: pred).map { $0[1] },
                      level: m[2]))
}
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
func ceiling(_ id: String) -> String? {
    let lid = id.lowercased()
    return rules.first { r in
        r.prefixes.contains { lid.hasPrefix($0) } || r.contains.contains { lid.contains($0) }
            || r.dashPrefixes.contains { lid.replacingOccurrences(of: ".", with: "-").hasPrefix($0) }
    }?.level
}
check("parsed the catalog rules (\(rules.count))", rules.count > 8)
check("gpt-6.1-sol → .max", ceiling("gpt-6.1-sol") == "max")
check("…also the dash spelling a relay may use (gpt-6-1-sol)", ceiling("gpt-6-1-sol") == "max")
check("…and upper-case / suffixed ids", ceiling("GPT-6.1-Sol") == "max" && ceiling("gpt-6.1-sol-2026-09-29") == "max")
check("REGRESSION: the gpt-6-sol rule alone does not match gpt-6.1-sol",
      !"gpt-6.1-sol".hasPrefix("gpt-6-sol"))
check("never .ultra (Sol's ladder stops at max, like gpt-6-sol / astra)", ceiling("gpt-6.1-sol") != "ultra")
check("existing GPT-6 ids unchanged", ceiling("gpt-6-sol") == "max" && ceiling("gpt-6-luna") == "max" && ceiling("gpt-6-astra") == "max")

// MARK: - [4] context window

print("\n▶️  4. context window")
check("contextWindowTokens returns the stored value first",
      types.contains("if let ctx = contextWindow, ctx > 0 { return ctx }"))
check("the id heuristic has no gpt-6 branch (so the explicit value is load-bearing)",
      !types.contains(#"lid.contains("gpt-6")"#) && !types.contains(#"lid.hasPrefix("gpt-6")"#))

// MARK: - [5] client version

print("\n▶️  5. Codex client version")
let version = matches(#"static let codexClientVersion = "([0-9.]+)""#, in: openai).first?[1] ?? ""
func atLeast(_ v: String, _ floor: String) -> Bool {
    let a = v.split(separator: ".").map { Int($0) ?? 0 }, b = floor.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return true
}
check("codexClientVersion \(version) ≥ 0.155.0 (gpt-6.1-sol's minimal_client_version)",
      !version.isEmpty && atLeast(version, "0.155.0"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
