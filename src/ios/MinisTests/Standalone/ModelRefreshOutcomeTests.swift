#!/usr/bin/env swift
// [T-ios-model-refresh-visible] "Refresh model list" says what happened
// (parity with Android bef5cfe05). Reports: a relay's hidden models "do not go
// away after several refreshes"; "the refresh button does not sync the latest
// models". A refresh that failed, fell back to a catalog, or kept the old list
// looked the same as one that worked, and the /models parser only accepted
// `{"data":[{"id":…}]}`.
//
//   [1] the shipping ModelListParsing block (OpenAIModelsAPI.swift): the
//       shapes gateways send, entry ids, the provider's own error message
//   [2] the shipping ModelRefreshOutcome block (ProviderConfigStore.swift):
//       which list replaces a failed / empty provider list, the log line
//   [3] one refresh end to end over both blocks: success with removals, 401,
//       an error object in a 200, an unknown shape, an empty list (the old
//       list is kept), the alternative shapes, fallback to the catalog
//   [4] source guards: store, Refresh row, debug RPC, strings
//
// Run: swift ModelRefreshOutcomeTests.swift   (needs swiftc)
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
let store = source("Providers/ProviderConfigStore.swift")
guard let parsing = between(api, "// BEGIN ModelListParsing", "// END ModelListParsing"),
      let outcomeBlock = between(store, "// BEGIN ModelRefreshOutcome", "// END ModelRefreshOutcome") else {
    print("❌ ModelListParsing / ModelRefreshOutcome block not found"); exit(1)
}

let harness = #"""
import Foundation
"""# + parsing + outcomeBlock + #"""

var fails = 0
func CHECK(_ label: String, _ ok: Bool) { print("  \(ok ? "PASS" : "FAIL") \(label)"); if !ok { fails += 1 } }
func D(_ s: String) -> Data { Data(s.utf8) }
func ids(_ body: String) -> [String]? { ModelListParsing.modelArray(D(body))?.compactMap { ModelListParsing.entry($0)?.id } }

print("[1] /models shapes")
CHECK("standard {data:[{id}]}", ids(#"{"object":"list","data":[{"id":"a"},{"id":"b"}]}"#) == ["a", "b"])
CHECK("{models:[…]}", ids(#"{"models":[{"id":"a"}]}"#) == ["a"])
CHECK("items / results / result", ids(#"{"items":[{"id":"a"}]}"#) == ["a"] && ids(#"{"results":[{"id":"b"}]}"#) == ["b"] && ids(#"{"result":[{"id":"c"}]}"#) == ["c"])
CHECK("one level of nesting {data:{models:[…]}}", ids(#"{"code":0,"data":{"models":[{"id":"a"},{"id":"b"}]}}"#) == ["a", "b"])
CHECK("a bare array", ids(#"[{"id":"a"},{"id":"b"}]"#) == ["a", "b"])
CHECK("bare id strings", ids(#"{"data":["a"," b ",""]}"#) == ["a", "b"])
CHECK("id under model / model_id / name", ids(#"{"data":[{"model":"m1"},{"model_id":"m2"},{"name":"m3"},{"owned_by":"x"}]}"#) == ["m1", "m2", "m3"])
CHECK("id wins over name; name is then the display name",
      { let e = ModelListParsing.entry(["id": "gpt-x", "name": "GPT X"] as [String: Any])!
        return e.id == "gpt-x" && ModelListParsing.displayName(of: e.object, id: e.id) == "GPT X" }())
CHECK("a name that only repeats the id is not a display name",
      { let e = ModelListParsing.entry(["name": "m3"] as [String: Any])!
        return ModelListParsing.displayName(of: e.object, id: e.id) == nil }())
CHECK("an empty list is a list, not a missing one", ModelListParsing.modelArray(D(#"{"data":[]}"#))?.isEmpty == true)
CHECK("error object in a 200 is not a model list", ModelListParsing.modelArray(D(#"{"error":{"code":16,"message":"Authorization Not Found"}}"#)) == nil)
CHECK("unknown shape / HTML / empty body are not model lists",
      ModelListParsing.modelArray(D(#"{"foo":1}"#)) == nil && ModelListParsing.modelArray(D("<html>404</html>")) == nil
      && ModelListParsing.modelArray(D("")) == nil && ModelListParsing.modelArray(D(#""ok""#)) == nil)

print("[2] the provider's own message")
CHECK("error.message", ModelListParsing.errorSnippet(D(#"{"error":{"code":16,"message":"Authorization Not Found"}}"#)) == "Authorization Not Found")
CHECK("top-level message, then a string error",
      ModelListParsing.errorSnippet(D(#"{"message":"quota exceeded"}"#)) == "quota exceeded"
      && ModelListParsing.errorSnippet(D(#"{"error":"bad key"}"#)) == "bad key")
CHECK("a non-JSON body is shown on one line, capped at 200",
      ModelListParsing.errorSnippet(D("<html>\n  <b>404</b>\n</html>")) == "<html> <b>404</b> </html>"
      && ModelListParsing.errorSnippet(D(String(repeating: "x", count: 500))).count == 200)
CHECK("an empty body says so", ModelListParsing.errorSnippet(D("  \n")) == "(empty body)")
CHECK("HTTP failure text", ModelListParsing.httpFailure(code: 401, body: D(#"{"error":{"message":"Authorization Not Found"}}"#)) == "HTTP 401: Authorization Not Found")

print("[3] which list replaces the provider's")
typealias F = ModelRefreshFallback
CHECK("a relay that failed keeps its list, even with a catalog match", F.decide(vendorThrew: true, isThirdParty: true, catalogCount: 5, builtInCount: 0) == .kept)
CHECK("a relay that listed nothing: catalog if it matches, else kept",
      F.decide(vendorThrew: false, isThirdParty: true, catalogCount: 5, builtInCount: 0) == .modelsDev
      && F.decide(vendorThrew: false, isThirdParty: true, catalogCount: 0, builtInCount: 9) == .kept)
CHECK("an official endpoint that failed: catalog, then built-in, then kept",
      F.decide(vendorThrew: true, isThirdParty: false, catalogCount: 5, builtInCount: 9) == .modelsDev
      && F.decide(vendorThrew: true, isThirdParty: false, catalogCount: 0, builtInCount: 9) == .builtIn
      && F.decide(vendorThrew: true, isThirdParty: false, catalogCount: 0, builtInCount: 0) == .kept)
CHECK("fetch source names map to outcome sources",
      ModelRefreshSource(fetchSource: "api") == .vendor && ModelRefreshSource(fetchSource: "models.dev") == .modelsDev
      && ModelRefreshSource(fetchSource: "built-in") == .builtIn)

print("[4] one refresh, end to end")
// The store's flow over the two blocks: read the body, pick the list, diff it
// against what the instance had. `stale` = ids already unlisted for longer
// than the grace window (they are the ones a refresh really deletes).
func refresh(status: Int, body: String, thirdParty: Bool = true, catalog: [String] = [], builtIn: [String] = [],
             before: [String], stale: Set<String> = []) -> (ModelRefreshOutcome, [String]) {
    var vendorError: String?
    var threw = false
    var listed: [String] = []
    if !(200..<300).contains(status) {
        threw = true; vendorError = ModelListParsing.httpFailure(code: status, body: D(body))
    } else if let array = ModelListParsing.modelArray(D(body)) {
        listed = array.compactMap { ModelListParsing.entry($0)?.id }
        if listed.isEmpty { vendorError = "the provider listed no models" }
    } else {
        threw = true; vendorError = "the response is not a model list: \(ModelListParsing.errorSnippet(D(body)))"
    }
    var source = ModelRefreshSource.vendor
    if listed.isEmpty {
        source = ModelRefreshFallback.decide(vendorThrew: threw, isThirdParty: thirdParty,
                                             catalogCount: catalog.count, builtInCount: builtIn.count)
        listed = source == .modelsDev ? catalog : source == .builtIn ? builtIn : []
    }
    guard source != .kept else {
        return (ModelRefreshOutcome(source: .kept, diff: ModelListDiff(total: before.count), vendorError: vendorError), before)
    }
    let absent = before.filter { !listed.contains($0) }
    let removed = absent.filter { stale.contains($0) }
    let unlisted = absent.filter { !stale.contains($0) }
    let diff = ModelListDiff(total: listed.count, added: listed.filter { !before.contains($0) }.count,
                             removed: removed.count, unlisted: unlisted.count)
    return (ModelRefreshOutcome(source: source, diff: diff, vendorError: vendorError), listed + unlisted)
}
let had = ["a", "b", "old1", "old2"]

var (o, list) = refresh(status: 200, body: #"{"data":[{"id":"a"},{"id":"b"},{"id":"new"}]}"#, before: had, stale: ["old1"])
CHECK("success with removals: 3 found, 1 new, 1 removed, 1 unlisted but kept for now",
      o == ModelRefreshOutcome(source: .vendor, diff: ModelListDiff(total: 3, added: 1, removed: 1, unlisted: 1), vendorError: nil)
      && list == ["a", "b", "new", "old2"])
CHECK("log line", o.logLine == "source=vendor total=3 added=1 removed=1 unlisted=1")

(o, list) = refresh(status: 401, body: #"{"error":{"code":16,"message":"Authorization Not Found"}}"#, before: had)
CHECK("401: kept, with the provider's message", o.source == .kept && o.vendorError == "HTTP 401: Authorization Not Found" && list == had && o.diff.total == 4)
CHECK("log line carries the reason", o.logLine == "source=kept total=4 added=0 removed=0 unlisted=0 vendorError=HTTP 401: Authorization Not Found")

(o, list) = refresh(status: 200, body: #"{"error":{"message":"invalid token"}}"#, before: had)
CHECK("error object in a 200: kept", o.source == .kept && o.vendorError == "the response is not a model list: invalid token" && list == had)

(o, list) = refresh(status: 200, body: "<html>login</html>", before: had)
CHECK("unknown shape: kept", o.source == .kept && o.vendorError == "the response is not a model list: <html>login</html>" && list == had)

(o, list) = refresh(status: 200, body: #"{"data":[]}"#, before: had)
CHECK("empty list: the old list is kept, never wiped", o.source == .kept && o.vendorError == "the provider listed no models" && list == had)

(o, list) = refresh(status: 200, body: #"{"data":{"models":["a","b","c"]}}"#, before: had)
CHECK("an alternative shape refreshes like the standard one", o.source == .vendor && o.diff.total == 3 && o.diff.added == 1 && o.vendorError == nil)

(o, list) = refresh(status: 500, body: "upstream down", thirdParty: false, catalog: ["gpt-a", "gpt-b"], before: ["gpt-a"])
CHECK("official endpoint down: the public catalog is used, and says why",
      o.source == .modelsDev && o.vendorError == "HTTP 500: upstream down" && o.diff.total == 2 && o.diff.added == 1)
(o, list) = refresh(status: 500, body: "upstream down", thirdParty: true, catalog: ["x"], before: had)
CHECK("relay down: no catalog swap", o.source == .kept && list == had)
exit(fails == 0 ? 0 : 1)
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("model-refresh-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
check("both blocks compile standalone", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("parsing / outcome checks all pass", status == 0 && !out.contains("FAIL "))
}

print("[5] source guards")
check("performFetch reads the list through ModelListParsing",
      api.contains("guard let modelsArray = ModelListParsing.modelArray(data) else {")
      && api.contains("guard let (id, item) = ModelListParsing.entry(raw) else { return nil }")
      && !api.contains("json[\"data\"] as? [[String: Any]]"))
check("a non-2xx says HTTP <code>: <provider message>; 401/403 stay invalidAPIKey",
      api.contains("let reason = ModelListParsing.httpFailure(code: statusCode, body: data)")
      && api.contains("throw LLMError.invalidAPIKey(detail: reason)") && api.contains("throw ModelListFetchError(reason: reason)"))
check("replaceEntries reports what it did (removed = really deleted, unlisted = kept for the grace window)",
      store.contains("func replaceEntries(for instanceId: String, models rawModels: [LLMModel], caller: String = #function) -> ModelListDiff {")
      && store.contains("removed: expiredAbsent.count, unlisted: keptAbsent.count)"))
let refresh = between(store, "func refreshModels(for instance: ProviderInstance, caller: String = \"refreshModels(manual)\") async -> ModelRefreshOutcome {",
                      "/// Why a refresh kept the old list") ?? ""
check("a failed refresh returns .kept and never replaces the list",
      refresh.contains("} catch {") && refresh.contains("outcome = ModelRefreshOutcome(source: .kept, diff: ModelListDiff(total: kept),")
      && refresh.components(separatedBy: "replaceEntries(").count - 1 == 1)
check("one outcome log line per refresh", refresh.contains("logger.info(\"[ModelList] refresh outcome caller=\\(caller)"))
check("the daily refresh goes through the same path",
      store.contains("await refreshModels(for: instance, caller: \"autoRefreshModels(daily)\")"))
check("fallback choice comes from ModelRefreshFallback.decide, with the vendor error carried along",
      store.contains("switch ModelRefreshFallback.decide(vendorThrew: vendorThrew, isThirdParty: isThirdParty,")
      && store.contains("source: \"models.dev\", warnings: warnings, vendorError: vendorError)")
      && store.contains("throw ModelRefreshError.modelsDevNoMatch(warnings: warnings, vendorError: vendorError)"))
check("an empty provider list is named", store.contains("vendorError = \"the provider listed no models\""))

let view = source("Views/Providers/ProviderInstanceDetailView.swift")
check("the Refresh button shows the outcome",
      view.contains("refreshOutcome = await store.refreshModels(for: freshInstance, caller: \"refreshModels(detail-view)\")")
      && view.contains("let summary = ModelRefreshSummary(outcome)"))
let keys = ["Found %lld models (%lld new, %lld removed)",
            "%lld no longer listed by the provider; kept for %lld days, then removed.",
            "Couldn't refresh: %@. The current list was kept.",
            "The provider's list was unavailable (%@). Used the public model catalog instead: %lld models.",
            "The provider's list was unavailable (%@). Used the built-in model list instead: %lld models."]
let catalog = source("Localizable.xcstrings")
for key in keys {
    let entry = between(catalog, "\"\(key)\" : {", "\n    },") ?? ""
    check("used + localized zh-Hans / zh-Hant: \(key.prefix(44))",
          view.contains("AppLocalized(\"\(key)\")") && entry.contains("\"zh-Hans\"") && entry.contains("\"zh-Hant\""))
}
let rpc = source("Debug/DebugRPCProviderChat.swift")
check("provider.models.refresh returns the outcome",
      rpc.contains("let outcome = await store.refreshModels(for: instance, caller: \"refreshModels(rpc)\")")
      && rpc.contains("\"source\": outcome.source.rawValue,") && rpc.contains("\"vendorError\": outcome.vendorError ?? NSNull(),"))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
