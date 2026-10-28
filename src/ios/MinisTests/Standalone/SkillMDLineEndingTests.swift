#!/usr/bin/env swift
// [T-skill-crlf] A SKILL.md written on Windows (CRLF line endings) imported as
// "Untitled Skill"; the same file converted to LF imported fine.
//
// Root cause: `SkillStore.parse(skillMD:)` split on "\n", leaving a trailing
// "\r" on every line, and compared `line.trimmingCharacters(in: .whitespaces)`
// against "---". `CharacterSet.whitespaces` does not contain CR, so the closing
// fence was never found and the whole file fell through to `body`.
//
// This compiles the SHIPPING parser (the "YAML Frontmatter Parser" section of
// Agent/Session/SkillStore.swift, lifted verbatim) with a tiny harness, so the
// code under test is exactly the one in the repo.
//
// Run: swift SkillMDLineEndingTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) \(detail())")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let store = source("Agent/Session/SkillStore.swift")
guard let start = store.range(of: "    // MARK: - YAML Frontmatter Parser"),
      let end = store.range(of: "    // MARK: - Import", range: start.upperBound..<store.endIndex) else {
    print("❌ parser section not found in SkillStore.swift"); exit(1)
}
let parser = "import Foundation\nenum SkillStore {\n" + store[start.lowerBound..<end.lowerBound] + "\n}\n"

// Cases: (label, content, expected name, description, version, body).
let main = #"""
func show(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") }
func report(_ label: String, _ md: String) {
    let p = SkillStore.parse(skillMD: md)
    print("CASE \(label)\u{1F}\(show(p.name))\u{1F}\(show(p.description))\u{1F}\(show(p.version))\u{1F}\(show(p.body))")
}
let lf = "---\nname: Test Skill\ndescription: 测试技能\nversion: 1.0.0\n---\n# Body\n\nLine two\n"
report("lf", lf)
report("crlf", lf.replacingOccurrences(of: "\n", with: "\r\n"))
report("cr", lf.replacingOccurrences(of: "\n", with: "\r"))
let block = "---\nname: Block Skill\ndescription: >-\n  folded line one\n  folded line two\nversion: 2.0.0\n---\nBody\n"
report("block-lf", block)
report("block-crlf", block.replacingOccurrences(of: "\n", with: "\r\n"))
let literal = "---\nname: Lit\ndescription: |\n  first\n  second\n---\nBody\n"
report("literal-crlf", literal.replacingOccurrences(of: "\n", with: "\r\n"))
let headless = "name: Headless\ndescription: no opening fence\n---\nBody\n"
report("headless-crlf", headless.replacingOccurrences(of: "\n", with: "\r\n"))
report("bom-crlf", "\u{FEFF}" + lf.replacingOccurrences(of: "\n", with: "\r\n"))
report("plain-crlf", "# Just markdown\r\n\r\nNo frontmatter here\r\n")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("skill-crlf-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = [("parser.swift", parser), ("main.swift", main)]
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
check("shipping SkillStore parser compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0, out)

var results: [String: [String]] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("CASE ") {
    let parts = line.dropFirst(5).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
    results[parts[0]] = Array(parts.dropFirst())
}
func expect(_ label: String, name: String, desc: String, version: String, body: String) {
    guard let r = results[label] else { check("\(label): produced a result", false); return }
    let want = [name, desc, version, body]
    check("\(label): name=\(name) desc=\(desc) version=\(version)", r == want, "got \(r)")
}

print("\n1. Same SKILL.md with LF / CRLF / CR endings parses identically")
expect("lf", name: "Test Skill", desc: "测试技能", version: "1.0.0", body: "# Body\\n\\nLine two")
expect("crlf", name: "Test Skill", desc: "测试技能", version: "1.0.0", body: "# Body\\n\\nLine two")
expect("cr", name: "Test Skill", desc: "测试技能", version: "1.0.0", body: "# Body\\n\\nLine two")

print("\n2. Block scalars and headless frontmatter under CRLF")
expect("block-lf", name: "Block Skill", desc: "folded line one folded line two", version: "2.0.0", body: "Body")
expect("block-crlf", name: "Block Skill", desc: "folded line one folded line two", version: "2.0.0", body: "Body")
expect("literal-crlf", name: "Lit", desc: "first\\nsecond", version: "1.0.0", body: "Body")
expect("headless-crlf", name: "Headless", desc: "no opening fence", version: "1.0.0", body: "Body")

print("\n3. Edge cases")
expect("bom-crlf", name: "Test Skill", desc: "测试技能", version: "1.0.0", body: "# Body\\n\\nLine two")
expect("plain-crlf", name: "Untitled Skill", desc: "", version: "1.0.0", body: "# Just markdown\\n\\nNo frontmatter here\\n")

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
