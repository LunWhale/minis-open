#!/usr/bin/env swift
// [ISS-031] Kimi Code subscription usage (GET {base}/usages, from the official
// MoonshotAI/kimi-cli `/usage` command), plus the MiniMax / OpenCode console
// links.
//
//   A. QuotaModels / QuotaRules / QuotaAdapters / QuotaPersistence compiled as
//      shipped, driven with the response shapes the CLI's parser accepts (NOT
//      captured replies - the real response is unverified):
//      used+limit, remaining+limit, usage only, limits only, MINUTE / HOUR /
//      DAY / unit-less windows, the reset spellings, missing / negative / junk
//      fields, {} and non-JSON, 401 / 404; no invented numbers; the request
//      goes to the fixed host with the credential only as the bearer and no
//      borrowed client identity; the logged shape carries no values.
//   B. Vendor routing and console links: Kimi Code on both hosts, MiniMax
//      (console only), OpenCode (console only), other vendors unchanged.
//   C. Store wiring (source): OAuth token source, instance-keyed subject,
//      once-per-launch shape log, OpenCode flag from the app's own detection.
//
// Standalone: `swift KimiCodeQuotaTests.swift` (needs swiftc).

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let pure = ["Providers/Quota/QuotaModels.swift", "Providers/Quota/QuotaRules.swift",
            "Providers/Quota/QuotaAdapters.swift", "Providers/Quota/QuotaPersistence.swift"].map(source)
let store = source("Providers/Quota/QuotaStore.swift")

print("A/B. Compiled harness")
let harness = #"""
import Foundation

var hFailures = 0
func t(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { hFailures += 1 }
}
func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
let now = Date(timeIntervalSince1970: 1_800_000_000)
let sid = QuotaSubjectID(vendor: .kimiCode, accountKey: "instance:k1")

func parse(_ json: String) -> Result<UpstreamQuotaSnapshot, QuotaFetchError> {
    do { return .success(try KimiCodeQuotaAdapter.parse(Data(json.utf8), subjectId: sid, now: now)) }
    catch let e as QuotaFetchError { return .failure(e) }
    catch { return .failure(QuotaFetchError(kind: .network, detail: "\(error)")) }
}
func windows(_ json: String) -> [QuotaWindow] {
    if case .success(let s) = parse(json) { return s.pools.first?.windows ?? [] }
    return []
}
func pct(_ w: QuotaWindow?) -> Decimal? { w?.utilization(poolKind: .usageWindow, unlimited: false)?.percent }
func failKind(_ json: String) -> QuotaError.Kind? {
    if case .failure(let e) = parse(json) { return e.kind }
    return nil
}

print("— Response shapes the official CLI parses")
let full = """
{"usage":{"limit":1000,"used":300,"resetTime":"2027-01-15T08:00:00.123456789Z"},
 "limits":[{"detail":{"limit":200,"used":150,"reset_in":3600},"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}]}
"""
if case .success(let snap) = parse(full) {
    let pool = snap.pools.first
    t("one account-wide usage-window pool", snap.pools.count == 1 && pool?.kind == .usageWindow
      && snap.bindings.first?.target == .subject && snap.bindings.first?.evidence == .assumedSubjectWide)
    t("labelled as observed-client dashboard API, not 'official API'",
      snap.provenance.source == .providerDashboardAPI && snap.provenance.confidence == .observedClient)
    let ws = pool?.windows ?? []
    t("usage → Weekly (the CLI's default label), limits[300 MINUTE] → 5h",
      ws.map(\.id) == ["weekly", "5h"] && ws.first?.calendarPeriod == .week && ws.last?.duration == 18000)
    t("counts kept as given (total = limit, used), percent computed 30% / 75%",
      ws.first?.amounts == QuotaAmounts(total: 1000, used: 300) && pct(ws.first) == 30 && pct(ws.last) == 75)
    t("percent basis is computed, never 'reported'",
      ws.first?.utilization(poolKind: .usageWindow, unlimited: false)?.basis == .computed
      && ws.allSatisfy { $0.reportedUsedFraction == nil })
    t("ISO reset with nanoseconds parsed (to the millisecond)",
      ws.first?.resetsAt.map { abs($0.timeIntervalSince1970 - 1_800_000_000.123) < 0.001 } == true)
    t("reset_in seconds → now + 3600", ws.last?.resetsAt == now.addingTimeInterval(3600))
    let status = QuotaStatusRules.poolStatus(pool!, now: now)
    t("worst window decides (75% = 5h)", status.decidingWindowId == "5h")
} else { t("full shape parses", false) }

let remaining = #"{"usage":{"limit":"1000","remaining":"700","reset_at":1800003600}}"#
t("remaining + limit (string numbers): used derived → 30%, remaining kept",
  pct(windows(remaining).first) == 30 && windows(remaining).first?.amounts?.remaining == 700
  && windows(remaining).first?.amounts?.used == nil)
t("epoch-seconds reset_at", windows(remaining).first?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
t("epoch-milliseconds resetAt", windows(#"{"usage":{"limit":10,"used":1,"resetAt":1800003600000}}"#).first?.resetsAt
  == Date(timeIntervalSince1970: 1_800_003_600))
t("ttl / window seconds as relative reset",
  windows(#"{"usage":{"limit":10,"used":1,"ttl":60}}"#).first?.resetsAt == now.addingTimeInterval(60)
  && windows(#"{"usage":{"limit":10,"used":1,"window":120}}"#).first?.resetsAt == now.addingTimeInterval(120))
t("usage only (no limits) → one window", windows(#"{"usage":{"limit":10,"used":5}}"#).count == 1)
let limitsOnly = """
{"limits":[
 {"detail":{"limit":10,"used":1},"window":{"duration":5,"timeUnit":"HOUR"}},
 {"detail":{"limit":10,"used":2},"window":{"duration":7,"timeUnit":"DAY"}},
 {"detail":{"limit":10,"used":3},"window":{"duration":90}},
 {"limit":10,"used":4,"duration":1440,"timeUnit":"MINUTE"},
 {"detail":{"limit":10,"used":5,"name":"Opus"}},
 {"detail":{"limit":10,"used":6}}]}
"""
let lw = windows(limitsOnly)
t("limits only: HOUR → 5h, DAY → 7d, unit-less → seconds, item-level counts, upstream name, numbered fallback",
  lw.map(\.id) == ["5h", "7d", "1m", "1d", "Opus", "limit 6"])
t("durations: 5h / 7d / 90 s / 1 day", lw.prefix(4).map(\.duration) == [18000, 604800, 90, 86400])
t("same id twice stays two windows", windows(#"{"limits":[{"detail":{"limit":5,"used":1},"window":{"duration":300,"timeUnit":"MINUTE"}},{"detail":{"limit":9,"used":1},"window":{"duration":300,"timeUnit":"MINUTE"}}]}"#).map(\.id) == ["5h", "5h #2"])

print("— Never an invented number")
t("limit without used/remaining → no window (the CLI would show '0 used')",
  failKind(#"{"usage":{"limit":1000}}"#) == .unsupportedResponse)
t("used without limit → no window", failKind(#"{"usage":{"used":5}}"#) == .unsupportedResponse)
t("limit 0 / negative / junk → skipped",
  failKind(#"{"usage":{"limit":0,"used":0}}"#) == .unsupportedResponse
  && failKind(#"{"usage":{"limit":10,"used":-1}}"#) == .unsupportedResponse
  && failKind(#"{"usage":{"limit":"lots","used":"some"}}"#) == .unsupportedResponse
  && failKind(#"{"usage":{"limit":true,"used":1}}"#) == .unsupportedResponse)
t("a bad entry is skipped, the good one kept",
  windows(#"{"usage":{"limit":10},"limits":[{"detail":{"limit":10,"used":2},"window":{"duration":300,"timeUnit":"MINUTE"}}]}"#).map(\.id) == ["5h"])
t("{} → unsupportedResponse", failKind("{}") == .unsupportedResponse)
t("non-JSON / array → unsupportedResponse", failKind("<html>nope</html>") == .unsupportedResponse && failKind("[1,2]") == .unsupportedResponse)
t("unreadable reset → no reset, window still shown",
  windows(#"{"usage":{"limit":10,"used":1,"reset_at":"soon"}}"#).first.map { $0.resetsAt == nil } == true)
if case .failure(let e) = parse(#"{"quota":{"left":42,"owner":"alice@example.com"}}"#) {
    t("failure detail carries the shape (names + types) without any value",
      e.detail.contains("\"quota\":{\"left\":int,\"owner\":string}") && !e.detail.contains("42") && !e.detail.contains("alice"))
} else { t("unknown shape fails", false) }

print("— Request")
final class FakeTransport: QuotaHTTPTransport, @unchecked Sendable {
    var urls: [URL] = [], bearers: [String] = [], sentHeaders: [[String: String]] = []
    let status: Int, body: String
    init(_ status: Int, _ body: String) { self.status = status; self.body = body }
    func get(_ url: URL, bearer: String, headers: [String: String]) async throws -> QuotaHTTPResponse {
        urls.append(url); bearers.append(bearer); sentHeaders.append(headers)
        return QuotaHTTPResponse(status: status, body: Data(body.utf8), headers: [:])
    }
}
func desc(_ kind: QuotaInstanceDescriptor.ProviderKind, oauth: Bool = false, base: String? = nil,
          openCode: Bool = false) -> QuotaInstanceDescriptor {
    QuotaInstanceDescriptor(instanceId: "k1", label: "L", providerKind: kind, isOAuth: oauth, isEnabled: true,
                            customBaseURL: base, isOpenCodeChannel: openCode)
}
func fetch(_ d: QuotaInstanceDescriptor, _ fake: FakeTransport) -> Result<QuotaFetchOutcome, QuotaFetchError> {
    let sem = DispatchSemaphore(value: 0)
    var out: Result<QuotaFetchOutcome, QuotaFetchError> = .failure(QuotaFetchError(kind: .network, detail: "not run"))
    Task {
        do { out = .success(try await KimiCodeQuotaAdapter().fetch(QuotaFetchContext(
            descriptor: d, subjectId: sid, credential: "kimi-oauth-SECRET-token", transport: fake, now: now))) }
        catch let e as QuotaFetchError { out = .failure(e) }
        catch { out = .failure(QuotaFetchError(kind: .network, detail: "\(error)")) }
        sem.signal()
    }
    sem.wait()
    return out
}
let okFake = FakeTransport(200, full)
let ok = fetch(desc(.kimiCode, oauth: true), okFake)
t("default host: GET https://api.kimi.com/coding/v1/usages",
  okFake.urls == [URL(string: "https://api.kimi.com/coding/v1/usages")!])
t("credential only as the bearer", okFake.bearers == ["kimi-oauth-SECRET-token"])
let ovFake = FakeTransport(200, full)
_ = { () -> Void in
    let sem = DispatchSemaphore(value: 0)
    var ctx = QuotaFetchContext(descriptor: desc(.kimiCode, oauth: true), subjectId: sid,
                                credential: "t", transport: ovFake, now: now)
    ctx.endpointOverride = URL(string: "http://10.0.0.5:18931/coding/v1/usages")
    Task { _ = try? await KimiCodeQuotaAdapter().fetch(ctx); sem.signal() }
    sem.wait()
}()
t("a (DEBUG-only) endpoint override replaces the URL and nothing else",
  ovFake.urls == [URL(string: "http://10.0.0.5:18931/coding/v1/usages")!] && ovFake.sentHeaders == [[:]])
t("no extra headers: no borrowed User-Agent / client identity", okFake.sentHeaders == [[:]])
if case .success(let o) = ok {
    t("shape returned for the once-per-launch log, with no values and no token",
      o.responseShape?.contains("\"limits\":[{\"detail\":{\"limit\":int,\"reset_in\":int,\"used\":int}") == true
      && o.responseShape?.contains("1000") == false && o.responseShape?.contains("SECRET") == false
      && o.responseShape?.contains("iso-date") == true)
} else { t("fetch succeeds", false) }
let aiFake = FakeTransport(200, full)
_ = fetch(desc(.openAI, base: "https://api.kimi.ai/coding/v1/some/path"), aiFake)
t("overseas base on api.kimi.ai → same fixed path on that host (user path ignored)",
  aiFake.urls == [URL(string: "https://api.kimi.ai/coding/v1/usages")!])
func failure(_ status: Int) -> QuotaError.Kind? {
    if case .failure(let e) = fetch(desc(.kimiCode, oauth: true), FakeTransport(status, "{}")) { return e.kind }
    return nil
}
t("401 → unauthorized, 404 → notFound, 500 → server",
  failure(401) == .unauthorized && failure(404) == .notFound && failure(500) == .server)
if case .failure(let e) = fetch(desc(.kimiCode, oauth: true), FakeTransport(401, "{}")) {
    t("error detail never contains the token", !e.detail.contains("SECRET"))
}

print("— Vendor routing")
func cap(_ d: QuotaInstanceDescriptor) -> QuotaCapability { QuotaAdapterRegistry.adapter(for: d).capability(for: d) }
t("Kimi Code OAuth → Kimi Code adapter (active, dashboard API / observed client)",
  QuotaVendorDetector.vendor(for: desc(.kimiCode, oauth: true)) == .kimiCode
  && cap(desc(.kimiCode, oauth: true)) == .activeQuery(source: .providerDashboardAPI, confidence: .observedClient))
t("Kimi Code API key on api.kimi.com / api.kimi.ai → Kimi Code adapter",
  QuotaVendorDetector.vendor(for: desc(.openAI, base: "https://api.kimi.com/coding/v1")) == .kimiCode
  && QuotaVendorDetector.vendor(for: desc(.openAI, base: "https://api.kimi.ai/coding/v1")) == .kimiCode)
t("Moonshot open platform unchanged", QuotaVendorDetector.vendor(for: desc(.openAI, base: "https://api.moonshot.cn/v1")) == .moonshot)
t("MiniMax (international / China) → no query (not supported yet), not a relay probe",
  QuotaVendorDetector.vendor(for: desc(.anthropic, base: "https://api.minimax.io/anthropic/v1")) == .miniMax
  && QuotaVendorDetector.vendor(for: desc(.anthropic, base: "https://api.minimaxi.com/anthropic")) == .miniMax
  && cap(desc(.anthropic, base: "https://api.minimax.io/anthropic/v1")) == .unsupported(.providerTypeUnsupported))
t("OpenCode channel → no lookup API (no relay probe against opencode.ai)",
  QuotaVendorDetector.vendor(for: desc(.openAI, base: "https://opencode.ai/zen/go/v1", openCode: true)) == .openCode
  && cap(desc(.openAI, base: "https://opencode.ai/zen/go/v1", openCode: true)) == .unsupported(.vendorHasNoQuotaAPI))
t("without the channel flag the host alone does not decide OpenCode (the app's detection is the source)",
  QuotaVendorDetector.vendor(for: desc(.openAI, base: "https://opencode.ai/zen/go/v1")) == .customRelay)
t("other unsupported vendors unchanged",
  cap(desc(.xAI)) == .unsupported(.vendorHasNoQuotaAPI)
  && cap(desc(.gemini, oauth: true)) == .unsupported(.providerTypeUnsupported)
  && cap(desc(.githubCopilot, oauth: true)) == .unsupported(.providerTypeUnsupported))

print("— Console links")
func link(_ d: QuotaInstanceDescriptor) -> String? { QuotaConsoleLink.url(for: d)?.absoluteString }
t("Kimi Code keeps kimi.com/code (top-up balance is only on the site)", link(desc(.kimiCode, oauth: true)) == "https://www.kimi.com/code")
t("MiniMax international → Billing > Token Plan",
  link(desc(.anthropic, base: "https://api.minimax.io/anthropic/v1")) == "https://platform.minimax.io/user-center/payment/token-plan")
t("MiniMax China → plan usage console", link(desc(.anthropic, base: "https://api.minimaxi.com/anthropic")) == "https://platform.minimaxi.com/console/usage")
t("OpenCode → opencode.ai/auth (the docs' console link)", link(desc(.openAI, base: "https://opencode.ai/zen/go/v1", openCode: true)) == "https://opencode.ai/auth")

print("HARNESS failures=\(hFailures)")
exit(hFailures == 0 ? 0 : 1)
"""#

do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kimiquota-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    var paths: [String] = []
    for (i, src) in pure.enumerated() {
        let u = tmp.appendingPathComponent("src\(i).swift")
        try src.write(to: u, atomically: true, encoding: .utf8)
        paths.append(u.path)
    }
    let main = tmp.appendingPathComponent("main.swift")
    try harness.write(to: main, atomically: true, encoding: .utf8)
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
    let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"] + paths + [main.path, "-o", bin.path])
    check("quota sources compile standalone", cc == 0)
    if cc != 0 { print(ccOut) }
    let (rc, out) = run(bin.path, [])
    print(out, terminator: "")
    check("all Kimi Code / console scenarios pass", rc == 0 && out.contains("HARNESS failures=0"))
} catch {
    check("harness setup: \(error)", false)
}

print("C. Store wiring")
check("Kimi Code OAuth: pasted token first, else the device-flow token (refreshed when due)",
      store.contains("} else if adapter.vendor == .kimiCode, d.isOAuth {")
      && store.contains("ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: \"manual-oauth-token\")?")
      && store.contains("return try? await KimiOAuthManager.shared.validAccessToken(instanceId: instanceId)"))
check("Kimi Code OAuth subject keyed by instance (rotating token never hashed)",
      store.range(of: "adapter.vendor == .kimiCode, d.isOAuth {\n            // [ISS-031]").map { r in
          store[r.upperBound...].prefix(600).contains("subjectId = Self.subscriptionSubject(vendor: adapter.vendor, instanceId: instanceId)")
      } == true)
check("response shape logged once per adapter per launch, never the body",
      store.contains("if let shape = outcome.responseShape, !loggedResponseShapes.contains(adapter.adapterId) {")
      && store.contains("logger.info(\"[Quota] 🧩 \\(adapter.adapterId) response shape: \\(shape)\")"))
check("no client-identity headers are added for Kimi Code",
      !(store.range(of: "switch adapter.vendor {\n        case .claudeSubscription:").map { String(store[$0.lowerBound...].prefix(1400)) } ?? "").contains(".kimiCode"))
check("endpoint override: DEBUG builds only, local file, keyed by instance (never a whole vendor)",
      store.contains("#if DEBUG\n        if let override = Self.debugEndpointOverride(instanceId: d.instanceId) {")
      && store.contains("let raw = map[instanceId], let url = URL(string: raw),")
      && store.contains("    #if DEBUG\n    /// [ISS-031] DEBUG builds only: `Library/Caches/quota-debug-endpoints.json`"))
check("OpenCode flag comes from the app's own detection",
      store.contains("isOpenCodeChannel: instance.isOpenCodeChannel)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
