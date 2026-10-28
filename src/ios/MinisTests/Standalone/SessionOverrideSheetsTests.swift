#!/usr/bin/env swift
// [T-session-skills-bulk-empty] [T-session-mcps-bulk-empty] The in-chat
// per-session override sheets, "Skills in Session" and "MCPs in Session".
//
// Both had one top-left button whose title flipped between "Enable All" and
// "Disable All" with the current state, so the user had to work out the state
// to know what it would do; and iOS hides the navigation bar while the search
// field is active, so the button was out of reach exactly when the list was
// filtered. Both empty states were one grey line. Android's sheets have an
// empty card with icon, title and subtitle. The two sheets now share
// Views/Chat/AIChatView/SessionOverrideListParts.swift: two fixed buttons in
// the section header, a footer stating the search scope, an empty card.
//
//   [1] SessionBulkToggleRules, compiled from the shipping file
//   [2] the shared views
//   [3] each sheet: uses the shared parts, keeps scope / draft / features
//   [4] the keys cover every shipped locale
//
// Run: swift SessionOverrideSheetsTests.swift   (needs swiftc)
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

let parts = source("Views/Chat/AIChatView/SessionOverrideListParts.swift")
guard let rules = between(parts, "// BEGIN SessionBulkToggleRules", "// END SessionBulkToggleRules") else {
    print("❌ SessionBulkToggleRules not found"); exit(1)
}

let harness = #"""
import Foundation
func show(_ tag: String, _ states: [Bool]) {
    let a = SessionBulkToggleRules.availability(states)
    print("R \(tag)=\(a.canEnable ? "E" : "-")\(a.canDisable ? "D" : "-")")
}
show("allOn", [true, true, true])
show("allOff", [false, false])
show("mixed", [true, false, true])
show("singleOn", [true])
show("singleOff", [false])
show("empty", [])
for (tag, q) in [("q.empty", ""), ("q.spaces", "   "), ("q.newline", " \n\t"), ("q.word", "web"), ("q.padded", "  web ")] {
    print("R \(tag)=\(SessionBulkToggleRules.isFiltered(q))")
}
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("session-override-sheets-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = ["Rules.swift": "import Foundation\n" + rules, "main.swift": harness]
for (n, c) in files { try? c.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"]
    + files.keys.sorted().map { tmp.appendingPathComponent($0).path } + ["-o", bin])
print("[1] SessionBulkToggleRules from the shipping file")
check("the rules block compiles on its own", cc == 0)
if cc != 0 { print(ccOut); print("\n❌ FAILED"); exit(1) }
let (_, out) = run(bin, [])
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let body = line.dropFirst(2)
    if let eq = body.firstIndex(of: "=") { r[String(body[..<eq])] = String(body[body.index(after: eq)...]) }
}
check("all on → only Disable All does something", r["allOn"] == "-D")
check("all off → only Enable All does something", r["allOff"] == "E-")
check("mixed → both entries are live", r["mixed"] == "ED")
check("one skill on → Disable All only", r["singleOn"] == "-D")
check("one skill off → Enable All only", r["singleOff"] == "E-")
check("nothing in scope → neither entry is live", r["empty"] == "--")
check("empty query is not a filter", r["q.empty"] == "false")
check("whitespace-only query is not a filter", r["q.spaces"] == "false" && r["q.newline"] == "false")
check("a real query is a filter, padded or not", r["q.word"] == "true" && r["q.padded"] == "true")

print("[2] Shared views")
let header = between(parts, "struct SessionBulkToggleHeader: View {", "\n}\n") ?? ""
check("header found", !header.isEmpty)
check("Enable All always applies true, Disable All always false",
      header.contains("Button(AppLocalized(\"Enable All\")) { apply(true) }")
      && header.contains("Button(AppLocalized(\"Disable All\")) { apply(false) }"))
check("a no-op button is disabled, not hidden",
      header.contains(".disabled(!availability.canEnable)") && header.contains(".disabled(!availability.canDisable)"))
check("header buttons keep separate hit areas and are not upper-cased",
      header.contains(".buttonStyle(.borderless)") && header.contains(".textCase(nil)"))
let footer = between(parts, "struct SessionOverrideListFooter: View {", "\n}\n") ?? ""
check("footer shows the sheet's note and, while filtered, the search scope",
      footer.contains("            note\n") && footer.contains("if SessionBulkToggleRules.isFiltered(searchQuery) {")
      && footer.contains("AppLocalized(\"Enable All and Disable All apply only to the search results.\")"))
let card = between(parts, "struct SessionOverrideEmptyCard: View {", "\n}\n") ?? ""
check("empty card: icon, title, subtitle, centered",
      card.contains("Image(systemName: systemImage)") && card.contains("Text(title)") && card.contains("Text(subtitle)")
      && card.contains(".multilineTextAlignment(.center)") && card.contains(".frame(maxWidth: .infinity)"))

print("[3] Sheets")
struct Sheet {
    let name, path, item, list, filtered, apply, note, emptyIcon, emptyTitle, emptySubtitle, oldEmpty: String
    let kept: [(String, String)]
}
let sheets = [
    Sheet(name: "Skills", path: "Views/Chat/SessionSkillsView.swift", item: "skill", list: "store.skills",
          filtered: "filteredSkills", apply: "private func applyToAll(_ scope: [Skill], enabled: Bool) {",
          note: "Toggles override the skill's default for this session only.",
          emptyIcon: "doc.text", emptyTitle: "No skills installed", emptySubtitle: "Import skills from Settings → Skills.",
          oldEmpty: "No skills installed. Add skills in Settings.",
          kept: [("no-match line", "AppLocalized(\"No skills match \\\"\\(searchQuery)\\\".\")"),
                 ("tap opens detail", "SessionSkillDetailView(skill: skill)"),
                 ("long-press copies source URL", ".modifier(SkillSourceURLContextMenu(url: skill.importSource.copyableURL) {})")]),
    Sheet(name: "MCPs", path: "Views/MCP/SessionMCPsView.swift", item: "server", list: "store.servers",
          filtered: "filteredServers", apply: "private func applyToAll(_ scope: [MCPServerConfig], enabled: Bool) {",
          note: "Toggles override the server's default for this session only.",
          emptyIcon: "square.stack.3d.up", emptyTitle: "No MCP servers", emptySubtitle: "Add servers in Settings → MCP Integrations.",
          oldEmpty: "No MCP servers configured. Add servers in Settings → MCP Integrations.",
          kept: [("no-match line", "AppLocalized(\"No MCP servers match \\\"\\(searchQuery)\\\".\")"),
                 ("server note subtitle", "if let note = server.note, !note.isEmpty {")]),
]
for s in sheets {
    let v = source(s.path)
    check("\(s.name): file found", !v.isEmpty)
    check("\(s.name): the state-dependent single button is gone",
          !v.contains("allEnabled ? \"Disable All\" : \"Enable All\"") && !v.contains("let allEnabled"))
    check("\(s.name): no bulk action in the toolbar", !v.contains("ToolbarItem(placement: .topBarLeading)"))
    check("\(s.name): section header has the shared buttons for the filtered list, fed by the toggles' state",
          v.contains("} header: {\n                        let scope = \(s.filtered)\n                        SessionBulkToggleHeader(\n                            availability: SessionBulkToggleRules.availability(scope.map { isEnabled($0) })\n                        ) { applyToAll(scope, enabled: $0) }"))
    check("\(s.name): footer keeps the note and passes the query",
          v.contains("SessionOverrideListFooter(\n                            note: Text(\"\(s.note)\"),\n                            searchQuery: searchQuery)"))
    let applyAll = between(v, s.apply, "\n    }\n") ?? ""
    check("\(s.name): a draft session is materialized once for the whole batch",
          applyAll.components(separatedBy: "ensureSessionId?()").count - 1 == 1
          && applyAll.contains("resolvedSessionId = sid\n                for \(s.item) in scope {"))
    check("\(s.name): filter trims like isFiltered",
          v.contains("let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()"))
    check("\(s.name): empty state is the card",
          v.contains("if \(s.list).isEmpty {\n                    Section {\n                        SessionOverrideEmptyCard(systemImage: \"\(s.emptyIcon)\"")
          && v.contains("title: AppLocalized(\"\(s.emptyTitle)\")") && v.contains("subtitle: AppLocalized(\"\(s.emptySubtitle)\")"))
    check("\(s.name): old one-line empty text is gone", !v.contains(s.oldEmpty))
    check("\(s.name): kept search and Done",
          v.contains(".searchable(text: $searchQuery") && v.contains("Button(\"Done\") { dismiss() }"))
    for (label, needle) in s.kept { check("\(s.name): kept \(label)", v.contains(needle)) }
}

print("[4] Localization")
let catalogURL = iosRoot.appendingPathComponent("Localizable.xcstrings")
let catalog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))) as? [String: Any]
let strings = catalog?["strings"] as? [String: Any] ?? [:]
func locales(_ key: String) -> Set<String> {
    Set(((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?.keys.map { $0 } ?? [])
}
let shipped = locales("Copy Link")
check("reference key has the shipped locales (\(shipped.count))", shipped.count >= 17)
for key in ["Enable All", "Disable All", "No skills installed", "Import skills from Settings → Skills.",
            "Enable All and Disable All apply only to the search results.",
            "No MCP servers", "Add servers in Settings → MCP Integrations."] {
    let missing = shipped.subtracting(locales(key))
    check("\"\(key)\" covers every shipped locale\(missing.isEmpty ? "" : " — missing \(missing.sorted())")", missing.isEmpty)
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
