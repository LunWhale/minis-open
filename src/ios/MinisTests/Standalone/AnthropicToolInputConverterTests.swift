#!/usr/bin/env swift
// [T-anthropic-tool-input-lossless] A stored tool call's arguments are
// replayed to Anthropic as the `input` of a `tool_use` block. The old
// converter kept only strings and numbers: user_ask's `{"questions":[…]}`
// went out as `{}`, and the model, seeing its own call with empty arguments
// answered `approved`, began sending empty user_ask calls itself.
//
//   [1] the shipping AnthropicToolInputConverter (BEGIN/END block in
//       AnthropicAgentProvider.swift), compiled against SwiftAnthropic's own
//       MessageResponse.swift so the JSON comes from the real encoder:
//       convert → encode → compare with the original input, semantically
//   [2] source guards: the request path calls the converter
//
// Run: swift AnthropicToolInputConverterTests.swift   (needs swiftc and a
// resolved SwiftAnthropic checkout under build/DerivedData or Xcode's
// DerivedData)
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

let provider = source("Providers/Anthropic/AnthropicAgentProvider.swift")
guard let block = between(provider, "// BEGIN AnthropicToolInputConverter", "// END AnthropicToolInputConverter") else {
    print("❌ AnthropicToolInputConverter block not found"); exit(1)
}

// SwiftAnthropic's MessageResponse.swift compiles on its own; use the real one.
func findMessageResponse() -> URL? {
    let fm = FileManager.default
    let rel = "SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic/Public/ResponseModels/Message/MessageResponse.swift"
    var roots = [iosRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DerivedData")]
    let xcodeDD = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    if let dirs = try? fm.contentsOfDirectory(at: xcodeDD, includingPropertiesForKeys: nil) {
        roots += dirs.filter { $0.lastPathComponent.hasPrefix("Minis-") }
    }
    return roots.map { $0.appendingPathComponent(rel) }.first { fm.fileExists(atPath: $0.path) }
}
guard let messageResponse = findMessageResponse() else {
    print("❌ SwiftAnthropic MessageResponse.swift not found — build the app once to resolve packages"); exit(1)
}

let harness = #"""
import Foundation

func encode(_ input: MessageResponse.Content.Input) -> Any? {
    guard let data = try? JSONEncoder().encode(input) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}
func parse(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}
func same(_ a: Any?, _ b: Any?) -> Bool {
    guard let a, let b else { return false }
    return (a as AnyObject).isEqual(b)
}
func R(_ k: String, _ v: Bool) { print("R \(k)=\(v ? 1 : 0)") }

// A user_ask call as the model sends it: CJK, newlines, quotes, nesting.
let userAsk = #"{"questions":[{"type":"options","header":"打包内容","question":"工作区有别人未提交的 \"UserAsk\" 改动，\n要现在打包吗？","options":[{"label":"现在就打","description":"带上 \\ 反斜杠"},{"label":"等一下"}],"multi_select":false},{"type":"confirm","question":"git push origin v1.15","impact":"可回滚","risk":"high"}]}"#
let ua = parse(userAsk)
let uaOut = encode(AnthropicToolInputConverter.input(ua))
R("ua_parsed", !ua.isEmpty)
R("ua_not_empty", (uaOut as? [String: Any])?.isEmpty == false)
R("ua_roundtrip", same(uaOut, ua))
R("ua_questions_count", ((uaOut as? [String: Any])?["questions"] as? [Any])?.count == 2)

// Every JSON value kind.
let mixed = #"{"s":"中文\n\"q\"","i":42,"neg":-7,"d":1.5,"tiny":0.001,"big":12345678901234,"t":true,"f":false,"n":null,"one":1,"zero":0,"arr":[1,"a",null,[true,2.25],{"k":"v"}],"obj":{"deep":{"deeper":[{"x":null}]}},"empty_arr":[],"empty_obj":{}}"#
let mx = parse(mixed)
let mxOut = encode(AnthropicToolInputConverter.input(mx)) as? [String: Any] ?? [:]
R("mx_roundtrip", same(mxOut, mx))
R("mx_key_count", mxOut.count == mx.count)
func boxed(_ v: Any?) -> NSNumber? { v as? NSNumber }
let isBool = { (v: Any?) -> Bool in boxed(v).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
R("bool_true_stays_bool", isBool(mxOut["t"]) && (mxOut["t"] as? Bool) == true)
R("bool_false_stays_bool", isBool(mxOut["f"]) && (mxOut["f"] as? Bool) == false)
R("int_1_not_bool", !isBool(mxOut["one"]) && boxed(mxOut["one"])?.intValue == 1)
R("int_0_not_bool", !isBool(mxOut["zero"]) && boxed(mxOut["zero"])?.intValue == 0)
R("double_keeps_fraction", boxed(mxOut["d"])?.doubleValue == 1.5 && boxed(mxOut["tiny"])?.doubleValue == 0.001)
R("big_int_exact", boxed(mxOut["big"])?.int64Value == 12345678901234)
R("null_kept", mxOut["n"] is NSNull)
R("nested_array_kept", same(mxOut["arr"], mx["arr"]))
R("nested_object_kept", same(mxOut["obj"], mx["obj"]))
R("empty_containers_kept", (mxOut["empty_arr"] as? [Any])?.isEmpty == true && (mxOut["empty_obj"] as? [String: Any])?.isEmpty == true)

// Swift-native values (args built in code rather than parsed).
let native: [String: Any] = ["b": true, "i": 3, "d": 2.5, "s": "x", "a": [1, 2], "o": ["k": false]]
let nOut = encode(AnthropicToolInputConverter.input(native)) as? [String: Any] ?? [:]
R("native_bool", isBool(nOut["b"]) && (nOut["b"] as? Bool) == true)
R("native_int", !isBool(nOut["i"]) && boxed(nOut["i"])?.intValue == 3)
R("native_double", boxed(nOut["d"])?.doubleValue == 2.5)
R("native_nested", same(nOut["a"], [1, 2]) && same(nOut["o"], ["k": false]))

// Unknown types fall back to text instead of disappearing.
let odd: [String: Any] = ["date": Date(timeIntervalSince1970: 0), "u64": UInt64.max]
let oOut = encode(AnthropicToolInputConverter.input(odd)) as? [String: Any] ?? [:]
R("unknown_type_kept_as_string", (oOut["date"] as? String)?.isEmpty == false)
R("uint64_max_not_negative", (boxed(oOut["u64"])?.doubleValue ?? -1) > 0)
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("anthropic-input-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Converter.swift", "import Foundation\n" + block), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings", messageResponse.path]
                      + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping converter compiles against SwiftAnthropic's MessageResponse", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}
func ok(_ k: String) -> Bool { r[k] == "1" }

print("\n1. user_ask replay")
check("fixture parses", ok("ua_parsed"))
check("{\"questions\":[…]} is no longer replayed as {}", ok("ua_not_empty"))
check("both questions survive", ok("ua_questions_count"))
check("encoded input == original (CJK, newline, quotes, backslash, nesting)", ok("ua_roundtrip"))

print("\n2. Every JSON value kind")
check("encoded input == original", ok("mx_roundtrip"))
check("no key dropped", ok("mx_key_count"))
check("true stays a boolean", ok("bool_true_stays_bool"))
check("false stays a boolean", ok("bool_false_stays_bool"))
check("1 stays an integer, not true", ok("int_1_not_bool"))
check("0 stays an integer, not false", ok("int_0_not_bool"))
check("1.5 / 0.001 keep their fraction (no Int truncation)", ok("double_keeps_fraction"))
check("a 14-digit integer stays exact", ok("big_int_exact"))
check("null is kept", ok("null_kept"))
check("nested array kept", ok("nested_array_kept"))
check("nested object kept", ok("nested_object_kept"))
check("empty [] and {} kept", ok("empty_containers_kept"))

print("\n3. Swift-native values and fallbacks")
check("Bool", ok("native_bool"))
check("Int", ok("native_int"))
check("Double", ok("native_double"))
check("nested Swift array / dictionary", ok("native_nested"))
check("a non-JSON value is sent as text, not dropped", ok("unknown_type_kept_as_string"))
check("UInt64.max does not wrap negative", ok("uint64_max_not_negative"))

print("\n4. Source guards")
let convertBody = between(provider, "private func convertToInput(_ dict: [String: Any]) -> MessageResponse.Content.Input {", "\n    }") ?? ""
check("convertToInput delegates to the converter", convertBody.contains("AnthropicToolInputConverter.input(dict)"))
check("the request path still replays tool_use through convertToInput",
      provider.contains("return .toolUse(sanitizeToolId(id), name, convertToInput(input))"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
