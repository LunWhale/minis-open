#!/usr/bin/env swift
// [T-ios-responses-empty-args] A tester on a Responses API provider kept
// getting tool calls blocked by the preflight with empty `{}` arguments and
// `chunkCount=0`. The stream took a call's arguments only from
// `function_call_arguments.delta` events matched by `item_id`, so an upstream
// that sends no deltas (full arguments only on `output_item.done`), or whose
// deltas name another `item_id`, produced `{}`. Reproduced on device with a
// mock Responses server before the fix.
//
//   [1] the shipping ResponsesFunctionCallAssembler (BEGIN/END block),
//       compiled standalone and driven through wire event sequences
//   [2] source guards on the provider wiring
//
// Run: swift ResponsesFunctionCallArgsTests.swift   (needs swiftc)
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

let provider = source("Providers/OpenAI/OpenAIAgentProvider.swift")
guard let block = between(provider, "// BEGIN ResponsesFunctionCallAssembler", "// END ResponsesFunctionCallAssembler") else {
    print("❌ ResponsesFunctionCallAssembler block not found"); exit(1)
}

// The harness mirrors the provider's dispatch: each wire event goes to the
// same assembler method the stream loop calls, and every completed call is
// printed as one `CALL` line (so duplicates are countable).
let harness = #"""
import Foundation
\#(block)

enum Ev {
    case added(String, Int)                 // item id, output_index
    case delta(String?, Int?, String)       // item_id, output_index, delta
    case argsDone(String?, Int?, String)
    case itemDone(String, String?)          // item id, item.arguments
    case unannouncedDone(String, String)    // item id with call_id/name, arguments
    case completed([String: String])        // response.output arguments by id
}

func play(_ label: String, _ events: [Ev]) {
    var a = ResponsesFunctionCallAssembler()
    var calls: [String] = []
    var progress: [String] = []
    var notes: [String] = []
    func record(_ c: ResponsesFunctionCallAssembler.Completed) {
        calls.append("\(c.itemId)=\(c.json)@\(c.source)\(c.announced ? "" : "!unannounced")")
    }
    for e in events {
        switch e {
        case .added(let id, let idx): a.added(itemId: id, callId: "call_" + id, name: "shell_execute", outputIndex: idx)
        case .delta(let id, let idx, let d):
            if let p = a.delta(itemId: id, outputIndex: idx, delta: d) { progress.append(p.accumulated) }
        case .argsDone(let id, let idx, let s): a.argumentsDone(itemId: id, outputIndex: idx, arguments: s)
        case .itemDone(let id, let s):
            if let c = a.itemDone(itemId: id, callId: "call_" + id, name: "shell_execute", arguments: s) { record(c) }
        case .unannouncedDone(let id, let s):
            if let c = a.itemDone(itemId: id, callId: "call_" + id, name: "shell_execute", arguments: s) { record(c) }
        case .completed(let out):
            for c in a.flush(outputArguments: out) { record(c) }
        }
        notes += a.takeNotes()
    }
    print("\(label) CALLS=\(calls.count) " + calls.map { "[\($0)]" }.joined())
    print("\(label) PROGRESS=" + progress.map { "<\($0)>" }.joined())
    print("\(label) NOTES=\(notes.count) " + notes.joined(separator: " || "))
}

let full = #"{"command":"echo hi"}"#
let h1 = #"{"command":"#, h2 = #""echo hi"}"#

// a) no deltas, full arguments only on output_item.done
play("A", [.added("fc1", 0), .itemDone("fc1", full), .completed(["fc1": full])])
// normal stream: deltas + matching item_id + the same full arguments
play("N", [.added("fc1", 0), .delta("fc1", 0, h1), .delta("fc1", 0, h2), .argsDone("fc1", 0, full),
           .itemDone("fc1", full), .completed(["fc1": full])])
// done item with arguments "" falls back to the deltas
play("E", [.added("fc1", 0), .delta("fc1", 0, h1), .delta("fc1", 0, h2), .itemDone("fc1", ""), .completed([:])])
// done item with no arguments field, but function_call_arguments.done has them
play("D", [.added("fc1", 0), .argsDone("fc1", 0, full), .itemDone("fc1", nil), .completed([:])])
// b) deltas name an unknown item_id (single open call) — rerouted, full args win
play("B", [.added("fc1", 0), .delta("fcX", 0, h1), .delta("fcX", 0, h2), .argsDone("fcX", 0, full),
           .itemDone("fc1", full), .completed(["fc1": full])])
// b') mismatched item_id, done item WITHOUT arguments: the rerouted deltas still produce the call
play("B2", [.added("fc1", 0), .delta("fcX", nil, h1), .delta("fcX", nil, h2), .itemDone("fc1", nil), .completed([:])])
// parallel, two calls, mismatched ids, routed by output_index
play("P", [.added("fc1", 0), .added("fc2", 1),
           .delta("zz1", 0, #"{"command":"echo 1"}"#), .delta("zz2", 1, #"{"command":"echo 2"}"#),
           .itemDone("fc1", nil), .itemDone("fc2", nil), .completed([:])])
// parallel, no deltas, full args on done
play("Q", [.added("fc1", 0), .added("fc2", 1), .itemDone("fc1", #"{"command":"echo 1"}"#),
           .itemDone("fc2", #"{"command":"echo 2"}"#), .completed([:])])
// unknown delta with two open calls and no output_index: dropped, logged
play("U", [.added("fc1", 0), .added("fc2", 1), .delta("zz", nil, h1),
           .itemDone("fc1", full), .itemDone("fc2", full), .completed([:])])
// duplicates: output_item.done twice, then response.completed lists it again
play("X", [.added("fc1", 0), .itemDone("fc1", full), .itemDone("fc1", full), .argsDone("fc1", 0, full),
           .completed(["fc1": full])])
// output_item.done never arrives: response.completed delivers it from output[]
play("F", [.added("fc1", 0), .completed(["fc1": full])])
// output_item.done for a call never announced by output_item.added
play("G", [.unannouncedDone("fc9", full), .completed(["fc9": full])])
"""#

print("[1] ResponsesFunctionCallAssembler")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("resp_fc_args_\(getpid()).swift")
try? harness.write(to: tmp, atomically: true, encoding: .utf8)
let (status, out) = run("/usr/bin/env", ["swift", tmp.path])
try? FileManager.default.removeItem(at: tmp)
check("harness compiled and ran", status == 0)
if status != 0 { print(out) }
var lines: [String: String] = [:]
for l in out.split(separator: "\n") {
    let parts = l.split(separator: " ", maxSplits: 1)
    if parts.count == 2 { lines[String(parts[0]) + String(parts[1].prefix { $0 != "=" })] = String(parts[1]) }
}
func line(_ label: String, _ kind: String) -> String { lines[label + kind] ?? "" }
let full = #"{"command":"echo hi"}"#

check("a) no deltas + full arguments → the real arguments, once",
      line("A", "CALLS") == "CALLS=1 [fc1=\(full)@item]")
check("normal deltas + full arguments → one call, same arguments",
      line("N", "CALLS") == "CALLS=1 [fc1=\(full)@item]")
check("normal stream still reports each delta for the input preview",
      line("N", "PROGRESS") == #"PROGRESS=<{"command":><{"command":"echo hi"}>"#)
check("normal stream logs nothing", line("N", "NOTES") == "NOTES=0 ")
check("empty full arguments → falls back to the deltas",
      line("E", "CALLS") == "CALLS=1 [fc1=\(full)@deltas]")
check("missing item arguments → function_call_arguments.done is used",
      line("D", "CALLS") == "CALLS=1 [fc1=\(full)@argumentsDone]")
check("b) mismatched delta item_id → the real arguments, once",
      line("B", "CALLS") == "CALLS=1 [fc1=\(full)@item]")
check("b) the mismatch is logged once, not per delta",
      line("B", "NOTES").hasPrefix("NOTES=1 ") && line("B", "NOTES").contains("item_id=fcX matches no call; routed to fc1"))
check("mismatched item_id without full arguments → rerouted deltas still give the call",
      line("B2", "CALLS") == "CALLS=1 [fc1=\(full)@deltas]")
check("parallel calls with mismatched ids are routed by output_index",
      line("P", "CALLS") == #"CALLS=2 [fc1={"command":"echo 1"}@deltas][fc2={"command":"echo 2"}@deltas]"#)
check("parallel calls without deltas each get their own arguments",
      line("Q", "CALLS") == #"CALLS=2 [fc1={"command":"echo 1"}@item][fc2={"command":"echo 2"}@item]"#)
check("an unroutable delta is logged instead of silently dropped",
      line("U", "NOTES").contains("arguments delta for unknown item_id=zz output_index=nil dropped"))
check("unroutable delta does not break the calls themselves",
      line("U", "CALLS") == "CALLS=2 [fc1=\(full)@item][fc2=\(full)@item]")
check("no duplicate toolCallComplete across repeated done / arguments.done / completed",
      line("X", "CALLS") == "CALLS=1 [fc1=\(full)@item]")
check("a call with no output_item.done is completed at response.completed",
      line("F", "CALLS") == "CALLS=1 [fc1=\(full)@item]")
check("an unannounced call is still delivered, flagged for its block start",
      line("G", "CALLS") == "CALLS=1 [fc9=\(full)@item!unannounced]")

print("[2] Provider wiring")
let stream = between(provider, "var functionCalls = ResponsesFunctionCallAssembler()", "// MARK: - Prompt Cache Key") ?? ""
check("old per-item delta-only accumulator is gone", !provider.contains("functionCallAccum"))
check("deltas go through the assembler and still yield toolInputDelta",
      stream.contains("case \"response.function_call_arguments.delta\":")
      && stream.contains("functionCalls.delta(")
      && stream.contains("continuation.yield(.toolInputDelta(name: progress.name, accumulated: progress.accumulated))"))
check("function_call_arguments.done is handled",
      stream.contains("case \"response.function_call_arguments.done\":") && stream.contains("functionCalls.argumentsDone("))
check("output_item.done passes the item's own arguments",
      stream.contains("arguments: item[\"arguments\"] as? String)"))
check("response.completed flushes calls before the stop reason",
      (stream.range(of: "functionCalls.flush(outputArguments:")?.lowerBound).map { f in
          stream.range(of: "let reason: AgentStopReason")
              .map { f < $0.lowerBound } ?? false } ?? false)
check("empty-args probe still fires when every source is empty",
      stream.contains("Self.diagEmptyToolArgs(rawJson: call.json"))
check("assembler notes are logged", stream.contains("logger.warning(\"[RespArgs] \\(note)\")"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
