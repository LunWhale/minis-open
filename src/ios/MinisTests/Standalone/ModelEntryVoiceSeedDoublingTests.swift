// Tests for [T-model-entry-voice-seed-doubling].
//
// ProviderConfigStore.replaceEntries re-adds catalog entries the provider did
// not list in two places: the absence-grace pass (`keptAbsent`, 974c19cbf)
// and the voice-template seed pass (`preservedVoice`, d20629088). An absent,
// non-custom voice seed matched both, so every refresh put two copies of it
// back, and the next refresh preserved each copy twice: 2^n copies after n
// refreshes. On the vphone iPad a MiniMax-backed instance reached 1,048,574
// copies of `speech-2.8-hd` / `speech-2.8-turbo` (303 MB provider-config.json);
// the process then ran out of memory, and the next launch spent >19 s decoding
// the file on the main thread and was killed by the scene-create watchdog.
//
// The copies are one entry, but not byte-identical: each refresh stamped the
// still-unstamped copies with its own time, so `absentSince` drifted (20
// different values on the vphone). Collapsing keeps the earliest stamp.
//
// The refresh rule is ported below (old and new); section [6] re-reads the
// sources so the port cannot drift from ProviderConfigStore.swift.
//
// Standalone (`swift ModelEntryVoiceSeedDoublingTests.swift`) like its neighbours.

import Foundation

var failures = 0
func check(_ l: String, _ a: Bool, _ e: Bool = true) {
    if a == e { print("  ✅ \(l)") } else { print("  ❌ \(l) — expected \(e), got \(a)"); failures += 1 }
}
func checkEq<T: Equatable>(_ l: String, _ a: T, _ b: T) {
    if a == b { print("  ✅ \(l)") } else { print("  ❌ \(l)\n     expected: \(b)\n     actual:   \(a)"); failures += 1 }
}

// MARK: - Ported model of the entry and the refresh rule

struct Entry: Equatable {
    var uuid: String
    var modelId: String
    var isCustom = false
    var isHidden = false
    var overrideName: String?        // stands in for ModelOverrides
    var absentSince: Date?
}

let grace: TimeInterval = 7 * 24 * 60 * 60
let voiceSeeds: Set<String> = ["speech-2.8-hd", "speech-2.8-turbo"]

/// ProviderConfigStore.collapsingRepeatedEntries (one instance here).
func collapse(_ entries: [Entry]) -> [Entry] {
    var indexByKey: [String: Int] = [:]
    var unique: [Entry] = []
    for entry in entries {
        guard let i = indexByKey[entry.uuid] else {
            indexByKey[entry.uuid] = unique.count
            unique.append(entry)
            continue
        }
        if let since = entry.absentSince, unique[i].absentSince.map({ since < $0 }) ?? true {
            unique[i].absentSince = since
        }
    }
    return unique
}

var uuidCounter = 0
func freshUUID() -> String { uuidCounter += 1; return "NEW-\(uuidCounter)" }

/// One refresh of one instance (replaceEntries). `fixed` selects the new behaviour.
func refresh(_ all: [Entry], listed rawListed: [String], now: Date, fixed: Bool) -> [Entry] {
    var seenIds = Set<String>()
    let listed = rawListed.filter { seenIds.insert($0).inserted }
    let existing = fixed ? collapse(all) : all
    let listedSet = Set(listed)
    var byModel: [String: Entry] = [:]
    for e in existing {
        if let prev = byModel[e.modelId], e.isCustom && !prev.isCustom { continue }
        byModel[e.modelId] = e
    }
    var out = listed.map { id -> Entry in
        let prior = byModel[id]
        return Entry(uuid: prior?.uuid ?? freshUUID(), modelId: id, isCustom: false,
                     isHidden: prior?.isHidden ?? false, overrideName: prior?.overrideName, absentSince: nil)
    }
    var keptAbsent: [Entry] = []
    for e in existing where !e.isCustom && !listedSet.contains(e.modelId) {
        let since = e.absentSince ?? now
        if now.timeIntervalSince(since) <= grace {
            var k = e; k.absentSince = since; keptAbsent.append(k)
        }
    }
    out += keptAbsent
    out += existing.filter { $0.isCustom && !listedSet.contains($0.modelId) }
    let keptUUIDs = Set(keptAbsent.map(\.uuid))
    out += existing.filter { e in
        !e.isCustom && !listedSet.contains(e.modelId) && voiceSeeds.contains(e.modelId)
            && (!fixed || !keptUUIDs.contains(e.uuid))
    }
    return out
}

let t0 = Date(timeIntervalSince1970: 1_791_400_000)
let start: [Entry] = [
    Entry(uuid: "U-OPUS", modelId: "claude-opus", overrideName: "My Opus"),
    Entry(uuid: "U-HD", modelId: "speech-2.8-hd"),
    Entry(uuid: "U-TURBO", modelId: "speech-2.8-turbo", isHidden: true),
    Entry(uuid: "U-MINE", modelId: "my-custom", isCustom: true),
]
let listed = ["claude-opus"]          // /models never lists the speech seeds

// MARK: - 1. The reported growth

print("\n▶️  old rule doubles an absent voice seed on every refresh")
var old = start
for i in 0..<10 { old = refresh(old, listed: listed, now: t0.addingTimeInterval(Double(i) * 3600), fixed: false) }
checkEq("10 refreshes -> 2^10 copies of speech-2.8-hd", old.filter { $0.modelId == "speech-2.8-hd" }.count, 1024)
checkEq("all copies share one uuid", Set(old.filter { $0.modelId == "speech-2.8-hd" }.map(\.uuid)).count, 1)
check("the copies' absence stamps drifted apart",
      Set(old.filter { $0.modelId == "speech-2.8-hd" }.map { $0.absentSince?.timeIntervalSince1970 ?? -1 }).count > 2)

// MARK: - 2. Fixed rule keeps exactly one copy

print("\n▶️  new rule keeps one copy per entry")
var new = start
for i in 0..<30 { new = refresh(new, listed: listed, now: t0.addingTimeInterval(Double(i) * 3600), fixed: true) }
checkEq("30 refreshes -> still 4 entries", new.count, 4)
checkEq("speech-2.8-hd once", new.filter { $0.modelId == "speech-2.8-hd" }.count, 1)
check("the seed keeps its first absence stamp", new.first { $0.modelId == "speech-2.8-hd" }?.absentSince == t0)
check("hidden flag kept", new.first { $0.uuid == "U-TURBO" }?.isHidden == true)
check("custom entry kept", new.contains { $0.uuid == "U-MINE" && $0.isCustom })
check("listed model keeps uuid and overrides", new.contains { $0.uuid == "U-OPUS" && $0.overrideName == "My Opus" && $0.absentSince == nil })

print("\n▶️  after the grace window the voice pass alone still keeps the seed once")
let late = refresh(new, listed: listed, now: t0.addingTimeInterval(grace + 7200), fixed: true)
checkEq("speech-2.8-hd once past grace", late.filter { $0.modelId == "speech-2.8-hd" }.count, 1)
checkEq("speech-2.8-turbo once past grace", late.filter { $0.modelId == "speech-2.8-turbo" }.count, 1)

// MARK: - 3. A bloated store heals without losing anything

print("\n▶️  a store that already holds copies heals")
let healedByRefresh = refresh(old, listed: listed, now: t0.addingTimeInterval(11 * 3600), fixed: true)
checkEq("one refresh collapses 2x1024 copies", healedByRefresh.count, 4)
check("the earliest stamp survives the refresh", healedByRefresh.first { $0.uuid == "U-HD" }?.absentSince == t0)
let healedByLoad = collapse(old)
checkEq("load keeps one entry per uuid", healedByLoad.count, 4)
check("load keeps the earliest stamp", healedByLoad.first { $0.uuid == "U-HD" }?.absentSince == t0)
check("load keeps the hidden flag", healedByLoad.first { $0.uuid == "U-TURBO" }?.isHidden == true)
let unstampedFirst = [Entry(uuid: "X", modelId: "speech-2.8-hd"),
                      Entry(uuid: "X", modelId: "speech-2.8-hd", absentSince: t0.addingTimeInterval(50)),
                      Entry(uuid: "X", modelId: "speech-2.8-hd", absentSince: t0.addingTimeInterval(10))]
check("a stamp beats a missing one, earliest wins", collapse(unstampedFirst).first?.absentSince == t0.addingTimeInterval(10))
let twoDistinct = [Entry(uuid: "A", modelId: "m"), Entry(uuid: "B", modelId: "m", isCustom: true)]
checkEq("distinct uuids for one model id are both kept", collapse(twoDistinct).count, 2)

// MARK: - 4. New rule == old rule, minus the duplicates (randomised)

print("\n▶️  randomised: new refresh output equals the old output with its copies merged")
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
let modelPool = ["claude-opus", "claude-sonnet", "gpt-x", "speech-2.8-hd", "speech-2.8-turbo", "whisper", "tts-1", "m1", "m2"]
var mismatches = 0, lossy = 0, dupsInNew = 0, cases = 0
for _ in 0..<3000 {
    cases += 1
    // An existing store as a pre-bug build left it: at most one entry per uuid.
    var existing: [Entry] = []
    var used = Set<String>()
    for (i, m) in modelPool.enumerated() where rnd(3) > 0 {
        let custom = rnd(5) == 0
        if !used.insert("\(m)/\(custom)").inserted { continue }
        let stamp: Date? = rnd(3) == 0 ? t0.addingTimeInterval(-Double(rnd(10)) * 86_400) : nil
        existing.append(Entry(uuid: "E\(i)\(custom ? "c" : "")", modelId: m, isCustom: custom,
                              isHidden: rnd(4) == 0, overrideName: rnd(3) == 0 ? "o\(i)" : nil, absentSince: stamp))
    }
    let listedNow = modelPool.filter { _ in rnd(2) == 0 } + (rnd(4) == 0 ? ["claude-opus"] : [])
    let now = t0.addingTimeInterval(Double(rnd(100)) * 3600)
    let saved = uuidCounter
    let oldOut = refresh(existing, listed: listedNow, now: now, fixed: false)
    uuidCounter = saved                     // same fresh uuids for both runs
    let newOut = refresh(existing, listed: listedNow, now: now, fixed: true)
    if newOut != collapse(oldOut) { mismatches += 1 }
    if Set(oldOut.map(\.uuid)) != Set(newOut.map(\.uuid)) { lossy += 1 }
    if Set(newOut.map(\.uuid)).count != newOut.count { dupsInNew += 1 }
}
checkEq("\(cases) cases: new == merge(old), entry for entry (fields and order)", mismatches, 0)
checkEq("no entry the old rule kept is missing from the new output", lossy, 0)
checkEq("the new output never repeats an entry", dupsInNew, 0)

// MARK: - 5. A store too big to decode in time is collapsed as raw JSON first

// Ported verbatim from ProviderConfigStore.collapsingDuplicateModelEntries.
func collapsingDuplicateModelEntries(in data: Data) -> Data? {
    guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let entries = root["modelEntries"] as? [[String: Any]] else { return nil }
    var indexByKey: [String: Int] = [:]
    var unique: [[String: Any]] = []
    unique.reserveCapacity(entries.count)
    for entry in entries {
        guard let uuid = entry["uuid"] as? String else { unique.append(entry); continue }
        let key = "\(entry["providerInstanceId"] as? String ?? "")/\(uuid)"
        guard let i = indexByKey[key] else {
            indexByKey[key] = unique.count
            unique.append(entry)
            continue
        }
        if let since = entry["absentSince"] as? Double,
           (unique[i]["absentSince"] as? Double).map({ since < $0 }) ?? true {
            unique[i]["absentSince"] = since
        }
    }
    guard unique.count != entries.count else { return nil }
    root["modelEntries"] = unique
    return try? JSONSerialization.data(withJSONObject: root)
}

print("\n▶️  raw-JSON collapse")
func entryJSON(_ uuid: String?, _ model: String, instance: String = "I", absent: Double? = nil) -> [String: Any] {
    var e: [String: Any] = ["providerInstanceId": instance, "isCustom": false, "isHidden": false,
                            "model": ["id": model, "displayName": "D \(model)", "modalityOverride": 128]]
    if let uuid { e["uuid"] = uuid }
    if let absent { e["absentSince"] = absent }
    return e
}
var bloatedEntries: [[String: Any]] = [entryJSON("A", "opus"), entryJSON("B", "speech-2.8-hd")]
for i in 0..<5000 { bloatedEntries.append(entryJSON("B", "speech-2.8-hd", absent: 813_203_700 - Double(i % 7))) }
bloatedEntries.append(entryJSON(nil, "legacy-no-uuid"))
bloatedEntries.append(entryJSON(nil, "legacy-no-uuid"))
bloatedEntries.append(entryJSON("B", "speech-2.8-hd", instance: "J"))
let bloated: [String: Any] = ["instances": [["id": "I"]], "modelEntries": bloatedEntries, "defaultPrimaryGroupId": "G"]
let bloatedData = try! JSONSerialization.data(withJSONObject: bloated)
if let healed = collapsingDuplicateModelEntries(in: bloatedData),
   let root = try? JSONSerialization.jsonObject(with: healed) as? [String: Any],
   let entries = root["modelEntries"] as? [[String: Any]] {
    checkEq("5004 entries -> 5 (uuid-less never merged; same uuid in another instance kept)", entries.count, 5)
    checkEq("earliest absence stamp kept", entries[1]["absentSince"] as? Double, 813_203_694)
    checkEq("the other copy fields are untouched", (entries[1]["model"] as? [String: Any])?["displayName"] as? String, "D speech-2.8-hd")
    check("other top-level keys survive", root["defaultPrimaryGroupId"] as? String == "G" && (root["instances"] as? [Any])?.count == 1)
    check("much smaller", healed.count * 100 < bloatedData.count)
} else {
    check("collapse produced a config", false)
}
check("nothing to collapse -> nil (file left as is)",
      collapsingDuplicateModelEntries(in: try! JSONSerialization.data(withJSONObject: ["modelEntries": [entryJSON("A", "x")]])) == nil)
check("not a config -> nil", collapsingDuplicateModelEntries(in: Data("[1,2]".utf8)) == nil)
check("corrupt bytes -> nil", collapsingDuplicateModelEntries(in: Data("{\"modelEntries\": [".utf8)) == nil)

// MARK: - 6. Source invariants

print("\n▶️  source invariants")
let here = URL(fileURLWithPath: #filePath)
let iosRoot = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard let store = try? String(contentsOf: iosRoot.appendingPathComponent("Providers/ProviderConfigStore.swift"), encoding: .utf8) else {
    print("  ❌ could not read ProviderConfigStore.swift"); exit(1)
}
check("replaceEntries merges existing copies first",
      store.contains("let existing = Self.collapsingRepeatedEntries(\n            config.modelEntries.filter { $0.providerInstanceId == instanceId })"))
check("voice pass skips what absence-grace already kept",
      store.contains("let keptAbsentUUIDs = Set(keptAbsent.map(\\.uuid))")
      && store.contains("&& !keptAbsentUUIDs.contains(e.uuid)"))
check("load merges copies", store.contains("config.modelEntries = collapsingRepeatedEntries(config.modelEntries)"))
check("the merge keeps the earliest absence stamp (typed)",
      store.contains("if let since = entry.absentSince, unique[i].absentSince.map({ since < $0 }) ?? true {"))
check("the merge keeps the earliest absence stamp (JSON)",
      store.contains("if let since = entry[\"absentSince\"] as? Double,")
      && store.contains("(unique[i][\"absentSince\"] as? Double).map({ since < $0 }) ?? true {"))
check("both merges key on instance + uuid",
      store.contains("let key = \"\\(entry.providerInstanceId)/\\(entry.uuid)\"")
      && store.contains("let key = \"\\(entry[\"providerInstanceId\"] as? String ?? \"\")/\\(uuid)\""))
check("only a file past the size gate is collapsed",
      store.contains("static let bloatedConfigThreshold = 4 * 1024 * 1024")
      && store.contains("guard data.count > bloatedConfigThreshold,"))
check("the collapsed copy must decode before it replaces the file",
      (store.range(of: "guard (try? JSONDecoder().decode(ProviderConfig.self, from: healed)) != nil else {")?.lowerBound ?? store.endIndex)
      < (store.range(of: "try healed.write(to: url, options: .atomic)")?.lowerBound ?? store.startIndex))
check("loadGuarded's validation decode reads through the collapse",
      store.contains("guard let data = readConfigData(from: url) else {\n            logger.error(\"[RebootGuard]"))
check("load reads through the collapse", store.contains("guard let data = readConfigData(from: url),\n              var config = try? JSONDecoder()"))
check("absence-grace pass still runs before the voice pass",
      (store.range(of: "config.modelEntries.append(contentsOf: keptAbsent)")?.lowerBound ?? store.endIndex)
      < (store.range(of: "let keptAbsentUUIDs")?.lowerBound ?? store.startIndex))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
