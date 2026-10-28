#!/usr/bin/env swift
// [T-config-batch-item-trap] `minis-config set-batch` crashed the app when the
// agent's stdin array held an element that is not an object.
//
// Crashpoint DKEDqFIVLasBSujebmMWbR, 1.15 (8), iPhone14,3 / iOS 16.3: SIGTRAP in
// _ArrayBuffer._getElementSlowPath <- IndexingIterator.next <-
// ConfigOffloadBridge.performWriteBatch <- writeFields. cmd_set_batch only
// checked "is an array"; the NSArray reached Swift as `[NSDictionary]`, whose
// lazy bridge type-checks each element on access and traps on a string,
// number, null or nested array.
//
//   [1] repro: the old `[NSDictionary]` shape traps on such input, the new
//       `[Any]` shape does not (both run in child processes)
//   [2] ConfigBatchItemRules, compiled from the shipping file
//   [3] source guards: the entry takes [Any], checks before use, the ObjC
//       declaration matches
//
// Run: swift ConfigBatchItemTrapTests.swift   (needs swiftc)
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

let bridge = source("NativeOffloads/ConfigOffloadBridge.swift")
let objc = source("NativeOffloads/ConfigOffload.m")
guard let rules = between(bridge, "// BEGIN ConfigBatchItemRules", "// END ConfigBatchItemRules") else {
    print("❌ ConfigBatchItemRules not found"); exit(1)
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("config-batch-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
func build(_ name: String, _ files: [String: String]) -> (Int32, String, String) {
    let dir = tmp.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (n, c) in files { try? c.write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
    let bin = dir.appendingPathComponent("t").path
    let (cc, out) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"]
        + files.keys.sorted().map { dir.appendingPathComponent($0).path } + ["-o", bin])
    return (cc, out, bin)
}

// The JSON the agent pipes in, parsed the way cmd_set_batch parses it.
let badJSON = #"[{"path":"appearance.theme","value_json":"\"dark\""}, "appearance.theme"]"#

print("[1] Repro")
let oldShape = #"""
import Foundation
@objc final class Bridge: NSObject {
    @objc static func writeFields(items: [NSDictionary]) -> Int {
        var n = 0
        for raw in items { if raw["path"] != nil { n += 1 } }
        return n
    }
}
let data = CommandLine.arguments[1].data(using: .utf8)!
let parsed = try! JSONSerialization.jsonObject(with: data) as! NSArray
// Same hand-off as the ObjC caller: an NSArray passed to an @objc [NSDictionary] parameter.
let sel = NSSelectorFromString("writeFieldsWithItems:")
typealias Fn = @convention(c) (AnyObject, Selector, NSArray) -> Int
let imp = (Bridge.self as AnyObject).method(for: sel)!
print("count", unsafeBitCast(imp, to: Fn.self)(Bridge.self, sel, parsed))
"""#
let (occ, oout, obin) = build("old", ["main.swift": oldShape])
check("old-shape harness compiles", occ == 0)
if occ != 0 { print(oout) }
let (ostatus, _) = run(obin, [badJSON])
check("old shape: a non-object element kills the process (status \(ostatus))", ostatus != 0)

let newHarness = #"""
import Foundation
func parse(_ s: String) -> [Any] { try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [Any] }
func show(_ tag: String, _ s: String) {
    print("R \(tag)=" + (ConfigBatchItemRules.firstProblem(parse(s)) ?? "ok"))
}
show("bad", CommandLine.arguments[1])
show("good", #"[{"path":"appearance.theme","value_json":"\"dark\""},{"path":"a.b","value_json":"1"}]"#)
show("noValue", #"[{"path":"a.b"}]"#)
show("number", #"[{"path":"a.b","value_json":"1"}, 3]"#)
show("null", #"[null]"#)
show("nested", #"[["a.b","1"]]"#)
show("noPath", #"[{"value_json":"1"}]"#)
show("blankPath", #"[{"path":"  ","value_json":"1"}]"#)
show("pathNotString", #"[{"path":7,"value_json":"1"}]"#)
show("valueNotString", #"[{"path":"a.b","value_json":true}]"#)
show("valueObject", #"[{"path":"a.b","value_json":{"x":1}}]"#)
show("empty", "[]")
"""#
let (ncc, nout, nbin) = build("new", ["Rules.swift": "import Foundation\n" + rules, "main.swift": newHarness])
print("[2] ConfigBatchItemRules from the shipping file")
check("the rules block compiles on its own", ncc == 0)
if ncc != 0 { print(nout); print("\n❌ FAILED"); exit(1) }
let (nstatus, out) = run(nbin, [badJSON])
check("new shape: the same input returns normally (status \(nstatus))", nstatus == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let body = line.dropFirst(2)
    if let eq = body.firstIndex(of: "=") { r[String(body[..<eq])] = String(body[body.index(after: eq)...]) }
}
check("the crash input is rejected at element 2 as a string", r["bad"] == "Batch element 2 is a string, not an object.")
check("well-formed batch passes", r["good"] == "ok")
check("missing value_json is still allowed (defaults to null downstream)", r["noValue"] == "ok")
check("number element rejected", r["number"] == "Batch element 2 is a number or boolean, not an object.")
check("null element rejected", r["null"] == "Batch element 1 is null, not an object.")
check("nested array rejected", r["nested"] == "Batch element 1 is an array, not an object.")
check("missing / blank / non-string path rejected",
      r["noPath"] == "Batch element 1 has no \"path\" string." && r["blankPath"] == r["noPath"] && r["pathNotString"] == r["noPath"])
check("non-string value_json rejected with the path named",
      r["valueNotString"]?.hasPrefix("Batch element 1 (a.b): \"value_json\" must be a string holding JSON text") == true
      && r["valueObject"]?.hasSuffix("not an object.") == true)
check("empty batch has no element problem (the CLI rejects it earlier)", r["empty"] == "ok")

print("[3] Source guards")
check("writeFields takes [Any]", bridge.contains("@objc public static func writeFields(items: [Any],"))
let entry = between(bridge, "@objc public static func writeFields(items: [Any],", "let sem = DispatchSemaphore(value: 0)") ?? ""
check("elements are checked before any is used as a dictionary",
      entry.contains("if let problem = ConfigBatchItemRules.firstProblem(items) {\n            return Self.invalidBatchEnvelope(problem)\n        }")
      && entry.contains("let items = items.compactMap { $0 as? NSDictionary }"))
check("the error is invalid_args, which the CLI maps to exit 1",
      bridge.contains("\"error\": \"invalid_args\",") && objc.contains("return NOFF_EXIT_INVALID_ARGS;"))
check("the ObjC fallback declaration takes a plain NSArray",
      objc.contains("+ (NSDictionary * _Nonnull)writeFieldsWithItems:(NSArray * _Nonnull)items"))
check("set-batch still hands the parsed array straight to the bridge",
      objc.contains("[ConfigOffloadBridge writeFieldsWithItems:items"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
