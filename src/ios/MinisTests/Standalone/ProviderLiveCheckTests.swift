#!/usr/bin/env swift
// [T-provider-live-check] (ISS-036) Before every agent request: is the
// provider instance in use still there, and enabled?
//
// User report (iOS, 2026-09-29): "I deleted every provider, the models are
// gone, and it still works" - on a conversation that was running. The agent
// loop builds its provider object once and reuses it for every round; the
// object carries its credential in memory, so removing or disabling the
// provider in Settings did not stop a running task.
//
// New rule: each request first checks the provider instance behind the entry
// it is about to use. Removed or disabled -> move to the next usable member of
// the model group through the existing router, with the reason on the fallback
// trail; fail (with the reason) only when no member is left, or there is no
// group. A hidden model entry is NOT a reason.
//
//   [1] the shipping ProviderAvailabilityRules (BEGIN/END block in
//       AIChatViewModel+Fallback.swift), compiled standalone
//   [2] the walk `streamWithGroupFallback` runs before each request, driven
//       over a ported store (with removeInstance's cleanup) and the ported
//       router: exists+enabled, removed, disabled, all unusable, no group,
//       hidden entry, sole member (group removed with it), no endless walk,
//       limits / prompt fragments follow the member moved to
//   [3] source guards: where the check sits, and what it must not touch
//   [4] the trail reasons and errors are localized (zh-Hans / zh-Hant)
//
// Run: swift ProviderLiveCheckTests.swift   (needs swiftc)
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

let fallback = source("Agent/Chat/AIChatViewModel+Fallback.swift")
let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let factory = source("Agent/Chat/AIChatViewModel+ProviderFactory.swift")
let storeSrc = source("Providers/ProviderConfigStore.swift")
let router = source("Providers/ModelGroupRouter.swift")
let strings = source("Localizable.xcstrings")
guard let block = between(fallback, "// BEGIN ProviderAvailabilityRules", "// END ProviderAvailabilityRules") else {
    print("❌ ProviderAvailabilityRules block not found"); exit(1)
}

// AppLocalized returns the key, so the harness sees the English source text.
let prelude = """
import Foundation
func AppLocalized(_ key: String) -> String { key }
"""

let harness = #"""
import Foundation

// ---- ported store (the parts the check and the router read) ----
struct Inst { var id: String; var label: String; var isEnabled = true; var hasAnyCredential = true }
struct Entry { var id: String; var name: String; var instanceId: String; var isHidden = false
               var contextWindow: Int; var capability: String }
struct Group { var id: String; var members: [String] }
struct Store {
    var instances: [String: Inst] = [:]
    var entries: [String: Entry] = [:]
    var groups: [String: Group] = [:]
    func instance(for id: String) -> Inst? { instances[id] }
    func entry(for id: String) -> Entry? { entries[id] }
    func group(for id: String) -> Group? { groups[id] }
    /// ProviderConfigStore.removeInstance: the instance, its entries, their
    /// group memberships, and any group left empty by exactly this removal.
    mutating func removeInstance(_ id: String) {
        let gone = Set(entries.values.filter { $0.instanceId == id }.map(\.id))
        let emptied = groups.values.filter { !$0.members.isEmpty && $0.members.allSatisfy(gone.contains) }.map(\.id)
        instances[id] = nil
        for e in gone { entries[e] = nil }
        for g in groups.keys { groups[g]!.members.removeAll(where: gone.contains) }
        for g in emptied { groups[g] = nil }
    }
}
/// ModelGroupRouter.availableEntryIds / nextFallback, verbatim logic.
func available(_ g: Group, _ s: Store) -> [String] {
    g.members.filter { id in
        guard let e = s.entry(for: id), !e.isHidden, let i = s.instance(for: e.instanceId),
              i.isEnabled, i.hasAnyCredential else { return false }
        return true
    }
}
func nextFallback(_ g: Group, current: String, _ s: Store) -> String? {
    let a = available(g, s)
    guard let idx = a.firstIndex(of: current) else { return a.first }
    if let next = a[(idx + 1)...].first { return next }
    if let wrapped = a[..<idx].first { return wrapped }
    return nil
}

// ---- the walk streamWithGroupFallback runs before each request ----
typealias Identity = ProviderAvailabilityRules.Identity
struct Outcome {
    var servedBy: String?          // entry the request goes to; nil = error
    var error: String?
    var trail: [String] = []
    var checks = 0                 // how many times the check ran
    var contextWindow: Int?        // limits of the member in use
    var capability: String?        // its prompt fragment
}
/// `identities` is what makeAgentProvider remembered when it built each
/// provider object - the store may no longer know the entry.
func walk(current: String, groupId: String?, store: Store, identities: inout [String: Identity]) -> Outcome {
    var out = Outcome()
    var currentId = current
    var tried: Set<String> = [current]
    func problem(_ id: String) -> (ProviderAvailabilityRules.Problem, Identity)? {
        let known = identities[id] ?? store.entry(for: id).map {
            Identity(entryId: $0.id, modelName: $0.name, instanceId: $0.instanceId,
                     instanceLabel: store.instance(for: $0.instanceId)?.label ?? "?")
        }
        guard let known else { return nil }
        let inst = store.instance(for: known.instanceId)
        guard let p = ProviderAvailabilityRules.problem(instanceExists: inst != nil,
                                                        instanceEnabled: inst?.isEnabled ?? false) else { return nil }
        return (p, known)
    }
    while true {
        out.checks += 1
        if out.checks > 50 { out.error = "RUNAWAY"; return out }
        guard let (p, who) = problem(currentId) else {
            out.servedBy = currentId
            out.contextWindow = store.entry(for: currentId)?.contextWindow
            out.capability = store.entry(for: currentId)?.capability
            return out
        }
        let line = "\(who.modelName) (\(who.instanceLabel)): \(ProviderAvailabilityRules.reason(p))"
        let group = groupId.flatMap { store.group(for: $0) }
        let candidate = group.flatMap { nextFallback($0, current: currentId, store) }
        switch ProviderAvailabilityRules.nextStep(hasGroup: group != nil,
                                                  candidate: candidate.flatMap { store.entry(for: $0) != nil ? $0 : nil },
                                                  tried: tried) {
        case .failNoGroup:
            out.error = ProviderAvailabilityRules.message(p, identity: who); return out
        case .failExhausted:
            out.trail.append(line)
            out.error = "No usable model is left in this model group."; return out
        case .advance(let next):
            out.trail.append(line)
            tried.insert(next)
            currentId = next
            let e = store.entry(for: next)!
            identities[next] = Identity(entryId: e.id, modelName: e.name, instanceId: e.instanceId,
                                        instanceLabel: store.instance(for: e.instanceId)!.label)
        }
    }
}

func fixture() -> (Store, [String: Identity]) {
    var s = Store()
    for (i, n) in ["A", "B", "C"].enumerated() {
        s.instances["inst-\(n)"] = Inst(id: "inst-\(n)", label: "Provider \(n)")
        s.entries["e-\(n)"] = Entry(id: "e-\(n)", name: "Model \(n)", instanceId: "inst-\(n)",
                                    contextWindow: 100_000 * (i + 1), capability: "cap-\(n)")
    }
    s.groups["g"] = Group(id: "g", members: ["e-A", "e-B", "e-C"])
    // The run started on member A: its provider object was built then.
    let ids = ["e-A": Identity(entryId: "e-A", modelName: "Model A", instanceId: "inst-A", instanceLabel: "Provider A")]
    return (s, ids)
}
func show(_ tag: String, _ o: Outcome) {
    print("R \(tag).served=\(o.servedBy ?? "nil")")
    print("R \(tag).error=\(o.error ?? "nil")")
    print("R \(tag).trail=\(o.trail.joined(separator: " | "))")
    print("R \(tag).checks=\(o.checks)")
    print("R \(tag).window=\(o.contextWindow.map(String.init) ?? "nil")")
    print("R \(tag).cap=\(o.capability ?? "nil")")
}

// pure rules
print("R rule.ok=\(String(describing: ProviderAvailabilityRules.problem(instanceExists: true, instanceEnabled: true)))")
print("R rule.removed=\(String(describing: ProviderAvailabilityRules.problem(instanceExists: false, instanceEnabled: true)))")
print("R rule.removedWins=\(String(describing: ProviderAvailabilityRules.problem(instanceExists: false, instanceEnabled: false)))")
print("R rule.disabled=\(String(describing: ProviderAvailabilityRules.problem(instanceExists: true, instanceEnabled: false)))")
print("R step.noGroup=\(ProviderAvailabilityRules.nextStep(hasGroup: false, candidate: "x", tried: []))")
print("R step.noCandidate=\(ProviderAvailabilityRules.nextStep(hasGroup: true, candidate: nil, tried: []))")
print("R step.tried=\(ProviderAvailabilityRules.nextStep(hasGroup: true, candidate: "x", tried: ["x"]))")
print("R step.advance=\(ProviderAvailabilityRules.nextStep(hasGroup: true, candidate: "x", tried: ["y"]))")

do { var (s, ids) = fixture(); _ = s
     show("healthy", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.removeInstance("inst-A")
     show("removed", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.instances["inst-A"]!.isEnabled = false
     show("disabled", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.removeInstance("inst-A"); s.instances["inst-B"]!.isEnabled = false
     show("skipDisabledNext", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.removeInstance("inst-A"); s.instances["inst-B"]!.isEnabled = false; s.removeInstance("inst-C")
     show("allGone", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.removeInstance("inst-A"); s.removeInstance("inst-B"); s.removeInstance("inst-C")
     print("R allRemoved.groupStillThere=\(s.group(for: "g") != nil)")
     show("allRemoved", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.removeInstance("inst-A")
     show("noGroupRemoved", walk(current: "e-A", groupId: nil, store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.instances["inst-A"]!.isEnabled = false
     show("noGroupDisabled", walk(current: "e-A", groupId: nil, store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.entries["e-A"]!.isHidden = true
     show("hidden", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { var (s, ids) = fixture(); s.groups["g"]!.members = ["e-A"]; s.removeInstance("inst-A")
     print("R sole.groupStillThere=\(s.group(for: "g") != nil)")
     show("sole", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { // Only the entry disappeared (a model dropped from the list); the provider is fine.
     var (s, ids) = fixture(); s.entries["e-A"] = nil; s.groups["g"]!.members.removeAll { $0 == "e-A" }
     show("entryOnly", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
do { // No remembered identity and no entry: nothing known, never blocks.
     var (s, _) = fixture(); s.removeInstance("inst-A"); var none: [String: Identity] = [:]
     show("unknown", walk(current: "e-A", groupId: "g", store: s, identities: &none)) }
do { // Checked again on later rounds: stays on the member it moved to.
     var (s, ids) = fixture(); s.removeInstance("inst-A")
     let first = walk(current: "e-A", groupId: "g", store: s, identities: &ids)
     let second = walk(current: first.servedBy!, groupId: "g", store: s, identities: &ids)
     print("R again.served=\(second.servedBy ?? "nil") again.trail=\(second.trail.count) again.checks=\(second.checks)")
     // ... and the member it moved to is then disabled as well.
     s.instances["inst-B"]!.isEnabled = false
     show("thenB", walk(current: "e-B", groupId: "g", store: s, identities: &ids)) }
do { // Two members on the same provider: removing it takes both out at once.
     var (s, ids) = fixture(); s.entries["e-B"]!.instanceId = "inst-A"; s.removeInstance("inst-A")
     show("sharedProvider", walk(current: "e-A", groupId: "g", store: s, identities: &ids)) }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("provider-live-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = ["Rules.swift": prelude + "\n" + block, "main.swift": harness]
for (n, c) in files { try? c.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"] + files.keys.sorted().map { tmp.appendingPathComponent($0).path } + ["-o", bin])
print("1. The shipping rules compile standalone")
check("ProviderAvailabilityRules block compiles on its own (pure: no store, no view model)", cc == 0)
if cc != 0 { print(ccOut); print("\n❌ FAILED"); exit(1) }
let (_, out) = run(bin, [])
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    // "R a=1 b=2" (several on a line, no spaces in values) or "R key=free text"
    let body = String(line.dropFirst(2))
    if body.hasPrefix("again.") {
        for kv in body.split(separator: " ") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { r[p[0]] = p[1] }
        }
    } else if let eq = body.firstIndex(of: "=") {
        r[String(body[..<eq])] = String(body[body.index(after: eq)...])
    }
}

print("\n2. What counts as unusable")
check("provider present and enabled -> usable", r["rule.ok"] == "nil")
check("provider removed -> unusable", r["rule.removed"]?.contains("removed") == true)
check("provider disabled -> unusable", r["rule.disabled"]?.contains("disabled") == true)
check("removed is reported as removed, not as disabled", r["rule.removedWins"]?.contains("removed") == true)
check("no group -> fail without looking for a candidate", r["step.noGroup"] == "failNoGroup")
check("group with no usable member left -> exhausted", r["step.noCandidate"] == "failExhausted")
check("a member already tried is never picked again -> exhausted", r["step.tried"] == "failExhausted")
check("an untried usable member -> advance to it", r["step.advance"] == "advance(to: \"x\")")

print("\n3. The walk before each request")
check("provider present and enabled: request goes to the same member, no trail, one check",
      r["healthy.served"] == "e-A" && r["healthy.trail"] == "" && r["healthy.checks"] == "1")
check("current provider REMOVED: moves to the next member",
      r["removed.served"] == "e-B" && r["removed.error"] == "nil")
check("... and the trail names the removed model, its provider and the reason",
      r["removed.trail"] == "Model A (Provider A): Provider removed")
check("current provider DISABLED: moves to the next member, reason on the trail",
      r["disabled.served"] == "e-B" && r["disabled.trail"] == "Model A (Provider A): Provider disabled")
check("the next member is unusable too: it is skipped, the one after serves",
      r["skipDisabledNext.served"] == "e-C" && r["skipDisabledNext.error"] == "nil")
check("limits follow the member moved to (context window of B, not of removed A)",
      r["removed.window"] == "200000" && r["skipDisabledNext.window"] == "300000")
check("the capability prompt fragment follows the member moved to",
      r["removed.cap"] == "cap-B" && r["skipDisabledNext.cap"] == "cap-C")
check("current and every later member unusable: a clear exhaustion error, no request",
      r["allGone.served"] == "nil" && r["allGone.error"] == "No usable model is left in this model group.")
check("... with the trail saying why the current one was passed over",
      r["allGone.trail"] == "Model A (Provider A): Provider removed")
check("every provider removed: the group went with them, so the error names the provider",
      r["allRemoved.groupStillThere"] == "false" && r["allRemoved.served"] == "nil"
      && r["allRemoved.error"]?.contains("The provider Provider A was removed") == true)
check("no model group, provider removed: error names provider and model, no request",
      r["noGroupRemoved.served"] == "nil"
      && r["noGroupRemoved.error"] == "The provider Provider A was removed, so Model A can no longer be used. Choose another model to continue.")
check("no model group, provider disabled: error says disabled and how to continue",
      r["noGroupDisabled.error"] == "The provider Provider A is disabled, so Model A cannot be used. Enable it in Settings or choose another model to continue.")
check("a HIDDEN model entry on a usable provider is not a reason: no fallback",
      r["hidden.served"] == "e-A" && r["hidden.trail"] == "")
check("the removed provider was the group's only member: the group is removed with it -> the no-group error",
      r["sole.groupStillThere"] == "false" && r["sole.served"] == "nil"
      && r["sole.error"]?.contains("The provider Provider A was removed") == true)
check("only the model entry disappeared, provider still fine: the running request is not blocked",
      r["entryOnly.served"] == "e-A" && r["entryOnly.error"] == "nil")
check("nothing known about the entry at all: never blocks",
      r["unknown.served"] == "e-A" && r["unknown.error"] == "nil")
check("checked again on the next round: stays on the member it moved to, no new trail",
      r["again.served"] == "e-B" && r["again.trail"] == "0" && r["again.checks"] == "1")
check("the member it moved to is disabled later: moves on again",
      r["thenB.served"] == "e-C" && r["thenB.trail"] == "Model B (Provider B): Provider disabled")
check("two members on the removed provider: both are gone, the third serves",
      r["sharedProvider.served"] == "e-C")
check("no scenario walks more than once per group member (triedEntries ends it)",
      ["healthy", "removed", "disabled", "skipDisabledNext", "allGone", "allRemoved", "noGroupRemoved",
       "hidden", "sole", "thenB", "sharedProvider"].allSatisfy { (Int(r["\($0).checks"] ?? "99") ?? 99) <= 3 }
      && !out.contains("RUNAWAY"))

print("\n4. Where the check sits")
let groupFn = between(fallback, "func streamWithGroupFallback(", "// MARK: - Group Fallback Until Content") ?? ""
let retryFn = between(fallback, "func streamWithAutoRetry(", "// MARK: - Exhausted-group error") ?? ""
if let whileR = groupFn.range(of: "        while true {\n"),
   let checkR = groupFn.range(of: "if let hit = providerProblem(forEntryId: currentEntryId)"),
   let doR = groupFn.range(of: "            do {\n                logger.info(\"🔀ROUTE trying entry="),
   let sendR = groupFn.range(of: "try await currentProvider.streamAgentMessage(") {
    check("streamWithGroupFallback checks at the top of every pass, before the request and outside its do/catch",
          whileR.lowerBound < checkR.lowerBound && checkR.lowerBound < doR.lowerBound && doR.lowerBound < sendR.lowerBound)
} else {
    check("streamWithGroupFallback checks at the top of every pass, before the request and outside its do/catch", false)
}
check("the next member comes from the existing router, not a second mechanism",
      groupFn.contains("ModelGroupRouter.nextFallback(group: $0, currentEntryId: unavailableEid, store: store)"))
check("the reason goes on the existing fallback trail",
      groupFn.contains("reason: ProviderAvailabilityRules.reason(hit.problem))") && groupFn.contains("fallbackReasons.append(trailLine)"))
check("exhaustion uses the existing groupExhaustedError with the trail",
      groupFn.contains("throw groupExhaustedError(\n                        fallbackTrail: fallbackReasons,"))
check("moving on rebuilds the provider and the model-specific prompt fragments, like the error fallbacks",
      groupFn.contains("currentProvider = await makeAgentProvider(for: nextEntry)\n                    var rebuiltPrompt = baseSystemPrompt")
      && groupFn.components(separatedBy: "nextEntry.model.capabilityPromptFragment").count - 1 == 4)
check("the walk records each member it moves to (triedEntries)",
      groupFn.contains("tried: triedEntries)") && groupFn.contains("triedEntries.insert(nextEntryId)\n                    currentEntryId = nextEntryId\n                    currentProvider = await makeAgentProvider(for: nextEntry)\n                    var rebuiltPrompt"))
if let checkR = retryFn.range(of: "if let hit = providerProblem(forEntryId: checkedEntryId)"),
   let sendR = retryFn.range(of: "try await currentProvider.streamAgentMessage(") {
    check("streamWithAutoRetry checks before each attempt's request", checkR.lowerBound < sendR.lowerBound)
} else {
    check("streamWithAutoRetry checks before each attempt's request", false)
}
check("the retry ladder follows a model switch made during its countdown", retryFn.contains("checkedEntryId = entry.id"))
check("every caller of the retry ladder says which entry its provider is for",
      (fallback + loop).components(separatedBy: "entryId: currentEntryId\n").count - 1 == 1
      && loop.components(separatedBy: "entryId: activeEntryId\n").count - 1 == 2)
check("the empty-reply reminder goes through the group path when its provider went away",
      loop.contains("if providerProblem(forEntryId: activeEntryId) != nil {")
      && loop.contains("reminderStream = try await streamWithGroupFallback("))
check("each provider object's model and provider are remembered when it is built",
      factory.contains("noteProviderIdentity(for: entry)  // [T-provider-live-check]\n        let provider = await Self.makeAgentProvider("))
check("after a fallback the loop's limits move to the new model (activeModel)",
      loop.contains("provider = await makeAgentProvider(for: newEntry)\n                // [T-provider-live-check]")
      && loop.contains("                activeModel = newEntry.model\n                userSystemPrompt = baseSystemPrompt"))
check("the check reads the config only: instance(for:) is a lookup over the instances, no I/O",
      storeSrc.contains("return config.instances.first { $0.id == id }"))
check("removeInstance is untouched by this change (still cleans entries, group members, emptied groups)",
      storeSrc.contains("config.modelEntries.removeAll { $0.providerInstanceId == instanceId }")
      && storeSrc.contains("config.modelGroups.removeAll { removedGroupIds.contains($0.id) }")
      && !storeSrc.contains("T-provider-live-check"))
check("the router's own filter is unchanged (hidden / disabled / no credential)",
      router.contains("guard !entry.isHidden else {") && router.contains("guard instance.isEnabled else {")
      && router.contains("guard instance.hasAnyCredential else {") && !router.contains("T-provider-live-check"))
check("a hidden entry is not part of the rule", !block.contains("isHidden"))

print("\n5. Localized")
func hasLocales(_ key: String) -> Bool {
    guard let r0 = strings.range(of: "    \"\(key)\" : {\n") else { return false }
    let tail = strings[r0.upperBound...]
    let end = tail.range(of: "\n    },\n")?.lowerBound ?? tail.endIndex
    let entry = tail[..<end]
    return entry.contains("\"zh-Hans\"") && entry.contains("\"zh-Hant\"")
}
for key in ["Provider removed", "Provider disabled", "No usable model is left in this model group.",
            "The provider %@ was removed, so %@ can no longer be used. Choose another model to continue.",
            "The provider %@ is disabled, so %@ cannot be used. Enable it in Settings or choose another model to continue."] {
    check("zh-Hans + zh-Hant: \(key.prefix(48))", hasLocales(key))
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
