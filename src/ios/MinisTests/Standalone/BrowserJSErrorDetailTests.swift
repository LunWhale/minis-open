#!/usr/bin/env swift
// [T-js-error-detail] TestFlight user report: browser_use often fails with
// "Error: JavaScript error: 发生了JavaScript异常  tab_id: 0" and no reason.
// Two causes, both fixed:
//   - getText / getReadable / getBackbone / scroll / scroll_and_collect (and
//     the debug RPC) reported `error.localizedDescription`, which for
//     WKError.javaScriptExceptionOccurred is only the generic sentence; the
//     reason sits in userInfo["WKJavaScriptExceptionMessage"].
//   - the read scripts used `document.body.*` unguarded, so a document with
//     no body (mid-navigation, or SVG / XML / an image) threw a TypeError.
//
//   [1] BrowserJSErrorFormatter (BEGIN/END block), compiled as shipped, on
//       hand-built WKErrorDomain NSErrors.
//   [2] REPRODUCTION in JavaScriptCore with a fake `document` (no body):
//       the shipped unguarded get_text throws exactly WebKit's TypeError;
//       the guarded one returns a clear JSON error. With a body, guarded and
//       unguarded results are byte-identical. A throw inside is caught as
//       "Script threw: …". get_page_info works without a body.
//   [3] Source guards: every call site uses the formatter; read scripts are
//       wrapped; scroll_and_collect body guarded.
//
// Run: swift BrowserJSErrorDetailTests.swift
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
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let jsFile = source("Agent/BrowserUse/BrowserUseJavaScript.swift")
let manager = source("Agent/BrowserUse/BrowserUseManager.swift")
let debug = source("Debug/DebugJSONRPC.swift")
check("sources readable", !jsFile.isEmpty && !manager.isEmpty && !debug.isEmpty)

// The whole shipped file compiles with one stub type.
let driver = #"""
import Foundation
import JavaScriptCore
enum BrowserActionInput { enum ScrollDirection: String { case up, down } }

func emit(_ k: String, _ v: String) { print("@@\(k)=" + v.replacingOccurrences(of: "\n", with: "⏎")) }

// [1] formatter
func wkError(_ info: [String: Any]) -> NSError {
    NSError(domain: "WKErrorDomain", code: 4, userInfo: [NSLocalizedDescriptionKey: "发生了JavaScript异常"].merging(info) { $1 })
}
emit("f.full", BrowserJSErrorFormatter.message(wkError([
    "WKJavaScriptExceptionMessage": "TypeError: null is not an object (evaluating 'document.body.innerText')",
    "WKJavaScriptExceptionLineNumber": NSNumber(value: 3), "WKJavaScriptExceptionColumnNumber": NSNumber(value: 37),
    "WKJavaScriptExceptionSourceURL": URL(string: "https://example.com/app.js")!])))
emit("f.msgOnly", BrowserJSErrorFormatter.message(wkError(["WKJavaScriptExceptionMessage": "ReferenceError: Can't find variable: foo"])))
emit("f.lineNoCol", BrowserJSErrorFormatter.describe(wkError(["WKJavaScriptExceptionMessage": "E", "WKJavaScriptExceptionLineNumber": NSNumber(value: 9)])))
emit("f.blankSource", BrowserJSErrorFormatter.describe(wkError(["WKJavaScriptExceptionMessage": "E", "WKJavaScriptExceptionSourceURL": "about:blank"])))
emit("f.longSource", BrowserJSErrorFormatter.describe(wkError(["WKJavaScriptExceptionMessage": "E", "WKJavaScriptExceptionSourceURL": "https://x.dev/" + String(repeating: "a", count: 200)])))
emit("f.fallback", BrowserJSErrorFormatter.message(wkError([:])))
emit("f.emptyMsg", BrowserJSErrorFormatter.message(wkError(["WKJavaScriptExceptionMessage": "  "])))
emit("f.unsupported", BrowserJSErrorFormatter.message(NSError(domain: "WKErrorDomain", code: 5,
    userInfo: [NSLocalizedDescriptionKey: "执行JavaScript返回结果的类型不受支持"])))

// [2] JavaScriptCore with a fake document
let fakeDOM = """
var console = {log: function(){}};
var window = {innerHeight: 800, innerWidth: 400, scrollY: 0, scrollBy: function(){},
  getComputedStyle: function(){ return {display: 'block', visibility: 'visible', opacity: '1'}; }};
var location = {href: 'https://example.com/logo.svg'};
window.location = location;
var bodyEl = {tagName: 'BODY', id: '', className: '', innerText: 'Hello world', textContent: 'Hello world',
  scrollHeight: 120, firstElementChild: {}, querySelectorAll: function(){ return []; }};
var document = {readyState: 'complete', title: 'T', contentType: 'image/svg+xml', body: null,
  documentElement: {scrollHeight: 44}, forms: [], links: [], images: [],
  querySelector: function(){ return null; }, querySelectorAll: function(){ return []; }};
"""
func eval(_ script: String, setup: String = "") -> String {
    let ctx = JSContext()!
    var thrown: String?
    ctx.exceptionHandler = { _, exc in thrown = exc?.toString() }
    ctx.evaluateScript(fakeDOM + setup)
    let v = ctx.evaluateScript(script)
    if let thrown { return "THROWS " + thrown }
    return v?.toString() ?? "nil"
}
// before: the unguarded script on a body-less document
emit("r.before", eval(BrowserUseJS.unguardedGetText(selector: nil)))
// after: clear JSON errors
emit("r.afterSvg", eval(BrowserUseJS.getText(selector: nil)))
emit("r.afterLoading", eval(BrowserUseJS.getText(selector: nil), setup: "document.readyState = 'loading';"))
emit("r.afterLoadingEmptyBody", eval(BrowserUseJS.getText(selector: nil),
    setup: "document.readyState = 'loading'; document.body = {firstElementChild: null, textContent: ''};"))
emit("r.readable", eval(BrowserUseJS.getReadable()))
emit("r.backbone", eval(BrowserUseJS.getBackbone(maxDepth: 5)))
emit("r.selector", eval(BrowserUseJS.getText(selector: "#x")))
// success pass-through: identical output with a body
let withBody = "document.body = bodyEl; document.contentType = 'text/html';"
emit("r.sameText", String(eval(BrowserUseJS.getText(selector: nil), setup: withBody) == eval(BrowserUseJS.unguardedGetText(selector: nil), setup: withBody)))
emit("r.textOK", eval(BrowserUseJS.getText(selector: nil), setup: withBody))
emit("r.sameReadable", String(eval(BrowserUseJS.getReadable(), setup: withBody) == eval(BrowserUseJS.unguardedGetReadable(), setup: withBody)))
// a throw inside the script is caught with its name and message
emit("r.caught", eval(BrowserUseJS.getText(selector: nil),
    setup: withBody + " bodyEl.querySelectorAll = function(){ throw new RangeError('boom'); };"))
// get_page_info works without a body
emit("r.pageInfo", eval(BrowserUseJS.getPageInfo()))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jserr_\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let shipped = tmp.appendingPathComponent("BrowserUseJavaScript.swift")
let main = tmp.appendingPathComponent("main.swift"), exe = tmp.appendingPathComponent("t")
try! jsFile.write(to: shipped, atomically: true, encoding: .utf8)
try! driver.write(to: main, atomically: true, encoding: .utf8)
let (cc, cout) = run("/usr/bin/xcrun", ["swiftc", main.path, shipped.path, "-o", exe.path])
check("shipped BrowserUseJavaScript.swift + driver compile", cc == 0)
if cc != 0 { print(cout); exit(1) }
var got: [String: String] = [:]
for line in run(exe.path, []).1.split(separator: "\n") where line.hasPrefix("@@") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    if kv.count == 2 { got[kv[0]] = kv[1] }
}

print("[1] BrowserJSErrorFormatter")
check("message + line:column + source, with the JavaScript error: prefix",
      got["f.full"] == "JavaScript error: TypeError: null is not an object (evaluating 'document.body.innerText') (line 3:37, https://example.com/app.js)")
check("message only", got["f.msgOnly"] == "JavaScript error: ReferenceError: Can't find variable: foo")
check("line without column", got["f.lineNoCol"] == "E (line 9)")
check("about:blank source omitted", got["f.blankSource"] == "E")
check("long source truncated to 120", (got["f.longSource"]?.contains("...)") == true) && (got["f.longSource"]?.count ?? 999) < 140)
check("no exception message → localized description (the old text)", got["f.fallback"] == "JavaScript error: 发生了JavaScript异常")
check("blank exception message → localized description", got["f.emptyMsg"] == "JavaScript error: 发生了JavaScript异常")
check("'result type unsupported' keeps its own clear wording", got["f.unsupported"] == "JavaScript error: 执行JavaScript返回结果的类型不受支持")

print("[2] Reproduction (JavaScriptCore, fake document without a body)")
check("BEFORE: unguarded get_text throws WebKit's TypeError (what became the generic sentence)",
      got["r.before"] == "THROWS TypeError: null is not an object (evaluating 'document.body.innerText')")
check("AFTER: a non-HTML document gets a clear 'no <body>' error",
      got["r.afterSvg"]?.hasPrefix("{\"error\":\"This document has no <body> (readyState=complete, contentType=image/svg+xml, url=https://example.com/logo.svg)") == true)
check("AFTER: still loading → 'no body yet … wait_for_dom_stable or get_page_info'",
      got["r.afterLoading"]?.contains("The page has no body yet (readyState=loading, url=https://example.com/logo.svg). Wait for it to finish loading - e.g. call wait_for_dom_stable or get_page_info first - then retry.") == true)
check("AFTER: loading with an empty body is treated the same", got["r.afterLoadingEmptyBody"]?.contains("The page has no body yet") == true)
check("get_readable guarded", got["r.readable"]?.hasPrefix("{\"error\":\"This document has no <body>") == true)
check("get_backbone guarded", got["r.backbone"]?.hasPrefix("{\"error\":\"This document has no <body>") == true)
check("get_text with a selector guarded", got["r.selector"]?.hasPrefix("{\"error\":\"This document has no <body>") == true)
check("with a body: guarded get_text output is byte-identical to unguarded", got["r.sameText"] == "true")
check("with a body: the success JSON is the normal shape", got["r.textOK"]?.hasPrefix("{\"text\":\"Hello world\",\"length\":11,\"debug\":") == true)
check("with a body: guarded get_readable output is byte-identical", got["r.sameReadable"] == "true")
check("a throw inside is caught: Script threw: <name>: <message>", got["r.caught"] == "{\"error\":\"Script threw: RangeError: boom\"}")
check("get_page_info works without a body (documentElement height)",
      got["r.pageInfo"]?.contains("\"scrollHeight\":44") == true && got["r.pageInfo"]?.contains("error") == false)
try? FileManager.default.removeItem(at: tmp)

print("[3] Call sites")
check("no 'JavaScript error: \\(error.localizedDescription)' left in the manager",
      !manager.contains("\"JavaScript error: \\(error.localizedDescription)\""))
check("no hand-rolled WKJavaScriptExceptionMessage extraction left in the manager",
      !manager.contains("userInfo[\"WKJavaScriptExceptionMessage\"]"))
check("manager uses the formatter at all 7 JS catch sites",
      manager.components(separatedBy: "return .error(BrowserJSErrorFormatter.message(error))").count - 1 == 7)
check("debug RPC uses it at both sites",
      debug.components(separatedBy: "message: BrowserJSErrorFormatter.message(error))").count - 1 == 2
      && !debug.contains("\"JavaScript error: \\(error.localizedDescription)\""))
check("scroll_and_collect body is guarded", jsFile.contains("return guardedAsyncBody(\"\"\"\n        var SCROLL_COUNT"))
check("timeouts unchanged", manager.contains("JavaScript timed out after \\(Int(Self.executeJSTimeout))s"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
