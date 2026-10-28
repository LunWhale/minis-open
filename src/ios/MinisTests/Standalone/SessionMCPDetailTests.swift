#!/usr/bin/env swift
// [T-session-mcp-detail] Tapping a server in the in-chat "MCPs in Session"
// sheet opens a read-only detail page: transport, URL (long-press copies it)
// and OAuth state, or command / args / startup timeout, the full note, and the
// NAMES of headers and env vars - never their values, which routinely hold API
// keys, on a sheet that sits over a chat that may be screen-shared. Same page
// as Android 3109967bc.
//
//   [1] MCPServerDetailRules, compiled from the shipping file, fed real-looking
//       secrets: only names come out
//   [2] source guards: the detail never reads a value or exports the config;
//       the row navigates, the toggle and the aligned pieces stay
//   [3] the keys cover every shipped locale
//
// Run: swift SessionMCPDetailTests.swift   (needs swiftc)
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

let view = source("Views/MCP/SessionMCPsView.swift")
guard let rules = between(view, "// BEGIN MCPServerDetailRules", "// END MCPServerDetailRules") else {
    print("❌ MCPServerDetailRules not found"); exit(1)
}

let harness = #"""
import Foundation
let headers = ["Authorization": "Bearer sk-live-SECRET-1", "X-Api-Key": "SECRET-2"]
let env = ["OPENAI_API_KEY": "sk-SECRET-3", "BASE": "https://SECRET-4.example"]
print("R headers=" + MCPServerDetailRules.secretNames(headers).joined(separator: ","))
print("R env=" + MCPServerDetailRules.secretNames(env).joined(separator: ","))
print("R nil=" + MCPServerDetailRules.secretNames(nil).joined(separator: ","))
print("R empty=" + MCPServerDetailRules.secretNames([:]).joined(separator: ","))
print("R t.stdio=" + MCPServerDetailRules.transportLabel(isSTDIO: true))
print("R t.url=" + MCPServerDetailRules.transportLabel(isSTDIO: false))
print("R args=" + (MCPServerDetailRules.argsLine(["-y", "@scope/server", "--port", "3000"]) ?? "nil"))
print("R args.empty=" + (MCPServerDetailRules.argsLine([]) ?? "nil"))
print("R args.nil=" + (MCPServerDetailRules.argsLine(nil) ?? "nil"))
print("R note=" + (MCPServerDetailRules.trimmedNote("  line one\nline two \n") ?? "nil").replacingOccurrences(of: "\n", with: "|"))
print("R note.blank=" + (MCPServerDetailRules.trimmedNote(" \n ") ?? "nil"))
print("R note.nil=" + (MCPServerDetailRules.trimmedNote(nil) ?? "nil"))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("session-mcp-detail-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = ["Rules.swift": "import Foundation\n" + rules, "main.swift": harness]
for (n, c) in files { try? c.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"]
    + files.keys.sorted().map { tmp.appendingPathComponent($0).path } + ["-o", bin])
print("[1] MCPServerDetailRules from the shipping file")
check("the rules block compiles on its own", cc == 0)
if cc != 0 { print(ccOut); print("\n❌ FAILED"); exit(1) }
let (_, out) = run(bin, [])
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let body = line.dropFirst(2)
    if let eq = body.firstIndex(of: "=") { r[String(body[..<eq])] = String(body[body.index(after: eq)...]) }
}
check("header names only, sorted", r["headers"] == "Authorization,X-Api-Key")
check("env names only, sorted", r["env"] == "BASE,OPENAI_API_KEY")
check("no secret value anywhere in the output", !out.contains("SECRET"))
check("no headers / empty headers → nothing", r["nil"] == "" && r["empty"] == "")
check("transport: STDIO / HTTP / SSE", r["t.stdio"] == "STDIO" && r["t.url"] == "HTTP / SSE")
check("args joined with spaces; none → hidden",
      r["args"] == "-y @scope/server --port 3000" && r["args.empty"] == "nil" && r["args.nil"] == "nil")
check("note trimmed, blank → hidden", r["note"] == "line one|line two" && r["note.blank"] == "nil" && r["note.nil"] == "nil")

print("[2] Source guards")
check("secretNames reads only the keys", rules.contains("return map.keys.sorted()") && !rules.contains(".values"))
let detail = between(view, "private struct SessionMCPDetailView: View {", "\n}\n") ?? ""
check("detail view found", !detail.isEmpty)
func count(_ s: String, _ n: String) -> Int { s.components(separatedBy: n).count - 1 }
check("headers are touched only through secretNames",
      count(detail, "server.headers") == 1 && detail.contains("MCPServerDetailRules.secretNames(server.headers)"))
check("env is touched only through secretNames",
      count(detail, "server.env") == 1 && detail.contains("MCPServerDetailRules.secretNames(server.env)"))
check("no value access, no export, no store writes",
      !detail.contains(".values") && !detail.contains("exportServerJSON") && !detail.contains("MCPStore")
      && !detail.contains("UIPasteboard") && !detail.contains("save(") && !detail.contains("update("))
check("values-hidden line under the names",
      detail.contains("AppLocalized(\"Values are hidden because they can contain keys. View or edit them in Settings → MCP Integrations.\")"))
check("STDIO: command, args, startup timeout with the default",
      detail.contains("detailRow(AppLocalized(\"Command\")") && detail.contains("detailRow(AppLocalized(\"Arguments\"), args)")
      && detail.contains("AppLocalized(\"Startup timeout (seconds)\")") && detail.contains("?? AppLocalized(\"Default 60\")"))
check("URL row: long-press copies via the shared modifier, not selectable",
      detail.contains("detailRow(AppLocalized(\"Server URL\"), url, selectable: false)\n                        .modifier(SkillSourceURLContextMenu(url: url.isEmpty ? nil : url,\n                                                            title: AppLocalized(\"Copy URL\")) {})"))
check("OAuth state only when OAuth is configured, read once per server",
      detail.contains("if server.oauth != nil {") && detail.contains(".task(id: server.id) {")
      && detail.contains("MCPOAuthController.isAuthorized(server: server.id)"))
check("full note, no line limit", detail.contains("Text(note).textSelection(.enabled)") && !detail.contains("lineLimit"))
check("no tool list", !detail.contains("tools") && !detail.contains("Tool"))
check("the row opens the detail", view.contains("NavigationLink {\n                                SessionMCPDetailView(server: server)\n                            } label: {"))
check("the toggle stays in the row and writes the session override",
      view.contains("set: { setOverride(server, $0) }"))
let mgmt = source("Views/Skills/SkillsManagementView.swift")
check("shared copy modifier: title defaults to Copy Source URL, still haptic",
      mgmt.contains("var title: String = AppLocalized(\"Copy Source URL\")") && mgmt.contains("Label(title, systemImage: \"link\")")
      && mgmt.contains("UINotificationFeedbackGenerator().notificationOccurred(.success)"))
check("kept: bulk header, footer, empty card, search, Done",
      view.contains("SessionBulkToggleHeader(") && view.contains("SessionOverrideListFooter(")
      && view.contains("SessionOverrideEmptyCard(") && view.contains(".searchable(text: $searchQuery")
      && view.contains("Button(\"Done\") { dismiss() }"))

print("[3] Localization")
let catalogURL = iosRoot.appendingPathComponent("Localizable.xcstrings")
let catalog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))) as? [String: Any]
let strings = catalog?["strings"] as? [String: Any] ?? [:]
func locales(_ key: String) -> Set<String> {
    Set(((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?.keys.map { $0 } ?? [])
}
let shipped = locales("Copy Link").subtracting(["en"])
check("reference key has the shipped locales (\(shipped.count))", shipped.count >= 17)
for key in ["Transport", "Command", "Arguments", "Startup timeout (seconds)", "Default 60", "Server URL", "Copy URL",
            "Authorized", "Not authorized", "Note", "Custom Headers", "Environment Variables",
            "Values are hidden because they can contain keys. View or edit them in Settings → MCP Integrations."] {
    let missing = shipped.subtracting(locales(key))
    check("\"\(key)\" covers every shipped locale\(missing.isEmpty ? "" : " — missing \(missing.sorted())")", missing.isEmpty)
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
