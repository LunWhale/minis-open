#!/usr/bin/env swift
// [T-batch-read-after-write] [T-readimage-fail-visible] read_image failed on
// device (2026-10-06 13:32:04, q-1.png, 0.0s) and the detail sheet showed only
// "Reading image /var/minis/workspace/tool_guide/q-1.png..." in bare text.
//   - Cause: the model sent `shell_execute` (renders q-1.png) and
//     `read_image q-1.png` in ONE batch; every call of a batch started at
//     once, so the read ran 15 ms in, before the file existed.
//   - The failure path never wrote its error into the block, so the sheet kept
//     the progress line; and read_image without an image fell through to the
//     generic text view, which has no card.
//
//   [1] BatchToolOrder (BEGIN/END block), compiled as shipped.
//   [2] readImageFailureText (BEGIN/END block), compiled as shipped.
//   [3] Source guards: the dispatcher waits for earlier writers before a
//       reader, the failure writes the block content, the sheet renders the
//       framed card in the live / snapshot / fallback paths.
//
// Run: swift ReadImageFailureViewTests.swift
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
func ordered(_ s: String, _ parts: [String]) -> Bool {
    var from = s.startIndex
    for p in parts {
        guard let r = s.range(of: p, range: from..<s.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let ct = source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let sheet = source("Views/Chat/ToolLiveSheet.swift")
guard let order = between(ct, "// BEGIN BatchToolOrder", "// END BatchToolOrder"),
      let failText = between(ct, "// BEGIN ReadImageFailureText", "// END ReadImageFailureText") else {
    print("❌ blocks not found"); exit(1)
}

print("[1][2] Pure rules, compiled as shipped")
let driver = """
import Foundation
final class AIChatViewModel {}
\(order)
\(failText)
func w(_ i: Int, _ n: [String]) -> String { BatchToolOrder.writersBefore(index: i, in: n).map(String.init).joined(separator: ",") }
print("@@shellThenRead=" + w(1, ["shell_execute", "read_image"]))
print("@@readFirst=" + w(0, ["read_image", "shell_execute"]))
print("@@twoWriters=" + w(3, ["file_write", "browser_use", "file_edit", "file_read"]))
print("@@writerIsNotReader=" + w(1, ["shell_execute", "shell_execute"]))
print("@@readersOnly=" + w(1, ["read_image", "read_image"]))
print("@@browserNotWriter=" + w(1, ["browser_use", "read_image"]))
print("@@outOfRange=" + w(5, ["read_image"]))
print("@@missing=" + AIChatViewModel.readImageFailureText(pathArg: "/var/minis/workspace/q.png", resolved: true, fileSize: nil))
print("@@empty=" + AIChatViewModel.readImageFailureText(pathArg: "/var/minis/workspace/q.png", resolved: true, fileSize: 0))
print("@@undecodable=" + AIChatViewModel.readImageFailureText(pathArg: "/var/minis/workspace/q.png", resolved: true, fileSize: 1234))
print("@@unresolved=" + AIChatViewModel.readImageFailureText(pathArg: "q.png", resolved: false, fileSize: nil))
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("readimg_\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let src = tmp.appendingPathComponent("main.swift"), exe = tmp.appendingPathComponent("t")
try! driver.write(to: src, atomically: true, encoding: .utf8)
let (cc, cout) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", exe.path])
check("blocks compile standalone", cc == 0)
if cc != 0 { print(cout); exit(1) }
var got: [String: String] = [:]
for line in run(exe.path, []).1.split(separator: "\n") where line.hasPrefix("@@") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    if kv.count == 2 { got[kv[0]] = kv[1] }
}
check("read after a shell in the same batch waits for it", got["shellThenRead"] == "0")
check("a read before the writer does not wait", got["readFirst"] == "")
check("waits for every earlier writer, not for browser_use", got["twoWriters"] == "0,2")
check("writers never wait for writers", got["writerIsNotReader"] == "")
check("readers never wait for readers", got["readersOnly"] == "")
check("browser_use is not a writer", got["browserNotWriter"] == "")
check("out-of-range index is safe", got["outOfRange"] == "")
check("missing file: says so, and how to fix it",
      got["missing"] == "Error: No file at '/var/minis/workspace/q.png'. If a command in this same turn creates it, read it in the next turn after that command has finished.")
check("empty file: says it may still be written", got["empty"]?.contains("exists but is empty (0 bytes)") == true)
check("undecodable file: says it exists, its size, the formats", got["undecodable"]?.contains("exists (1234 bytes) but is not a decodable image") == true)
check("unresolvable path: points at /var/minis/", got["unresolved"]?.contains("not a readable Minis path") == true)
try? FileManager.default.removeItem(at: tmp)

print("[3] Wiring")
let dispatch = between(loop, "Rate-limit: hold here until we're below the in-flight cap.", "group.addTask { [weak self] in") ?? ""
check("dispatcher consults BatchToolOrder before each dispatch",
      dispatch.contains("let earlierWriters = BatchToolOrder.writersBefore(index: idx, in: toolEntries.map(\\.name))"))
check("…and drains the group until those writers have finished",
      dispatch.contains("while earlierWriters.contains(where: { outcomesByIndex[$0] == nil }),")
      && dispatch.contains("let pair = await group.next()") && dispatch.contains("harvested += 1"))
check("the wait is logged", dispatch.contains("[BatchOrder]"))
check("results still stitched in tool_use order (unchanged)", loop.contains("outcomesByIndex[pair.0] = pair.1"))
let failBranch = between(ct, "[read_image] FAILED pathArg=", "case \"memory_write\":") ?? ""
check("failure text comes from readImageFailureText", failBranch.contains("toolOutput = Self.readImageFailureText(pathArg: pathArg,"))
check("failure writes the reason into the block the sheet renders",
      ordered(failBranch, ["toolSuccess = false", "messages[msgIdx].blocks[blockIdx].content = toolOutput"]))
check("old vague message is gone", !ct.contains("Verify the path exists and is a valid image file."))
let card = between(sheet, "private func readImageResultContent(_ text: String) -> some View {", "private func fileEditorContent(") ?? ""
check("read-image card exists", !card.isEmpty)
check("card matches the file editor card: title bar, divider, monospaced body, rounded border",
      card.contains("Divider()") && card.contains(".font(.system(size: 13, design: .monospaced))")
      && card.contains(".clipShape(RoundedRectangle(cornerRadius: 10))")
      && card.contains(".overlay(RoundedRectangle(cornerRadius: 10).stroke(") && card.contains("lineWidth: 0.5))"))
check("failure is marked in the card", card.contains("if case .failed = block.toolStatus") && card.contains("Text(\"Failed\")"))
check("card used in the live path", sheet.contains("case .readImageTool:\n                // [T-readimage-fail-visible] Same card as the completed view,"))
check("card used in the snapshot (text) path",
      sheet.contains("} else if case .readImageTool = block.kind {\n                readImageResultContent("))
check("card used in the fallback path (no generic textContent for read_image)",
      (between(sheet, "            // Fallback to block content", "case .fileEditTool:\n                fileDiffContent()") ?? "")
        .contains("readImageResultContent(block.content)"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
