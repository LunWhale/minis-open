#!/usr/bin/env swift
// [T-config-readable] Human-readable descriptions of minis-config changes.
//
//   [1] pure logic, compiled from the SHIPPING sources (ConfigField.swift,
//       ConfigError.swift, Readable/ConfigReadable.swift) with swiftc:
//       list diff, placeholder counting, rendering + bad-translation fallback,
//       secret / image masking, URL scrubbing, line deltas, number formats,
//       ReadableSummary JSON round trip
//   [2] old audit rows: the app's real SQL on in-memory SQLite — a table from
//       before the `readable` column migrates, keeps its rows (NULL readable),
//       migrating twice is a no-op, and an older build's SELECT / INSERT still
//       work on the new table (downgrade)
//   [3] model-side leak guards: the CLI's audit serialization and every
//       bridge response stay free of the readable text
//   [4] fallback + enforcement: `readable` is a requirement without a default,
//       the renderer falls back to the generic sentence, `.generic(reason:)`
//       uses are allow-listed
//   [5] localization: every label / sentence key has zh-Hans and zh-Hant
//
// Run: swift ConfigReadableTests.swift   (needs swiftc)
import Foundation
import SQLite3

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.upperBound..<r2.lowerBound])
}
func matches(_ pattern: String, in text: String, group: Int = 1, options: NSRegularExpression.Options = []) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
        let r = $0.range(at: group)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}

// MARK: - [1] pure logic (compiled from shipping sources)

print("▶️  1. pure logic — shipping ConfigReadable.swift")

let harness = #"""
import Foundation
func out(_ k: String, _ v: Any) { print("\(k)=\(v)") }
func ids(_ items: [ReadableCore.ListItem]) -> String { items.map { $0.count > 1 ? "\($0.id)x\($0.count)" : $0.id }.joined(separator: ",") }
func d(_ o: [String], _ n: [String], _ ordered: Bool = true) -> ReadableCore.ListDiff { ReadableCore.listDiff(old: o, new: n, ordered: ordered) }

// list diff
var x = d(["a", "b", "c"], ["c", "a", "b"])
out("REORDER", "\(x.newFirst ?? "-")|\(ids(x.added))|\(ids(x.removed))|\(x.reordered)|\(x.keptCount)")
x = d(["a", "b", "b", "c"], ["n", "a", "c"])
out("TOP_ADD_REMOVE_DUP", "\(x.newFirst ?? "-")|\(ids(x.added))|\(ids(x.removed))|\(x.reordered)|\(x.keptCount)")
x = d(["a", "b"], ["a", "b", "c"])
out("APPEND", "\(x.newFirst ?? "-")|\(ids(x.added))|\(ids(x.removed))|\(x.reordered)")
x = d(["a", "b", "c"], ["b", "c"])
out("REMOVE_FIRST", "\(x.newFirst ?? "-")|\(ids(x.removed))|\(x.reordered)|\(x.keptCount)")
x = d(["a", "b"], ["a", "b"])
out("SAME_EMPTY", x.isEmpty)
x = d([], ["a"])
out("FROM_EMPTY", "\(x.newFirst ?? "-")|\(ids(x.added))")
x = d(["a", "b"], [])
out("TO_EMPTY", "\(x.newFirst ?? "-")|\(ids(x.removed))|\(x.keptCount)")
x = d(["a", "b", "c"], ["c", "b", "a"], false)
out("UNORDERED_FIRST", x.newFirst ?? "-")
out("UNORDERED_REORDER", x.reordered)
x = d(["a", "a", "a"], ["a"])
out("DUP_ONLY", "\(ids(x.removed))|\(x.reordered)")

// placeholders
out("PH", [ReadableCore.placeholderCount("%@: %@ → %@"),
           ReadableCore.placeholderCount("%1$@: %2$@ → %3$@"),
           ReadableCore.placeholderCount("100%% done %@"),
           ReadableCore.placeholderCount("no args"),
           ReadableCore.placeholderCount("%d bad"),
           ReadableCore.placeholderCount("%1$@ and %@ mixed"),
           ReadableCore.placeholderCount("$%1$@ – %2$@")].map(String.init).joined(separator: ","))

// render
let zh: [String: String] = [
    "%1$@: %2$@ → %3$@": "%1$@：%2$@ → %3$@",
    "Group “%1$@” – %2$@": "分组「%1$@」的%2$@",
    "Default thinking level": "默认思考强度",
    "High": "高", "Med": "中",
    "; ": "；", ", ": "、",
    "added %@": "新增 %@",
    "broken %1$@": "坏的 %1$@ %2$@",          // translation with an extra placeholder
    "positional %1$@ then %2$@": "先 %2$@ 后 %1$@",
]
let loc: (String) -> String = { zh[$0] ?? $0 }
let line = ReadableLine("%1$@: %2$@ → %3$@", [
    .line(ReadableLine("Group “%1$@” – %2$@", [.text("Light Models"), .key("Default thinking level")])),
    .key("High"), .key("Med")])
out("RENDER_ZH", ReadableCore.render(line, localize: loc))
out("RENDER_EN", ReadableCore.render(line, localize: { $0 }))
out("RENDER_CLAUSES", ReadableCore.render(ReadableLine("%1$@: %2$@", [.key("Models"),
    .clauses([.line(ReadableLine("added %@", [.list([.text("A"), .text("B")])])), .key("order changed")])]), localize: loc))
out("RENDER_BAD_TRANSLATION", ReadableCore.render(ReadableLine("broken %1$@", [.text("X")]), localize: loc))
out("RENDER_POSITIONAL", ReadableCore.render(ReadableLine("positional %1$@ then %2$@", [.text("A"), .text("B")]), localize: loc))
out("RENDER_PERCENT_ARG", ReadableCore.render(ReadableLine("%@", [.text("100% %@ %d")]), localize: loc))
out("RENDER_ARG_MISMATCH", ReadableCore.render(ReadableLine("%@ and %@", [.text("only one")]), localize: loc))

// redaction
let secret = RedactedConfigValue(fieldLeaf: "apiKey", value: .string("sk-live-SECRET-123"))
out("MASK_FIELD", secret.value.jsonString())
out("MASK_REF", RedactedConfigValue(fieldLeaf: "apiKey", value: .string("$$OPENAI_KEY")).value.jsonString())
out("MASK_OTHER_LEAF", RedactedConfigValue(fieldLeaf: "label", value: .string("sk-visible-label")).value.jsonString())
let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"
out("MASK_IMAGE", RedactedConfigValue(fieldLeaf: "icon", value: .string(png)).value.jsonString())
let payload = RedactedConfigValue(payload: .object(["label": .string("P"), "apiKey": .string("sk-live-SECRET-456"),
    "nested": .object(["oauthToken": .string("tok-SECRET-789"), "img": .string(png)])]))
out("MASK_PAYLOAD", payload.value.jsonString())

// helpers
out("URL", ReadableCore.safeURL("https://user:pw@api.example.com/v1?key=SECRET#frag"))
out("URL_PLAIN", ReadableCore.safeURL("api.example.com/v1?token=SECRET"))
let delta = ReadableCore.lineDelta(old: "a\nb\nc", new: "a\nc\nd\ne")
out("DELTA", "\(delta.added)/\(delta.removed)")
out("COUNTS", [64000, 131072, 1_048_576, 2_000_000, 1500, 999].map(ReadableCore.compactCount).joined(separator: ","))
out("PLAIN", [1.0, 0.5, 1.25, 0.333].map(ReadableCore.plainNumber).joined(separator: ","))
out("QUOTED", ReadableCore.quoted("line one\nline two that is long", preview: 12))

// summary JSON
let sum = ReadableSummary(locale: "zh-Hans", text: "t", lines: [line], subject: "groups:G1")
let json = sum.jsonString() ?? ""
out("JSON_ROUNDTRIP", ReadableSummary.decode(json: json) == sum)
out("JSON_NIL", ReadableSummary.decode(json: nil) == nil)
out("JSON_GARBAGE", ReadableSummary.decode(json: "{not json") == nil)

// generic opt-out is visible
out("GENERIC", ConfigReadable.generic(reason: "r").isGeneric && ConfigReadable.notWritable.isGeneric && !ConfigReadable(.bool()).isGeneric)
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("readable-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files: [(String, String)] = [
    ("ConfigField.swift", source("Shared/Config/ConfigField.swift")),
    ("ConfigError.swift", source("Shared/Config/ConfigError.swift")),
    ("ConfigReadable.swift", source("Shared/Config/Readable/ConfigReadable.swift")),
    ("main.swift", harness),
]
for (name, text) in files { try text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")

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

let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
check("shipping ConfigReadable + ConfigField compile standalone", cc == 0)
if cc != 0 { print(ccOut) }
let (rc, runOut) = cc == 0 ? run(bin.path, []) : (-1, "")
check("harness runs", rc == 0)
var r: [String: String] = [:]
for l in runOut.split(separator: "\n") {
    guard let eq = l.firstIndex(of: "=") else { continue }
    r[String(l[..<eq])] = String(l[l.index(after: eq)...])
}

check("reorder only: new first, nothing added/removed, reordered", r["REORDER"] == "c|||true|3")
check("REGRESSION example: model moved to top + one removed ×2 → first, added, removed ×2, rest in order",
      r["TOP_ADD_REMOVE_DUP"] == "n|n|bx2|false|2")
check(".append reads as an addition, order untouched", r["APPEND"] == "-|c||false")
check("removing the first element changes the primary but is NOT a reorder", r["REMOVE_FIRST"] == "b|a|false|2")
check("identical lists → empty diff", r["SAME_EMPTY"] == "true")
check("empty → one", r["FROM_EMPTY"] == "a|a")
check("one → empty: everything removed, no 'first'", r["TO_EMPTY"] == "-|a,b|0")
check("unordered lists never report a new first", r["UNORDERED_FIRST"] == "-")
check("…but a pure reorder is still visible", r["UNORDERED_REORDER"] == "true")
check("duplicates count: [a,a,a] → [a] removes a ×2", r["DUP_ONLY"] == "ax2|false")

check("placeholder counts (%@, %n$@, %% literal, none, %d invalid, mixed invalid, $ before %)",
      r["PH"] == "3,3,1,0,-1,-1,2")
check("renders a nested sentence in Chinese", r["RENDER_ZH"] == "分组「Light Models」的默认思考强度：高 → 中")
check("renders the English key when untranslated", r["RENDER_EN"] == "Group “Light Models” – Default thinking level: High → Med")
check("clauses and lists use the localized separators", r["RENDER_CLAUSES"] == "Models: 新增 A、B；order changed")
check("a translation with the wrong placeholder count falls back to English (no crash)",
      r["RENDER_BAD_TRANSLATION"] == "broken X")
check("positional placeholders reorder arguments", r["RENDER_POSITIONAL"] == "先 B 后 A")
check("an argument containing % / %@ / %d is inserted verbatim", r["RENDER_PERCENT_ARG"] == "100% %@ %d")
check("a key/argument mismatch degrades to joined text, never a format crash",
      r["RENDER_ARG_MISMATCH"] == "%@ and %@ only one")

check("SECRET: an apiKey value is masked", r["MASK_FIELD"] == #""••• (hidden)""#)
check("SECRET: a $$VAR reference stays (it names a variable, not the secret)", r["MASK_REF"] == #""$$OPENAI_KEY""#)
check("non-secret leaves are untouched", r["MASK_OTHER_LEAF"] == #""sk-visible-label""#)
check("an inline image collapses to <image>", r["MASK_IMAGE"] == #""<image>""#)
let maskedPayload = r["MASK_PAYLOAD"] ?? ""
check("SECRET: nested payload secrets are masked, none of the raw values survive",
      !maskedPayload.contains("SECRET") && maskedPayload.contains("••• (hidden)") && maskedPayload.contains("<image>")
      && !maskedPayload.contains("iVBOR"))

check("SECRET: URL user-info, query and fragment are dropped", r["URL"] == "https://api.example.com/v1")
check("SECRET: a scheme-less URL still loses its query", r["URL_PLAIN"] == "api.example.com/v1")
check("line delta counts added / removed lines", r["DELTA"] == "2/1")
check("token counts read compactly", r["COUNTS"] == "64K,128K,1M,2M,1,500,999")
check("plain numbers drop trailing zeros", r["PLAIN"] == "1,0.5,1.25,0.33")
check("quoted text is flattened and shortened", r["QUOTED"] == "“line one lin…”")
check("ReadableSummary JSON round-trips", r["JSON_ROUNDTRIP"] == "true")
check("missing / garbage JSON decodes to nil (old rows)", r["JSON_NIL"] == "true" && r["JSON_GARBAGE"] == "true")
check("generic opt-out is flagged, a real formatter is not", r["GENERIC"] == "true")

// MARK: - [2] old audit rows (real SQL, in-memory SQLite)

print("\n▶️  2. audit table — old rows and downgrade")
let auditSrc = source("Shared/Config/Audit/ConfigAuditLog.swift")
let createSQL = between(auditSrc, "exec(\"\"\"\n", "\"\"\")")
let alterSQL = matches(#"exec\("(ALTER TABLE config_audit ADD COLUMN [a-z_]+ TEXT)"\)"#, in: auditSrc)
let insertSQL = "INSERT OR REPLACE INTO config_audit" + between(auditSrc, "INSERT OR REPLACE INTO config_audit", "\"\"\"")
let selectSQL = matches(#""(SELECT id, at, actor[^"]*FROM config_audit)""#, in: auditSrc).first ?? ""
// What the build before this change ran, verbatim.
let oldInsert = """
    INSERT OR REPLACE INTO config_audit
      (id, at, actor, session_id, scope, key, old_value, new_value,
       confirmed_at, status, revert_of, caption)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""
let oldSelect = "SELECT id, at, actor, session_id, scope, key, old_value, new_value, confirmed_at, status, revert_of, caption FROM config_audit"

check("found CREATE / ALTERs / INSERT / SELECT in the shipping source",
      createSQL.contains("CREATE TABLE IF NOT EXISTS config_audit") && alterSQL.contains("ALTER TABLE config_audit ADD COLUMN readable TEXT")
      && insertSQL.contains("readable)") && selectSQL.contains("caption, readable FROM"))

var db: OpaquePointer?
sqlite3_open(":memory:", &db)
@discardableResult func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
func insert(_ sql: String, id: String, readable: String?) -> Bool {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(st) }
    let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let vals: [String?] = [id, nil, "agent", nil, "groups", "groups.G.entries", "[\"a\"]", "[\"b\"]", nil, "applied", nil, "cap"]
    for (i, v) in vals.enumerated() {
        let idx = Int32(i + 1)
        if i == 1 { sqlite3_bind_double(st, idx, 1000) }
        else if let v { sqlite3_bind_text(st, idx, v, -1, T) } else { sqlite3_bind_null(st, idx) }
    }
    if sqlite3_bind_parameter_count(st) == 13 {
        if let readable { sqlite3_bind_text(st, 13, readable, -1, T) } else { sqlite3_bind_null(st, 13) }
    }
    return sqlite3_step(st) == SQLITE_DONE
}
func selectRows(_ sql: String) -> [[String?]] {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(st) }
    var rows: [[String?]] = []
    while sqlite3_step(st) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(st)).map { c in sqlite3_column_text(st, c).map { String(cString: $0) } })
    }
    return rows
}

// A database as the previous build left it: CREATE + the caption ALTER only.
exec(createSQL)
exec("ALTER TABLE config_audit ADD COLUMN caption TEXT")
check("legacy row inserted by the OLD insert", insert(oldInsert, id: "legacy", readable: nil))
// This build's migration, twice (the second run must be a harmless no-op).
for sql in alterSQL { exec(sql) }
for sql in alterSQL { exec(sql) }
let afterMigrate = selectRows(selectSQL)
check("after migrating, the legacy row is still there", afterMigrate.count == 1 && afterMigrate.first?.first == "legacy")
check("…with readable = NULL (UI shows raw diff + 'predates' note)", afterMigrate.first?.last.flatMap { $0 } == nil)
check("migrating twice leaves exactly one readable column",
      selectRows("SELECT name FROM pragma_table_info('config_audit') WHERE name = 'readable'").count == 1)
check("new INSERT stores the readable JSON", insert(insertSQL, id: "new", readable: "{\"v\":1}"))
check("new SELECT reads it back", selectRows(selectSQL + " WHERE id = 'new'").first?.last.flatMap { $0 } == "{\"v\":1}")
check("DOWNGRADE: the old build's SELECT still works on the new table", selectRows(oldSelect).count == 2)
check("DOWNGRADE: the old build's INSERT still works (readable left NULL)", insert(oldInsert, id: "old2", readable: nil)
      && selectRows(selectSQL + " WHERE id = 'old2'").first?.last.flatMap { $0 } == nil)
sqlite3_close(db)

// MARK: - [3] model-side leak guards

print("\n▶️  3. the readable text never reaches the model")
let bridge = source("NativeOffloads/ConfigOffloadBridge.swift")
let dictFn = between(bridge, "private static func auditEntryDict(_ e: ConfigAuditEntry) -> NSDictionary {", "\n    }\n")
let dictKeys = Set(matches(#"(?:d\[)?"([a-z_]+)"(?:\]| *:)"#, in: dictFn))
check("audit list/get serialization is the unchanged allow-list",
      dictKeys == ["id", "at", "actor", "scope", "key", "old", "new", "status", "session_id", "confirmed_at", "revert_of"])
check("…and never touches `readable` or serializes the whole entry",
      !dictFn.isEmpty && !dictFn.contains("readable") && !dictFn.contains("JSONEncoder") && !dictFn.contains("encode("))
check("no bridge response carries a readable / summary key",
      !bridge.contains("\"readable\"") && !bridge.contains("\"summary\"") && !bridge.contains("\"readable_text\""))
let appliedRows = matches(#"appliedRow = \[([^\]]*)\]"#, in: bridge, options: [.dotMatchesLineSeparators])
check("applied[] rows are built without the readable text (\(appliedRows.count) sites)",
      appliedRows.count == 3 && appliedRows.allSatisfy { !$0.contains("readable") })
let userMessageLines = bridge.split(separator: "\n").filter { $0.contains("user_message") }
check("no user_message mentions the readable text", !userMessageLines.isEmpty && userMessageLines.allSatisfy { !$0.contains("readable") && !$0.contains("displayText") })
check("the readable summary is never rendered to text inside the bridge",
      !bridge.contains("displayText") && !bridge.contains(".text,") && !bridge.contains("readable.text"))
check("debug RPC config.audit reuses the CLI serialization (no own readable output)",
      !source("Debug/DebugRPCConfig.swift").contains("readable"))

// MARK: - [4] fallback + enforcement

print("\n▶️  4. required templates, rendering order, fallback")
let field = source("Shared/Config/ConfigField.swift")
check("ConfigField requires `readable` with no default implementation",
      field.contains("var readable: ConfigReadable { get }") && !field.contains("var readable: ConfigReadable {\n"))
let closure = source("Shared/Config/Fields/ClosureField.swift")
check("ClosureField takes `readable:` as a required argument", closure.contains("    let readable: ConfigReadable\n"))
let storage = source("Shared/Config/Fields/AppStorageFields.swift")
check("enum-backed AppStorage fields require value labels", storage.components(separatedBy: "    let valueLabels: [String: String]\n").count == 3)
check("string AppStorage fields require `readable:`", storage.contains("    let readable: ConfigReadable\n"))
let coll = source("Shared/Config/Fields/ConfigCollection.swift")
check("collections must name their children and describe add / remove",
      coll.contains("var readableSubjectFormat: String { get }") && coll.contains("func entityLabel(id: String) -> String?")
      && coll.contains("func readableForAdd(_ payload: RedactedConfigValue) -> [ReadableLine]")
      && coll.contains("func readableForRemove(id: String) -> [ReadableLine]")
      && !coll.contains("func entityLabel(id: String) -> String? {"))
let renderIdx = bridge.range(of: "ConfigReadableRenderer.forFieldWrite")?.lowerBound
let gateIdx = bridge.range(of: "ConfigConfirmationGate.shared.requestConfirmation(pending)")?.lowerBound
check("descriptions are rendered BEFORE the confirmation sheet", renderIdx != nil && gateIdx != nil && renderIdx! < gateIdx!)
let removeRender = bridge.range(of: "ConfigReadableRenderer.forCollectionRemove")?.lowerBound
let removeCall = bridge.range(of: "try collection.remove(id: childId)")?.lowerBound
check("a removal is described BEFORE the record is removed", removeRender != nil && removeCall != nil && removeRender! < removeCall!)
check("the renderer only accepts masked values", source("Shared/Config/Readable/ConfigReadableRenderer.swift")
      .contains("old: RedactedConfigValue,\n                              new: RedactedConfigValue)"))
let auditAppends = matches(#"audit\.append\(ConfigAuditEntry\((.*?)\)\)"#, in: bridge, options: [.dotMatchesLineSeparators])
check("every audit row the bridge writes carries its readable text (\(auditAppends.count) sites)",
      auditAppends.count == 4 && auditAppends.allSatisfy { $0.contains("readable: readable") })
let renderer = source("Shared/Config/Readable/ConfigReadableRenderer.swift")
check("an unknown shape falls back to the generic sentence, never an error",
      renderer.contains("?? [genericLine(phrase, old: old.value, new: new.value)]"))
check("launch validation runs after registration", source("Shared/Config/ConfigRegistry.swift")
      .contains("Self.registerBuiltins(into: self)\n        ConfigReadableRenderer.validateRegistry(self)"))

// Every `.generic(reason:)` on a writable field is listed here on purpose. The
// list may only shrink: a new setting needs a real template.
let genericAllowList: [String] = []
let configSources = ["Shared/Config/ConfigRegistry+Builtins.swift"]
    + ["Groups", "Models", "Providers", "EnvVars", "ThinkingRules", "SubAgents"].map { "Shared/Config/Collections/\($0)Collection.swift" }
let genericUses = configSources.flatMap { matches(#"\.generic\(reason: "([^"]*)"\)"#, in: source($0)) }
check("no registration uses .generic(reason:) beyond the allow-list (\(genericUses))",
      Set(genericUses).isSubset(of: Set(genericAllowList)))
let closureSites = configSources.map { source($0).components(separatedBy: "ClosureField(\n").count - 1 }.reduce(0, +)
let readableSites = configSources.map { matches(#"\n\s+readable: "#, in: source($0), group: 0).count }.reduce(0, +)
check("every ClosureField registration passes readable: (\(closureSites) ClosureField, \(readableSites) readable)",
      closureSites > 40 && readableSites >= closureSites)

// MARK: - [5] localization

print("\n▶️  5. zh-Hans / zh-Hant for every key")
let catalogData = (try? Data(contentsOf: ios.appendingPathComponent("Localizable.xcstrings"))) ?? Data()
let catalog = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
func translated(_ key: String, _ locale: String) -> Bool {
    guard let entry = catalog[key] as? [String: Any],
          let locs = entry["localizations"] as? [String: Any],
          let l = locs[locale] as? [String: Any],
          let unit = l["stringUnit"] as? [String: Any],
          let value = unit["value"] as? String else { return false }
    return !value.isEmpty
}
let str = #""((?:[^"\\]|\\.)*)""#
var keys = Set<String>()
let keySources = configSources + ["Shared/Config/Readable/ConfigReadable.swift", "Shared/Config/Readable/ConfigReadableRenderer.swift",
                                  "Shared/Config/Fields/AppStorageFields.swift"]
for rel in keySources {
    let s = source(rel)
    keys.formUnion(matches(#"ReadableLine\("# + str, in: s))
    keys.formUnion(matches(#"\.key\("# + str + #"\)"#, in: s))
    keys.formUnion(matches(#"\b(?:label|on|off|zero|empty|zeroLabel|firstKey):\s*"# + str, in: s))
    keys.formUnion(matches(#"\b(?:on|off|zero|empty): String\??\s*=\s*"# + str, in: s))
    keys.formUnion(matches(#"readableSubjectFormat = "# + str, in: s))
    // Keys held in constants (`static let primaryFirstKey = "…"`) or looked up
    // directly — both were missed once and shipped untranslated.
    keys.formUnion(matches(#"\b\w+Key(?:\s*:\s*String)?\s*=\s*"# + str, in: s))
    keys.formUnion(matches(#"localize\("# + str + #"\)"#, in: s))
    let dictBlocks = matches(#"(?:[Ll]abels(?::\s*\[String: String\])?\s*=\s*|valueLabels:\s*|\.enumLabels\(|merging\()\[(.*?)\]"#,
                             in: s, options: [.dotMatchesLineSeparators])
    for block in dictBlocks { keys.formUnion(matches(#""[^"]*":\s*"# + str, in: block)) }
    // Default field labels: the displayName of every writable registration.
    keys.formUnion(matches(#"(?:ClosureField|AppStorage\w+Field|fontScaleField)\(\s*path:[^\n]*\n\s*displayName:\s*"# + str, in: s)
        .filter { !$0.contains("\\(") })
}
// SwiftUI literals added for this feature.
keys.formUnion(["Summary of approved changes", "Status", "Changed by", "Requested", "Resolved", "Note from the assistant",
                "What changed", "This record predates readable descriptions, so only the raw change is shown.",
                "Raw change", "Setting", "Before", "After", "Revert This Change", "Reverted", "Change Details",
                "Revert this change?", "Revert", "Assistant", "You", "Assistant (revert)", "You (revert)",
                "This undoes:", "Setting restored.", "Revert Failed", "Unknown error"])
keys.remove("")
check("extracted a meaningful key set (\(keys.count))", keys.count > 120)
check("REGRESSION: the primary-model clause and both separators are covered",
      keys.isSuperset(of: ["primary is now %@", "first is now %@", ", ", "; "]))
let missingHans = keys.filter { !translated($0, "zh-Hans") }.sorted()
let missingHant = keys.filter { !translated($0, "zh-Hant") }.sorted()
check("every key has zh-Hans (\(missingHans.count) missing)", missingHans.isEmpty)
check("every key has zh-Hant (\(missingHant.count) missing)", missingHant.isEmpty)
if !missingHans.isEmpty || !missingHant.isEmpty {
    print("MISSING_KEYS_JSON=" + (String(data: try JSONSerialization.data(withJSONObject: Array(Set(missingHans + missingHant)).sorted()), encoding: .utf8) ?? ""))
}
for key in keys {
    guard let hans = ((catalog[key] as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any],
          let v = (hans["stringUnit"] as? [String: Any])?["value"] as? String else { continue }
    if matches(#"%(?:\d+\$)?@"#, in: v, group: 0).count != matches(#"%(?:\d+\$)?@"#, in: key, group: 0).count {
        check("zh-Hans placeholders match for '\(key)'", false)
    }
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
