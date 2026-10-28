#!/usr/bin/env swift
// [OpenMinis#438] A custom OpenAI-compatible gateway reports
// `"context_length": 1000000` on /v1/models, but iOS read no context field on
// that path: the window came only from models.dev matched by id, so a relay id
// like `cn:deepseek-v4-pro` matched nothing and fell back to the 128K guess,
// and a bare id could be overwritten by another provider's larger window.
//
//   [1] the shipping ModelListParsing block (OpenAIModelsAPI.swift):
//       reportedLimits() reads the fields gateways send
//   [2] source guards: performFetch stamps the limits + flag, applyDevData
//       only fills what a flagged model left nil, ModelEntry carries the flag,
//       LLMModel's field is Optional (old saves still decode)
//
// Run: swift ReportedModelLimitsTests.swift   (needs swiftc)
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

let api = source("Providers/OpenAI/OpenAIModelsAPI.swift")
let dev = source("Providers/ModelsDevAPI.swift")
let types = source("Providers/LLMTypes.swift")
let entry = source("Providers/ModelEntry.swift")
guard let parsing = between(api, "// BEGIN ModelListParsing", "// END ModelListParsing") else {
    print("❌ ModelListParsing block not found"); exit(1)
}

let harness = #"""
import Foundation
"""# + parsing + #"""

var fails = 0
func CHECK(_ label: String, _ ok: Bool) { print("  \(ok ? "PASS" : "FAIL") \(label)"); if !ok { fails += 1 } }
func L(_ json: String) -> (context: Int?, output: Int?) {
    let arr = ModelListParsing.modelArray(Data(json.utf8)) ?? []
    let obj = arr.first.flatMap { ModelListParsing.entry($0)?.object } ?? [:]
    return ModelListParsing.reportedLimits(of: obj)
}

print("[1] reportedLimits")
let issue = L(#"{"object":"list","data":[{"id":"cn:deepseek-v4-pro","object":"model","owned_by":"workbuddy","context_length":1000000,"max_output_tokens":393216}]}"#)
CHECK("issue #438 body -> 1000000 / 393216", issue.context == 1_000_000 && issue.output == 393_216)
CHECK("context_window", L(#"{"data":[{"id":"a","context_window":200000}]}"#).context == 200_000)
CHECK("contextWindow + maxOutputTokens", { let l = L(#"{"data":[{"id":"a","contextWindow":64000,"maxOutputTokens":8192}]}"#); return l.context == 64_000 && l.output == 8_192 }())
CHECK("max_context_length", L(#"{"data":[{"id":"a","max_context_length":32768}]}"#).context == 32_768)
CHECK("limit.context / limit.output", { let l = L(#"{"data":[{"id":"a","limit":{"context":512000,"output":65536}}]}"#); return l.context == 512_000 && l.output == 65_536 }())
CHECK("top_provider (OpenRouter shape)", { let l = L(#"{"data":[{"id":"a","top_provider":{"context_length":131072,"max_completion_tokens":16384}}]}"#); return l.context == 131_072 && l.output == 16_384 }())
CHECK("max_completion_tokens", L(#"{"data":[{"id":"a","max_completion_tokens":4096}]}"#).output == 4_096)
CHECK("top-level wins over limit.*", L(#"{"data":[{"id":"a","context_length":192000,"limit":{"context":262144}}]}"#).context == 192_000)
CHECK("numeric string", L(#"{"data":[{"id":"a","context_length":"1000000"}]}"#).context == 1_000_000)
CHECK("float number", L(#"{"data":[{"id":"a","context_length":128000.0}]}"#).context == 128_000)
CHECK("zero / negative / null / bool / junk -> absent", {
    let a = L(#"{"data":[{"id":"a","context_length":0,"max_output_tokens":-1}]}"#)
    let b = L(#"{"data":[{"id":"a","context_length":null,"max_output_tokens":true}]}"#)
    let c = L(#"{"data":[{"id":"a","context_length":"lots","max_output_tokens":{}}]}"#)
    return a.context == nil && a.output == nil && b.context == nil && b.output == nil && c.context == nil && c.output == nil
}())
CHECK("a zero top-level falls through to limit.context", L(#"{"data":[{"id":"a","context_length":0,"limit":{"context":64000}}]}"#).context == 64_000)
CHECK("nothing reported -> both nil", { let l = L(#"{"data":[{"id":"a","owned_by":"x"}]}"#); return l.context == nil && l.output == nil }())
CHECK("only output reported -> context nil", { let l = L(#"{"data":[{"id":"a","max_output_tokens":8192}]}"#); return l.context == nil && l.output == 8_192 }())
CHECK("huge float does not trap", L(#"{"data":[{"id":"a","context_length":1e300}]}"#).context == nil)
exit(fails == 0 ? 0 : 1)
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reported-limits-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h")
try! harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, cout) = run("/usr/bin/xcrun", ["swiftc", "-O", "-o", bin.path, src.path])
if cc != 0 { print(cout); check("harness compiles", false); exit(1) }
let (rc, out) = run(bin.path, [])
for line in out.split(separator: "\n") {
    if line.hasPrefix("  PASS ") { check(String(line.dropFirst(7)), true) }
    else if line.hasPrefix("  FAIL ") { check(String(line.dropFirst(7)), false) }
    else { print(line) }
}
if rc != 0 && failures == 0 { check("harness exit 0", false) }

print("[2] wiring")
let fetch = between(api, "private static func performFetch", "static func normalizeModality") ?? ""
check("performFetch reads ModelListParsing.reportedLimits", fetch.contains("ModelListParsing.reportedLimits(of: item)"))
check("performFetch stamps limitsReportedByEndpoint before enrichModels",
      { guard let s = fetch.range(of: "limitsReportedByEndpoint = true"),
              let e = fetch.range(of: "ModelsDevAPI.enrichModels(models)") else { return false }
        return s.lowerBound < e.lowerBound }())
check("performFetch only flags when something was reported", fetch.contains("if limits.context != nil || limits.output != nil"))
let apply = between(dev, "private static func applyDevData", "// Reasoning capability") ?? ""
check("applyDevData keeps a reported contextWindow", apply.contains("!(keepReported && result.contextWindow != nil)"))
check("applyDevData keeps a reported maxOutputTokens", apply.contains("!(keepReported && result.maxOutputTokens != nil)"))
check("keepReported keyed on the flag", apply.contains("model.limitsReportedByEndpoint == true"))
check("no unconditional overwrite left", !apply.contains("if let ctx = devModel.limit?.context {"))
check("LLMModel.limitsReportedByEndpoint is Optional (old saves decode)", types.contains("var limitsReportedByEndpoint: Bool?"))
check("ModelEntry.model rebuild carries the flag", entry.contains("rebuilt.limitsReportedByEndpoint = baseModel.limitsReportedByEndpoint"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
