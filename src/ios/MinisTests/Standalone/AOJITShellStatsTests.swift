// Tests for [T-aojit-shell-stats]: one [AOJIT] line in the app log per
// shell_execute, from /proc/ish/jit snapshots taken before and after it.
//
//   [1] parsing the runtime report's totals and per-module rows (port)
//   [2] the log line: deltas, rate, per-module breakdown, other, overlap
//   [3] wiring (source guards)
//
// Standalone: `swift AOJITShellStatsTests.swift`.

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

// MARK: - Ports (AOJITRuntimeStatus rows + AOJITShellStats)

struct Cov: Equatable { var blocks = 0, hits = 0, moved = 0 }
func rows(_ report: String) -> [String: Cov] {
    var hits: [String: Cov] = [:]
    for raw in report.split(separator: "\n") {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 4, parts[0].hasPrefix("/"), parts[2] == "/",
           let blocks = Int(parts[1]), let hit = Int(parts[3]) {
            let moved = parts.count >= 6 && parts[4] == "/" ? Int(parts[5]) ?? 0 : 0
            hits[parts[0]] = Cov(blocks: blocks, hits: hit, moved: moved)
        }
    }
    return hits
}
struct Snap {
    var aotOn = false, blocks = 0, installs = 0, moved = 0
    var modules: [String: Cov] = [:]
    init(report: String) {
        aotOn = report.contains("\nAOT: on")
        blocks = Snap.int(after: "blocks translated or looked up: ", in: report)
        installs = Snap.int(after: "AOT installs: ", in: report)
        moved = Snap.int(after: "(moved: ", in: report)
        modules = rows(report)
    }
    static func int(after key: String, in s: String) -> Int {
        guard let r = s.range(of: key) else { return 0 }
        return Int(s[r.upperBound...].prefix { $0.isNumber }) ?? 0
    }
}
func percent(_ part: Int, of whole: Int) -> String {
    guard whole > 0 else { return "-" }
    var p = Int((Double(part) / Double(whole) * 100).rounded())
    if part < whole { p = min(p, 99) }
    if part > 0 { p = max(p, 1) }
    return "\(p)%"
}
func format(before: Snap, after: Snap, seconds: Double, exitCode: Int, overlap: Int, command: String) -> String {
    let blocks = max(0, after.blocks - before.blocks)
    let installs = max(0, after.installs - before.installs)
    let moved = max(0, after.moved - before.moved)
    var perModule: [(name: String, blocks: Int, hits: Int)] = []
    for (path, now) in after.modules {
        let was = before.modules[path] ?? Cov()
        let b = now.blocks - was.blocks, h = now.hits - was.hits
        guard b > 0 else { continue }
        perModule.append(((path as NSString).lastPathComponent, b, max(0, h)))
    }
    perModule.sort { $0.blocks != $1.blocks ? $0.blocks > $1.blocks : $0.name < $1.name }
    let inModules = perModule.reduce(0) { $0 + $1.blocks }
    let modules = perModule.map { "\($0.name) \($0.hits)/\($0.blocks) (\(percent($0.hits, of: $0.blocks)))" }
        .joined(separator: " ")
    let cmd = command.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
    let shortCmd = cmd.count > 100 ? String(cmd.prefix(100)) + "…" : cmd
    // The logger's category already prefixes "[AOJIT]".
    return "exec aot=\(after.aotOn ? "on" : "off") dur=\(String(format: "%.2f", seconds))s exit=\(exitCode) "
        + "overlap=\(overlap) blocks=+\(blocks) aot=+\(installs) (\(percent(installs, of: blocks))) moved=+\(moved)"
        + " | \(modules.isEmpty ? "-" : modules) other=+\(max(0, blocks - inModules))"
        + " | cmd=\"\(shortCmd)\""
}

func report(on: Bool, blocks: Int, installs: Int, moved: Int, _ modules: [(String, Int, Int, Int)]) -> String {
    var s = "mode: AOT images only (no executable memory)\nAOT: \(on ? "on" : "off") (echo on|off > /proc/ish/jit; affects blocks compiled afterwards, i.e. new processes)\n"
    s += "blocks translated or looked up: \(blocks), AOT installs: \(installs) (moved: \(moved), with pc-relative immediates fixed: 0, slot taken elsewhere: 0), reused: 0\n"
    s += "images: 13 in use, 0 rejected (abi daf8fcc7)\nmodules with an image (blocks / AOT hits / of which moved):\n"
    for (p, b, h, m) in modules { s += "  \(p)   \(b) / \(h)   / \(m)\n" }
    s += "  /usr/bin/node                            not loaded by any process yet\n"
    return s
}

print("▶️  1. report parsing")
let r1 = report(on: true, blocks: 5000, installs: 3000, moved: 10,
                [("/lib/ld-musl-aarch64.so.1", 2000, 1500, 0), ("/usr/lib/libpython3.12.so.1.0", 2500, 1400, 10)])
let s1 = Snap(report: r1)
check("totals: blocks, installs, moved", s1.blocks == 5000 && s1.installs == 3000 && s1.moved == 10)
check("AOT on read", s1.aotOn)
check("AOT off read", !Snap(report: report(on: false, blocks: 1, installs: 0, moved: 0, [])).aotOn)
check("per-module rows, 'not loaded' skipped", s1.modules.count == 2 && s1.modules["/usr/lib/libpython3.12.so.1.0"] == Cov(blocks: 2500, hits: 1400, moved: 10))

print("\n▶️  2. log line")
let r2 = report(on: true, blocks: 6000, installs: 3880, moved: 30,
                [("/lib/ld-musl-aarch64.so.1", 2300, 1780, 0), ("/usr/lib/libpython3.12.so.1.0", 3200, 2000, 30)])
let line = format(before: s1, after: Snap(report: r2), seconds: 3.2104, exitCode: 0, overlap: 0, command: "python3 -c 'print(1)'")
print("    " + line)
check("deltas: +1000 blocks, +880 from images (88%), +20 moved",
      line.contains("blocks=+1000 aot=+880 (88%) moved=+20"))
check("per module, largest first, each with its own rate",
      line.contains("| libpython3.12.so.1.0 600/700 (86%) ld-musl-aarch64.so.1 280/300 (93%) other=+0 |"))
check("other = blocks outside modules with an image", line.contains("other=+0"))
check("aot state, duration, exit, overlap (the logger adds the [AOJIT] prefix)", line.hasPrefix("exec aot=on dur=3.21s exit=0 overlap=0 "))
check("command quoted", line.hasSuffix("| cmd=\"python3 -c 'print(1)'\""))
do {
    let off = format(before: Snap(report: report(on: false, blocks: 100, installs: 0, moved: 0, [])),
                     after: Snap(report: report(on: false, blocks: 400, installs: 0, moved: 0, [])),
                     seconds: 1, exitCode: 1, overlap: 2, command: "ls\n-la \"x\"")
    print("    " + off)
    check("AOT off: rate 0%, no modules, all 'other', overlap shown", off.contains("aot=off") && off.contains("blocks=+300 aot=+0 (0%)")
          && off.contains("| - other=+300") && off.contains("overlap=2") && off.contains("exit=1"))
    check("newlines and double quotes are flattened", off.hasSuffix("cmd=\"ls -la 'x'\""))
    let same = format(before: s1, after: s1, seconds: 0.01, exitCode: 0, overlap: 0, command: "true")
    check("nothing compiled → rate '-', no modules", same.contains("blocks=+0 aot=+0 (-)") && same.contains("| - other=+0"))
    let long = format(before: s1, after: s1, seconds: 0, exitCode: 0, overlap: 0, command: String(repeating: "a", count: 300))
    check("long commands: only the first 100 chars, then …", long.hasSuffix("cmd=\"" + String(repeating: "a", count: 100) + "…\""))
    let exact = format(before: s1, after: s1, seconds: 0, exitCode: 0, overlap: 0, command: String(repeating: "b", count: 100))
    check("exactly 100 chars: kept whole, no …", exact.hasSuffix("cmd=\"" + String(repeating: "b", count: 100) + "\""))
}

// MARK: - Sources

let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
let src = read("Agent/Chat/AOJITShellStats.swift")
let tools = read("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let pbx = read("Minis.xcodeproj/project.pbxproj")
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""

print("\n▶️  3. wiring")
func body(_ s: String, _ from: String, _ to: String) -> String {
    guard let a = s.range(of: from), let b = s.range(of: to, range: a.upperBound..<s.endIndex) else { return "" }
    // The port names the coverage type Cov; the app's is AOJITRuntimeStatus.Coverage.
    return String(s[a.lowerBound..<b.upperBound]).replacingOccurrences(of: "AOJITRuntimeStatus.Coverage()", with: "Cov()")
        .replacingOccurrences(of: "Self.maxCommandChars", with: "100")
        .filter { !$0.isWhitespace }
}
check("the cap is 100 characters", src.contains("static let maxCommandChars = 100"))
check("format port is verbatim",
      !body(src, "let blocks = max(0, after.blocks - before.blocks)", "+ \" | cmd=\\\"\\(shortCmd)\\\"\"").isEmpty
      && body(src, "let blocks = max(0, after.blocks - before.blocks)", "+ \" | cmd=\\\"\\(shortCmd)\\\"\"")
         == body(me, "let blocks = max(0, after.blocks - before.blocks)", "+ \" | cmd=\\\"\\(shortCmd)\\\"\""))
check("totals parsed from the report's own labels",
      src.contains("blocks = Self.int(after: \"blocks translated or looked up: \", in: report)")
      && src.contains("installs = Self.int(after: \"AOT installs: \", in: report)") && src.contains("moved = Self.int(after: \"(moved: \", in: report)"))
check("report read off the main thread", src.contains("await Task.detached(priority: .utility) { ISHKernel.aojitStatusReport() }.value"))
check("no JIT runtime → no log line", src.contains("guard text.contains(\"images:\") else { return nil }"))
check("logged with AOJIT off too (the aot=off baseline), not gated on the setting",
      !src.contains("isAOJITEnabled()"))
check("logged through the AOJIT category (one prefix, not two)",
      src.contains("private static let logger = AppLogger(category: \"AOJIT\")") && !src.contains("return \"[AOJIT] exec"))
check("overlap = others running at start + started during",
      src.contains("return token.othersAtStart + (starts - token.startsAtStart)"))
check("shell_execute: snapshot before the command, log after it (errors too)",
      (tools.range(of: "let aojitToken = await AOJITShellStats.begin()")?.lowerBound ?? tools.endIndex)
        < (tools.range(of: "result = try await executeCommand(command, timeout: timeout)")?.lowerBound ?? tools.startIndex)
      && (tools.range(of: "result = CommandResult(output: \"Error: \\(error.localizedDescription)\", exitCode: -1)")?.upperBound ?? tools.endIndex)
        < (tools.range(of: "await AOJITShellStats.end(aojitToken, command: command, exitCode: result.exitCode)")?.lowerBound ?? tools.startIndex))
check("in the app target", pbx.contains("E5AJS0001 /* AOJITShellStats.swift in Sources */,"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
