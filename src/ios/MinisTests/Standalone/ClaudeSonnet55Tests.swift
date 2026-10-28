// Tests for [T-anthropic-sonnet55] — Claude Sonnet 5.5 (claude-sonnet-5-5),
// from CLIProxyAPI registry commit 9a3b869f ("feat(models): add
// claude-sonnet-5-5 model"): 1M context, 128K output, text + image in,
// thinking levels low…max.
//
// Compiles the REAL ThinkingLevelCatalog and the REAL Claude version gates
// (parseClaudeVersion + the three predicates, extracted from
// AnthropicProvider.swift) and runs the new id through them, next to
// claude-sonnet-5 whose wire behaviour it must share.
//
// Standalone: `swift ClaudeSonnet55Tests.swift` from this directory.
import Foundation

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func src(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let types = src("Providers/LLMTypes.swift")
let catalog = src("Providers/ThinkingLevelCatalog.swift")
let provider = src("Providers/Anthropic/AnthropicProvider.swift")
let ua = src("Providers/Anthropic/OAuthHTTPClient.swift")
check("sources readable", !types.isEmpty && !catalog.isEmpty && !provider.isEmpty && !ua.isEmpty)

print("▶️  catalog entry")
let entry: String = {
    guard let r = types.range(of: "static let claudeSonnet55 = LLMModel(") else { return "" }
    return String(types[r.lowerBound...].prefix(260))
}()
check("claudeSonnet55 is defined as claude-sonnet-5-5 / \"Claude Sonnet 5.5\"",
      entry.contains("id: \"claude-sonnet-5-5\"") && entry.contains("displayName: \"Claude Sonnet 5.5\"")
      && entry.contains("provider: \"Anthropic\""))
check("1M context, 128K output (upstream values)",
      entry.contains("contextWindow: 1_000_000") && entry.contains("maxOutputTokens: 128_000"))
check("no modality override: Claude's provider default (text + image) applies, as for Sonnet 5",
      !entry.contains("modalityOverride"))
let list: String = {
    guard let s = types.range(of: "static let allAnthropic: [LLMModel] = ["),
          let e = types.range(of: "]", range: s.upperBound..<types.endIndex) else { return "" }
    return String(types[s.upperBound..<e.lowerBound])
}()
check("allAnthropic lists it, right before Sonnet 5",
      list.contains(".claudeSonnet55, .claudeSonnet5,"))

print("▶️  real ThinkingLevelCatalog + real Claude version gates")
func extract(_ text: String, from start: String, through endMarker: String) -> String? {
    guard let s = text.range(of: start),
          let e = text.range(of: endMarker, range: s.upperBound..<text.endIndex) else { return nil }
    return String(text[s.lowerBound..<e.upperBound])
}
// parseClaudeVersion … offThinking(for:), as shipped.
guard let gates = extract(provider, from: "    static func parseClaudeVersion(",
                          through: "        return .lowEffort\n    }") else {
    print("❌ could not extract the Claude version gates"); exit(1)
}
let harness = """
import Foundation
enum ThinkingLevel: String { case off, low, medium, high, xhigh, max, ultra }
\(catalog)
enum Gates {
\(gates)
}
for id in CommandLine.arguments.dropFirst() {
    let v = Gates.parseClaudeVersion(id).map { "\\($0.major).\\($0.minor)" } ?? "nil"
    print("\\(id) ceiling=\\(ThinkingLevelCatalog.declaredMaxLevel(for: id)?.rawValue ?? "nil") version=\\(v) noTemp=\\(Gates.modelRejectsTemperature(id)) adaptive=\\(Gates.modelUsesAdaptiveThinking(id)) off=\\(Gates.offThinking(for: id))")
}
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("s55-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("catalog + gates compile standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, ["claude-sonnet-5-5", "claude-sonnet-5.5", "anthropic/claude-sonnet-5.5", "claude-sonnet-5"])
func line(_ id: String) -> String { o.split(separator: "\n").first { $0.hasPrefix(id + " ") }.map(String.init) ?? "" }
let s55 = line("claude-sonnet-5-5"), s5 = line("claude-sonnet-5")
check("Max is reachable: ceiling .max for claude-sonnet-5-5", s55.contains("ceiling=max"))
check("…also for the dotted spelling (claude-sonnet-5.5)", line("claude-sonnet-5.5").contains("ceiling=max"))
// Deliberately NOT for vendor-prefixed relay ids, like the claude-opus rules:
// a rule can RAISE a ceiling above a model's declared tiers
// (catalogMaxThinkingLevel), and an OpenRouter-style relay publishing
// anthropic/claude-sonnet-5.5 speaks its own effort ladder.
check("…but not for a vendor-prefixed relay id (anthropic/claude-sonnet-5.5)",
      line("anthropic/claude-sonnet-5.5").contains("ceiling=nil"))
check("the rule is scoped to 5-5: claude-sonnet-5 keeps its catalog-derived ceiling (no rule)",
      s5.contains("ceiling=nil"))
check("parsed as Claude 5.5", s55.contains("version=5.5"))
check("Claude-5 wire path: no temperature, adaptive thinking",
      s55.contains("noTemp=true") && s55.contains("adaptive=true") && s5.contains("noTemp=true") && s5.contains("adaptive=true"))
// [T-claude5-thinking-off] Per Anthropic's per-model table: Sonnet 5.5 400s on
// `disabled` and takes `between_tools`; Sonnet 5 accepts `disabled`.
check("thinking off: Sonnet 5.5 → between_tools", s55.contains("off=betweenTools"))
check("thinking off: Sonnet 5 → disabled", s5.contains("off=disabled"))

print("▶️  models.dev snapshot")
if let data = FileManager.default.contents(atPath: root + "Resources/models-dev-api.json"),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let anth = (json["anthropic"] as? [String: Any])?["models"] as? [String: Any] {
    // The 2026-09-29 snapshot refresh added it. The explicit entry + rule stay:
    // the rule is the ceiling's floor when a lookup misses (stale on-device
    // catalog, relay spelling).
    let s55m = anth["claude-sonnet-5-5"] as? [String: Any]
    let s55efforts = ((s55m?["reasoning_options"] as? [[String: Any]]) ?? [])
        .compactMap { $0["values"] as? [String] }.flatMap { $0 }
    check("claude-sonnet-5-5 is in the snapshot with low…max",
          s55efforts == ["low", "medium", "high", "xhigh", "max"])
    check("…and a release date, so it ranks above Sonnet 5",
          ((s55m?["release_date"] as? String) ?? "") >= "2026-09-28")
    let s5m = anth["claude-sonnet-5"] as? [String: Any]
    let opts = (s5m?["reasoning_options"] as? [[String: Any]]) ?? []
    let efforts = opts.compactMap { $0["values"] as? [String] }.flatMap { $0 }
    check("the stage-3 prefix fallback target claude-sonnet-5 declares low…max",
          efforts == ["low", "medium", "high", "xhigh", "max"])
}

print("▶️  CLI fingerprint")
if let r = ua.range(of: #"claude-cli/(\d+)\.(\d+)\.(\d+)"#, options: .regularExpression) {
    print("  ℹ️  \(ua[r])")
    check("claude-cli fingerprint still >= 2.1.280 (Opus 5.5's floor)",
          ua[r].split(separator: "/")[1].split(separator: ".").map { Int($0)! }.lexicographicallyPrecedes([2, 1, 280]) == false)
}

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
