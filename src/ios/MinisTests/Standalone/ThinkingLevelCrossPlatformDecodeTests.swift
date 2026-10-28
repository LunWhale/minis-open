// Tests for [T-ios-restore-thinking-level] — an Android backup's thinking
// levels restore on iOS at the level the user set, not silently raised.
//
// Android persists ThinkingLevel by enum NAME ("HIGH"); iOS by raw value
// ("high"). iOS parsed with the case-sensitive `init(rawValue:)`, so:
//   • `ThinkingLevel.decoded("HIGH")` fell back to `.xhigh` (group default
//     levels, per-model ceilings: "High" on Android came back "XHigh"),
//   • `ThinkingLevel(rawValue: "HIGH")` returned nil (sub agent overrides
//     in the backup importer: the level was dropped),
//   • the synthesized Codable decoder threw on "HIGH".
// The Android side of the same mismatch is T-android-restore-thinking-level.
//
// Standalone (`swift ThinkingLevelCrossPlatformDecodeTests.swift`) like its
// neighbours. The enum's parsing surface is mirrored below; section [4]
// re-reads the shipping sources so the mirror and the call sites cannot drift.

import Foundation

// Mirrors the shipped ThinkingLevel parsing surface (Providers/LLMTypes.swift).
enum ThinkingLevel: String, Codable, CaseIterable {
    case off, low, medium, high, xhigh, max, ultra

    static func parse(_ raw: String) -> ThinkingLevel? {
        ThinkingLevel(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func decoded(_ raw: String) -> ThinkingLevel {
        parse(raw) ?? .xhigh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let level = ThinkingLevel.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown ThinkingLevel \"\(raw)\""
            )
        }
        self = level
    }
}

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if ok { print("✅ \(name)") } else { print("❌ \(name)"); failures += 1 }
}

// [1] Android spelling reads as the same level, not a raised one.
print("[1] parse / decoded")
let androidNames = ["OFF", "LOW", "MEDIUM", "HIGH", "XHIGH", "MAX", "ULTRA"]
for (name, level) in zip(androidNames, ThinkingLevel.allCases) {
    check(ThinkingLevel.parse(name) == level, "parse(\"\(name)\") == .\(level.rawValue)")
    check(ThinkingLevel.decoded(name) == level, "decoded(\"\(name)\") == .\(level.rawValue), not .xhigh")
}
check(ThinkingLevel.decoded("high") == .high, "iOS spelling still reads")
check(ThinkingLevel.parse(" High ") == .high, "mixed case + whitespace")
check(ThinkingLevel.parse("SUPREME") == nil, "unknown level parses to nil")
check(ThinkingLevel.decoded("SUPREME") == .xhigh, "unknown level still clamps to .xhigh")

// [2] Codable: Android JSON decodes; unknown still throws; encoding unchanged.
print("[2] Codable")
struct Group: Codable { var defaultThinkingLevel: ThinkingLevel? }
let dec = JSONDecoder()
let g = try? dec.decode(Group.self, from: Data(#"{"defaultThinkingLevel":"HIGH"}"#.utf8))
check(g?.defaultThinkingLevel == .high, "synthesized container decodes Android \"HIGH\"")
let ios = try? dec.decode(Group.self, from: Data(#"{"defaultThinkingLevel":"max"}"#.utf8))
check(ios?.defaultThinkingLevel == .max, "iOS \"max\" still decodes")
check((try? dec.decode(Group.self, from: Data(#"{"defaultThinkingLevel":"SUPREME"}"#.utf8))) == nil,
      "unknown level still throws (callers' fallbacks unchanged)")
let map = try? dec.decode([ThinkingLevel].self, from: Data(#"["LOW","ultra"]"#.utf8))
check(map == [.low, .ultra], "array of mixed spellings")
let enc = String(data: try! JSONEncoder().encode(Group(defaultThinkingLevel: .high)), encoding: .utf8)!
check(enc == #"{"defaultThinkingLevel":"high"}"#, "encoding still writes the iOS raw value")

// [3] Round trip through the Android spelling (Android backup → iOS → iOS backup).
print("[3] round trip")
for level in ThinkingLevel.allCases {
    let wire = "{\"defaultThinkingLevel\":\"\(level.rawValue.uppercased())\"}"
    let back = try? dec.decode(Group.self, from: Data(wire.utf8))
    check(back?.defaultThinkingLevel == level, "\(level.rawValue.uppercased()) → .\(level.rawValue)")
}

// [4] Source guards: the shipped enum and the call sites that read Android data.
print("[4] source guards")
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iosRoot = here.deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let llm = src("Providers/LLMTypes.swift")
check(llm.contains("ThinkingLevel(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"),
      "LLMTypes: parse() is case-insensitive")
check(llm.contains("parse(raw) ?? .xhigh"), "LLMTypes: decoded() goes through parse()")
check(llm.contains("guard let level = ThinkingLevel.parse(raw) else"), "LLMTypes: init(from:) goes through parse()")
check(llm.contains("case off\n    case low\n    case medium\n    case high\n    case xhigh\n    case max\n    case ultra"),
      "LLMTypes: mirror above has the shipped cases")
for rel in ["Agent/Backup/BackupImporter+Categories.swift",
            "Agent/Sync/V2/ChatStoreSyncHydrators.swift",
            "Providers/Thinking/ThinkingRuleCoding.swift",
            "Views/Chat/HelperBlockView.swift",
            "Shared/Config/ConfigRegistry+Builtins.swift"] {
    let s = src(rel)
    check(!s.isEmpty && !s.contains("ThinkingLevel(rawValue:"), "\(rel): no case-sensitive ThinkingLevel(rawValue:)")
}

if failures == 0 { print("ALL PASSED") } else { print("\(failures) FAILED"); exit(1) }
