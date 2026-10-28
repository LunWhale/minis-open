#!/usr/bin/env swift
// [T-crash-diag-export] Tests for the crash-diagnostics export: redaction rules
// (Shared/LogRedaction.swift) and the bundle / zip
// (Diagnostics/CrashDiagnosticsExport.swift), both compiled as shipped.
//
//   [1] sanitizeForExport: sk- keys, Bearer tokens, Authorization values (log
//       and JSON form), URL query parameters, e-mail addresses
//   [2] sanitizeLogForExport: an old-format log keeps each entry's first line
//       (with the body size) but drops the pretty-printed request body lines
//       after "[URLProtocol] Body (...)" and "📤 Anthropic Request"; other
//       multi-line entries are kept
//   [3] writeBundle: layout, sanitising per kind, empty sources skipped,
//       README manifest
//   [4] tail: the last N bytes, starting on a line boundary
//   [5] zip: a real archive holding exactly the bundle's files, all sanitised
//   [6] source guards: Settings > Logs entry, RPC registered + dispatched,
//       contexts archived instead of deleted
//
// Run: swift CrashDiagnosticsExportTests.swift
import Foundation

let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crashdiag-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let work = tmp.appendingPathComponent("work")

let main = tmp.appendingPathComponent("main.swift")
try! #"""
import Foundation
let work = URL(fileURLWithPath: CommandLine.arguments[1])
func out(_ k: String, _ v: String) { print("\(k)\t\(v.replacingOccurrences(of: "\n", with: "⏎"))") }

let token = "sk-ant-oat01-SECRETSECRETSECRET0123"
out("SK", LogRedaction.sanitizeForExport("key=\(token) end"))
out("BEARER", LogRedaction.sanitizeForExport("[URLProtocol] Set Bearer token (prefix: \(token)...)"))
out("AUTH_LOG", LogRedaction.sanitizeForExport("[17:34:58]   Authorization: Bearer abc.def-ghi"))
out("AUTH_JSON", LogRedaction.sanitizeForExport("{\"Authorization\" : \"Bearer xyz123\", \"x\": 1}"))
out("URL", LogRedaction.sanitizeForExport("GET https://api.example.com/v1/models?key=AIzaDUMMY&alt=sse done"))
out("URL_NOQ", LogRedaction.sanitizeForExport("POST https://api.anthropic.com/v1/messages"))
out("EMAIL", LogRedaction.sanitizeForExport("user ethan.smith+test@example.co.uk logged in"))
out("PLAIN", LogRedaction.sanitizeForExport("[CellSizing] idx=219 held=122.0 actual=61.3"))

let oldLog = """
[17:34:58] 2026-10-01 17:34:58.678 Minis[1:2] [AnthropicAgent] [INFO] stream START model=claude-sonnet-5-5
[17:34:58] 2026-10-01 17:34:58.684 Minis[1:3] [AnthropicProvider] [DEBUG] 📤 Anthropic Request
  model: claude-sonnet-5-5
  messages: 13
    [1] "You are Pikachu, a capable AI assistant"
[17:34:58] 2026-10-01 17:34:58.736 Minis[1:4] [AnthropicStreamTransport] [DEBUG] [URLProtocol] Body (134420 bytes):
[17:34:58] {
[17:34:58]   "messages" : [ { "content" : "secret chat text from the user" } ]
[17:34:58] }
[17:34:59] 2026-10-01 17:34:59.022 Minis[1:5] [Voice] [INFO] [capsule-calc] capsule rects=2
[17:34:59]     p0 inputBar[y446…840] overlap=true
[17:34:59] 2026-10-01 17:34:59.074 Minis[1:6] [SidebarIdentity] [INFO] [sidebar] sections 15->15 REORDER
"""
let cleaned = LogRedaction.sanitizeLogForExport(oldLog)
out("LOG", cleaned)

try? FileManager.default.removeItem(at: work)
let bundle = work.appendingPathComponent("bundle")
let written = try CrashDiagnosticsExport.writeBundle([
    .init(kind: .breadcrumbs, path: "breadcrumbs/run-1.txt") { "0 1 req.start claude\n1 2 life active key=\(token)" },
    .init(kind: .context, path: "contexts/context-1.txt") { "signal=SIGSEGV si_addr=0x18 pc=0x1" },
    .init(kind: .metricKit, path: "metrickit/a.json") { "{\"crashDiagnostics\":[], \"note\":\"mail me@x.io\"}" },
    .init(kind: .log, path: "logs/minis.log") { oldLog },
    .init(kind: .breadcrumbs, path: "breadcrumbs/empty.txt") { "" },
    .init(kind: .breadcrumbs, path: "breadcrumbs/nil.txt") { nil },
], into: bundle, header: "Minis crash diagnostics\nApp 1.15 (1)")
out("WRITTEN", written.joined(separator: ","))
out("README", (try? String(contentsOf: bundle.appendingPathComponent("README.txt"), encoding: .utf8)) ?? "")
out("B_CRUMBS", (try? String(contentsOf: bundle.appendingPathComponent("breadcrumbs/run-1.txt"), encoding: .utf8)) ?? "")
out("B_LOG", (try? String(contentsOf: bundle.appendingPathComponent("logs/minis.log"), encoding: .utf8)) ?? "")

let big = work.appendingPathComponent("big.log")
var bigText = ""
for i in 0..<5000 { bigText += "line \(i) " + String(repeating: "x", count: 90) + "\n" }
try Data(bigText.utf8).write(to: big)
let t = CrashDiagnosticsExport.tail(of: big, maxBytes: 10_000) ?? ""
out("TAIL_LEN", "\(t.utf8.count)")
out("TAIL_FIRST", String(t.prefix(12)))
out("TAIL_LAST", String(t.split(separator: "\n").last?.prefix(10) ?? ""))
out("TAIL_ALL", CrashDiagnosticsExport.tail(of: big, maxBytes: 10_000_000)?.utf8.count == bigText.utf8.count ? "1" : "0")

let zip = work.appendingPathComponent("out.zip")
try CrashDiagnosticsExport.zip(folder: bundle, to: zip)
out("ZIP", zip.path)
"""#.write(to: main, atomically: true, encoding: .utf8)

let bin = tmp.appendingPathComponent("diag").path
let (cs, co) = run("/usr/bin/xcrun", ["swiftc", "-o", bin,
                                      ios.appendingPathComponent("Shared/LogRedaction.swift").path,
                                      ios.appendingPathComponent("Diagnostics/CrashDiagnosticsExport.swift").path, main.path])
guard cs == 0 else { print("❌ compile failed:\n\(co)"); exit(1) }
let (rs, out) = run(bin, [work.path])
var r: [String: String] = [:]
for line in out.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1)
    if parts.count == 2 { r[String(parts[0])] = String(parts[1]) }
}
if rs != 0 { print("❌ harness exited \(rs):\n\(out)"); exit(1) }

print("▶️  1. sanitizeForExport")
check("sk- keys", r["SK"] == "key=sk-*** end")
check("token prefixes after 'prefix:'", r["BEARER"]?.contains("SECRET") == false && r["BEARER"]?.contains("sk-***") == true)
check("Authorization header value in a log line", r["AUTH_LOG"] == "[17:34:58]   Authorization: <redacted>")
check("Authorization value in JSON", r["AUTH_JSON"] == "{\"Authorization\" : \"<redacted>\", \"x\": 1}")
check("URL query parameters dropped, path kept", r["URL"] == "GET https://api.example.com/v1/models?<redacted> done")
check("a URL without a query is untouched", r["URL_NOQ"] == "POST https://api.anthropic.com/v1/messages")
check("e-mail addresses", r["EMAIL"] == "user <email> logged in")
check("ordinary diagnostics untouched", r["PLAIN"] == "[CellSizing] idx=219 held=122.0 actual=61.3")

print("▶️  2. sanitizeLogForExport")
let log = (r["LOG"] ?? "").replacingOccurrences(of: "⏎", with: "\n")
check("request body lines are gone", !log.contains("secret chat text") && !log.contains("You are Pikachu"))
check("…the entry keeps its first line with the size", log.contains("[URLProtocol] Body (134420 bytes):") && log.contains("📤 Anthropic Request"))
check("…and says what was dropped (3 + 3 lines)", log.components(separatedBy: "<request body omitted: 3 lines>").count == 3)
check("other multi-line entries are kept", log.contains("p0 inputBar[y446…840] overlap=true"))
check("entries after a body are kept", log.contains("REORDER") && log.contains("stream START"))

print("▶️  3. writeBundle")
check("files written, empty / nil sources skipped, README last",
      r["WRITTEN"] == "breadcrumbs/run-1.txt,contexts/context-1.txt,metrickit/a.json,logs/minis.log,README.txt")
let readme = (r["README"] ?? "").replacingOccurrences(of: "⏎", with: "\n")
check("README has the header, the file list and what was redacted",
      readme.hasPrefix("Minis crash diagnostics\nApp 1.15 (1)") && readme.contains("  logs/minis.log") && readme.contains("Redacted before export"))
check("breadcrumbs sanitised on the way out", r["B_CRUMBS"]?.contains("sk-***") == true && r["B_CRUMBS"]?.contains("SECRET") == false)
check("the log loses its request bodies", r["B_LOG"]?.contains("secret chat text") == false && r["B_LOG"]?.contains("request body omitted") == true)

print("▶️  4. tail")
let tl = Int(r["TAIL_LEN"] ?? "") ?? 0
check("at most the requested bytes", tl > 0 && tl <= 10_000)
check("starts on a line boundary, ends with the last line", r["TAIL_FIRST"]?.hasPrefix("line ") == true && r["TAIL_LAST"] == "line 4999 ")
check("a small file comes back whole", r["TAIL_ALL"] == "1")

print("▶️  5. zip")
let zipPath = r["ZIP"] ?? ""
let (us, listing) = run("/usr/bin/unzip", ["-l", zipPath])
check("a valid zip archive", us == 0)
check("…holding the bundle's files",
      ["breadcrumbs/run-1.txt", "contexts/context-1.txt", "metrickit/a.json", "logs/minis.log", "README.txt"].allSatisfy { listing.contains($0) })
let (_, unzipped) = run("/usr/bin/unzip", ["-p", zipPath, "*/metrickit/a.json"])
check("…with sanitised contents", unzipped.contains("<email>") && !unzipped.contains("me@x.io"))

print("▶️  6. source guards")
check("Settings > Logs links Crash Diagnostics", source("Views/Settings/LogManagementView.swift").contains("CrashDiagnosticsView()"))
let rpc = source("Debug/DebugJSONRPC.swift"), reg = source("Debug/DebugMethodRegistry.swift")
check("debug.crashDiag.list / read dispatched and registered",
      rpc.contains("case \"debug.crashDiag.list\":") && rpc.contains("case \"debug.crashDiag.read\":")
      && reg.contains("name: \"debug.crashDiag.list\"") && reg.contains("name: \"debug.crashDiag.read\""))
check("the RPC returns the same sanitised text as the view", rpc.contains("CrashDiagnostics.read(id: id)"))
let view = source("Views/Settings/CrashDiagnosticsView.swift")
check("CrashDiagnostics.read sanitises", view.contains("return LogRedaction.sanitizeForExport(rawText(item))"))
check("export goes through CrashDiagnosticsExport (sanitising writer + system zip)",
      view.contains("CrashDiagnosticsExport.writeBundle(sources") && view.contains("CrashDiagnosticsExport.zip(folder:"))
let reporter = source("Diagnostics/CrashReporter.swift")
check("crash contexts are archived (last 5), not deleted at launch",
      reporter.contains("Self.archivePreviousCrashContext()") && reporter.contains("names.dropFirst(5)"))

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)\n\(out)")
exit(failures == 0 ? 0 : 1)
