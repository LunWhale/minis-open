// [T-composer-typing-lag] Typing in the composer lagged while a reply streamed
// or a shell tool ran (iPhone 8 / iOS 16.1 Time Profiler, 37 s: 24 main-thread
// hangs, main thread at 71% of a core).
//
//   AppLocalized → String(localized:)   18.3% of main (15% from ToolCapsuleView.body)
//   ProviderConfigStore.entry(for:)     ~15% (≈6 calls per AIChatView.body)
//
// Both run once per body evaluation, and the chat body re-runs per streamed
// token. Fixes: memoize argument-free AppLocalized keys per bundle; index
// entry(for:) instead of up to four linear scans.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift ComposerTypingLagTests.swift`

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
let loc = src("Shared/AppLocalization.swift")
let store = src("Providers/ProviderConfigStore.swift")
check("sources found", !loc.isEmpty && !store.isEmpty)

print("\n▶️  1. plain literals resolve to the cached StaticString overload")
// Round 2 (second iOS 16 trace): the first version recovered the key from a
// LocalizationValue by reflection; its layout differs on iOS 16, the cache
// never hit and AppLocalized was still 25% of the main thread. Overload
// resolution picks the key at compile time instead.
// Round 3 (third trace, idle typing): an unlabeled LocalizedStringResource
// overload also accepts string literals and WON for every call without
// `comment:` (and for interpolated ones), so the cache still never hit. The
// resource overload is labeled `resource:` now; the model includes it.
@_disfavoredOverload func pick(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String { "LV" }
func pick(_ key: StaticString, comment: StaticString? = nil) -> String { "SS:\(key)" }
func pick(resource: LocalizedStringResource) -> String { "RES" }
let n = 3
check("plain literal → StaticString (cached)", pick("Run Command") == "SS:Run Command")
let res: LocalizedStringResource = "r"
check("a real resource still resolves via the label", pick(resource: res) == "RES")
check("source: resource overload is labeled", loc.contains("func AppLocalized(resource: LocalizedStringResource) -> String {")
      && !loc.contains("func AppLocalized(_ resource: LocalizedStringResource)"))
check("…also with a comment", pick("Run Command", comment: "c") == "SS:Run Command")
check("interpolated literal → LocalizationValue (uncached)", pick("\(n) chats") == "LV")
let v: String.LocalizationValue = "x"
check("LocalizationValue variable → LocalizationValue", pick(v) == "LV")
check("source: LocalizationValue overload is disfavored",
      loc.contains("@_disfavoredOverload\nfunc AppLocalized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {"))
check("source: StaticString overload is cached",
      loc.contains("func AppLocalized(_ key: StaticString, comment: StaticString? = nil) -> String {")
      && loc.contains("if let hit = LocalizedStringCache.lookup(plain, bundle: bundle) { return hit }"))
check("source: no reflection left", !loc.contains("Mirror(reflecting:"))

print("\n▶️  2. cache scoping")
final class Cache {
    var table: [String: String] = [:]; var bundle: Int?; let capacity = 3
    func lookup(_ k: String, _ b: Int) -> String? { bundle == b ? table[k] : nil }
    func store(_ v: String, _ k: String, _ b: Int) {
        if bundle != b || table.count >= capacity { table.removeAll(); bundle = b }
        table[k] = v
    }
}
do {
    let c = Cache()
    c.store("Ejecutar", "Run", 1)
    check("hit for the same bundle", c.lookup("Run", 1) == "Ejecutar")
    check("in-app language switch (other bundle) misses", c.lookup("Run", 2) == nil)
    c.store("Ausführen", "Run", 2)
    check("…and starts a fresh table", c.lookup("Run", 2) == "Ausführen" && c.table.count == 1)
    c.store("a", "A", 2); c.store("b", "B", 2); c.store("c", "C", 2)
    check("capacity bound resets instead of growing", c.table.count <= 3)
}
check("source: cache is locked", loc.contains("lock.lock(); defer { lock.unlock() }"))

print("\n▶️  3. entry index")
struct E { let id: String; let uuid: String; let colon: String }
let entries = [E(id: "i/a", uuid: "U1", colon: "i:a"), E(id: "i/b", uuid: "U2", colon: "i:b"), E(id: "i/a", uuid: "U3", colon: "i:a")]
var byId: [String: Int] = [:], byUuid: [String: Int] = [:], byColon: [String: Int] = [:]
for (i, e) in entries.enumerated() {
    if byId[e.id] == nil { byId[e.id] = i }
    if byUuid[e.uuid] == nil { byUuid[e.uuid] = i }
    if byColon[e.colon] == nil { byColon[e.colon] = i }
}
func lookup(_ r: String, legacy: [String: String] = [:]) -> Int? {
    if let i = byId[r] { return i }
    if let i = byUuid[r] { return i }
    if let m = legacy[r], let i = byId[m] { return i }
    return byColon[r]
}
check("duplicate ids: first occurrence wins, like first(where:)", lookup("i/a") == 0)
check("legacy uuid resolves", lookup("U2") == 1)
check("legacy uuid map resolves", lookup("OLD", legacy: ["OLD": "i/b"]) == 1)
check("legacy colon key resolves", lookup("i:b") == 1)
check("unknown → nil", lookup("nope") == nil)
check("source: config change drops the index", store.contains("didSet { entryIndex = nil }"))
check("source: entry(for:) uses the index, no linear scans left",
      store.contains("if let i = index.byId[entryId] { return entries[i] }")
      && !store.contains("config.modelEntries.first(where: { $0.legacyColonCompositeKey == entryId })"))

print("\n▶️  4. FloatingToolBar takes one block snapshot per render")
let bar = src("Views/Chat/ToolLiveSheet.swift")
check("body snapshots once and hands it to collapsedBar",
      bar.contains("let facts = blockFacts\n        Group {\n            if runningAgentIdx(in: facts) != nil {")
      && bar.contains("collapsedBar(now: Date(), facts: facts)"))
check("displayedIdx uses the passed snapshot", bar.contains("let idx = copy.displayedIdx(in: facts)")
      && bar.contains("if let held = recentlyFinishedIdx(in: facts) { return held }"))
check("no second snapshot inside displayedIdx", !bar.contains("`@Published` reads inside the index math.\n        let facts = blockFacts"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
