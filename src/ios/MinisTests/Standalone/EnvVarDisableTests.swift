// Tests for [T-envvar-disable] — environment variables can be switched off
// without being deleted, the state syncs between devices, and builds that
// predate the feature can never overwrite or erase it.
//
// Compiles the REAL EnvVarEntry / EnvVarStateBook / EnvVarBackupEntry out of
// Shared/EnvVarStore.swift and runs them (including simulated older-build
// writes), then checks the wiring in source.
//
// Standalone: `swift EnvVarDisableTests.swift` from this directory.
import Foundation

/// The sources that used to be the single file Agent/Chat/ChatStore.swift -
/// the actor plus the files it was split into - read as one text.
func chatStoreSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["ChatStore", "ChatStore+Schema", "ChatStore+SessionCRUD", "ChatStore+SessionList",
                 "ChatStore+Search", "ChatStore+SessionQueries", "ChatStore+Folders",
                 "ChatStore+SessionDeletion", "ChatStore+StoredPreview", "ChatStore+Messages",
                 "ChatStore+Media", "ChatStore+CompactMarkers", "ChatStore+Tombstones",
                 "ChatStore+WebAppShortcuts", "ChatStore+Maintenance", "ChatStore+Helpers",
                 "ChatStore+UsageStats", "ChatStoreModels", "ContentPart+ProviderConversion",
                 "RawMessage+Conversion", "ChatStore+SyncDirty", "ChatStore+SyncRemoteSessions",
                 "ChatStore+SyncRemoteRecords", "ChatStore+BackupRestore"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func read(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let storeSrc = read("Shared/EnvVarStore.swift")
check("EnvVarStore.swift readable", !storeSrc.isEmpty)
guard let s = storeSrc.range(of: "struct EnvVarEntry: Identifiable, Codable {"),
      let e = storeSrc.range(of: "// END EnvVarStateBook", range: s.upperBound..<storeSrc.endIndex) else {
    print("❌ EnvVarEntry … EnvVarStateBook not found"); exit(1)
}
let models = String(storeSrc[s.lowerBound..<e.lowerBound])

let harness = "import Foundation\n" + models + #"""
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
func p(_ k: String, _ v: Any) { print("\(k)=\(v)") }

// 1. env-vars.json format is unchanged (older builds read/write it as before)
let oldJSON = #"[{"id":"A","key":"API_KEY","createdAt":700000000,"note":"n"}]"#
let entries = try! JSONDecoder().decode([EnvVarEntry].self, from: Data(oldJSON.utf8))
p("oldDecode", entries.count == 1 && entries[0].key == "API_KEY")
let reencoded = String(data: try! JSONEncoder().encode(entries), encoding: .utf8)!
p("entryHasNoEnabledKey", !reencoded.contains("enabled"))

// 2. default enabled, local switch, file round trip
var book = EnvVarStateBook()
p("defaultEnabled", book.isEnabled("A"))
book.setEnabled(false, id: "A", key: "API_KEY", now: at(0))
p("disabled", !book.isEnabled("A"))
let bookData = try! JSONEncoder().encode(book)
let book2 = try! JSONDecoder().decode(EnvVarStateBook.self, from: bookData)
p("roundTrip", book2 == book && !book2.isEnabled("A"))

// 3. an older build rewrites env-vars.json (edit / legacy merge / downgrade):
//    only the entry file changes, the state file is not its business.
var oldBuildEntries = entries; oldBuildEntries[0].note = "edited by old build"
_ = try! JSONEncoder().encode(oldBuildEntries)
p("oldRewriteKeepsState", !book2.isEnabled("A"))

// 4. inbound records
var r = book
p("missingFieldNoop", r.applyRemote(id: "A", key: "API_KEY", enabled: nil, updatedAt: at(100)) == false && !r.isEnabled("A"))
p("missingClockNoop", r.applyRemote(id: "A", key: "API_KEY", enabled: true, updatedAt: nil) == false && !r.isEnabled("A"))
p("olderIgnored", r.applyRemote(id: "A", key: "API_KEY", enabled: true, updatedAt: at(-5)) == false && !r.isEnabled("A"))
p("tieKeepsLocal", r.applyRemote(id: "A", key: "API_KEY", enabled: true, updatedAt: r.record("A")!.updatedAt) == false && !r.isEnabled("A"))
p("newerApplied", r.applyRemote(id: "A", key: "API_KEY", enabled: true, updatedAt: at(10)) == true && r.isEnabled("A"))
p("earlyStateKept", r.applyRemote(id: "NEW", key: "TOKEN", enabled: false, updatedAt: at(1)) && !r.isEnabled("NEW"))

// 5. clock: a peer with a clock ahead enabled it at +600; this device (clock
//    behind, now=+60) disables it -> its own change must still win here and
//    not be undone when the peer's older record is delivered again.
var c = EnvVarStateBook()
c.applyRemote(id: "A", key: "K", enabled: true, updatedAt: at(600))
let mine = c.setEnabled(false, id: "A", key: "K", now: at(60))
p("bumpAboveSeen", mine.updatedAt > at(600))
p("redeliveredOlderIgnored", c.applyRemote(id: "A", key: "K", enabled: true, updatedAt: at(600)) == false && !c.isEnabled("A"))
let mine2 = c.setEnabled(true, id: "A", key: "K", now: at(700))
p("normalClockUsesNow", mine2.updatedAt == at(700) && c.isEnabled("A"))

// 6. delete + same-name re-create (older build or this one): new id, enabled
var d = EnvVarStateBook()
d.setEnabled(false, id: "OLD", key: "API_KEY", now: at(0))
d.remove("OLD")
p("deleteClears", d.record("OLD") == nil)
p("recreatedStartsEnabled", d.isEnabled("NEWID"))

// 7. rename keeps the state (id-keyed)
var n = EnvVarStateBook()
n.setEnabled(false, id: "A", key: "OLD_NAME", now: at(0))
n.rename("A", to: "NEW_NAME")
p("renameKeeps", !n.isEnabled("A") && n.record("A")!.key == "NEW_NAME")

// 8. backup lines (iso8601, as the backup writer/reader use)
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let lines = [EnvVarBackupEntry(id: "A", key: "API_KEY", createdAt: at(0), note: "", enabled: false),
             EnvVarBackupEntry(id: "B", key: "OTHER", createdAt: at(0), note: "x", enabled: true)]
let bj = String(data: try! enc.encode(lines), encoding: .utf8)!
let back = try! dec.decode([EnvVarBackupEntry].self, from: Data(bj.utf8))
p("backupRoundTrip", back == lines && bj.contains("\"enabled\":false"))
let oldBackup = #"[{"id":"A","key":"API_KEY","createdAt":"2026-09-01T00:00:00Z","note":"n"}]"#
let ob = try! dec.decode([EnvVarBackupEntry].self, from: Data(oldBackup.utf8))
p("oldBackupEnabled", ob[0].enabled)
let androidLike = #"[{"id":"A","key":"API_KEY","createdAt":"2026-09-01T00:00:00Z","note":"n","enabled":false}]"#
p("androidLineDisabled", !(try! dec.decode([EnvVarBackupEntry].self, from: Data(androidLike.utf8)))[0].enabled)
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("evd-\(UUID().uuidString)")
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
check("models compile standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])
let lines = Set(o.split(separator: "\n").map(String.init))
func ok(_ k: String) -> Bool { lines.contains("\(k)=true") }

print("▶️  data model")
check("old env-vars.json (no enabled) still decodes", ok("oldDecode"))
check("env-vars.json format unchanged — no enabled key written there", ok("entryHasNoEnabledKey"))
check("default enabled; disabling sticks; state file round-trips", ok("defaultEnabled") && ok("disabled") && ok("roundTrip"))
check("an older build rewriting env-vars.json cannot touch the state", ok("oldRewriteKeepsState"))

print("▶️  inbound sync (state's own clock)")
check("a record missing enabled or its clock changes nothing (missing ≠ enable)", ok("missingFieldNoop") && ok("missingClockNoop"))
check("older and equal clocks are ignored, a newer one applies", ok("olderIgnored") && ok("tieKeepsLocal") && ok("newerApplied"))
check("a state arriving before its variable is kept", ok("earlyStateKept"))
check("a local switch beats every state already seen even with a slow clock", ok("bumpAboveSeen"))
check("…and an older record delivered again does not re-enable it", ok("redeliveredOlderIgnored"))
check("with a normal clock the change uses now", ok("normalClockUsesNow"))

print("▶️  delete / re-create / rename")
check("deleting a variable drops its state", ok("deleteClears"))
check("a variable re-created under the same name (new id) starts enabled", ok("recreatedStartsEnabled"))
check("rename keeps the state", ok("renameKeeps"))

print("▶️  backup lines")
check("export → import keeps enabled", ok("backupRoundTrip"))
check("an older backup without the field imports as enabled", ok("oldBackupEnabled"))
check("a line with enabled:false (iOS or Android writer) reads disabled", ok("androidLineDisabled"))

// MARK: - Wiring
func body(_ src: String, _ fn: String, end: String = "\n    }\n") -> String {
    guard let r = src.range(of: fn),
          let x = src.range(of: end, range: r.upperBound..<src.endIndex) else { return "" }
    return String(src[r.lowerBound..<x.lowerBound])
}
func ordered(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for p in parts {
        guard let r = text.range(of: p, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
let redactor = read("Shared/EnvVarRedactor.swift")
let term = read("Views/Rootfs/ISHTerminalView.swift")
let coord = read("Agent/ISH/ISHExecutionCoordinator.swift")
let types = read("Agent/Sync/V2/SyncedTypes.swift")
let hyd = read("Agent/Sync/V2/ChatStoreSyncHydrators.swift")
let chatStore = chatStoreSource()
let transport = read("Agent/Sync/V2/ICloudSharedZoneTransport.swift")
let policy = read("Agent/Sync/V2/UploadPolicy.swift")
let engine = read("Agent/Sync/CloudSyncEngine.swift")
let providers = read("Shared/Config/Collections/ProvidersCollection.swift")
let coll = read("Shared/Config/Collections/EnvVarsCollection.swift")
let builtins = read("Shared/Config/ConfigRegistry+Builtins.swift")
let exporter = read("Agent/Backup/BackupExporter.swift")
let importer = read("Agent/Backup/BackupImporter+Categories.swift")
let view = read("Views/Settings/EnvironmentVariablesView.swift")
let mcp = read("Views/MCP/MCPFormSheet.swift")

print("▶️  environment injection and masking")
check("allAsDict skips disabled variables",
      body(storeSrc, "nonisolated func allAsDict()").contains("for entry in entries where book.isEnabled(entry.id) {"))
check("masking still covers every variable, disabled ones included",
      redactor.contains("for entry in entries {") && !redactor.contains("loadStateBook")
      && !redactor.contains("stateBook") && !redactor.contains("isEnabled(entry"))
check("terminal: the kernel environment is always replaced (no stale variables when all are off)",
      term.contains("ISHKernel.shared.customEnvironment = customEnv")
      && !term.contains("if !customEnv.isEmpty {\n            ISHKernel.shared.customEnvironment"))
check("agent commands always get the current set (never nil)",
      coord.contains("environment: customEnv,") && !coord.contains("environment: customEnv.isEmpty ? nil : customEnv"))

print("▶️  sync: own record type, all five wiring points")
check("SyncedEnvVarState registered as EnvVarStateItem (entryId/key/enabled/updatedAt, LWW on its clock)",
      types.contains("recordType: \"EnvVarStateItem\"") && types.contains("r.register(SyncedEnvVarState.self)")
      && types.contains("F.int(\"enabled\",") && types.contains("conflictPolicy: .lastWriteWinsByField(\\SyncedEnvVarState.updatedAt)"))
check("hydrator: builder / merger / deletion applier",
      ordered(hyd, ["recordType: \"EnvVarStateItem\"", "buildEnvVarState(id: id)", "mergeEnvVarState(record: record)", "applyEnvVarStateDeletion(id: id)"]))
check("merger passes a missing field through as nil (not true)",
      hyd.contains("let enabled = intField(record, \"enabled\").map { $0 != 0 }"))
check("dirty whitelist, secrets zone, fetch list, full-history list",
      chatStore.contains("\"EnvVarStateItem\",  // [T-envvar-disable]")
      && transport.contains("\"EnvVarStateItem\":    secretsZoneName")
      && transport.contains("(\"EnvVarStateItem\", \"updatedAt\")")
      && transport.contains("\"EnvVarItem\", \"EnvVarStateItem\","))
check("the environments upload switch covers EnvVarItem and EnvVarStateItem",
      policy.contains("return [\"EnvVar\", \"EnvVarV2\", \"EnvVarItem\", \"EnvVarStateItem\"]"))

print("▶️  older-build paths cannot reach the state")
check("value / note sync (applyRemoteItem) never touches the state",
      !body(storeSrc, "func applyRemoteItem(").contains("stateBook"))
check("legacy whole-file merge (mergeEnvVars) never touches the state",
      !body(engine, "static func mergeEnvVars(remoteJson: String) {").contains("state"))
check("a variable deleted (here or by a peer) loses its state",
      body(storeSrc, "func delete(id: String) {").contains("stateBook.remove(id)")
      && body(storeSrc, "func applyRemoteDeletion(id: String) {").contains("stateBook.remove(id)"))
check("value/note edits keep the state; only setEnabled changes it",
      !body(storeSrc, "func updateNote(id: String, note: String) {").contains("setEnabled")
      && !body(storeSrc, "func saveFromShortcut(").contains("setEnabled"))

print("▶️  references, minis-config, backup, UI")
// Round 2 decision: a disabled variable's $$NAME resolves to "" with a warning.
let resolveBody = body(providers, "static func resolveSecret(_ raw: String) throws -> String {")
check("$$NAME of a disabled variable resolves to an empty value with a warning (no error)",
      ordered(resolveBody, ["guard EnvVarStore.isKeyEnabledSync(name) else {", "AppLogger(category: \"EnvVarRef\").warning(",
                            "ConfigWriteWarnings.add(warning)", "return \"\""])
      && !resolveBody.contains("is disabled — enable it in Settings → Environment Variables first\")"))
let bridge = read("NativeOffloads/ConfigOffloadBridge.swift")
let cfgErr = read("Shared/Config/ConfigError.swift")
check("minis-config: a batch starts with no warnings and returns what it collected",
      cfgErr.contains("enum ConfigWriteWarnings {")
      && ordered(bridge, ["var writeErrors: [[String: String]] = []", "_ = ConfigWriteWarnings.drain()",
                          "let warnings = ConfigWriteWarnings.drain()", "result[\"warnings\"] = warnings"]))
check("minis-config envvars.<KEY>.enabled: bool, sensitive, revertable, localized on/off",
      coll.contains("path: \"envvars.\\(key).enabled\"") && coll.contains("risk: .sensitive, revertable: true")
      && coll.contains("ConfigReadable(.bool(on: \"Enabled\", off: \"Disabled (environment variable)\"))"))
check("the envvars summary reports enabled", builtins.contains("\"enabled\": .bool(EnvVarStore.shared.isEnabled(id: e.id))"))
check("backup export writes EnvVarBackupEntry with enabled",
      exporter.contains("EnvVarBackupEntry(id: $0.id, key: $0.key, createdAt: $0.createdAt,")
      && exporter.contains("enabled: store.isEnabled(id: $0.id))"))
check("backup import: reads enabled, leaves an existing variable alone, disables a new one when the line says so",
      importer.contains("decoder.decode([EnvVarBackupEntry].self, from: data)")
      && ordered(importer, ["guard !existing.contains(entry.key) else {", "store.add(key: entry.key, value: value, note: entry.note)",
                            "if !entry.enabled,", "store.setEnabled(id: created.id, false)"]))
check("list: greyed + Disabled tag + Duplicate tag",
      view.contains(".opacity(isEnabled ? 1 : 0.6)") && view.contains("AppLocalized(\"Disabled (environment variable)\")")
      && view.contains("AppLocalized(\"Duplicate name\")"))
// Round 2 decision: the left-swipe buttons hold Delete and, beside it, Disable/Enable.
check("swiping left shows Delete and Disable/Enable (no leading swipe)",
      ordered(view, [".swipeActions(edge: .trailing, allowsFullSwipe: true) {",
                     "Button(role: .destructive) {", "store.delete(id: entry.id)",
                     "store.setEnabled(id: entry.id, !isEnabled)",
                     "isEnabled ? AppLocalized(\"Disable\") : AppLocalized(\"Enable\")"])
      && !view.contains(".swipeActions(edge: .leading"))
// Round 2 decision: no "restart terminals / MCP" hint anywhere.
check("no restart hint in the editor or the catalog",
      !view.contains("restart them to apply a change")
      && !read("Localizable.xcstrings").contains("restart them to apply a change"))
check("editor: Enabled switch; deep link to an existing name opens its editor",
      view.contains("Toggle(AppLocalized(\"Enabled\"), isOn: $enabled)")
      && ordered(view, ["if let existing = store.entries.first(where: { $0.key == normalizedKey }) {",
                        "highlightEnabledFor = store.isEnabled(id: existing.id) ? nil : existing.id",
                        "editingEntry = existing"]))
check("MCP variable picker marks disabled variables", mcp.contains("AppLocalized(\"$$\\(key) (disabled)\")"))
check("MCP form warns under headers and env when a value references a disabled variable",
      mcp.contains("disabledReferenceWarning(in: [url] + headers.map(\\.value))")
      && mcp.contains("disabledReferenceWarning(in: env.map(\\.value))")
      && mcp.contains("refers to a disabled environment variable and resolves to an empty value."))
// The reference scanner, compiled from source.
if let rs = mcp.range(of: "enum MCPEnvReferences {"),
   let re = mcp.range(of: "// END MCPEnvReferences", range: rs.upperBound..<mcp.endIndex) {
    let h = "import Foundation\n" + String(mcp[rs.lowerBound..<re.lowerBound]) + #"""
    print("refs=" + MCPEnvReferences.names(in: ["Bearer $$API_KEY", "$${TOKEN}/x $$API_KEY", "$PLAIN and $$ alone", ""]).joined(separator: ","))
    """#
    let m2 = tmp.appendingPathComponent("refs.swift"); try! h.write(to: m2, atomically: true, encoding: .utf8)
    let b2 = tmp.appendingPathComponent("refs").path
    let (c2, out2) = run("/usr/bin/xcrun", ["swiftc", "-o", b2, m2.path])
    if c2 != 0 { print(out2) }
    let (_, o2) = run(b2, [])
    check("MCP reference scan: $$NAME and $${NAME}, deduped, $NAME / bare $$ ignored",
          c2 == 0 && o2.contains("refs=API_KEY,TOKEN\n"))
} else { check("MCPEnvReferences found", false) }

print("▶️  backup values restore with their own category [T-envvar-backup-values]")
let secretsImp = read("Agent/Backup/BackupSecretsImporter.swift")
check("environment variables restore their values from secrets.json before creating the variables",
      ordered(importer, ["decoder.decode([EnvVarBackupEntry].self, from: data)",
                         "BackupSecretsImporter.restoreEnvVarValues(from: root)",
                         "store.add(key: entry.key, value: value, note: entry.note)"]))
check("one value writer, never overwriting (shared by the Providers credential pass)",
      secretsImp.contains("static func restoreEnvVarValues(from root: URL) -> (restored: Int, kept: Int) {")
      && secretsImp.contains("let env = restoreEnvVarValues(secrets.envVars)")
      && ordered(secretsImp, ["private static func restoreEnvVarValues(_ envVars:", "if EnvVarStore.loadValueSync(forKey: e.name) == nil {",
                              "EnvVarStore.saveValueSync(value, forKey: e.name)"]))

print("▶️  product decisions")
// (1) restore never overwrites an existing same-name variable's state
check("restore onto an existing same-name variable skips it before any state write",
      ordered(importer, ["guard !existing.contains(entry.key) else {", "report.skipped += 1", "continue",
                         "store.add(key: entry.key"]))
// (2) disabled rows stay visible and fully editable
check("disabled rows are listed (no filter) and tapping still opens the editor",
      !view.contains("filter { store.isEnabled") && !view.contains(".filter { isEnabled")
      && view.contains(".onTapGesture {\n            editingEntry = entry")
      && !view.contains(".disabled(!isEnabled)"))
// (3) zh-Hans tag wording 已禁用, own key so other screens keep 已停用
let catalog = read("Localizable.xcstrings")
func zhHans(_ key: String) -> String? {
    guard let d = try? JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any],
          let strings = d["strings"] as? [String: Any], let e = strings[key] as? [String: Any],
          let l = e["localizations"] as? [String: Any], let z = l["zh-Hans"] as? [String: Any],
          let u = z["stringUnit"] as? [String: Any] else { return nil }
    return u["value"] as? String
}
check("zh-Hans disabled tag reads 已禁用", zhHans("Disabled (environment variable)") == "已禁用")
check("the shared \"Disabled\" used by other screens is unchanged", zhHans("Disabled") == "已停用")

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
