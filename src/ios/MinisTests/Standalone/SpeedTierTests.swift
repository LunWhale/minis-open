#!/usr/bin/env swift
// [T-codex-speed-tier] "Enable Fast Mode" → Speed tiers (Standard / Fast /
// Ultrafast).
//
//   [1] storage migration, run against a real UserDefaults suite: the old Bool
//       `codexFastModeEnabled == true` reads as Fast, the tier key wins once
//       written, writes keep the Bool in step (downgrade-safe)
//   [2] Ultrafast whitelist (gpt-6-astra prefix only — [T-ultrafast-astra-only])
//   [3] request `service_tier` per tier: none / "priority" / "ultrafast"; a
//       non-whitelisted model falls back to "priority"; non-gpt ids get none
//   [4] xAI never receives "ultrafast"
//   [5] routing hint value + catalogue-declared Ultrafast [T-codex-routing-hint,
//       T-codex-ultrafast-echo]; the old "account doesn't support Ultrafast"
//       notice is gone
//   [6] source guards: every injection site goes through SpeedTierSettings, the
//       old single switch is kept when Ultrafast is not offered, both menus
//       agree, strings exist in every language
//
// [1]–[5] compile the SHIPPING Providers/OpenAI/SpeedTier.swift with swiftc.
// Run: swift SpeedTierTests.swift
import Foundation

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let harness = #"""
import Foundation
func out(_ k: String, _ v: Any) { print("\(k)=\(v)") }
let suite = "speedtier-test-\(UUID().uuidString)"
let d = UserDefaults(suiteName: suite)!
defer { d.removePersistentDomain(forName: suite) }
let S = SpeedTierSettings.self

// [1] migration
out("EMPTY", S.storedTier(in: d).rawValue)
d.set(true, forKey: S.legacyFastModeKey)
out("LEGACY_TRUE", S.storedTier(in: d).rawValue)
d.set(false, forKey: S.legacyFastModeKey)
out("LEGACY_FALSE", S.storedTier(in: d).rawValue)
S.setTier(.ultrafast, in: d)
out("SET_ULTRA", "\(S.storedTier(in: d).rawValue)|\(d.bool(forKey: S.legacyFastModeKey))|\(d.string(forKey: S.tierDefaultsKey) ?? "nil")")
S.setTier(.standard, in: d)
out("SET_STD", "\(S.storedTier(in: d).rawValue)|\(d.bool(forKey: S.legacyFastModeKey))")
S.setTier(.fast, in: d)
out("SET_FAST", "\(S.storedTier(in: d).rawValue)|\(d.bool(forKey: S.legacyFastModeKey))")
d.set("warp9", forKey: S.tierDefaultsKey); d.set(true, forKey: S.legacyFastModeKey)
out("GARBAGE_TIER", S.storedTier(in: d).rawValue)
d.set("standard", forKey: S.tierDefaultsKey); d.set(true, forKey: S.legacyFastModeKey)
out("TIER_WINS", S.storedTier(in: d).rawValue)

// [2] whitelist
for id in ["gpt-6.1-sol", "GPT-6.1-Sol", "gpt-6.1-sol-2026-09-29", "gpt-6-astra", "gpt-6-astra-pro",
           "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "grok-4.20", "openai/gpt-6.1-sol"] {
    out("WL_\(id)", S.supportsUltrafast(modelId: id))
}

// [3] request bodies
for (tier, name) in [(SpeedTier.standard, "std"), (.fast, "fast"), (.ultrafast, "ultra")] {
    for id in ["gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol", "grok-4.20"] {
        out("REQ_\(name)_\(id)", S.responsesServiceTier(stored: tier, modelId: id) ?? "none")
    }
}
out("EFF_ULTRA_OFFLIST", S.effectiveTier(.ultrafast, modelId: "gpt-5.5").rawValue)

// [4] xAI
out("XAI", [SpeedTier.standard, .fast, .ultrafast].map { S.xaiServiceTier(stored: $0) ?? "none" }.joined(separator: ","))

// [5] routing hint + catalogue declaration
out("HINT_TIER", S.codexRoutingHint(model: "gpt-6-astra", serviceTier: "ultrafast") ?? "nil")
out("HINT_PRIO", S.codexRoutingHint(model: "gpt-5.6-sol", serviceTier: "priority") ?? "nil")
out("HINT_NOTIER", S.codexRoutingHint(model: "gpt-6-astra", serviceTier: nil) ?? "nil")
out("HINT_EMPTYTIER", S.codexRoutingHint(model: "gpt-6-astra", serviceTier: "") ?? "nil")
out("HINT_NOMODEL", S.codexRoutingHint(model: nil, serviceTier: "priority") ?? "nil")
out("HINT_FIELD", S.routingHintHeaderField)
out("DECL", [
    S.catalogDeclaresUltrafast(["service_tiers": [["id": "priority", "name": "Fast"]], "additional_speed_tiers": ["fast"]]),
    S.catalogDeclaresUltrafast(["service_tiers": [["id": "priority"], ["id": "ultrafast", "name": "Ultrafast"]]]),
    S.catalogDeclaresUltrafast(["additional_speed_tiers": ["fast", "Ultrafast"]]),
    S.catalogDeclaresUltrafast([:]),
].map { $0 ? "1" : "0" }.joined())
S.recordCatalogUltrafast(modelIds: [], in: d)
out("CAT_NONE", ["gpt-6-astra", "gpt-5.6-sol"].map { S.supportsUltrafast(modelId: $0, in: d) ? "1" : "0" }.joined())
S.recordCatalogUltrafast(modelIds: ["GPT-5.6-Sol"], in: d)
out("CAT_DECLARED", ["gpt-5.6-sol", "gpt-5.6-sol-x", "gpt-6-astra", "gpt-5.5"].map { S.supportsUltrafast(modelId: $0, in: d) ? "1" : "0" }.joined())
out("CAT_REQ", S.responsesServiceTier(stored: .ultrafast, modelId: "gpt-5.6-sol", in: d) ?? "none")
// [T-ultrafast-unsupported-log] the catalogue above declares only gpt-5.6-sol
out("NOTE_UNSUP", S.ultrafastUnsupportedNote(stored: .ultrafast, modelId: "gpt-5.5", in: d) ?? "nil")
out("NOTE_WL", S.ultrafastUnsupportedNote(stored: .ultrafast, modelId: "gpt-6-astra", in: d) ?? "nil")
out("NOTE_DECL", S.ultrafastUnsupportedNote(stored: .ultrafast, modelId: "gpt-5.6-sol", in: d) ?? "nil")
out("NOTE_FAST", S.ultrafastUnsupportedNote(stored: .fast, modelId: "gpt-5.5", in: d) ?? "nil")
out("NOTE_GROK", S.ultrafastUnsupportedNote(stored: .ultrafast, modelId: "grok-4.20", in: d) ?? "nil")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("speedtier-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = [("SpeedTier.swift", source("Providers/OpenAI/SpeedTier.swift")), ("main.swift", harness)]
for (name, text) in files { try text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin])
check("shipping SpeedTier.swift compiles standalone", cc == 0)
if cc != 0 { print(ccOut) }
let (rc, output) = cc == 0 ? run(bin, []) : (-1, "")
check("harness runs", rc == 0)
var r: [String: String] = [:]
for line in output.split(separator: "\n") {
    guard let eq = line.firstIndex(of: "=") else { continue }
    r[String(line[..<eq])] = String(line[line.index(after: eq)...])
}

print("\n▶️  1. storage migration")
check("nothing stored → Standard", r["EMPTY"] == "standard")
check("MIGRATION: old switch on (Bool true) → Fast, same behaviour as before", r["LEGACY_TRUE"] == "fast")
check("old switch off → Standard", r["LEGACY_FALSE"] == "standard")
check("choosing Ultrafast writes the tier AND leaves the Bool on (an older build reads Fast)", r["SET_ULTRA"] == "ultrafast|true|ultrafast")
check("choosing Standard turns the Bool off", r["SET_STD"] == "standard|false")
check("choosing Fast turns the Bool on", r["SET_FAST"] == "fast|true")
check("an unknown tier value falls back to the Bool", r["GARBAGE_TIER"] == "fast")
check("a valid tier wins over the Bool", r["TIER_WINS"] == "standard")

print("\n▶️  2. Ultrafast whitelist")
for id in ["gpt-6-astra", "gpt-6-astra-pro"] {
    check("\(id) → offered", r["WL_\(id)"] == "true")
}
// [T-ultrafast-astra-only] gpt-6.1-sol was whitelisted from DevDay coverage;
// OpenAI's Codex docs make Ultrafast GPT-6 Astra only.
for id in ["gpt-6.1-sol", "GPT-6.1-Sol", "gpt-6.1-sol-2026-09-29",
           "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "grok-4.20", "openai/gpt-6.1-sol"] {
    check("\(id) → not offered", r["WL_\(id)"] == "false")
}

print("\n▶️  3. service_tier per tier")
for id in ["gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol"] { check("Standard + \(id) → no field", r["REQ_std_\(id)"] == "none") }
for id in ["gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol"] { check("Fast + \(id) → priority", r["REQ_fast_\(id)"] == "priority") }
check("Ultrafast + gpt-6.1-sol → priority (Astra only, per OpenAI's Codex speed docs)", r["REQ_ultra_gpt-6.1-sol"] == "priority")
check("Ultrafast + gpt-6-astra → ultrafast", r["REQ_ultra_gpt-6-astra"] == "ultrafast")
check("FALLBACK: Ultrafast + a model outside the whitelist → priority, never ultrafast",
      r["REQ_ultra_gpt-5.6-sol"] == "priority" && r["EFF_ULTRA_OFFLIST"] == "fast")
check("non-gpt ids never get a tier on the Responses path (any tier)",
      r["REQ_std_grok-4.20"] == "none" && r["REQ_fast_grok-4.20"] == "none" && r["REQ_ultra_grok-4.20"] == "none")

print("\n▶️  4. xAI")
check("xAI: Standard → none, Fast → priority, Ultrafast → priority (never ultrafast)", r["XAI"] == "none,priority,priority")

print("\n▶️  5. routing hint + catalogue declaration")
check("with a tier: model=<m>;tier=<t> (official build_routing_hint_header shape)", r["HINT_TIER"] == "model=gpt-6-astra;tier=ultrafast")
check("Fast's wire value appears as-is", r["HINT_PRIO"] == "model=gpt-5.6-sol;tier=priority")
check("no tier → model=<m> only (also for an empty tier)", r["HINT_NOTIER"] == "model=gpt-6-astra" && r["HINT_EMPTYTIER"] == "model=gpt-6-astra")
check("no model → no header", r["HINT_NOMODEL"] == "nil")
check("header name x-codex-routing-hint", r["HINT_FIELD"] == "x-codex-routing-hint")
check("catalogue declaration: only an \"ultrafast\" id counts (today's priority/fast entries do not)", r["DECL"] == "0110")
check("no catalogue declaration → whitelist fallback unchanged (the user's decision)", r["CAT_NONE"] == "10")
check("a catalogue declaration adds that exact model (case-insensitive), whitelist still applies",
      r["CAT_DECLARED"] == "1010")
check("…and a declared model is sent \"ultrafast\"", r["CAT_REQ"] == "ultrafast")

print("\n▶️  5b. unsupported-Ultrafast log line [T-ultrafast-unsupported-log]")
check("a model not offered Ultrafast is logged, naming the priority fallback",
      (r["NOTE_UNSUP"] ?? "").contains("not supported for model=gpt-5.5") && (r["NOTE_UNSUP"] ?? "").contains("service_tier=priority"))
check("whitelist-only (catalogue silent) is logged as likely served at Standard",
      (r["NOTE_WL"] ?? "").contains("fallback whitelist only") && (r["NOTE_WL"] ?? "").contains("service_tier=ultrafast"))
check("a catalogue-declared model is not logged", r["NOTE_DECL"] == "nil")
check("another tier chosen → nothing to log", r["NOTE_FAST"] == "nil")
check("non-gpt ids (xAI has its own priority path) → nothing to log", r["NOTE_GROK"] == "nil")
check("both Responses builders log the note",
      source("Providers/OpenAI/OpenAIProvider.swift").contains("SpeedTierSettings.ultrafastUnsupportedNote(")
      && source("Providers/OpenAI/OpenAIAgentProvider.swift").contains("SpeedTierSettings.ultrafastUnsupportedNote("))

print("\n▶️  6. source guards")
let op = source("Providers/OpenAI/OpenAIProvider.swift")
let agent = source("Providers/OpenAI/OpenAIAgentProvider.swift")
let view = chatViewSource()
let factory = source("Agent/Chat/AIChatViewModel+ProviderFactory.swift")
let tiers = source("Providers/OpenAI/SpeedTier.swift")
check("the legacy key is the old key (no silent reset for existing users)",
      tiers.contains("static let legacyFastModeKey = \"codexFastModeEnabled\"")
      && op.contains("static let fastModeDefaultsKey = SpeedTierSettings.legacyFastModeKey"))
check("no request builder reads the old Bool directly any more",
      !op.contains("bool(forKey: Self.fastModeDefaultsKey)") && !agent.contains("bool(forKey: OpenAIProvider.fastModeDefaultsKey)"))
let tierCall = "SpeedTierSettings.responsesServiceTier(\n            stored: SpeedTierSettings.storedTier(), modelId: model.id)"
check("both Responses builders take service_tier from the tier", op.contains(tierCall) && agent.contains(tierCall))
func codeOnly(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
let xaiSites = (try? NSRegularExpression(pattern: #"sendsPriorityServiceTier \{\s*body\["service_tier"\] = "priority""#))
    .map { $0.numberOfMatches(in: op + agent, range: NSRange((op + agent).startIndex..., in: op + agent)) } ?? 0
check("xAI paths still write the constant \"priority\" (4 sites: chat + Responses in each builder), gated by sendsPriorityServiceTier",
      op.contains("isXAI && SpeedTierSettings.xaiServiceTier(stored: SpeedTierSettings.storedTier()) != nil")
      && xaiSites == 4)
check("\"ultrafast\" is written nowhere in code but SpeedTier.wireValue",
      !codeOnly(op).contains("\"ultrafast\"") && !codeOnly(agent).contains("\"ultrafast\"")
      && !codeOnly(view).contains("\"ultrafast\""))
// [T-codex-ultrafast-echo] An echoed "default" is no verdict about the account.
check("REGRESSION: no \"account doesn't support Ultrafast\" toast or its plumbing is left",
      !view.contains("doesn't support Ultrafast") && !view.contains("ultrafastNotHonored")
      && !agent.contains("ultrafastNotHonored") && !tiers.contains("UltrafastNotice")
      && !tiers.contains("ultrafastWasDowngraded") && !factory.contains("resolveSessionIdForNotices")
      && !op.contains("resolveSessionIdForNotices"))
check("the echo is logged side by side without a verdict",
      agent.contains("let requestedServiceTier = body[\"service_tier\"] as? String")
      && agent.contains("[SpeedTier] requested service_tier=\\(requestedServiceTier); server echoed service_tier=\\(effectiveTier ?? \"nil\") (not verifiable for ChatGPT auth)")
      && !agent.contains("ultrafast not honored"))
// [T-codex-routing-hint] Both Codex OAuth builders, from the final body, never for API key.
check("the routing hint is applied in both Codex builders, just before the body is serialised, Codex-only",
      op.components(separatedBy: "if isCodexOAuth { Self.applyCodexRoutingHint(to: &request, body: body) }\n        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])").count - 1 == 2)
check("the header value comes from the body's model and service_tier",
      op.contains("model: body[\"model\"] as? String, serviceTier: body[\"service_tier\"] as? String)")
      && op.contains("forHTTPHeaderField: SpeedTierSettings.routingHintHeaderField"))
check("the Codex flags that gate it are the ChatGPT-backend ones (API key / custom base excluded)",
      op.contains("let isCodexOAuth = isResponsesAPI && !forceResponsesAPI && isOAuth && customBaseURL == nil")
      && op.contains("let isCodexOAuth = !forceResponsesAPI && isOAuth && customBaseURL == nil"))
let modelsApi = source("Providers/OpenAI/OpenAIModelsAPI.swift")
check("discovery records catalogue Ultrafast declarations on every success",
      modelsApi.contains("SpeedTierSettings.recordCatalogUltrafast(modelIds: ultrafastIds)")
      && modelsApi.contains("SpeedTierSettings.catalogDeclaresUltrafast($0)"))
check("UI: Ultrafast offered only on top of Fast, never for xAI, via the whitelist",
      view.contains("guard activeModelSupportsFastMode else { return false }")
      && view.contains("instance.providerType != .xAI else { return false }")
      && view.contains("return SpeedTierSettings.supportsUltrafast(modelId: modelId)"))
check("UI shows Fast when Ultrafast is chosen but not offered (matches the request)",
      view.contains("if stored == .ultrafast, !activeModelSupportsUltrafast { return .fast }"))
check("UIKit: the old single switch when Ultrafast is not offered",
      view.contains("if key.showFastModeToggle && !key.showUltrafast {")
      && view.contains("coordinator.parent.setSpeedTier(fastOn ? .standard : .fast)"))
check("UIKit: otherwise a single-selection Speed submenu with the tier as subtitle",
      view.contains("options: .singleSelection") && view.contains("speedMenu.subtitle = key.speedTier.title"))
check("SwiftUI fallback mirrors both shapes",
      view.contains("if showFastModeToggle && !showUltrafast {") && view.contains("set: { setSpeedTier($0 ? .fast : .standard) }")
      && view.contains("Text(verbatim: speedTier.title)"))
check("rebuild keys carry the tier and the offer (toolbar host, SwiftUI ==, UIKit Key)",
      view.contains("diffs.append(\"speedTier\")") && view.contains("&& lhs.speedTier == rhs.speedTier")
      && view.components(separatedBy: "let showUltrafast: Bool").count - 1 == 4)
// [T-codex-speed-icons] Native SF Symbols instead of emoji prefixes.
func block(_ s: String, from a: String, to b: String) -> String {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.lowerBound..<r2.upperBound])
}
let tierExt = block(view, from: "extension SpeedTier {", to: "\n}\n")
check("titles are text only (no emoji; the icon is the SF Symbol)",
      tierExt.contains("case .fast: return AppLocalized(\"Fast\")")
      && tierExt.contains("case .ultrafast: return AppLocalized(\"Ultrafast\")")
      && !view.contains("⚡") && !tiers.contains("⚡"))
check("tier symbols: speedometer / outline bolt / filled bolt",
      tierExt.contains("case .standard: return \"speedometer\"") && tierExt.contains("case .fast: return \"bolt\"")
      && tierExt.contains("case .ultrafast: return \"bolt.fill\""))
check("Speed entry uses speedometer (UIKit + SwiftUI)",
      tierExt.contains("static let entrySymbol = \"speedometer\"")
      && view.contains("image: UIImage(systemName: SpeedTier.entrySymbol),")
      && view.contains("Image(systemName: SpeedTier.entrySymbol)"))
check("each tier row carries its symbol (UIKit + SwiftUI); selection is the system checkmark",
      view.contains("UIAction(title: tier.title,\n                         image: UIImage(systemName: tier.symbol),\n                         state: key.speedTier == tier ? .on : .off)")
      && view.contains("Label(tier.title, systemImage: tier.symbol).tag(tier)"))
check("the plain Fast switch (models without Ultrafast) uses the same outline bolt, UIKit + SwiftUI",
      view.contains("Label(AppLocalized(\"Enable Fast Mode\"), systemImage: SpeedTier.fast.symbol)")
      && view.contains("UIAction(title: AppLocalized(\"Enable Fast Mode\"),\n                                              image: UIImage(systemName: SpeedTier.fast.symbol),")
      && !view.contains("Label(AppLocalized(\"Enable Fast Mode\"), systemImage: \"bolt.fill\")"))
check("badge: one monochrome glyph (outline = Fast, filled = Ultrafast), no double bolt, labelled",
      view.contains("if let symbol = displayedSpeedTier.badgeSymbol {")
      && view.contains(".accessibilityLabel(Text(verbatim: displayedSpeedTier.title))")
      && tierExt.contains("self == .standard ? nil : symbol")
      && !view.contains("HStack(spacing: -1) {\n                                Image(systemName: \"bolt.fill\")")
      && view.contains("speedBadge: displayedSpeedTier"))

let catalogData = (try? Data(contentsOf: ios.appendingPathComponent("Localizable.xcstrings"))) ?? Data()
let strings = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
let allLocales = Set(((strings["Enable Fast Mode"] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]).keys)
for key in ["Speed", "Standard", "Fast", "Ultrafast"] {
    let locs = Set(((strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]).keys)
    check("string \"\(key.prefix(40))\" in every language (\(locs.count)/\(allLocales.count))",
          allLocales.count >= 18 && allLocales.isSubset(of: locs))
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
