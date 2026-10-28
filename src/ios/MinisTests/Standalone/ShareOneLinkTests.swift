#!/usr/bin/env swift
// [T-share-one-link] One web-page share puts one link in the composer, and
// the share extension ends its request exactly once.
//
// Report (iOS 27.0, Minis 1.14): sharing a page from Safari to Minis put two
// links into the composer -
//     https://buzzkit.dev/buzz.html
//     https://buzzkit.dev/buzz?t=6
// - and afterwards Minis was missing from Safari's share sheet until the page
// was reloaded.
//
// Safari hands the extension more than one item provider for one page (two
// loads were seen for a single share on iOS 26.6); the extension turned every
// provider into its own line. The rules now live in Shared/PendingShare.swift
// (compiled into the app and the extension).
//
//   [1] ShareItemRules, compiled from the shipping file: what one share keeps
//   [2] merging with an unconsumed earlier share; injecting into a composer
//   [3] how the request ends
//   [4] source guards: the extension and the app use the rules; the request
//       has one exit
//
// Run: swift ShareOneLinkTests.swift   (needs swiftc)
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

let shared = source("Shared/PendingShare.swift")
let viewModel = source("ShareExtension/ShareViewModel.swift")
let controller = source("ShareExtension/ShareViewController.swift")
let injection = source("Views/Chat/AIChatView/AIChatView+ShareInjection.swift")
let plist = source("ShareExtension/Info.plist")
guard shared.contains("// BEGIN ShareItemRules") else { print("❌ ShareItemRules not found"); exit(1) }

let harness = #"""
import Foundation
typealias C = ShareItemRules.Candidate
func url(_ v: String, _ g: Int = 0) -> C { C(source: .webURL, value: v, group: g) }
func text(_ v: String, _ g: Int = 0) -> C { C(source: .text, value: v, group: g) }
func file(_ v: String, _ g: Int = 0) -> C { C(source: .attachment, value: v, group: g) }
func show(_ tag: String, _ input: [C]) {
    let out = ShareItemRules.reduce(input)
    print("R \(tag)=" + out.map { "\($0.source):\($0.value)" }.joined(separator: " | "))
}
// The report: page URL + a plain-text provider holding another address of the same page.
show("report", [url("https://buzzkit.dev/buzz.html"), text("https://buzzkit.dev/buzz?t=6")])
show("reportReversed", [text("https://buzzkit.dev/buzz?t=6"), url("https://buzzkit.dev/buzz.html")])
show("sameURLTwice", [url("https://example.com/a"), text("https://example.com/a")])
show("textURLPadded", [url("https://example.com/a"), text("  https://example.com/a?utm=1 \n")])
show("wwwVariant", [url("https://www.example.com/a"), text("https://example.com/b")])
show("hostCase", [url("https://Example.COM/a"), text("https://example.com/b")])
// Kept: real text next to the URL.
show("title", [url("https://example.com/a"), text("An interesting article")])
show("selection", [url("https://example.com/a"), text("Quoted sentence from the page, see https://example.com/a for more")])
show("otherHost", [url("https://example.com/a"), text("https://other.org/x")])
show("twoLinksInText", [url("https://example.com/a"), text("https://example.com/b https://example.com/c")])
show("nonWebScheme", [url("https://example.com/a"), text("mailto:someone@example.com")])
// Kept: text-only shares, including a bare URL with no URL provider beside it.
show("textOnlyURL", [text("https://example.com/only")])
show("plainText", [text("just some words")])
// Different extension items are different things.
show("otherGroup", [url("https://example.com/a", 0), text("https://example.com/b", 1)])
// Attachments are never dropped by the link rule; identical values are.
show("attachments", [url("https://example.com/a"), file("shared-1_a.pdf"), file("shared-2_b.pdf")])
show("exactDuplicates", [text("hello"), text("hello"), file("f.png"), file("f.png")])
show("fileNamedLikeText", [text("f.png"), file("f.png")])
show("empty", [])

print("R sole.url=\(ShareItemRules.soleWebURL(in: " https://a.dev/x?y=1 ")?.absoluteString ?? "nil")")
print("R sole.sentence=\(ShareItemRules.soleWebURL(in: "see https://a.dev/x")?.absoluteString ?? "nil")")
print("R sole.noScheme=\(ShareItemRules.soleWebURL(in: "a.dev/x")?.absoluteString ?? "nil")")
print("R sole.file=\(ShareItemRules.soleWebURL(in: "file:///tmp/x")?.absoluteString ?? "nil")")
print("R sole.empty=\(ShareItemRules.soleWebURL(in: "  ")?.absoluteString ?? "nil")")

// merge with an unconsumed earlier share
func item(_ k: PendingShare.Item.Kind, _ v: String) -> PendingShare.Item { .init(kind: k, value: v) }
func names(_ a: [PendingShare.Item]) -> String { a.map { "\($0.kind.rawValue):\($0.value)" }.joined(separator: " | ") }
print("R merge.same=" + names(ShareItemRules.merge(existing: [item(.inlineText, "https://a.dev/1")], new: [item(.inlineText, "https://a.dev/1")])))
print("R merge.different=" + names(ShareItemRules.merge(existing: [item(.inlineText, "https://a.dev/1")], new: [item(.inlineText, "https://a.dev/2"), item(.attachment, "f.png")])))
print("R merge.kindMatters=" + names(ShareItemRules.merge(existing: [item(.inlineText, "f.png")], new: [item(.attachment, "f.png")])))
print("R merge.emptyExisting=" + names(ShareItemRules.merge(existing: [], new: [item(.inlineText, "x")])))

// injecting into a composer
print("R inject.empty=\(ShareItemRules.shouldInject("https://a.dev/1", into: ""))")
print("R inject.alreadyALine=\(ShareItemRules.shouldInject("https://a.dev/1", into: "note\nhttps://a.dev/1 \nmore"))")
print("R inject.substringOnly=\(ShareItemRules.shouldInject("https://a.dev/1", into: "see https://a.dev/1 please"))")
print("R inject.otherLink=\(ShareItemRules.shouldInject("https://a.dev/2", into: "https://a.dev/1 "))")
print("R inject.blank=\(ShareItemRules.shouldInject("   ", into: "x"))")

// how the request ends
print("R finish.none=\(ShareItemRules.finish(savedItemCount: 0))")
print("R finish.some=\(ShareItemRules.finish(savedItemCount: 2))")

// PendingShare's wire format is unchanged.
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
let share = PendingShare(items: [item(.inlineText, "u"), item(.attachment, "f")], timestamp: Date(timeIntervalSince1970: 0))
print("R wire=" + String(decoding: try! enc.encode(share), as: UTF8.self))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("share-one-link-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = ["PendingShare.swift": shared, "main.swift": harness]
for (n, c) in files { try? c.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"]
    + files.keys.sorted().map { tmp.appendingPathComponent($0).path } + ["-o", bin])
print("0. The shipping file compiles on its own")
check("Shared/PendingShare.swift (PendingShare + ShareItemRules) compiles standalone", cc == 0)
if cc != 0 { print(ccOut); print("\n❌ FAILED"); exit(1) }
let (_, out) = run(bin, [])
var r: [String: String] = [:]
for line in out.components(separatedBy: "\nR ").dropFirst() + (out.hasPrefix("R ") ? [String(out.dropFirst(2).prefix { $0 != "\n" })] : []) {
    let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
    if let eq = body.firstIndex(of: "=") { r[String(body[..<eq])] = String(body[body.index(after: eq)...]) }
}

print("\n1. What one share keeps")
check("the report: page URL + another address of the same page as text -> ONE link, the declared page URL",
      r["report"] == "webURL:https://buzzkit.dev/buzz.html")
check("same result whichever provider comes first", r["reportReversed"] == "webURL:https://buzzkit.dev/buzz.html")
check("URL and identical URL-as-text -> one link", r["sameURLTwice"] == "webURL:https://example.com/a")
check("padding and tracking parameters do not make it a second link", r["textURLPadded"] == "webURL:https://example.com/a")
check("www. and letter case do not make it another site",
      r["wwwVariant"] == "webURL:https://www.example.com/a" && r["hostCase"] == "webURL:https://Example.COM/a")
check("a page title next to the URL is kept", r["title"] == "webURL:https://example.com/a | text:An interesting article")
check("selected text that merely contains the link is kept", r["selection"]?.hasSuffix("for more") == true && r["selection"]?.hasPrefix("webURL:") == true)
check("a link to ANOTHER site is kept", r["otherHost"] == "webURL:https://example.com/a | text:https://other.org/x")
check("text holding two links is text, not a duplicate", r["twoLinksInText"]?.contains(" | text:https://example.com/b https://example.com/c") == true)
check("a non-web address is kept", r["nonWebScheme"]?.contains("text:mailto:someone@example.com") == true)
check("a bare URL shared as text only is kept", r["textOnlyURL"] == "text:https://example.com/only")
check("plain text is kept", r["plainText"] == "text:just some words")
check("a same-site link in a DIFFERENT extension item is kept", r["otherGroup"] == "webURL:https://example.com/a | text:https://example.com/b")
check("attachments are untouched by the link rule", r["attachments"] == "webURL:https://example.com/a | attachment:shared-1_a.pdf | attachment:shared-2_b.pdf")
check("identical items collapse", r["exactDuplicates"] == "text:hello | attachment:f.png")
check("a text and a file with the same string are both kept", r["fileNamedLikeText"] == "text:f.png | attachment:f.png")
check("nothing in, nothing out", r["empty"] == "")
check("soleWebURL: only a lone http(s) URL counts",
      r["sole.url"] == "https://a.dev/x?y=1" && r["sole.sentence"] == "nil" && r["sole.noScheme"] == "nil"
      && r["sole.file"] == "nil" && r["sole.empty"] == "nil")

print("\n2. Merging and injecting")
check("the same link shared twice before the app picked it up stays one", r["merge.same"] == "inlineText:https://a.dev/1")
check("different content is appended in order", r["merge.different"] == "inlineText:https://a.dev/1 | inlineText:https://a.dev/2 | attachment:f.png")
check("kind is part of identity", r["merge.kindMatters"] == "inlineText:f.png | attachment:f.png")
check("nothing unconsumed -> just the new items", r["merge.emptyExisting"] == "inlineText:x")
check("a link goes into an empty composer", r["inject.empty"] == "true")
check("a link already sitting on its own line is not added again", r["inject.alreadyALine"] == "false")
check("a link the user merely mentioned inside a sentence is still added", r["inject.substringOnly"] == "true")
check("a different link is added", r["inject.otherLink"] == "true")
check("blank text is never added", r["inject.blank"] == "false")
check("PendingShare's stored format is unchanged",
      r["wire"] == #"{"items":[{"kind":"inlineText","value":"u"},{"kind":"attachment","value":"f"}],"timestamp":"1970-01-01T00:00:00Z"}"#)

print("\n3. How the request ends")
check("nothing saved -> cancel (the app is not opened)", r["finish.none"] == "cancel")
check("something saved -> open the app, then complete", r["finish.some"] == "openAppThenComplete")

print("\n4. Wiring")
check("the extension collects candidates and lets the rules decide",
      viewModel.contains("let kept = ShareItemRules.reduce(candidates)") && viewModel.contains("add(.webURL, url.absoluteString)")
      && viewModel.contains("add(.text, text)"))
check("no provider result bypasses the rules", !viewModel.contains("pendingItems.append("))
check("each NSExtensionItem is its own group", viewModel.contains("for (group, extensionItem) in extensionItems.enumerated()") && viewModel.contains("currentGroup = group"))
check("long text still becomes a file, after the rules ran",
      viewModel.contains("guard candidate.value.count > inlineTextLimit else {") && viewModel.contains("shared-text-"))
check("merging with an unconsumed share de-duplicates", viewModel.contains("items = ShareItemRules.merge(existing: existing.items, new: items)"))
check("the app does not add a line the composer already has",
      injection.contains("guard ShareItemRules.shouldInject(item.value, into: vm.inputText) else {"))
let finishFn = between(controller, "private func finish(_ how: ShareItemRules.Finish) {", "// MARK: - Redirect to main app") ?? ""
check("completeRequest / cancelRequest are called from ONE function only",
      controller.components(separatedBy: "completeRequest(").count - 1 == 1 && controller.components(separatedBy: "cancelRequest(").count - 1 == 1
      && finishFn.contains("completeRequest(") && finishFn.contains("cancelRequest("))
check("that function runs once", finishFn.contains("guard !finished else { return }\n        finished = true"))
check("viewDidAppear no longer ends the request", !controller.contains("override func viewDidAppear"))
check("processing is bounded", controller.contains("private static let processingLimit: TimeInterval = 8")
      && controller.contains("let timedOut = await processWithLimit(vm, items)") && controller.contains("vm.finalizeItems()"))
check("nothing saved -> cancel without opening the app",
      controller.contains("case .cancel:\n                finish(.cancel)\n            case .openAppThenComplete:"))
check("the request completes when the open reports back, or after a grace period",
      controller.contains("openHostApp { [weak self] in self?.finish(.openAppThenComplete) }")
      && controller.contains("try? await Task.sleep(nanoseconds: UInt64(Self.openGrace * 1_000_000_000))\n                finish(.openAppThenComplete)"))
check("every exit of openHostApp reports back", (between(controller, "private func openHostApp(", "\n}\n") ?? "").components(separatedBy: "done()").count - 1 >= 4)
check("the activation rule still allows at most one web URL per share",
      plist.contains("<key>NSExtensionActivationSupportsWebURLWithMaxCount</key>\n\t\t\t\t<integer>1</integer>"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
