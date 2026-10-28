#!/usr/bin/env swift
// [T-skill-copy-source-url] Feature request from Telegram: on the Skills screens,
// long-press a skill to copy the URL it was installed from.
//
//   [1] SkillImportSource (BEGIN/END block in SkillStore.swift), compiled as
//       shipped: copyableURL for url / file / bundled / session sources, the
//       "url:<value>" DB round-trip, blank and whitespace-padded URLs.
//   [2] Source guards: the context menu exists only when there is a URL, the
//       Settings list / detail Source row / in-session list all use it, the
//       copy writes the pasteboard and gives feedback, and both new strings
//       are in the catalog for every shipped language.
//
// Run: swift SkillCopySourceURLTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
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

let store = source("Agent/Session/SkillStore.swift")
guard let block = between(store, "// BEGIN SkillImportSource", "// END SkillImportSource") else {
    print("❌ SkillImportSource block not found"); exit(1)
}

print("[1] SkillImportSource.copyableURL, compiled as shipped")
let driver = #"""
import Foundation
\#(block)
func show(_ s: String?) -> String { s.map { "<\($0)>" } ?? "nil" }
let cases: [(String, SkillImportSource)] = [
    ("url", .url("https://github.com/a/b/blob/main/SKILL.md")),
    ("padded", .url("  https://x.dev/s.md \n")),
    ("blank", .url("")),
    ("spaces", .url("   ")),
    ("file", .file), ("bundled", .bundled), ("session", .session),
    ("db-url", SkillImportSource.fromDB("url:https://x.dev/a?b=1#c")),
    ("db-bare", SkillImportSource.fromDB("url:")),
    ("db-file", SkillImportSource.fromDB("file")),
    ("db-bundled", SkillImportSource.fromDB("bundled")),
    ("db-unknown", SkillImportSource.fromDB("something")),
]
for (name, src) in cases { print("\(name)=\(show(src.copyableURL))") }
let rt = SkillImportSource.fromDB(SkillImportSource.url("https://x.dev/u:1").dbValue)
print("roundtrip=\(show(rt.copyableURL))")
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("skill_copy_url_\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let src = tmp.appendingPathComponent("main.swift"), exe = tmp.appendingPathComponent("t")
try! driver.write(to: src, atomically: true, encoding: .utf8)
let (cc, cout) = run("/usr/bin/xcrun", ["swiftc", "-O", src.path, "-o", exe.path])
check("block compiles standalone", cc == 0)
if cc != 0 { print(cout); exit(1) }
let out = run(exe.path, []).1
var got: [String: String] = [:]
for line in out.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { got[parts[0]] = parts[1] }
}
check("URL source → copied verbatim", got["url"] == "<https://github.com/a/b/blob/main/SKILL.md>")
check("surrounding whitespace trimmed", got["padded"] == "<https://x.dev/s.md>")
check("empty URL → no action", got["blank"] == "nil")
check("whitespace-only URL → no action", got["spaces"] == "nil")
check("file import → no action", got["file"] == "nil")
check("bundled → no action", got["bundled"] == "nil")
check("session-created → no action", got["session"] == "nil")
check("DB row keeps query and fragment", got["db-url"] == "<https://x.dev/a?b=1#c>")
check("bare \"url:\" DB row → no action", got["db-bare"] == "nil")
check("DB file / bundled / unknown → no action",
      got["db-file"] == "nil" && got["db-bundled"] == "nil" && got["db-unknown"] == "nil")
check("dbValue round-trip keeps a colon in the URL", got["roundtrip"] == "<https://x.dev/u:1>")

print("[2] Source guards")
let mgmt = source("Views/Skills/SkillsManagementView.swift")
let session = source("Views/Chat/SessionSkillsView.swift")
let modifier = between(mgmt, "struct SkillSourceURLContextMenu: ViewModifier {", "// MARK: - Import Sheet") ?? ""
check("modifier found", !modifier.isEmpty)
check("no URL → content returned without a context menu",
      modifier.contains("if let url {") && modifier.contains("} else {\n            content\n        }"))
check("copy writes the pasteboard with the URL", modifier.contains("UIPasteboard.general.string = url"))
check("copy gives haptic feedback", modifier.contains("UINotificationFeedbackGenerator().notificationOccurred(.success)"))
check("menu label is the localized key", modifier.contains("AppLocalized(\"Copy Source URL\")"))
check("Settings list rows use it with a toast",
      mgmt.contains(".modifier(SkillSourceURLContextMenu(url: skill.importSource.copyableURL) {\n                    showToast(AppLocalized(\"Source URL copied\"))"))
check("detail Source row uses it and flashes Copied",
      mgmt.contains("showSourceURLCopied = true") && mgmt.contains("if showSourceURLCopied {"))
check("in-session skills list uses it",
      session.contains(".modifier(SkillSourceURLContextMenu(url: skill.importSource.copyableURL)"))
check("swipe-to-delete on the Settings list is kept", mgmt.contains(".onDelete { offsets in"))
check("toast timer cannot clear a newer toast", mgmt.contains("if toastToken == token { toastMessage = nil }"))

let catalogURL = iosRoot.appendingPathComponent("Localizable.xcstrings")
let catalog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))) as? [String: Any]
let strings = catalog?["strings"] as? [String: Any] ?? [:]
func locales(_ key: String) -> Set<String> {
    Set(((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?.keys.map { $0 } ?? [])
}
let shipped = locales("Copy Link")
check("reference key has the shipped locales (\(shipped.count))", shipped.count >= 17)
for key in ["Copy Source URL", "Source URL copied"] {
    let missing = shipped.subtracting(locales(key))
    check("\"\(key)\" covers every shipped locale\(missing.isEmpty ? "" : " — missing \(missing.sorted())")", missing.isEmpty)
}

try? FileManager.default.removeItem(at: tmp)
print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
