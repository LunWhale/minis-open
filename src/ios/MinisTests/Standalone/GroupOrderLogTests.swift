#!/usr/bin/env swift
// [T-group-order-log] A user reported (Telegram, iOS TestFlight) that the
// member order of a model group "changes by itself over time": 1 used to be
// before 2, later 2 was before 1. In a fallback group the order is the
// priority, so that silently changes which model answers.
//
// Reading the code did not settle who does it. The strongest suspect is the
// inbound iCloud merge (the side with the newer group updated_at decides the
// member order) together with ProviderConfigDB.bulkReplace re-stamping a
// group's updated_at when only its position in the group list moved. That is
// a deduction, not a reproduction.
//
// So this change adds logging only - no merge rule, timestamp or order is
// touched. Every path that can rewrite a group's member list reports under
// one prefix, `[GroupOrder]`, with a fixed, greppable `reason=`.
//
// [1] compiles the two shipping blocks (the order diff, and bulkReplace's
//     "why is this row re-stamped" note) and runs them.
// [2] pins the wiring: the inbound-sync path cannot change an order without a
//     line, every reason is attached to its path, no merge rule moved, and no
//     writer of memberEntryIds exists outside the known files.
//
// Run: swift GroupOrderLogTests.swift
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
func code(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.lowerBound..<rb.lowerBound])
}
func index(_ hay: String, _ needle: String) -> Int {
    hay.range(of: needle).map { hay.distance(from: hay.startIndex, to: $0.lowerBound) } ?? -1
}
func count(_ hay: String, _ needle: String) -> Int { hay.components(separatedBy: needle).count - 1 }

let modelGroup = source("Providers/ModelGroup.swift")
let db = source("Providers/ProviderConfigDB.swift")
let diffBlock = between(modelGroup, "// BEGIN GroupOrderDiff", "// END GroupOrderDiff")
let noteBlock = between(db, "    // BEGIN GroupRewriteNote", "    // END GroupRewriteNote")

// MARK: - 1. The shipping blocks

let scenario = #"""

// Stand-ins for the app types bulkReplace's note reads.
enum RoutingStrategy: String { case fallback, loadBalance }
enum FallbackStrategy: String { case limited, always }
enum ThinkingLevel: String { case low, high }
struct ModelGroup {
    var id: String
    var name: String
    var memberEntryIds: [String]
    var strategy: RoutingStrategy = .fallback
    var fallbackStrategy: FallbackStrategy = .limited
    var defaultThinkingLevel: ThinkingLevel? = nil
    var contextLimitTokens: Int? = nil
    var lastContextLimitTokens: Int? = nil
}
enum GroupOrderLog {
    static func stamp(_ epoch: Double?) -> String { epoch.map { "t\(Int($0))" } ?? "-" }
}
enum DB {
NOTE_BLOCK
}

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
typealias D = GroupOrderDiff
let i1 = "11111111-AAAA-4AAA-8AAA-AAAAAAAAAAAA", i2 = "22222222-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
let a = "\(i1)/claude-sonnet", b = "\(i1)/claude-opus", c = "\(i2)/gpt-5", d = "\(i2)/gemini-pro"

print("1a. Is it a reorder")
check("identical lists: no", !D.relativeOrderChanged(before: [a, b, c], after: [a, b, c]))
check("appended at the end, order kept: no", !D.relativeOrderChanged(before: [a, b], after: [a, b, c]))
check("inserted in front or in the middle, the others kept in order: no",
      !D.relativeOrderChanged(before: [a, b], after: [c, a, b]) && !D.relativeOrderChanged(before: [a, b], after: [a, c, b]))
check("one removed, the rest in the same order: no",
      !D.relativeOrderChanged(before: [a, b, c], after: [a, c]) && !D.relativeOrderChanged(before: [a, b, c], after: [b, c]))
check("two swapped: yes", D.relativeOrderChanged(before: [a, b], after: [b, a]))
check("one moved to the end / to the front: yes",
      D.relativeOrderChanged(before: [a, b, c], after: [b, c, a]) && D.relativeOrderChanged(before: [a, b, c], after: [c, a, b]))
check("the set changed AND the survivors changed places: yes",
      D.relativeOrderChanged(before: [a, b, c], after: [b, a, d]) && D.relativeOrderChanged(before: [a, b, c], after: [c, a]))
check("everything replaced, nothing in common: no (there is no shared member to be out of order)",
      !D.relativeOrderChanged(before: [a, b], after: [c, d]))
check("emptied, or filled from empty: no",
      !D.relativeOrderChanged(before: [a, b], after: []) && !D.relativeOrderChanged(before: [], after: [a, b]))
check("a duplicate dropped, first occurrences in the same order: no",
      !D.relativeOrderChanged(before: [a, b, a], after: [a, b]))

print("1b. What changed")
let appended = D.summary(before: [a, b], after: [a, b, c, d])
check("append: not reordered, added listed, at the tail, change=members",
      !appended.reordered && appended.added == [c, d] && appended.removed.isEmpty && appended.addedOnlyAtTail && appended.change == "members")
let inserted = D.summary(before: [a, b], after: [c, a, b])
check("insert in front: not reordered, and NOT at the tail", !inserted.reordered && inserted.added == [c] && !inserted.addedOnlyAtTail)
let removed = D.summary(before: [a, b, c], after: [a, c])
check("remove: not reordered, removed listed", !removed.reordered && removed.removed == [b] && removed.added.isEmpty && removed.change == "members")
let moved = D.summary(before: [a, b, c], after: [b, a, c])
check("move: reordered, nothing added or removed, change=reorder",
      moved.reordered && moved.added.isEmpty && moved.removed.isEmpty && moved.change == "reorder")
let both = D.summary(before: [a, b, c], after: [b, a, d])
check("set and order together: reordered, with what came and went", both.reordered && both.added == [d] && both.removed == [c])
check("identical: unchanged", D.summary(before: [a, b], after: [a, b]).isUnchanged && D.summary(before: [a, b], after: [a, b]).change == "none")
check("how 1,2 becomes 2,1 without any single reorder: removed, then added back at the end - both steps are reported as member changes",
      !D.summary(before: [a, b], after: [b]).isUnchanged && !D.summary(before: [b], after: [b, a]).isUnchanged
      && !D.summary(before: [a, b], after: [b]).reordered && !D.summary(before: [b], after: [b, a]).reordered)

print("1c. What goes into the log")
check("a member id is the first 8 of the instance id plus the model id", D.shortId(a) == "11111111/claude-sonnet")
check("a legacy bare uuid is cut to 8", D.shortId(i2) == "22222222")
check("a model id with slashes keeps them", D.shortId("\(i1)/accounts/fireworks/models/x") == "11111111/accounts/fireworks/models/x")
check("a model id shaped like a URL or carrying credentials is masked",
      D.shortId("\(i1)/https://user:sk-secret@host/v1") == "11111111/<masked>"
      && D.shortId("\(i1)/model?api_key=sk-secret") == "11111111/<masked>"
      && D.shortId("\(i1)/token=abc") == "11111111/<masked>")
check("a very long model id is cut", D.shortId("\(i1)/" + String(repeating: "m", count: 200)).count == 9 + 48)
check("a list is bracketed; more than 24 members are counted, not printed",
      D.describe([a, c]) == "[11111111/claude-sonnet, 22222222/gpt-5]"
      && D.describe((0..<30).map { "\(i1)/m\($0)" }).hasSuffix(", …+6]"))
check("the group tag is the first 8 of the id and the name", D.groupTag(id: "AB12CD34-0000-4000-8000-000000000000", name: "子代理") == "AB12CD34(子代理)")
let line = D.line(reason: "user-drag", groupId: "AB12CD34-0000-4000-8000-000000000000", name: "子代理",
                  before: [a, b], after: [b, a], detail: "via=X.swift:1")
check("a reorder line: reason, change, group, both orders, the detail",
      line?.text == "reason=user-drag change=reorder group=AB12CD34(子代理) before=[11111111/claude-sonnet, 11111111/claude-opus] after=[11111111/claude-opus, 11111111/claude-sonnet] via=X.swift:1"
      && line?.summary.reordered == true)
let addLine = D.line(reason: "user-add", groupId: "AB12CD34", name: "G", before: [a], after: [a, c])
check("an append line says what was added and that it went to the end",
      addLine?.text.contains("change=members") == true && addLine?.text.contains("added=[22222222/gpt-5] addedAtTail=true") == true)
check("no line at all when nothing changed", D.line(reason: "user-drag", groupId: "AB12CD34", name: "G", before: [a, b], after: [a, b]) == nil)
check("no full instance id ever reaches a line",
      [line?.text, addLine?.text].allSatisfy { $0?.contains(i1) == false && $0?.contains(i2) == false })

print("1d. bulkReplace: why a group row gets a fresh updated_at")
func stored(_ g: ModelGroup, sort: Int, members: [String]? = nil) -> [String: Any] {
    let json = String(data: try! JSONEncoder().encode(members ?? g.memberEntryIds), encoding: .utf8)!
    return ["name": g.name, "strategy": g.strategy.rawValue, "fallback_strategy": g.fallbackStrategy.rawValue,
            "default_thinking_level": g.defaultThinkingLevel?.rawValue as Any,
            "context_limit_tokens": g.contextLimitTokens as Any, "context_limit_remembered": g.lastContextLimitTokens as Any,
            "member_entry_ids_json": json, "sort_order": sort, "updated_at": 1000.0,
            "removed_members_json": "{}", "added_members_json": "{}"]
}
func note(_ row: [String: Any], _ g: ModelGroup, sort: Int) -> String {
    let json = String(data: try! JSONEncoder().encode(g.memberEntryIds), encoding: .utf8)!
    return DB.groupRewriteNote(stored: row, group: g, sortOrder: sort, memberJSON: json, removedJSON: "{}", addedJSON: "{}", now: 2000)
}
let g = ModelGroup(id: "AB12CD34-0000-4000-8000-000000000000", name: "Sub", memberEntryIds: [a, b])
let sortOnly = note(stored(g, sort: 3), g, sort: 2)
check("only its position in the group list moved: its own reason, old and new index, old and new stamp, members untouched",
      sortOnly == "reason=updatedAt-bump-sortorder-only group=AB12CD34(Sub) sortOrder=3→2 updatedAt=t1000→t2000 members=2(unchanged)")
var renamed = g; renamed.name = "Sub2"
check("a renamed group: the general reason, with the field named",
      note(stored(g, sort: 2), renamed, sort: 2).hasPrefix("reason=updatedAt-bump group=AB12CD34(Sub2) fields=[name] sortOrder=2→2"))
var reordered = g; reordered.memberEntryIds = [b, a]
let memberNote = note(stored(g, sort: 2), reordered, sort: 2)
check("members reordered: fields=[members], membersChange=reorder, both orders",
      memberNote.contains("fields=[members]") && memberNote.contains("membersChange=reorder")
      && memberNote.contains("before=[11111111/claude-sonnet, 11111111/claude-opus] after=[11111111/claude-opus, 11111111/claude-sonnet]"))
var grown = g; grown.memberEntryIds = [a, b, c]
check("a member appended while the list position also moved: both fields, membersChange=members, not the sort-only reason",
      note(stored(g, sort: 1), grown, sort: 0).contains("fields=[members,sort_order]")
      && note(stored(g, sort: 1), grown, sort: 0).contains("membersChange=members")
      && !note(stored(g, sort: 1), grown, sort: 0).contains("sortorder-only"))
var tuned = g; tuned.strategy = .loadBalance; tuned.fallbackStrategy = .always; tuned.defaultThinkingLevel = .high; tuned.contextLimitTokens = 128_000
check("every scalar field is named when it differs",
      note(stored(g, sort: 2), tuned, sort: 2).contains("fields=[strategy,fallback,thinking,ctx]"))
let tomb = DB.groupRewriteNote(stored: stored(g, sort: 2), group: g, sortOrder: 2,
                               memberJSON: String(data: try! JSONEncoder().encode(g.memberEntryIds), encoding: .utf8)!,
                               removedJSON: "{\"x\":1}", addedJSON: "{\"y\":2}", now: 2000)
check("member tombstone maps are named too", tomb.contains("fields=[removed,added]"))

exit(failures == 0 ? 0 : 1)
"""#.replacingOccurrences(of: "NOTE_BLOCK", with: noteBlock)

print("1. The shipping blocks")
check("both blocks were found", diffBlock.contains("enum GroupOrderDiff {") && noteBlock.contains("static func groupRewriteNote("))
if failures == 0 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GroupOrderLog-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? ("import Foundation\n" + diffBlock + scenario).write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text, terminator: "")
    let passed = text.components(separatedBy: "✅").count - 1
    check("harness ran to the end (\(passed) checks) and exited 0", p.terminationStatus == 0 && passed >= 34)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 2. Wiring

print("\n2a. The inbound sync path cannot change an order silently")
let store = source("Providers/ProviderConfigStore.swift")
let engine = source("Agent/Sync/CloudSyncEngine.swift")
let hydrators = source("Agent/Sync/V2/ChatStoreSyncHydrators.swift")
let detail = source("Views/Providers/ModelGroupDetailView.swift")
let picker = source("Views/Providers/UnifiedModelPicker.swift")
let groupsCollection = source("Shared/Config/Collections/GroupsCollection.swift")
let debugRPC = source("Debug/DebugRPCProviderChat.swift")
let backup = source("Agent/Backup/BackupImporter+Categories.swift")
let appLogger = source("Shared/AppLogger.swift")

let inbound = between(db, "    func upsertGroupFromInbound(", "    /// Delete a row by id. Used by V3 deletionApplier paths.")
let logAt = index(inbound, "if localTs != nil, finalMembers != localMembers {")
check("the line is decided from the final order against the local one, once the final order is known",
      logAt > index(inbound, "for m in addedMerged.keys where isPresent(m) && !seen.contains(m) { finalMembers.append(m); seen.insert(m) }")
      && index(inbound, "for m in addedMerged.keys where isPresent(m)") > 0)
check("... and before either way out of the function: the early return and the row write",
      logAt > 0 && logAt < index(inbound, "if !scalarIsNewer && !memberChanged {\n            return false")
      && logAt < index(inbound, "let finalMemberJSON = (try? Self.jsonString(finalMembers))"))
let inboundLog = between(inbound, "if localTs != nil, finalMembers != localMembers {", "if !scalarIsNewer && !memberChanged {")
check("a changed order is a WARNING, a changed set alone is info",
      inboundLog.contains("let s = GroupOrderDiff.summary(before: localMembers, after: finalMembers)")
      && inboundLog.contains("if !s.isUnchanged {")
      && inboundLog.contains("GroupOrderLog.emit(text, warning: s.reordered)"))
check("it carries the three orders, the winning side, both timestamps and the comparison that decided",
      ["reason=sync-inbound change=", " local=", " inbound=", " final=", "winner=\\(scalarIsNewer ? \"inbound\" : \"local\")",
       "localUpdatedAt=\\(GroupOrderLog.stamp(localTs))", "inboundUpdatedAt=\\(GroupOrderLog.stamp(updatedAt))",
       "scalarIsNewer=\\(scalarIsNewer)", "inboundSortOrder=\\(sortOrder)", "droppedByRemovalTombstone="].allSatisfy { inboundLog.contains($0) })
check("the record's own metadata is passed in by the V3 merger (a group record names no source device)",
      hydrators.contains("inboundMeta: \"record=ProviderModelGroupV3 schema=\\(record.schemaVersion) inboundTombstones=added:\\(inboundAdded.count)/removed:\\(inboundRemoved.count)\"")
      && inboundLog.contains("if !inboundMeta.isEmpty { text += \" \\(inboundMeta)\" }"))
check("the merge rule itself is untouched: the newer side's order leads, the other side's extras follow",
      inbound.contains("let scalarIsNewer = (localTs == nil) || (updatedAt > localTs!)")
      && inbound.contains("let primaryOrder = scalarIsNewer ? inboundMembers : localMembers\n        let secondaryOrder = scalarIsNewer ? localMembers : inboundMembers")
      && inbound.contains("for m in primaryOrder where isPresent(m) && !seen.contains(m) { finalMembers.append(m); seen.insert(m) }"))

print("\n2b. bulkReplace reports every group row it re-stamps")
let bulk = between(db, "    func bulkReplace(from config: ProviderConfig", "    /// [T-group-order-log] Why `bulkReplace` is about to rewrite")
check("the comparison that decides a rewrite is unchanged, sort_order included",
      bulk.contains("(r[\"member_entry_ids_json\"] as? String) == memberJSON,\n               (r[\"sort_order\"] as? Int) == idx,\n               ((r[\"removed_members_json\"] as? String) ?? \"{}\") == removedJSON,\n               ((r[\"added_members_json\"] as? String) ?? \"{}\") == addedJSON {\n                continue\n            }\n            groupChanged += 1"))
check("an existing row on the rewrite path gets a note; a brand-new row does not",
      bulk.contains("groupChanged += 1\n            if let stored = storedGroup[group.id] {\n                groupRewriteNotes.append(Self.groupRewriteNote("))
check("the row is still written with updated_at = now", count(bulk, "updatedAt: now,") == 3)
check("the notes are written after COMMIT, not inside the transaction",
      index(bulk, "Self.exec(db: db, \"COMMIT\")") > 0
      && index(bulk, "for note in groupRewriteNotes { GroupOrderLog.emit(note) }") > index(bulk, "Self.exec(db: db, \"COMMIT\")"))
check("a rewrite caused by sort_order alone has its own reason",
      noteBlock.contains("if fields == [\"sort_order\"] {\n            return \"reason=updatedAt-bump-sortorder-only group="))

print("\n2c. Every path has its reason")
let updateGroup = between(store, "    func updateGroup(_ group: ModelGroup, orderReason: String = \"group-update\",", "    /// Reorder model groups.")
check("updateGroup compares the stored members with the incoming ones before anything else, and names its caller",
      updateGroup.contains("GroupOrderLog.note(reason: orderReason, groupId: group.id, name: group.name,\n                           before: config.modelGroups[idx].memberEntryIds, after: group.memberEntryIds,")
      && updateGroup.contains("detail: \"via=\\(file):\\(line)\")")
      && index(updateGroup, "GroupOrderLog.note(") < index(updateGroup, "let prior = config.modelGroups[idx]"))
check("a caller that only meant to change a setting but reorders members is a WARNING",
      updateGroup.contains("warnOnReorder: orderReason == \"group-update\","))
check("user-drag: moving a member in the group page",
      detail.contains("updated.memberEntryIds.move(fromOffsets: source, toOffset: destination)\n        store.updateGroup(updated, orderReason: \"user-drag\")"))
check("user-add: the picker's append", detail.contains("group.memberEntryIds.append(contentsOf: ids.sorted())\n                store.updateGroup(group, orderReason: \"user-add\")"))
check("user-delete: both removals in the group page and the dangling-member removal in the picker",
      count(detail, "store.updateGroup(updated, orderReason: \"user-delete\")") == 2
      && picker.contains("store.updateGroup(fresh, orderReason: \"user-delete\")"))
check("config-tool: every minis-config group field, naming the field that wrote",
      groupsCollection.contains("ProviderConfigStore.shared.updateGroup(g, orderReason: \"config-tool\",\n                                               file: \"GroupsCollection.\\(field)\")")
      && groupsCollection.contains("private func mutate(_ id: String, field: String = #function,"))
check("debug-rpc", debugRPC.contains("store.updateGroup(group, orderReason: \"debug-rpc\")"))
check("sync-inbound-legacy / restore-merge: same id, and both same-name collapses",
      engine.contains("let orderLogReason = isRestore ? \"restore-merge\" : \"sync-inbound-legacy\"")
      && count(engine, "GroupOrderLog.note(reason: orderLogReason,") == 3
      && engine.contains("detail: \"path=same-id winner=remote remote=")
      && engine.contains("detail: \"path=same-name winner=local collapsed=")
      && engine.contains("detail: \"path=same-name winner=remote collapsed="))
check("restore-merge: the fallback restore path", backup.contains("store.applyConfig(local, orderReason: \"restore-merge\")"))
check("entry-prune: removing an instance, removing an entry, a model list refresh",
      count(store, "GroupOrderLog.noteAll(reason: \"entry-prune\",") == 3
      && ["cause=remove-instance", "cause=remove-entry", "cause=replace-entries"].allSatisfy { store.contains($0) })
check("dedupe and normalize (legacy id remap, and the JSON load)",
      store.contains("GroupOrderLog.noteAll(reason: \"dedupe\",")
      && count(store, "GroupOrderLog.note(reason: \"normalize\",") == 2
      && store.contains("detail: \"stage=legacy-uuid-remap\")") && store.contains("detail: \"stage=load-json\")"))
check("the whole config being replaced: from the database (launch, reload), from JSON, by an inbound apply, by applyConfig",
      count(store, "GroupOrderLog.noteAll(reason: \"reload-db\",") == 2
      && store.contains("GroupOrderLog.noteAll(reason: \"reload-json\",")
      && store.contains("GroupOrderLog.noteAll(reason: \"sync-apply\", before: config.modelGroups,\n                              after: deduped.modelGroups, detail: \"source=\\(source)\")")
      && store.contains("GroupOrderLog.noteAll(reason: orderReason, before: config.modelGroups, after: newConfig.modelGroups)")
      && engine.contains("store.applyMergedConfigFromSync(local, source: isRestore ? \"restore\" : \"legacy-merge\")"))
check("each whole-config line is written BEFORE the assignment it describes",
      index(store, "GroupOrderLog.noteAll(reason: \"sync-apply\"") < index(store, "        config = deduped\n        // [T-icloud-fresh-restore-provider-groups]")
      && index(store, "GroupOrderLog.noteAll(reason: orderReason, before: config.modelGroups, after: newConfig.modelGroups)") < index(store, "        config = newConfig\n        save()"))

print("\n2d. Nobody else writes a member list")
let writer = try! NSRegularExpression(pattern: #"memberEntryIds\s*(=[^=]|\.(append|remove|insert|move|swapAt|sort|removeAll|replaceSubrange)\b)|memberEntryIds\[[^\]]+\]\s*="#)
let known: Set<String> = ["ProviderConfigStore.swift", "ModelGroup.swift", "CloudSyncEngine.swift", "GroupsCollection.swift",
                          "ModelGroupDetailView.swift", "UnifiedModelPicker.swift", "DebugRPCProviderChat.swift"]
var writers = Set<String>()
if let walker = FileManager.default.enumerator(at: iosRoot, includingPropertiesForKeys: nil) {
    for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/MinisTests/") {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("memberEntryIds") else { continue }
        let body = code(text)
        if writer.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil { writers.insert(url.lastPathComponent) }
    }
}
check("the files that assign or mutate memberEntryIds are exactly the ones wired above (a new writer must add its line and this name)",
      writers == known)
if writers != known { print("     unexpected: \(writers.subtracting(known).sorted())  missing: \(known.subtracting(writers).sorted())") }

print("\n2e. The lines reach the daily log file in Release builds")
check("GroupOrderLog writes through AppLogger with its own category, info or warning",
      modelGroup.contains("private static let logger = AppLogger(category: \"GroupOrder\")")
      && modelGroup.contains("logger.warning(\"[GroupOrder] \\(text)\")") && modelGroup.contains("logger.info(\"[GroupOrder] \\(text)\")")
      && !between(modelGroup, "enum GroupOrderLog {", "\n}\n").contains("logger.debug"))
check("AppLogger's info and warning are unconditional (only debug is compiled out of Release)",
      appLogger.contains("func info(_ message: String)     { log(\"INFO\", message) }")
      && appLogger.contains("func warning(_ message: String)  { log(\"WARN\", message) }")
      && between(appLogger, "func debug(_ message: @autoclosure () -> String) {", "func info(").contains("#if DEBUG"))
check("a call with equal lists costs one comparison and builds no string",
      modelGroup.contains("guard before != after,\n              let line = GroupOrderDiff.line(")
      && modelGroup.contains("detail: @autoclosure () -> String = \"\""))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
