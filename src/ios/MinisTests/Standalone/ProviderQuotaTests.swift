// [T-provider-quota] Upstream provider quota / balance: model, rules,
// adapters, persistence.
//
//   A. QuotaModels / QuotaRules / QuotaAdapters / QuotaPersistence, compiled
//      together as shipped:
//      - Decimal parsing never turns junk into 0;
//      - DeepSeek multi-currency parsing (one pool per currency, never summed,
//        is_available → verdict);
//      - Moonshot / SiliconFlow / OpenRouter parsing, including limit == null
//        and partial failure;
//      - percent derivation only with a reliable denominator, and never for a
//        prepaid balance;
//      - several windows reported side by side, never summed;
//      - the 10-minute refresh gate, Retry-After, backoff, and the forced
//        debounce;
//      - the 24-hour capability gate;
//      - shared-pool de-duplication across instances and models;
//      - manual-mapping validity and evidence;
//      - store-file round trip with Decimals as strings;
//      - single flight;
//      - vendor detection and the fixed-host request.
//   B. App wiring:
//      - the store persists outside backup and never logs a credential;
//      - the detail section sits between Status and Thinking Rules;
//      - the store starts at launch;
//      - all files are in the target.
//
// Standalone: `swift ProviderQuotaTests.swift` (needs swiftc).

import Foundation

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = FileManager.default.currentDirectoryPath
func source(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: root)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent("src/ios/" + rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("source not found: \(rel)")
}

let pure = ["Providers/Quota/QuotaModels.swift", "Providers/Quota/QuotaRules.swift",
            "Providers/Quota/QuotaAdapters.swift", "Providers/Quota/QuotaPersistence.swift"].map(source)
let store = source("Providers/Quota/QuotaStore.swift")
let section = source("Views/Providers/ProviderQuotaSection.swift")
let detail = source("Views/Providers/ProviderInstanceDetailView.swift")
let app = source("MinisApp.swift")
let pbx = source("Minis.xcodeproj/project.pbxproj")

// MARK: - A. Compiled harness

print("A. Quota model / rules / adapters / persistence (compiled as shipped)")

let harness = #"""
import Foundation

var hFailures = 0
func t(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { hFailures += 1 }
}
func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
let now = Date(timeIntervalSince1970: 1_800_000_000)
let sub = QuotaSubjectID(vendor: .deepSeek, accountKey: "abcd1234abcd1234")
let prov = QuotaProvenance(source: .officialQuery, confidence: .documented, adapterId: "test", endpoint: nil, relayHost: nil)
func pool(_ family: String, kind: QuotaPool.Kind, unit: QuotaUnit = .currency(code: "USD"),
          amounts: QuotaAmounts? = nil, windows: [QuotaWindow] = [], verdict: QuotaPool.Verdict? = nil,
          subject: QuotaSubjectID = sub, at: Date = now, adapterId: String = "test") -> QuotaPool {
    var p = prov; p.adapterId = adapterId
    return QuotaPool(id: QuotaPoolKey(subject: subject, family: family), subjectId: subject, kind: kind, unit: unit,
                     vendorLabel: nil, amounts: amounts, windows: windows, verdict: verdict, unlimited: false,
                     provenance: p, observedAt: at)
}
func window(_ id: String, used: String? = nil, remaining: String? = nil, resets: Date? = nil, at: Date = now) -> QuotaWindow {
    QuotaWindow(id: id, isRolling: true, reportedUsedFraction: used.map(dec),
                reportedRemainingFraction: remaining.map(dec), resetsAt: resets, observedAt: at, provenance: prov)
}

// ── Decimal parsing ────────────────────────────────────────────────────
print("— Decimal parsing")
t("\"110.00\" → 110", QuotaDecimalParser.parse("110.00") == dec("110"))
t("JSON number 0.1 → exactly 0.1 (no binary artefact)", QuotaDecimalParser.parse(NSNumber(value: 0.1)) == dec("0.1"))
t("\"12abc\" → nil (not the numeric prefix)", QuotaDecimalParser.parse("12abc") == nil)
t("\"\" → nil", QuotaDecimalParser.parse("") == nil)
t("\"-\" → nil (no digit)", QuotaDecimalParser.parse("-") == nil)
t("Bool true → nil (never an amount)", QuotaDecimalParser.parse(NSNumber(value: true)) == nil)
t("null / missing → nil, never 0", QuotaDecimalParser.parse(nil) == nil && QuotaDecimalParser.parse(NSNull()) == nil)

// ── DeepSeek ────────────────────────────────────────────────────────────
print("— DeepSeek /user/balance")
let dsJSON = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"3.50","granted_balance":"0.00","topped_up_balance":"3.50"}]}"#
let ds = try! DeepSeekQuotaAdapter.parse(Data(dsJSON.utf8), subjectId: sub, now: now)
t("two currencies → two pools", ds.pools.count == 2)
let cny = ds.pools.first { $0.unit == .currency(code: "CNY") }!
let usd = ds.pools.first { $0.unit == .currency(code: "USD") }!
t("pool keys differ by currency (never merged)", cny.id != usd.id && cny.id.rawValue.hasSuffix(":balance:CNY") && usd.id.rawValue.hasSuffix(":balance:USD"))
t("CNY remaining = total_balance 110 (Decimal)", cny.amounts?.remaining == dec("110"))
t("CNY breakdown granted 10 + topped up 100", cny.amounts?.breakdown == [.init(role: .granted, amount: 10), .init(role: .toppedUp, amount: 100)])
t("USD kept in USD: 3.50", usd.amounts?.remaining == dec("3.5"))
t("prepaid balance kind, no total", cny.kind == .prepaidBalance && cny.amounts?.total == nil)
t("is_available true → verdict allowed", cny.verdict == .allowed && ds.accountAvailable == true)
t("every pool bound account-wide (vendorDocumented)", ds.bindings.count == 2 && ds.bindings.allSatisfy { $0.target == .subject && $0.evidence == .vendorDocumented })
t("source official, confidence documented", ds.provenance.source == .officialQuery && ds.provenance.confidence == .documented)
let dsOff = try! DeepSeekQuotaAdapter.parse(Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#.utf8), subjectId: sub, now: now)
t("is_available false → verdict rejected → exhausted",
  dsOff.pools[0].verdict == .rejected && QuotaStatusRules.poolStatus(dsOff.pools[0], now: now).status == .exhausted)
t("missing balance_infos → unsupportedResponse",
  { do { _ = try DeepSeekQuotaAdapter.parse(Data(#"{"foo":1}"#.utf8), subjectId: sub, now: now); return false }
    catch let e as QuotaFetchError { return e.kind == .unsupportedResponse } catch { return false } }())
t("non-JSON → unsupportedResponse",
  { do { _ = try DeepSeekQuotaAdapter.parse(Data("<html>".utf8), subjectId: sub, now: now); return false }
    catch let e as QuotaFetchError { return e.kind == .unsupportedResponse } catch { return false } }())
let dsBad = try? DeepSeekQuotaAdapter.parse(Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"n/a"}]}"#.utf8), subjectId: sub, now: now)
t("unparseable amount → error, not a ¥0 balance", dsBad == nil)

// ── Moonshot / SiliconFlow / OpenRouter ─────────────────────────────────
print("— Moonshot / SiliconFlow / OpenRouter")
let ms = try! MoonshotQuotaAdapter.parse(Data(#"{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"status":true}"#.utf8), host: "api.moonshot.cn", subjectId: sub, now: now)
t("Moonshot .cn → CNY, remaining = available_balance", ms.pools[0].unit == .currency(code: "CNY") && ms.pools[0].amounts?.remaining == dec("49.58894"))
t("Moonshot .ai → USD", MoonshotQuotaAdapter.currency(forHost: "api.moonshot.ai") == "USD")
let sf = try! SiliconFlowQuotaAdapter.parse(Data(#"{"code":20000,"status":true,"data":{"id":"u1","name":"Alice","email":"a@b.c","balance":"0.88","chargeBalance":"88.00","totalBalance":"88.88"}}"#.utf8), host: "api.siliconflow.cn", subjectId: sub, now: now)
t("SiliconFlow remaining = totalBalance 88.88", sf.pools[0].amounts?.remaining == dec("88.88"))
let sfDump = String(data: try! JSONEncoder().encode(sf), encoding: .utf8)!
t("SiliconFlow snapshot keeps no PII (name / email)", !sfDump.contains("Alice") && !sfDump.contains("a@b.c"))

func http(_ status: Int, _ body: String, headers: [String: String] = [:]) -> QuotaHTTPResponse {
    QuotaHTTPResponse(status: status, body: Data(body.utf8), headers: headers)
}
let orSub = QuotaSubjectID(vendor: .openRouter, accountKey: "k")
let orNoLimit = try! OpenRouterQuotaAdapter.combine(
    key: .success(http(200, #"{"data":{"label":"x","limit":null,"usage":3.2,"limit_remaining":null}}"#)),
    credits: .success(http(200, #"{"data":{"total_credits":50,"total_usage":8.5}}"#)), subjectId: orSub, now: now)
t("OpenRouter limit == null → no key-limit pool", !orNoLimit.snapshot.pools.contains { $0.id.rawValue.hasSuffix(":key-limit") })
let credits = orNoLimit.snapshot.pools.first { $0.id.rawValue.hasSuffix(":account-credits") }
t("OpenRouter credits → prepaid remaining 41.5 = total − usage", credits?.amounts?.remaining == dec("41.5") && credits?.kind == .prepaidBalance)
t("both answered → complete", orNoLimit.isComplete)
let orCap = try! OpenRouterQuotaAdapter.combine(
    key: .success(http(200, #"{"data":{"limit":10,"usage":3.2,"limit_remaining":6.8}}"#)),
    credits: .failure(QuotaFetchError(kind: .forbidden, detail: "403", httpStatus: 403)), subjectId: orSub, now: now)
let cap = orCap.snapshot.pools.first { $0.id.rawValue.hasSuffix(":key-limit") }
t("OpenRouter key limit → spendCap 10, remaining 6.8", cap?.kind == .spendCap && cap?.amounts?.total == 10 && cap?.amounts?.remaining == dec("6.8"))
t("credits 403 → partial (incomplete), key pool still delivered", !orCap.isComplete && orCap.partialErrors.first?.kind == .forbidden)
t("spendCap percent computed from limit & remaining: 32%",
  cap?.amounts?.computedUtilization(kind: .spendCap, unlimited: false) == QuotaUtilization(percent: 32, basis: .computed))
t("both fail → the auth error is thrown",
  { do { _ = try OpenRouterQuotaAdapter.combine(key: .failure(QuotaFetchError(kind: .server, detail: "500")),
                                                credits: .failure(QuotaFetchError(kind: .unauthorized, detail: "401")),
                                                subjectId: orSub, now: now); return false }
    catch let e as QuotaFetchError { return e.kind == .unauthorized } catch { return false } }())

// ── Percent derivation ─────────────────────────────────────────────────
print("— Percent derivation")
t("prepaid balance → no percent, even with total",
  QuotaAmounts(total: 100, remaining: 40).computedUtilization(kind: .prepaidBalance, unlimited: false) == nil)
t("DeepSeek pool status carries no utilization", QuotaStatusRules.poolStatus(cny, now: now).utilization == nil)
t("spendCap total 10 used 3.2 → 32%", QuotaAmounts(total: 10, used: dec("3.2")).computedUtilization(kind: .spendCap, unlimited: false)?.percent == 32)
t("total 0 → no percent (no reliable denominator)", QuotaAmounts(total: 0, used: 0).computedUtilization(kind: .allowance, unlimited: false) == nil)
t("total missing → no percent", QuotaAmounts(used: 5, remaining: 5).computedUtilization(kind: .allowance, unlimited: false) == nil)
t("total but neither used nor remaining → no percent", QuotaAmounts(total: 10).computedUtilization(kind: .allowance, unlimited: false) == nil)
t("unlimited → no percent", QuotaAmounts(total: 10, used: 9).computedUtilization(kind: .spendCap, unlimited: true) == nil)
t("rate limit → no percent", QuotaAmounts(total: 50, used: 48).computedUtilization(kind: .rateLimit, unlimited: false) == nil)
t("reported used fraction 0.81 → 81% (reported)", window("7d", used: "0.81").utilization(poolKind: .usageWindow, unlimited: false) == QuotaUtilization(percent: 81, basis: .reported))
t("reported remaining 0.3 → 70% (complement)", window("5h", remaining: "0.3").utilization(poolKind: .usageWindow, unlimited: false) == QuotaUtilization(percent: 70, basis: .reportedComplement))

// ── Windows side by side, worst wins, never summed ─────────────────────
print("— Multiple windows")
let windowed = pool("primary", kind: .usageWindow, unit: .percentOnly,
                    windows: [window("5h", used: "0.30", resets: now.addingTimeInterval(3600)),
                              window("7d", used: "0.81", resets: now.addingTimeInterval(86400))])
let ws = QuotaStatusRules.poolStatus(windowed, now: now)
t("status decided by the tightest window (7d 81% → low)", ws.status == .low && ws.decidingWindowId == "7d" && ws.utilization?.percent == 81)
t("percent is 81, not 111 (sum) or 55.5 (average)", ws.utilization?.percent != 111 && ws.utilization?.percent != dec("55.5"))
let passed = pool("primary", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "1.0", resets: now.addingTimeInterval(-1))])
t("a window past its reset is expired → unknown, not 'exhausted'", QuotaStatusRules.poolStatus(passed, now: now).status == .unknown)
t("100% → exhausted", QuotaStatusRules.poolStatus(pool("w", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "1")]), now: now).status == .exhausted)

// ── Freshness ──────────────────────────────────────────────────────────
print("— Freshness")
let fp = QuotaFreshnessPolicy()
t("balance 10 min old → fresh", fp.freshness(ofAmountsIn: pool("b", kind: .prepaidBalance, amounts: .init(remaining: 1), at: now.addingTimeInterval(-600)), now: now) == .fresh)
t("balance 2 h old → stale", fp.freshness(ofAmountsIn: pool("b", kind: .prepaidBalance, amounts: .init(remaining: 1), at: now.addingTimeInterval(-7200)), now: now) == .stale)
t("balance 7 h old → expired (numbers hidden)", fp.freshness(ofAmountsIn: pool("b", kind: .prepaidBalance, amounts: .init(remaining: 1), at: now.addingTimeInterval(-25200)), now: now) == .expired)

// ── Refresh gate: 10 min / forced / Retry-After / backoff ───────────────
print("— Refresh gate")
let pol = QuotaRefreshPolicy()
t("never refreshed → allowed", QuotaRefreshGate.decide(nil, now: now, forced: false) == .allowed)
let ok = QuotaRefreshGate.recordSuccess(nil, now: now, forced: false)
t("5 min after success → tooSoon", QuotaRefreshGate.decide(ok, now: now.addingTimeInterval(300), forced: false) == .tooSoon(until: now.addingTimeInterval(600)))
t("10 min after success → allowed", QuotaRefreshGate.decide(ok, now: now.addingTimeInterval(600), forced: false) == .allowed)
t("forced 5 min after success → allowed (bypasses the 10-min cache)", QuotaRefreshGate.decide(ok, now: now.addingTimeInterval(300), forced: true) == .allowed)
// [T-quota-manual-refresh] Only the user's own previous tap debounces the button.
t("manual refresh 10 s after an AUTOMATIC request → allowed", QuotaRefreshGate.decide(ok, now: now.addingTimeInterval(10), forced: true) == .allowed)
let okForced = QuotaRefreshGate.recordSuccess(nil, now: now, forced: true)
t("manual refresh 10 s after a MANUAL one → debounced", QuotaRefreshGate.decide(okForced, now: now.addingTimeInterval(10), forced: true) == .forcedDebounce(until: now.addingTimeInterval(pol.forcedMinInterval)))
t("manual refresh bypasses backoff and the unattended hour",
  QuotaRefreshGate.decide(QuotaRefreshGate.recordFailure(nil, error: QuotaError(kind: .server, detail: "500", httpStatus: 500, at: now), now: now, forced: false),
                          now: now.addingTimeInterval(5), forced: true, attended: false) == .allowed)
let limited = QuotaRefreshGate.recordFailure(ok, error: QuotaError(kind: .rateLimited, detail: "429", httpStatus: 429, at: now, retryAfter: now.addingTimeInterval(1800)), now: now, forced: false)
t("Retry-After binds even a forced refresh", QuotaRefreshGate.decide(limited, now: now.addingTimeInterval(600), forced: true) == .serverCooldown(until: now.addingTimeInterval(1800)))
t("after Retry-After passes → allowed", QuotaRefreshGate.decide(limited, now: now.addingTimeInterval(1801), forced: false) == .allowed)
let f1 = QuotaRefreshGate.recordFailure(nil, error: QuotaError(kind: .server, detail: "500", httpStatus: 500, at: now), now: now, forced: false)
let f2 = QuotaRefreshGate.recordFailure(f1, error: QuotaError(kind: .server, detail: "500", httpStatus: 500, at: now), now: now, forced: false)
t("backoff 5 min then 10 min", f1.nextAllowedAt == now.addingTimeInterval(300) && f2.nextAllowedAt == now.addingTimeInterval(600))
t("backoff reports .backoff, not .tooSoon", QuotaRefreshGate.decide(f1, now: now.addingTimeInterval(30), forced: false) == .backoff(until: now.addingTimeInterval(300)))
// [T-quota-attention-refresh] Unattended (not on screen) → at most hourly.
t("unattended: 10 min after success still too soon, until 1 h",
  QuotaRefreshGate.decide(ok, now: now.addingTimeInterval(600), forced: false, attended: false) == .tooSoon(until: now.addingTimeInterval(3600)))
t("unattended: 1 h after success → allowed", QuotaRefreshGate.decide(ok, now: now.addingTimeInterval(3600), forced: false, attended: false) == .allowed)
t("attended (on screen): the 10-min interval applies", QuotaRefreshGate.decide(ok, now: now.addingTimeInterval(600), forced: false, attended: true) == .allowed)
t("unattended: never refreshed → the first query still runs", QuotaRefreshGate.decide(nil, now: now, forced: false, attended: false) == .allowed)
t("no automatic interval under 5 min for any vendor (success, failure)",
  QuotaVendor.allCases.allSatisfy { QuotaRefreshPolicy.forVendor($0).normalInterval >= 300 && QuotaRefreshPolicy.forVendor($0).backoff.allSatisfy { $0 >= 300 } }
  && pol.unattendedInterval == 3600)
let bad = QuotaRefreshGate.recordFailure(nil, error: QuotaError(kind: .unauthorized, detail: "401", httpStatus: 401, at: now), now: now, forced: false)
t("401 stops automatic refresh", QuotaRefreshGate.decide(bad, now: now.addingTimeInterval(7200), forced: false) == .credentialRejected)
t("401: a forced refresh may retry (after the debounce)", QuotaRefreshGate.decide(bad, now: now.addingTimeInterval(60), forced: true) == .allowed)
let nf = QuotaRefreshGate.recordFailure(nil, error: QuotaError(kind: .notFound, detail: "404", httpStatus: 404, at: now), now: now, forced: false)
t("404 never retried sooner than 10 min", nf.nextAllowedAt == now.addingTimeInterval(600))
t("Retry-After seconds", QuotaHTTP.retryAfter("120", now: now) == now.addingTimeInterval(120))
t("Retry-After HTTP-date", QuotaHTTP.retryAfter("Fri, 15 Jan 2027 08:00:00 GMT", now: now) == QuotaHTTP.httpDate("Fri, 15 Jan 2027 08:00:00 GMT"))
t("Retry-After capped at 1 day", QuotaHTTP.retryAfter("999999", now: now) == now.addingTimeInterval(86400))
t("Retry-After junk → nil", QuotaHTTP.retryAfter("soon", now: now) == nil)
t("HTTP 429 carries Retry-After", QuotaHTTP.error(for: http(429, "", headers: ["retry-after": "60"]), endpoint: "e", now: now)?.retryAfter == now.addingTimeInterval(60))
t("HTTP 401/403/404/503 → kinds", [401, 403, 404, 503].map { QuotaHTTP.error(for: http($0, ""), endpoint: "e", now: now)?.kind } == [.unauthorized, .forbidden, .notFound, .server])

// ── Capability gate: 24 h ──────────────────────────────────────────────
print("— Capability gate")
let key = QuotaCapabilityKey(providerType: "openAI", baseURL: QuotaCapabilityKey.normalize("https://api.deepseek.com/v1/"))
t("capability key normalises base URL (case, trailing /, /v1)", key.baseURL == "https://api.deepseek.com")
let failedRec = QuotaCapabilityRecord(key: key, adapterId: "x", status: .failed, source: nil, confidence: nil, probedAt: now, detail: "HTTP 404")
t("no record → probe", QuotaCapabilityGate.shouldProbe(nil, now: now, userRequested: false))
t("23 h after a failed probe → no probe", !QuotaCapabilityGate.shouldProbe(failedRec, now: now.addingTimeInterval(23 * 3600), userRequested: false))
t("24 h after → probe again", QuotaCapabilityGate.shouldProbe(failedRec, now: now.addingTimeInterval(24 * 3600), userRequested: false))
t("manual refresh re-checks a paused endpoint immediately (even right after an automatic probe)",
  QuotaCapabilityGate.shouldProbe(failedRec, now: now.addingTimeInterval(1), userRequested: true))

// ── Shared pool de-duplication ─────────────────────────────────────────
print("— Shared pools")
let keyA = QuotaAccountKey.derive(from: "sk-test-same-key-000001")
let keyB = QuotaAccountKey.derive(from: "sk-test-same-key-000001")
t("same key on two instances → same subject (queried once)", keyA == keyB && keyA.count == 16)
t("different key → different subject", QuotaAccountKey.derive(from: "sk-test-other-key-00002") != keyA)
t("masked label never contains the key body", QuotaAccountKey.mask("sk-test-same-key-000001") == "sk-…0001")
var pools: [QuotaPoolKey: QuotaPool] = [:]
var bindings: [QuotaPoolBinding] = []
QuotaMerge.ingest(ds, authoritative: true, pools: &pools, bindings: &bindings)
QuotaMerge.ingest(ds, authoritative: true, pools: &pools, bindings: &bindings)   // second instance, same subject
t("ingesting the same account twice keeps each pool once", pools.count == 2 && bindings.count == 2)
let viewA = QuotaModelResolver.view(instanceId: "i1", modelId: "deepseek-chat", subjectId: sub, pools: pools, bindings: bindings, manualBindings: [], now: now)
let viewB = QuotaModelResolver.view(instanceId: "i1", modelId: "deepseek-reasoner", subjectId: sub, pools: pools, bindings: bindings, manualBindings: [], now: now)
t("two models see the SAME pool keys (not copies)", Set(viewA.bound.map(\.poolKey)) == Set(viewB.bound.map(\.poolKey)) && viewA.bound.count == 2)
t("bound as shared, not model-specific", viewA.bound.allSatisfy(\.isShared) && !viewA.hasModelSpecificPool)
t("headline picks one pool, no summed total", QuotaHeadline.pick(Array(pools.values), now: now) != nil)
let dsOnlyCNY = try! DeepSeekQuotaAdapter.parse(Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"99.00"}]}"#.utf8), subjectId: sub, now: now.addingTimeInterval(700))
var p2 = pools, b2 = bindings
QuotaMerge.ingest(dsOnlyCNY, authoritative: false, pools: &p2, bindings: &b2)
t("partial (non-authoritative) fetch keeps the USD pool", p2.count == 2 && p2[cny.id]?.amounts?.remaining == 99)
QuotaMerge.ingest(dsOnlyCNY, authoritative: true, pools: &pools, bindings: &bindings)
t("complete fetch retires the vanished USD pool and its binding", pools.count == 1 && pools[usd.id] == nil && !bindings.contains { $0.poolKey == usd.id })
var wp: [QuotaPoolKey: QuotaPool] = [:], wb: [QuotaPoolBinding] = []
let olderW = UpstreamQuotaSnapshot(id: UUID(), subjectId: sub, provenance: prov, capturedAt: now, serverClockOffset: nil, plan: nil,
    pools: [pool("p", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "0.2", at: now), window("7d", used: "0.5", at: now)])], bindings: [], accountAvailable: nil)
let newer5h = UpstreamQuotaSnapshot(id: UUID(), subjectId: sub, provenance: prov, capturedAt: now, serverClockOffset: nil, plan: nil,
    pools: [pool("p", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "0.4", at: now.addingTimeInterval(60))], at: now.addingTimeInterval(60))], bindings: [], accountAvailable: nil)
QuotaMerge.ingest(olderW, authoritative: false, pools: &wp, bindings: &wb)
QuotaMerge.ingest(newer5h, authoritative: false, pools: &wp, bindings: &wb)
let merged = wp.values.first!
t("windows merge by id: 5h updated, 7d kept", merged.windows.count == 2 && merged.windows.first { $0.id == "5h" }?.reportedUsedFraction == dec("0.4") && merged.windows.first { $0.id == "7d" }?.reportedUsedFraction == dec("0.5"))

// ── Manual mappings ────────────────────────────────────────────────────
print("— Manual mappings")
let m = QuotaManualMapping(id: UUID(), instanceId: "i1", modelId: "my-relay-alias", poolKey: cny.id, note: nil, createdAt: now, updatedAt: now)
t("valid mapping", QuotaMappingRules.validity(m, instanceExists: true, instanceModelIds: ["my-relay-alias"], instanceSubject: sub, pools: pools) == .valid)
t("model removed → modelMissing", QuotaMappingRules.validity(m, instanceExists: true, instanceModelIds: [], instanceSubject: sub, pools: pools) == .modelMissing)
t("key changed (other subject) → poolMissing, never re-pointed", QuotaMappingRules.validity(m, instanceExists: true, instanceModelIds: ["my-relay-alias"], instanceSubject: QuotaSubjectID(vendor: .deepSeek, accountKey: "other"), pools: pools) == .poolMissing)
t("instance deleted → instanceMissing", QuotaMappingRules.validity(m, instanceExists: false, instanceModelIds: ["my-relay-alias"], instanceSubject: sub, pools: pools) == .instanceMissing)
let mb = QuotaMappingRules.binding(for: m)
t("mapping binding carries userManualMapping evidence", mb.evidence == .userManualMapping && mb.target == .model(key: "my-relay-alias"))
let mview = QuotaModelResolver.view(instanceId: "i1", modelId: "my-relay-alias", subjectId: sub, pools: pools, bindings: bindings, manualBindings: [mb], now: now)
t("manual mapping shows as model-specific AND manual", mview.hasModelSpecificPool && mview.bound.first { $0.poolKey == cny.id }?.isManual == true)
var bb = bindings
QuotaMerge.ingest(UpstreamQuotaSnapshot(id: UUID(), subjectId: sub, provenance: prov, capturedAt: now, serverClockOffset: nil, plan: nil,
    pools: [], bindings: [mb], accountAvailable: nil), authoritative: false, pools: &pools, bindings: &bb)
t("an adapter can never inject a userManualMapping binding", bb == bindings)
t("manual rank is the lowest evidence", QuotaPoolBinding.Evidence.userManualMapping.rank < QuotaPoolBinding.Evidence.assumedSubjectWide.rank)

// ── Persistence ────────────────────────────────────────────────────────
print("— Store file")
var file = QuotaStoreFile()
file.pools = Array(pools.values)
file.bindings = bindings
file.mappings = [m]
file.subjects = [QuotaSubject(id: sub, kind: .credential, parent: nil, instanceIds: ["i1", "i2"], accountLabel: "sk-…0001", plan: nil, state: .available, lastRefresh: ok)]
file.capabilities = [failedRec]
file.instanceSubjects = ["i1": sub, "i2": sub]
let data = try! QuotaStoreFile.encode(file)
let json = String(data: data, encoding: .utf8)!
t("round trip is lossless", QuotaStoreFile.decode(data) == file)
t("Decimals are stored as strings", json.contains(#""remaining":"99""#) || json.contains(#""amount":"#))
t("no credential in the file", !json.contains("sk-test-same-key"))
var future = file; future.version = 99
t("future-version file is ignored, not misread", QuotaStoreFile.decode(try! QuotaStoreFile.encode(future)) == nil)
t("garbage file → nil (start empty)", QuotaStoreFile.decode(Data("{".utf8)) == nil)

// ── Vendor detection / fixed host ──────────────────────────────────────
print("— Vendor detection")
func desc(_ kind: QuotaInstanceDescriptor.ProviderKind, oauth: Bool = false, base: String? = nil) -> QuotaInstanceDescriptor {
    QuotaInstanceDescriptor(instanceId: "i", label: "L", providerKind: kind, isOAuth: oauth, isEnabled: true, customBaseURL: base)
}
t("OpenAI-compatible on api.deepseek.com → DeepSeek", QuotaVendorDetector.vendor(for: desc(.openAI, base: "https://api.deepseek.com/v1")) == .deepSeek)
t("Anthropic-format on api.deepseek.com → DeepSeek", QuotaVendorDetector.vendor(for: desc(.anthropic, base: "https://api.deepseek.com/anthropic")) == .deepSeek)
t("unknown relay host → customRelay → relay probe adapter (relay ledger, third party)",
  QuotaAdapterRegistry.adapter(for: desc(.openAI, base: "https://relay.example.com/v1")).capability(for: desc(.openAI, base: "https://relay.example.com/v1")) == .activeQuery(source: .relayAccountLedger, confidence: .thirdParty))
t("Codex OAuth → subscription adapter (active usage query, labelled undocumented)",
  QuotaAdapterRegistry.adapter(for: desc(.openAI, oauth: true)).capability(for: desc(.openAI, oauth: true)) == .activeQuery(source: .providerDashboardAPI, confidence: .observedClient))
t("Claude OAuth → subscription adapter (active usage query, labelled undocumented)", QuotaVendorDetector.vendor(for: desc(.anthropic, oauth: true)) == .claudeSubscription
  && QuotaAdapterRegistry.adapter(for: .claudeSubscription).capability(for: desc(.anthropic, oauth: true)) == .activeQuery(source: .providerDashboardAPI, confidence: .observedClient))
t("OpenRouter type → OpenRouter active adapter", QuotaAdapterRegistry.adapter(for: desc(.openRouter)).capability(for: desc(.openRouter)).active)
t("xAI → vendorHasNoQuotaAPI", QuotaAdapterRegistry.adapter(for: desc(.xAI)).capability(for: desc(.xAI)) == .unsupported(.vendorHasNoQuotaAPI))

final class FakeTransport: QuotaHTTPTransport, @unchecked Sendable {
    var urls: [URL] = []
    var bearers: [String] = []
    let body: String
    init(_ body: String) { self.body = body }
    var sentHeaders: [[String: String]] = []
    func get(_ url: URL, bearer: String, headers: [String: String]) async throws -> QuotaHTTPResponse {
        urls.append(url); bearers.append(bearer); sentHeaders.append(headers)
        return QuotaHTTPResponse(status: 200, body: Data(body.utf8), headers: [:])
    }
}
let fake = FakeTransport(dsJSON)
let sem = DispatchSemaphore(value: 0)
var fetched: QuotaFetchOutcome?
Task {
    fetched = try? await DeepSeekQuotaAdapter().fetch(QuotaFetchContext(
        descriptor: desc(.openAI, base: "https://api.deepseek.com/some/custom/path"), subjectId: sub,
        credential: "sk-secret", transport: fake, now: now))
    sem.signal()
}
sem.wait()
t("DeepSeek request goes to the fixed official URL, not the custom path", fake.urls == [URL(string: "https://api.deepseek.com/user/balance")!])
t("one request returns both currencies (one snapshot)", fake.urls.count == 1 && fetched?.snapshot.pools.count == 2)
t("bearer credential passed to the transport only", fake.bearers == ["sk-secret"])

// ── Claude subscription (OAuth): active + passive into the same pools ──
print("— Claude subscription")
let csub = QuotaSubjectID(vendor: .claudeSubscription, accountKey: "instance:abc")
let claudeJSON = #"{"five_hour":{"utilization":6.0,"resets_at":"2026-09-27T16:59:59.943648+00:00"},"seven_day":{"utilization":35.5,"resets_at":"2026-10-01T03:59:59+00:00"},"seven_day_opus":{"utilization":80.0,"resets_at":null},"seven_day_oauth_apps":null,"extra_usage":{"is_enabled":false}}"#
let cu = try! ClaudeSubscriptionQuotaAdapter.parseUsage(Data(claudeJSON.utf8), subjectId: csub, now: now)
let cMain = cu.pools.first { $0.id.rawValue.hasSuffix(":subscription") }
t("API: five_hour / seven_day → pool 'subscription' with windows 5h, 7d", cMain.map { Set($0.windows.map(\.id)) == ["5h", "7d"] } == true)
t("API utilization is percent → stored as fraction (6% → 0.06)", cMain?.windows.first { $0.id == "5h" }?.reportedUsedFraction == dec("0.06"))
t("API resets_at with fractional seconds parsed", cMain?.windows.first { $0.id == "5h" }?.resetsAt != nil)
let cOpus = cu.pools.first { $0.id.rawValue.hasSuffix(":model:opus") }
t("seven_day_opus → model pool bound to claude-opus* (named upstream)",
  cOpus != nil && cu.bindings.contains { $0.poolKey == cOpus!.id && $0.target == .modelFamily(pattern: "claude-opus*") && $0.evidence == .explicitUpstream })
t("null window (seven_day_oauth_apps) skipped, extra_usage ignored", cu.pools.count == 2)
t("source is dashboard API / observed client, not 'official API'", cu.provenance.source == .providerDashboardAPI && cu.provenance.confidence == .observedClient)
t("empty usage body → unsupportedResponse",
  { do { _ = try ClaudeSubscriptionQuotaAdapter.parseUsage(Data("{}".utf8), subjectId: csub, now: now); return false }
    catch let e as QuotaFetchError { return e.kind == .unsupportedResponse } catch { return false } }())
let ch = ClaudeSubscriptionQuotaAdapter.parseHeaders([
    "Anthropic-Ratelimit-Unified-Status": "allowed_warning",
    "anthropic-ratelimit-unified-5h-utilization": "0.42",
    "anthropic-ratelimit-unified-5h-reset": "1800003600",
    "anthropic-ratelimit-unified-5h-status": "allowed",
    "anthropic-ratelimit-unified-7d-utilization": "0.91",
    "anthropic-ratelimit-unified-7d-reset": "1800500000",
    "anthropic-ratelimit-unified-representative-claim": "five_hour",
    "anthropic-ratelimit-requests-remaining": "49"], subjectId: csub, now: now.addingTimeInterval(60))
let chMain = ch?.pools.first
t("headers: same pool key as the API ('subscription')", chMain?.id == cMain?.id)
t("headers: fractions kept (0.42), windows 5h / 7d, epoch reset", chMain.map { $0.windows.first { $0.id == "5h" }?.reportedUsedFraction == dec("0.42") && Set($0.windows.map(\.id)) == ["5h", "7d"] && $0.windows.first { $0.id == "5h" }?.resetsAt == Date(timeIntervalSince1970: 1800003600) } == true)
t("headers: overall allowed_warning → pool verdict warning", chMain?.verdict == .warning)
t("headers: source official response headers", ch?.provenance.source == .officialHeaders)
t("headers without unified windows → nil (no fake data)", ClaudeSubscriptionQuotaAdapter.parseHeaders(["anthropic-ratelimit-requests-remaining": "49"], subjectId: csub, now: now) == nil)
t("a header value in percent form (35) is read as 0.35, not 35×", ClaudeSubscriptionQuotaAdapter.fraction(35, isPercent: false) == dec("0.35"))
var cp: [QuotaPoolKey: QuotaPool] = [:], cb: [QuotaPoolBinding] = []
QuotaMerge.ingest(cu, authoritative: true, pools: &cp, bindings: &cb)
QuotaMerge.ingest(ch!, authoritative: false, pools: &cp, bindings: &cb)
let merged5h = cp[cMain!.id]?.windows.first { $0.id == "5h" }
t("passive after active: newer header value wins per window (0.42), opus pool kept", merged5h?.reportedUsedFraction == dec("0.42") && cp.count == 2)
t("Claude window status: 7d 91% → low (model view sees it)", QuotaStatusRules.poolStatus(cp[cMain!.id]!, now: now.addingTimeInterval(60)).status == .low)
let fakeC = FakeTransport(claudeJSON)
let semC = DispatchSemaphore(value: 0)
Task {
    var ctx = QuotaFetchContext(descriptor: desc(.anthropic, oauth: true), subjectId: csub, credential: "oauth-token",
                                transport: fakeC, now: now)
    ctx.extraHeaders = ["User-Agent": "claude-cli/x"]
    _ = try? await ClaudeSubscriptionQuotaAdapter().fetch(ctx)
    semC.signal()
}
semC.wait()
t("Claude active query: fixed URL, oauth beta header, CLI headers passed", fakeC.urls == [URL(string: "https://api.anthropic.com/api/oauth/usage")!] && fakeC.sentHeaders.first?["anthropic-beta"] == "oauth-2025-04-20" && fakeC.sentHeaders.first?["User-Agent"] == "claude-cli/x")
t("Claude OAuth instance → active adapter; API-key Anthropic stays unsupported",
  QuotaAdapterRegistry.adapter(for: desc(.anthropic, oauth: true)).capability(for: desc(.anthropic, oauth: true)).active
  && !QuotaAdapterRegistry.adapter(for: desc(.anthropic)).capability(for: desc(.anthropic)).active)

// ── Codex subscription ────────────────────────────────────────────────
print("— Codex subscription")
let xsub = QuotaSubjectID(vendor: .codexSubscription, accountKey: "instance:cdx")
let codexJSON = #"{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1800003600},"secondary_window":{"used_percent":81,"limit_window_seconds":604800,"reset_at":1800500000}},"credits":{"has_credits":true,"unlimited":false,"balance":"12.5"},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000}}}]}"#
let xu = try! CodexSubscriptionQuotaAdapter.parseUsage(Data(codexJSON.utf8), subjectId: xsub, now: now)
let xMain = xu.pools.first { $0.id.rawValue.hasSuffix(":codex") }
t("wham/usage: primary 18000 s → 5h, secondary 604800 s → 7d", xMain.map { Set($0.windows.map(\.id)) == ["5h", "7d"] } == true)
t("wham/usage: used_percent 42 → fraction 0.42, reset_at epoch", xMain?.windows.first { $0.id == "5h" }.map { $0.reportedUsedFraction == dec("0.42") && $0.resetsAt == Date(timeIntervalSince1970: 1800003600) } == true)
let spark2 = xu.pools.first { $0.id.rawValue.contains(":model:") }
t("additional_rate_limits → model pool bound to that model (explicitUpstream)",
  spark2 != nil && xu.bindings.contains { $0.poolKey == spark2!.id && $0.target == .model(key: "gpt-5.3-codex-spark") && $0.evidence == .explicitUpstream })
let xCredits = xu.pools.first { $0.id.rawValue.hasSuffix(":credits") }
t("credits → prepaid pool in credits (no percent)", xCredits?.unit == .credits(name: nil) && xCredits?.amounts?.remaining == dec("12.5") && xCredits?.kind == .prepaidBalance)
t("plan_type kept", xu.plan?.rawId == "plus")
let xh = CodexSubscriptionQuotaAdapter.parseHeaders([
    "x-codex-primary-used-percent": "55.0", "x-codex-primary-window-minutes": "300", "x-codex-primary-reset-after-seconds": "1200",
    "X-Codex-Secondary-Used-Percent": "83", "x-codex-secondary-window-minutes": "10080", "x-codex-secondary-reset-at": "1800600000"],
    subjectId: xsub, now: now)
t("Codex headers: same pool key as the API, windows 5h / 7d", xh?.pools.first?.id == xMain?.id && Set(xh?.pools.first?.windows.map(\.id) ?? []) == ["5h", "7d"])
t("Codex headers: reset-after-seconds relative to now", xh?.pools.first?.windows.first { $0.id == "5h" }?.resetsAt == now.addingTimeInterval(1200))
t("Codex headers without used-percent → nil", CodexSubscriptionQuotaAdapter.parseHeaders(["x-codex-primary-window-minutes": "300"], subjectId: xsub, now: now) == nil)
t("window id: 300 → 5h, 10080 → 7d, 1440 → 1d, 90 → 90m",
  [300, 10080, 1440, 90].map(CodexSubscriptionQuotaAdapter.windowId(minutes:)) == ["5h", "7d", "1d", "90m"])
t("Codex OAuth instance → active adapter", QuotaAdapterRegistry.adapter(for: desc(.openAI, oauth: true)).capability(for: desc(.openAI, oauth: true)).active)

// ── 5-minute window across both sources (product decision) ────────────
print("— Subscription refresh window")
let sp = QuotaRefreshPolicy.forVendor(.claudeSubscription)
t("subscriptions use a 5-minute window; others keep 10", sp.normalInterval == 300 && QuotaRefreshPolicy.forVendor(.codexSubscription).normalInterval == 300 && QuotaRefreshPolicy.forVendor(.deepSeek).normalInterval == 600)
t("no data yet → initial query allowed", QuotaRefreshGate.decide(nil, now: now, forced: false, policy: sp) == .allowed)
let obs = QuotaRefreshGate.recordObservation(nil, now: now, policy: sp)
t("unattended subscription: a header update restarts the hour",
  QuotaRefreshGate.decide(obs, now: now.addingTimeInterval(1800), forced: false, policy: sp, attended: false) == .tooSoon(until: now.addingTimeInterval(3600)))
t("header update 4 min ago → scheduled query skipped", !QuotaRefreshGate.decide(obs, now: now.addingTimeInterval(240), forced: false, policy: sp).isAllowed)
t("header update 5 min ago → scheduled query runs", QuotaRefreshGate.decide(obs, now: now.addingTimeInterval(300), forced: false, policy: sp) == .allowed)
let activeOK = QuotaRefreshGate.recordSuccess(nil, now: now, forced: false, policy: sp)
let obsLater = QuotaRefreshGate.recordObservation(activeOK, now: now.addingTimeInterval(200), policy: sp)
t("an observation after an active query pushes the next query to 5 min after the observation",
  !QuotaRefreshGate.decide(obsLater, now: now.addingTimeInterval(400), forced: false, policy: sp).isAllowed
  && QuotaRefreshGate.decide(obsLater, now: now.addingTimeInterval(500), forced: false, policy: sp) == .allowed)
let cooled = QuotaRefreshGate.recordFailure(nil, error: QuotaError(kind: .rateLimited, detail: "429", httpStatus: 429, at: now, retryAfter: now.addingTimeInterval(3600)), now: now, forced: false, policy: sp)
let cooledObs = QuotaRefreshGate.recordObservation(cooled, now: now.addingTimeInterval(60), policy: sp)
t("an observation never lifts a server Retry-After", QuotaRefreshGate.decide(cooledObs, now: now.addingTimeInterval(1000), forced: true, policy: sp) == .serverCooldown(until: now.addingTimeInterval(3600)))
t("manual refresh still bypasses the window (after the 30 s debounce)", QuotaRefreshGate.decide(obs, now: now.addingTimeInterval(60), forced: true, policy: sp) == .allowed)
t("subscription usage endpoint 401/403 → endpoint paused (24 h), not re-armed by headers",
  QuotaCapabilityRules.failureDisablesEndpoint(.forbidden, vendor: .claudeSubscription) && QuotaCapabilityRules.failureDisablesEndpoint(.unauthorized, vendor: .codexSubscription))
t("… but for a balance API a 401 is the key's problem, not the endpoint's", !QuotaCapabilityRules.failureDisablesEndpoint(.unauthorized, vendor: .deepSeek) && QuotaCapabilityRules.failureDisablesEndpoint(.notFound, vendor: .deepSeek))

// ── Official usage pages / MiMo ────────────────────────────────────────
print("— Console links")
func link(_ d: QuotaInstanceDescriptor) -> String? { QuotaConsoleLink.url(for: d)?.absoluteString }
t("ChatGPT (Codex OAuth) → Codex usage analytics", link(desc(.openAI, oauth: true)) == "https://chatgpt.com/codex/cloud/settings/analytics#usage")
t("Claude OAuth → claude.ai/settings/usage", link(desc(.anthropic, oauth: true)) == "https://claude.ai/settings/usage")
t("Anthropic API key → console billing", link(desc(.anthropic)) == "https://console.anthropic.com/settings/billing")
t("OpenAI API key → platform usage", link(desc(.openAI)) == "https://platform.openai.com/usage")
t("DeepSeek (any protocol on api.deepseek.com) → platform usage", link(desc(.anthropic, base: "https://api.deepseek.com/anthropic")) == "https://platform.deepseek.com/usage")
t("Moonshot .cn / .ai → their own console", link(desc(.openAI, base: "https://api.moonshot.cn/v1")) == "https://platform.moonshot.cn/console/account" && link(desc(.openAI, base: "https://api.moonshot.ai/v1")) == "https://platform.moonshot.ai/console/account")
t("Kimi Code → kimi.com/code", link(desc(.kimiCode)) == "https://www.kimi.com/code")
t("OpenRouter → credits page", link(desc(.openRouter)) == "https://openrouter.ai/settings/credits")
t("Xiaomi MiMo host → own vendor, no API-key balance, console link",
  QuotaVendorDetector.vendor(for: desc(.openAI, base: "https://api.xiaomimimo.com/v1")) == .xiaomiMiMo
  && QuotaAdapterRegistry.adapter(for: .xiaomiMiMo).capability(for: desc(.openAI)) == .unsupported(.vendorHasNoQuotaAPI)
  && link(desc(.openAI, base: "https://api.xiaomimimo.com/v1")) == "https://platform.xiaomimimo.com/console/plan-manage")
t("unknown relay → no link (never built from a user URL)", link(desc(.openAI, base: "https://relay.example.com/v1")) == nil)

// ── Relays: probe by data structure (sub2api / New API / billing) ─────
print("— Relay probe")
final class RouteTransport: QuotaHTTPTransport, @unchecked Sendable {
    var routes: [String: (Int, String)]
    var hits: [String] = []
    init(_ routes: [String: (Int, String)]) { self.routes = routes }
    func get(_ url: URL, bearer: String, headers: [String: String]) async throws -> QuotaHTTPResponse {
        hits.append(url.absoluteString)
        let (code, body) = routes[url.path] ?? (404, "404 page not found")
        return QuotaHTTPResponse(status: code, body: Data(body.utf8), headers: [:])
    }
}
let rsub = QuotaSubjectID(vendor: .customRelay, accountKey: "k")
func runRelay(_ t: RouteTransport, base: String = "https://relay.example.com/v1", hint: RelayKind? = nil) -> Result<QuotaFetchOutcome, QuotaFetchError> {
    let sem = DispatchSemaphore(value: 0)
    var out: Result<QuotaFetchOutcome, QuotaFetchError> = .failure(QuotaFetchError(kind: .network, detail: "none"))
    Task {
        var ctx = QuotaFetchContext(descriptor: desc(.openAI, base: base), subjectId: rsub, credential: "sk-relay", transport: t, now: now)
        ctx.relayKindHint = hint
        do { out = .success(try await RelayQuotaAdapter().fetch(ctx)) }
        catch let e as QuotaFetchError { out = .failure(e) } catch {}
        sem.signal()
    }
    sem.wait()
    return out
}
let sub2Wallet = #"{"isValid":true,"balance":12.34,"usage":{"total":{"actual_cost":3.2}}}"#
let t1 = RouteTransport(["/v1/usage": (200, sub2Wallet)])
if case .success(let o) = runRelay(t1) {
    t("Sub2API detected by isValid on /v1/usage (1 request)", o.relayKind == .sub2api && t1.hits == ["https://relay.example.com/v1/usage"])
    t("Sub2API wallet → prepaid USD 12.34, labelled relay ledger / third party",
      o.snapshot.pools.first?.amounts?.remaining == dec("12.34") && o.snapshot.pools.first?.unit == .currency(code: "USD")
      && o.snapshot.provenance.source == .relayAccountLedger && o.snapshot.provenance.confidence == .thirdParty
      && o.snapshot.provenance.relayHost == "relay.example.com")
} else { t("Sub2API wallet probe", false) }
let newAPI = #"{"code":true,"message":"ok","data":{"object":"token_usage","name":"Default Token","total_granted":1000000,"total_used":250000,"total_available":750000,"unlimited_quota":false,"expires_at":0}}"#
let t2 = RouteTransport(["/api/usage/token": (200, newAPI)])
if case .success(let o) = runRelay(t2) {
    let p = o.snapshot.pools.first!
    t("/v1/usage 404 → New API detected on /api/usage/token (2 requests)", o.relayKind == .newAPI && t2.hits.count == 2)
    t("New API: quota units kept (no $ conversion), 25% used computed", p.unit == .custom(name: "quota") && p.amounts?.total == 1000000 && QuotaBarRules.poolFraction(p).map { abs($0 - 0.25) < 1e-9 } == true)
} else { t("New API probe", false) }
let html = "<!doctype html><html><body>SPA</body></html>"
let billingSub = #"{"object":"billing_subscription","hard_limit_usd":50,"has_payment_method":true}"#
let billingUse = #"{"object":"list","total_usage":1234}"#
let t3 = RouteTransport(["/v1/usage": (200, html), "/api/usage/token": (200, html),
                         "/v1/dashboard/billing/subscription": (200, billingSub), "/v1/dashboard/billing/usage": (200, billingUse)])
if case .success(let o) = runRelay(t3) {
    let p = o.snapshot.pools.first!
    t("SPA HTML (200) is not mistaken for a relay → OpenAI billing detected", o.relayKind == .openAIBilling)
    t("billing: hard limit $50, used 1234 cents = $12.34, spend cap", p.kind == .spendCap && p.amounts?.total == 50 && p.amounts?.used == dec("12.34") && p.amounts?.remaining == dec("37.66"))
} else { t("billing probe", false) }
let t3b = RouteTransport(["/v1/dashboard/billing/subscription": (200, #"{"hard_limit_usd":100000000}"#), "/v1/dashboard/billing/usage": (200, billingUse)])
if case .success(let o) = runRelay(t3b) { t("hard_limit_usd 1e8 → unlimited, no fake cap", o.snapshot.pools.first?.unlimited == true && o.snapshot.pools.first?.amounts?.total == nil) } else { t("sentinel", false) }
let t4 = RouteTransport([:])
if case .failure(let e) = runRelay(t4) {
    t("CLIProxyAPI-like (nothing answers) → notFound, lists what was checked",
      e.kind == .notFound && e.detail.contains("/v1/usage") && e.detail.contains("/api/usage/token") && e.detail.contains("/v1/dashboard/billing/subscription"))
} else { t("none found", false) }
let t5 = RouteTransport(["/v1/usage": (401, "{}"), "/api/usage/token": (401, "{}"), "/v1/dashboard/billing/subscription": (401, "{}")])
if case .failure(let e) = runRelay(t5) { t("every family refuses the key → unauthorized (not 'no endpoint')", e.kind == .unauthorized) } else { t("all 401", false) }
let t6 = RouteTransport(["/api/usage/token": (200, newAPI), "/v1/usage": (200, sub2Wallet)])
if case .success(let o) = runRelay(t6, hint: .newAPI) { t("a known type skips the probe: one request to its endpoint", o.relayKind == .newAPI && t6.hits == ["https://relay.example.com/api/usage/token"]) } else { t("hint", false) }
let t7 = RouteTransport(["/api/usage/token": (401, "{}")])
if case .failure(let e) = runRelay(t7, hint: .newAPI) { t("a known type that refuses reports that error (no re-probe storm)", e.kind == .unauthorized && t7.hits.count == 1) } else { t("hint error", false) }
let t8 = RouteTransport(["/gw/v1/usage": (200, sub2Wallet)])
if case .success(let o) = runRelay(t8, base: "https://relay.example.com/gw/v1/") { t("root keeps a path prefix, drops the trailing /v1", o.relayKind == .sub2api && t8.hits == ["https://relay.example.com/gw/v1/usage"]) } else { t("prefix", false) }
let quotaLimited = try! RelayQuotaAdapter.parseSub2API(Data(#"{"isValid":true,"mode":"quota_limited","quota":{"limit":20,"remaining":5,"used":15}}"#.utf8), subjectId: rsub, relayHost: "r", now: now)
t("Sub2API quota_limited → spend cap 15 of 20 (75%)", quotaLimited.pools.first.map { $0.kind == .spendCap && QuotaBarRules.poolFraction($0).map { abs($0 - 0.75) < 1e-9 } == true } == true)
let subUnlimited = try! RelayQuotaAdapter.parseSub2API(Data(#"{"isValid":true,"remaining":-1,"usage":{"total":{"actual_cost":2}}}"#.utf8), subjectId: rsub, relayHost: "r", now: now)
t("Sub2API subscription remaining -1 → unlimited", subUnlimited.pools.first?.unlimited == true)
t("relay capability: active only with a custom base URL", RelayQuotaAdapter().capability(for: desc(.openAI, base: "https://r.example.com/v1")).active && !RelayQuotaAdapter().capability(for: desc(.openAI)).active)
t("relay type ↔ capability record id round trip", RelayKind.allCases.allSatisfy { RelayKind.from(adapterId: $0.adapterId) == $0 } && RelayKind.from(adapterId: "deepseek.balance") == nil)

// ── Nav bar yellow dot: quota low ──────────────────────────────────────
print("— Quota low (yellow dot)")
func lowView(_ ps: [QuotaPool], model: String = "m") -> (ModelQuotaView, [QuotaPoolKey: QuotaPool]) {
    let dict = Dictionary(uniqueKeysWithValues: ps.map { ($0.id, $0) })
    let binds = ps.map { QuotaPoolBinding(poolKey: $0.id, target: .subject, evidence: .vendorDocumented) }
    return (QuotaModelResolver.view(instanceId: "i", modelId: model, subjectId: sub, pools: dict, bindings: binds, manualBindings: [], now: now), dict)
}
func isLow(_ ps: [QuotaPool]) -> Bool { let (v, d) = lowView(ps); return QuotaLowRules.isLow(v, pools: d) }
t("window 91% used (9% left) → low", isLow([pool("w", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "0.91")])]))
t("window 89% used (11% left) → not low", !isLow([pool("w", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "0.89")])]))
t("prepaid $0.99 → low; $1.00 → not low",
  isLow([pool("b", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: dec("0.99")))])
  && !isLow([pool("b", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: 1))]))
t("prepaid ¥7.00 → low (fixed 7.2 CNY/USD); ¥7.50 → not low",
  isLow([pool("b", kind: .prepaidBalance, unit: .currency(code: "CNY"), amounts: .init(remaining: 7))])
  && !isLow([pool("b", kind: .prepaidBalance, unit: .currency(code: "CNY"), amounts: .init(remaining: dec("7.5")))]))
t("DeepSeek ¥36 + $0 in two currency pools → judged together, not low",
  !isLow([pool("b:cny", kind: .prepaidBalance, unit: .currency(code: "CNY"), amounts: .init(remaining: 36)),
          pool("b:usd", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: 0))]))
t("spend cap with $0.50 left → low", isLow([pool("c", kind: .spendCap, unit: .currency(code: "USD"), amounts: .init(total: 10, remaining: dec("0.5")))]))
t("verdict rejected (DeepSeek is_available false) → low", isLow([pool("b", kind: .prepaidBalance, unit: .currency(code: "CNY"), amounts: .init(remaining: 100), verdict: .rejected)]))
t("unknown currency / credits never judged by amount", !isLow([pool("b", kind: .prepaidBalance, unit: .credits(name: nil), amounts: .init(remaining: dec("0.1")))]))
t("no data → never low (stays green)", !QuotaLowRules.isLow(.empty(instanceId: "i", modelKey: "m"), pools: [:]))
t("expired data → not low (not trusted)", !isLow([pool("b", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: dec("0.1")), at: now.addingTimeInterval(-86400))]))
t("unlimited pool → not low", { var p = pool("u", kind: .spendCap, unit: .currency(code: "USD"), amounts: .init(remaining: 0)); p.unlimited = true; return !isLow([p]) }())

// ── Percent shown as usage; tag levels ─────────────────────────────────
print("— Usage wording and tag levels")
t("every percent reads as usage", QuotaFormat.percentUsedText(44) == "44% used" && QuotaFormat.percentUsedText(dec("4.25")) == "4.3% used")
t("Codex (used_percent) and Claude (utilization) are stored the same way: used",
  xu.pools.first { $0.id.rawValue.hasSuffix(":codex") }?.windows.first { $0.id == "5h" }?.reportedUsedFraction == dec("0.42")
  && cu.pools.first { $0.id.rawValue.hasSuffix(":subscription") }?.windows.first { $0.id == "5h" }?.reportedUsedFraction == dec("0.06"))
t("95% used → low, from either vendor", { let p = pool("x", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "0.95")])
    return QuotaLevelRules.level([(QuotaStatusRules.poolStatus(p, now: now), p)]) == .low }())
t("a vendor that reports a REMAINING fraction (5% left) is judged the same (low)",
  { let p = pool("r", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", remaining: "0.05")])
    return QuotaLevelRules.level([(QuotaStatusRules.poolStatus(p, now: now), p)]) == .low }())
func lvl(_ ps: [QuotaPool]) -> QuotaLevel { ps.isEmpty ? .normal : QuotaLevelRules.level(ps.map { (QuotaStatusRules.poolStatus($0, now: now), $0) }) }
t("tag: 50% used → normal (gray)", lvl([pool("w", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "0.5")])]) == .normal)
t("tag: 100% used → depleted (red)", lvl([pool("w", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "1")])]) == .depleted)
t("tag: $0.50 prepaid → low (yellow); $0 → depleted (red); -$2 → depleted",
  lvl([pool("b", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: dec("0.5")))]) == .low
  && lvl([pool("b", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: 0))]) == .depleted
  && lvl([pool("b", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: -2))]) == .depleted)
t("tag: ¥36 + $0 (one account) → normal, not red", lvl([pool("b:cny", kind: .prepaidBalance, unit: .currency(code: "CNY"), amounts: .init(remaining: 36)), pool("b:usd", kind: .prepaidBalance, unit: .currency(code: "USD"), amounts: .init(remaining: 0))]) == .normal)
t("tag: relay quota units at 0 → depleted; credits at 5 → normal (no $ threshold)",
  lvl([pool("q", kind: .allowance, unit: .custom(name: "quota"), amounts: .init(total: 100, used: 100, remaining: 0))]) == .depleted
  && lvl([pool("c", kind: .prepaidBalance, unit: .credits(name: nil), amounts: .init(remaining: 5))]) == .normal)
t("dot and tags share one rule (isLow == level != normal)", QuotaLowRules.isLow(.empty(instanceId: "i", modelKey: "m"), pools: [:]) == false)

// ── Single flight ──────────────────────────────────────────────────────
print("— Single flight")
let sem2 = DispatchSemaphore(value: 0)
var calls = 0
var results: [Int] = []
Task { @MainActor in
    let sf = QuotaSingleFlight<String, Int>()
    async let a = sf.run("subject") { calls += 1; try? await Task.sleep(nanoseconds: 50_000_000); return 7 }
    async let b = sf.run("subject") { calls += 1; return 8 }
    results = await [a, b]
    let c = await sf.run("subject") { calls += 1; return 9 }
    results.append(c)
    sem2.signal()
}
while sem2.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
t("concurrent same-key calls share one execution", results.prefix(2).allSatisfy { $0 == 7 })
t("after it finishes a new call runs again", results.last == 9 && calls == 2)

// ── Picker hints (P2) ──────────────────────────────────────────────────
print("— Picker hints")
func oldPoolForTest() -> QuotaPool { pool("old", kind: .prepaidBalance, unit: .currency(code: "CNY"), amounts: .init(remaining: 5), at: now.addingTimeInterval(-86400)) }
func oldPoolKeyForTest() -> QuotaPoolKey { oldPoolForTest().id }
let okDS = QuotaModelResolver.view(instanceId: "i1", modelId: "deepseek-chat", subjectId: sub, pools: pools, bindings: bindings, manualBindings: [], now: now)
t("healthy shared balance → no model-row warning hint (no green)", QuotaPickerHintRules.modelRow(okDS) == nil)
t("no data → no hint", QuotaPickerHintRules.modelRow(.empty(instanceId: "i", modelKey: "m")) == nil)
let hsub = QuotaSubjectID(vendor: .codexSubscription, accountKey: "h")
let shared5h = pool("primary", kind: .usageWindow, unit: .percentOnly, windows: [window("7d", used: "0.85")], subject: hsub)
let spark = pool("model:spark", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "0.92")], subject: hsub)
let hp: [QuotaPoolKey: QuotaPool] = [shared5h.id: shared5h, spark.id: spark]
let hb = [QuotaPoolBinding(poolKey: shared5h.id, target: .subject, evidence: .assumedSubjectWide),
          QuotaPoolBinding(poolKey: spark.id, target: .model(key: "gpt-5.3-codex-spark"), evidence: .explicitUpstream)]
let sparkView = QuotaModelResolver.view(instanceId: "c", modelId: "GPT-5.3-Codex-Spark", subjectId: hsub, pools: hp, bindings: hb, manualBindings: [], now: now)
t("model-specific pool is the tightest → hint '5h 92%' on the model row",
  QuotaPickerHintRules.modelRow(sparkView) == .modelSpecific(status: .low, detail: "5h 92%", isManual: false))
let otherView = QuotaModelResolver.view(instanceId: "c", modelId: "gpt-5.5", subjectId: hsub, pools: hp, bindings: hb, manualBindings: [], now: now)
t("only the shared pool is tight → nothing on the provider-section row (header shows it)", QuotaPickerHintRules.modelRow(otherView) == nil)
// Member pill (Model Group rows): own pool first, else account; remaining % or amount.
let sparkPill = QuotaPickerHintRules.memberPill(sparkView, pools: hp)
t("member pill prefers the model's own pool: '92% used', orange",
  sparkPill?.text == "92% used" && sparkPill?.isPercent == true && sparkPill?.isModelSpecific == true && sparkPill?.tone == .caution && sparkPill?.poolKey == spark.id)
let otherPill = QuotaPickerHintRules.memberPill(otherView, pools: hp)
t("no own pool → the account pool: 7d '85% used'", otherPill?.text == "85% used" && otherPill?.isModelSpecific == false && otherPill?.poolKey == shared5h.id)
let dsPill = QuotaPickerHintRules.memberPill(okDS, pools: pools, locale: Locale(identifier: "en_US"))
t("prepaid account → remaining amount with currency, not a percent, neutral tone",
  dsPill.map { !$0.isPercent && $0.text.contains("99") && !$0.text.contains("%") && $0.tone == .normal } == true)
t("no data → no member pill", QuotaPickerHintRules.memberPill(.empty(instanceId: "i", modelKey: "m"), pools: [:]) == nil)
let expiredPools: [QuotaPoolKey: QuotaPool] = [oldPoolKeyForTest(): oldPoolForTest()]
t("expired data → no member pill", QuotaPickerHintRules.memberPill(QuotaModelResolver.view(instanceId: "i", modelId: "m", subjectId: sub, pools: expiredPools, bindings: [QuotaPoolBinding(poolKey: oldPoolKeyForTest(), target: .subject, evidence: .vendorDocumented)], manualBindings: [], now: now), pools: expiredPools) == nil)
let overPool = pool("over", kind: .usageWindow, unit: .percentOnly, windows: [window("5h", used: "1.2")], subject: hsub)
let overView = QuotaModelResolver.view(instanceId: "c", modelId: "x", subjectId: hsub, pools: [overPool.id: overPool], bindings: [QuotaPoolBinding(poolKey: overPool.id, target: .subject, evidence: .assumedSubjectWide)], manualBindings: [], now: now)
t("overage shows the real usage ('120% used') with a red tag",
  QuotaPickerHintRules.memberPill(overView, pools: [overPool.id: overPool]).map { $0.text == "120% used" && $0.level == .depleted } == true)
let manualView = QuotaModelResolver.view(instanceId: "c", modelId: "relay-alias", subjectId: hsub, pools: hp, bindings: hb,
    manualBindings: [QuotaPoolBinding(poolKey: spark.id, target: .model(key: "relay-alias"), evidence: .userManualMapping)], now: now)
t("manually mapped tight pool → hint marked manual", QuotaPickerHintRules.modelRow(manualView) == .modelSpecific(status: .low, detail: "5h 92%", isManual: true))
t("manual mapping pill is marked manual", QuotaPickerHintRules.memberPill(manualView, pools: hp)?.isManual == true)
// [T-quota-composer-hint] Composer placeholder quota segment = the member pill, worded.
let segSpark = QuotaComposerHintRules.segment(sparkView, pools: hp)
// [T-composer-hint-carousel] The quota is its own placeholder line again, so
// it keeps the "used" wording.
t("composer segment: percent pool → 'Quota 92% used', highlight is the pill text",
  segSpark == QuotaComposerHintRules.Segment(text: "Quota 92% used", highlight: "92% used", level: sparkPill!.level))
t("member pill carries the bare used percent; its own text keeps 'used'",
  sparkPill?.usedPercent == 92 && sparkPill?.text == "92% used")
let segDS = QuotaComposerHintRules.segment(okDS, pools: pools, locale: Locale(identifier: "en_US"))
t("composer segment: prepaid → 'Balance <amount>', normal level",
  segDS.map { $0.text == "Balance \($0.highlight)" && $0.highlight.contains("99") && $0.level == .normal } == true)
t("composer segment: no data → nil (line stays context-only)",
  QuotaComposerHintRules.segment(.empty(instanceId: "i", modelKey: "m"), pools: [:]) == nil)
t("composer segment: overage → red level",
  QuotaComposerHintRules.segment(overView, pools: [overPool.id: overPool])?.level == .depleted)
// [T-quota-composer-windows] 5h + 7d on one subscription pool → both, compactly.
let twoWin = pool("subscription", kind: .usageWindow, unit: .percentOnly,
                  windows: [window("7d", used: "0.32"), window("5h", used: "0.14")], subject: hsub)
let twoWinView = QuotaModelResolver.view(instanceId: "c", modelId: "x", subjectId: hsub, pools: [twoWin.id: twoWin],
    bindings: [QuotaPoolBinding(poolKey: twoWin.id, target: .subject, evidence: .assumedSubjectWide)], manualBindings: [], now: now)
let twoSeg = QuotaComposerHintRules.segment(twoWinView, pools: [twoWin.id: twoWin], now: now)
t("composer segment: 5h + 7d shown together, shorter window first: 'Quota 5h 14% / 7d 32% used'",
  twoSeg?.text == "Quota 5h 14% / 7d 32% used" && twoSeg?.highlight == "5h 14% / 7d 32%")
t("composer segment: a single window shows its percent with 'used'",
  QuotaComposerHintRules.segment(overView, pools: [overPool.id: overPool], now: now)?.text == "Quota 120% used")
let prepaidHead = QuotaPickerHintRules.headerText(pool: cny, status: QuotaStatusRules.poolStatus(cny, now: now), locale: Locale(identifier: "en_US"))
t("header shows the balance with its currency, no percent", prepaidHead.map { $0.hasPrefix("Balance ") && $0.contains("110") && !$0.contains("%") } == true)
let oldPool = pool("b", kind: .prepaidBalance, unit: .currency(code: "CNY"), amounts: .init(remaining: 5), at: now.addingTimeInterval(-86400))
t("expired data → no header text", QuotaPickerHintRules.headerText(pool: oldPool, status: QuotaStatusRules.poolStatus(oldPool, now: now)) == nil)

// ── Status → tone, bars (quota badge UI) ───────────────────────────────
print("— Tone and bars")
func ps(_ st: QuotaStatus, _ f: QuotaFreshness = .fresh, pct: Decimal? = nil) -> PoolStatus {
    PoolStatus(status: st, decidingWindowId: nil, utilization: pct.map { QuotaUtilization(percent: $0, basis: .computed) }, freshness: f)
}
t("exhausted → critical (red)", QuotaToneRules.tone(ps(.exhausted)) == .critical)
t("low → caution (orange)", QuotaToneRules.tone(ps(.low, pct: 85)) == .caution)
t("rate limited → caution", QuotaToneRules.tone(ps(.rateLimited)) == .caution)
t("available WITH a reliable percent → healthy (the only green)", QuotaToneRules.tone(ps(.available, pct: 30)) == .healthy)
t("available prepaid balance (no percent) → normal, not green", QuotaToneRules.tone(ps(.available)) == .normal)
t("unknown → muted grey", QuotaToneRules.tone(ps(.unknown)) == .muted)
t("expired data → muted even if it said exhausted", QuotaToneRules.tone(ps(.exhausted, .expired)) == .muted)
t("stale keeps its tone (the view dims it)", QuotaToneRules.tone(ps(.low, .stale, pct: 90)) == .caution)
t("the picker pill never goes green", QuotaToneRules.pillTone(ps(.available, pct: 10)) == .normal && QuotaToneRules.pillTone(ps(.exhausted)) == .critical)
t("DeepSeek balance status → normal tone (no fake health)", QuotaToneRules.tone(QuotaStatusRules.poolStatus(cny, now: now)) == .normal)
t("bar: none for a prepaid balance", QuotaBarRules.poolFraction(cny) == nil)
let capPool = pool("cap", kind: .spendCap, amounts: QuotaAmounts(total: 10, used: dec("3.2")))
t("bar: spend cap 3.2 of 10 → 0.32", QuotaBarRules.poolFraction(capPool).map { abs($0 - 0.32) < 1e-9 } == true)
var unl = capPool; unl.unlimited = true
t("bar: none for an unlimited pool", QuotaBarRules.poolFraction(unl) == nil)
t("bar: none without a total", QuotaBarRules.poolFraction(pool("x", kind: .allowance, amounts: QuotaAmounts(used: 3))) == nil)
t("bar: overage draws full, never beyond", QuotaBarRules.fraction(QuotaUtilization(percent: 150, basis: .reported)) == 1)
t("bar: window 81% → 0.81", QuotaBarRules.windowFraction(window("7d", used: "0.81"), in: windowed).map { abs($0 - 0.81) < 1e-9 } == true)
t("bar: nil utilization → no bar", QuotaBarRules.fraction(nil) == nil)
let noAmounts = pool("n", kind: .prepaidBalance, unit: .currency(code: "CNY"))
t("pill hidden when a pool has nothing to show", QuotaPickerHintRules.headerText(pool: noAmounts, status: QuotaStatusRules.poolStatus(noAmounts, now: now)) == nil)

// ── Formatting ─────────────────────────────────────────────────────────
print("— Formatting")
let en = Locale(identifier: "en_US")
t("prepaid short text is a balance, never a percent",
  QuotaFormat.shortText(pool: cny, status: QuotaStatusRules.poolStatus(cny, now: now), locale: en).map { $0.hasPrefix("Balance ") && !$0.contains("%") } == true)
t("percent under 10 keeps one decimal", QuotaFormat.percent(dec("4.25")) == "4.3%" && QuotaFormat.percent(81) == "81%")

print("HARNESS failures=\(hFailures)")
exit(hFailures == 0 ? 0 : 1)
"""#

do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quota-\(UUID().uuidString)")
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
    check("all quota scenarios pass", rc == 0 && out.contains("HARNESS failures=0"))
} catch {
    check("harness setup: \(error)", false)
}

// MARK: - B. App wiring

print("B. Wiring")
check("store persists under Application Support/Quota, excluded from backup",
      store.contains("appendingPathComponent(\"Quota\", isDirectory: true)") && store.contains("isExcludedFromBackup = true"))
check("store never logs the credential",
      !store.split(separator: "\n").contains { $0.contains("logger.") && ($0.contains("\\(credential") || $0.contains("\\(key)") || $0.contains("\\(token)")) })
check("foreground only: refresh driven by didBecomeActive / willResignActive",
      store.contains("UIApplication.didBecomeActiveNotification") && store.contains("UIApplication.willResignActiveNotification"))
check("10-minute gate and single flight are both used", store.contains("QuotaRefreshGate.decide(") && store.contains("singleFlight.run(subjectId)"))
check("404 / unreadable answer (and a refused subscription endpoint) records a failed capability", store.contains("QuotaCapabilityRules.failureDisablesEndpoint(fe.kind, vendor: subjectId.vendor)"))
let statusIdx = detail.range(of: "// MARK: Status")?.lowerBound
let quotaIdx = detail.range(of: "ProviderQuotaSection(instance: instance, consoleURL:")?.lowerBound
let thinkIdx = detail.range(of: "// MARK: Thinking Rules")?.lowerBound
check("detail page: Quota between Status and Thinking Rules",
      statusIdx != nil && quotaIdx != nil && thinkIdx != nil && statusIdx! < quotaIdx! && quotaIdx! < thinkIdx!)
check("section labels shared pools", section.contains("Text(\"Shared by all models on this account\")"))
check("manual mapping removed from the product: no entry row, list or editor in the quota section",
      !section.contains("Map a model to a quota pool") && !section.contains("QuotaMappingEditor") && !section.contains("QuotaMappingRow"))
check("store starts at launch", app.contains("QuotaStore.shared.start()"))
let oauthHTTP = source("Providers/Anthropic/OAuthHTTPClient.swift")
let openaiProv = source("Providers/OpenAI/OpenAIProvider.swift")
let factory = source("Providers/LLMProviderFactory.swift")
let agentFactory = source("Agent/Chat/AIChatViewModel+ProviderFactory.swift")
check("Claude OAuth replies feed the passive sink (OAuthURLProtocol didReceive response)",
      oauthHTTP.contains("QuotaObservationSink.recordAnthropicResponse(instanceId: quotaInstanceId, response: http)")
      && oauthHTTP.contains("quotaInstanceId = tokenBox.quotaInstanceId"))
check("Codex replies feed the passive sink (streamRaw, errors included)",
      openaiProv.contains("if isCodexOAuth, let http = response as? HTTPURLResponse {\n            QuotaObservationSink.recordCodexResponse(instanceId: quotaInstanceId, response: http)"))
check("both factories tag Claude and Codex OAuth providers with their instance",
      factory.contains("quotaInstanceId: iid") && agentFactory.contains("quotaInstanceId: iid")
      && factory.components(separatedBy: ".quotaInstanceId = iid").count - 1 == 2
      && agentFactory.components(separatedBy: ".quotaInstanceId = iid").count - 1 == 2)
check("subscription subjects keyed by instance (token rotates), token fetched only after the gates",
      store.contains("Self.subscriptionSubject(vendor: adapter.vendor, instanceId: instanceId)")
      && store.contains("guard let credential = await credentialSource() else {"))
check("header observation counts as a refresh (recordObservation) and merges non-authoritatively",
      store.contains("QuotaRefreshGate.recordObservation(subject.lastRefresh, now: now,") && store.contains("QuotaMerge.ingest(snapshot, authoritative: false"))
check("the sink allocates nothing unless the reply carries usage headers",
      store.contains("guard let key = (k as? String)?.lowercased(), key.hasPrefix(\"anthropic-ratelimit-\")"))
let hints = source("Views/Providers/QuotaPickerHints.swift")
let sheet = source("Views/Providers/QuotaDetailSheet.swift")
check("pill: gray capsule in the picker's tag style, with a chevron",
      hints.contains("case .normal: return Color(UIColor.tertiarySystemFill)") && hints.contains("Image(systemName: \"chevron.right\")"))
check("pill colour comes from QuotaToneRules.pillTone (never green)", hints.contains("QuotaToneRules.pillTone(head.status)"))
check("pill is a button that only calls back; no sheet on the header", hints.contains("onTap?()") && !hints.contains(".sheet("))
check("picker hosts the quota detail sheet at list level",
      picker.contains(".sheet(item: $quotaDetailProvider)") && picker.contains("QuotaDetailSheet(instanceId: target.id)")
      && picker.contains("quotaDetailProvider = ProviderEditTarget(id: item.instance.id)"))
check("detail sheet reuses QuotaPoolRow (detailed) and the store", sheet.contains("QuotaPoolRow(pool: pool, status: status, detailed: true)") && sheet.contains("quota.pools(of: sid)"))
check("detail sheet shows source, update time and scope, and no manual-mapping rows",
      sheet.contains("Self.sourceText(pool.provenance)") && sheet.contains("Self.stamp(pool.observedAt)") && sheet.contains("Self.scopeText(binding.target)") && !sheet.contains("quota.mappings("))
check("bars are drawn only from QuotaBarRules (no ad-hoc ProgressView percent)",
      !section.contains("ProgressView(value:") && section.contains("QuotaBarRules.poolFraction(pool)") && section.contains("QuotaBarRules.windowFraction(window, in: pool)"))
check("detail sheet icons use the shared Settings circle badge (BackupActionIcon), no bare glyphs",
      sheet.contains("BackupActionIcon(systemName: \"person.2.fill\", tint: .blue)")
      && !sheet.contains("Image(systemName: binding.target == .subject"))
check("detail sheet shows no key, not even the masked label",
      !sheet.contains("accountLabel") && !sheet.contains("String(localized: \"Key\")"))
check("prepaid card says why there is no percentage", section.contains("Prepaid balance — no total cap, so no percentage is shown."))
let picker = source("Views/Providers/UnifiedModelPicker.swift")
check("picker section header carries the account badge after the provider name",
      picker.contains("QuotaSectionHeaderBadge(instanceId: item.instance.id) {") && (picker.range(of: "QuotaSectionHeaderBadge(instanceId: item.instance.id)")!.lowerBound < picker.range(of: "Spacer(minLength: 8)")!.lowerBound))
check("provider-section model rows use the providerSection hint rule",
      picker.contains("ModelQuotaHintView(instanceId: entry.providerInstanceId,\n                               modelId: entry.baseModel.id)"))
let groupPage = source("Views/Providers/ModelGroupDetailView.swift")
check("picker group rows: member pill right after the name and BEFORE the Active badge",
      { guard let expanded = picker.range(of: "private func expandedEntryRow("),
              let pillR = picker.range(of: "ModelQuotaMemberPill(instanceId: entry.providerInstanceId,", range: expanded.upperBound..<picker.endIndex),
              let nameR = picker.range(of: "Text(entry.model.displayName)", range: expanded.upperBound..<picker.endIndex),
              let badgeR = picker.range(of: "activeBadge", range: pillR.upperBound..<picker.endIndex) else { return false }
        return nameR.lowerBound < pillR.lowerBound && pillR.lowerBound < badgeR.lowerBound }())
check("picker group-row pill opens the provider's quota sheet",
      picker.contains("quotaDetailProvider = ProviderEditTarget(id: entry.providerInstanceId)"))
check("Model Group settings page shows the member pill after the name and hosts the sheet",
      groupPage.contains("ModelQuotaMemberPill(instanceId: entry.providerInstanceId,") && groupPage.contains(".sheet(item: $quotaDetailProviderId)")
      && groupPage.contains("QuotaDetailSheet(instanceId: target.id)"))
check("provider-section rows do NOT get the member pill (they have the header pill)",
      picker.components(separatedBy: "ModelQuotaMemberPill(").count - 1 == 1)
check("member pill tap is borderless (only the capsule takes the tap)", hints.contains(".buttonStyle(.borderless)"))
check("hints sit on the SECOND line, not as trailing controls",
      !picker.contains("quickTestButton(entry)\n                QuotaSection") && !picker.contains("ModelQuotaHintView(instanceId: entry.providerInstanceId,\n                                           modelId: entry.baseModel.id, context: .providerSection)\n\n                Spacer()"))
check("picker appearance refreshes only when due (no Keychain read for a current subject)",
      store.contains("func refreshIfDue(instanceId: String, reason: String)") && hints.contains(".quotaWatch(instanceId: instanceId, reason: \"pickerAppeared\")"))
check("attention: header badge, member pill, nav dot, quota sheet and provider page all watch while on screen",
      hints.contains("reason: \"groupMemberAppeared\")") && hints.contains(".quotaWatch(instanceId: instanceId, reason: \"chatNavBar\")")
      && source("Views/Providers/QuotaDetailSheet.swift").contains(".quotaWatch(instanceId: instanceId, reason: \"detailSheet\")")
      && section.contains(".quotaWatch(instanceId: instance.id, reason: \"detailAppeared\")")
      && !hints.contains(".onAppear { quota.refreshIfDue"))
check("attention: watch starts with beginWatching and ends with endWatching when the task is cancelled",
      hints.contains("quota.beginWatching(instanceId: instanceId, reason: reason)") && hints.contains("quota.endWatching(instanceId: instanceId)")
      && hints.contains("content.task(id: instanceId)"))
check("scheduler: every tick sweeps all instances, attended only while watched; no 30-min recency filter",
      store.contains("attended: isWatched(instance.id)).isAllowed") && store.contains("attended: attended)")
      && !store.contains("recentOnly") && store.contains("guard instanceNotes[instance.id] == nil else { return false }"))
check("no .sheet on the quota Section (a Section inside a Form has no stable sheet host)",
      !section.contains(".sheet("))
check("the detail view no longer hosts a mapping editor, and the store no longer applies mappings",
      !detail.contains("QuotaMappingEditor") && !detail.contains("showQuotaMappingEditor")
      && store.contains("manualBindings: [], now: now") && !store.contains("func addMapping("))
check("a credential change clears 'no key' notes and re-resolves viewed instances",
      store.contains("ProviderConfigStore.shared.$authRevision.dropFirst()") && store.contains("instanceNotes.removeAll()"))
for f in ["QuotaModels.swift", "QuotaRules.swift", "QuotaAdapters.swift", "QuotaPersistence.swift", "QuotaStore.swift", "ProviderQuotaSection.swift", "QuotaPickerHints.swift", "QuotaDetailSheet.swift"] {
    check("\(f) in the app target", pbx.split(separator: "\n").filter { $0.contains(f) }.count == 4)
}

check("console link row in the provider page's quota section, browser hosted by the detail view",
      section.contains("QuotaConsoleLinkRow(url: url) { consoleURL = url }") && !section.contains(".sheet(")
      && detail.contains(".sheet(item: $quotaConsoleURL)") && detail.contains("MinisLinkPreviewView(url: url, browserPool: nil)"))
check("console link in the quota sheet (account section, and for states without pools)",
      sheet.components(separatedBy: "QuotaConsoleLinkRow(url: url) { consoleURL = url }").count - 1 == 2 && sheet.contains(".sheet(item: $consoleURL)"))
check("relay: a type probed < 1 day ago is reused as a hint, otherwise probe",
      store.contains("ctx.relayKindHint = kind") && store.contains("RelayKind.from(adapterId: rec.adapterId)"))
check("relay: detected type recorded on the capability (adapterId relay.<kind>, detail name · path)",
      store.contains("adapterId: outcome.relayKind?.adapterId ?? adapter.adapterId") && store.contains("detail: outcome.relayKind.map"))
check("relay detection shown in the section footer and the quota sheet",
      section.contains("quota.relayDetection(for: instance)") && sheet.contains("quota.relayDetection(for: instance)"))
check("header summary pill: 1 pt vertical padding, drawn 2 pt lower (top level with the name's capitals)",
      hints.contains(".padding(.vertical, 1)\n                    .background(QuotaTagStyle.background(level), in: Capsule())")
      && hints.contains(".offset(y: 2)") && picker.contains("            HStack(spacing: 8) {\n                // [T-picker-provider-edit]"))
check("group-row member pills stay centred on the name's capitals",
      picker.components(separatedBy: ".alignmentGuide(.quotaCapCenter) { $0.quotaCapCenter }").count - 1 == 1
      && groupPage.contains(".alignmentGuide(.quotaCapCenter) { $0.quotaCapCenter }"))
let chatView = chatViewSource()
check("chat nav bar dot: ModelQuotaStatusDot for the current entry (orange / yellow / green)",
      chatView.contains("ModelQuotaStatusDot(isAuthed: isAuthed,") && chatView.contains("let currentEntry = vm.resolveCurrentEntry()")
      && hints.contains("return Self.isLow(instanceId: instanceId, modelId: modelId, quota: quota) ? .yellow : .green")
      && hints.contains("guard isAuthed else { return .orange }"))
check("VoiceOver hears the low-quota state", chatView.contains(", quota low"))
check("picker tags: yellow / red backgrounds by level, header from the whole account",
      hints.contains(".background(QuotaTagStyle.background(level), in: Capsule())")
      && hints.contains(".background(QuotaTagStyle.background(pill.level), in: Capsule())")
      && hints.contains("case .low: return .yellow") && hints.contains("case .depleted: return .red")
      && store.contains("func subjectLevel(instanceId: String"))
check("window rows show usage, no direction attribute left", section.contains("QuotaFormat.percentUsedText(util.percent)") && !section.contains("percentDirection"))
check("model-row member pill: 5 pt sides, 2 pt top/bottom (header pill untouched: 6 / 1 + offset 2)",
      hints.contains(".padding(.horizontal, 5)\n                    .padding(.vertical, 2)\n                    .background(QuotaTagStyle.background(pill.level), in: Capsule())")
      && hints.contains(".padding(.horizontal, 6)\n                    .padding(.vertical, 1)\n                    .background(QuotaTagStyle.background(level), in: Capsule())")
      && hints.contains(".offset(y: 2)"))
do {
    let r = picker.range(of: "private func expandedEntryRow(")!
    let body = String(picker[r.lowerBound..<picker.range(of: "quickTestButton(entry)", range: r.upperBound..<picker.endIndex)!.lowerBound])
    check("group member row: name + tags on one line when they fit, else tags on their own line (ViewThatFits)",
          body.contains("ViewThatFits(in: .horizontal)") && body.contains(".fixedSize(horizontal: true, vertical: false)")
          && body.components(separatedBy: "memberRowTags(entry,").count - 1 == 2)
    check("group member row: the text column takes the free width, no Spacer",
          body.contains(".frame(maxWidth: .infinity, alignment: .leading)") && !body.contains("\n            Spacer()\n"))
    let e = picker.range(of: "private func entryRow(_ entry: ModelEntry)")!
    let ebody = String(picker[e.lowerBound..<picker.range(of: "quickTestButton(entry)", range: e.upperBound..<picker.endIndex)!.lowerBound])
    check("provider-section row: same Spacer fix", ebody.contains(".frame(maxWidth: .infinity, alignment: .leading)") && !ebody.contains("\n                Spacer()\n"))
    check("provider-section row: id + tags on one line when they fit, else the id keeps the width and tags drop below",
          ebody.contains("ViewThatFits(in: .horizontal)")
          && ebody.components(separatedBy: "entryRowSubtitle(entry, traits: traits)").count - 1 == 2
          && ebody.components(separatedBy: "entryRowTags(badges, disabled: disabled)").count - 1 == 2
          && ebody.contains("entryRowSubtitle(entry, traits: traits)\n                                .fixedSize(horizontal: true, vertical: false)"))
}
do {
    let chatModelsSrc = source("Agent/Chat/ChatModels.swift")
    let vmSrc = chatViewModelSource()
    check("composer hint: every ContextUsageHint.make passes the quota part (3 call sites)",
          vmSrc.components(separatedBy: "quota: composerQuotaPart())").count - 1 == 3
          && !vmSrc.contains("generation: contextUsageHintGeneration)"))
    // [T-composer-hint-carousel] The composer shows the quota as its own
    // page after the context one; the voice panel keeps the joined line.
    check("composer hint: the quota is its own page after the context, and joined with ' · ' for the whole line",
          chatModelsSrc.contains("text += \" · \" + quota.text\n            pages.append(Page(text: quota.text, highlights: [quota.highlight], tier: quota.tier))"))
    check("composer hint: both renderers tint the quota figure by its own tier",
          chatModelsSrc.contains("Page(text: quota.text, highlights: [quota.highlight], tier: quota.tier)")
          && source("Views/Chat/ChatInputBar.swift").contains("if let tone = page.tier.highlightColor {")
          && source("Views/Chat/Voice/InlineVoiceInputView.swift").contains("usageTint(for: hint.quotaTier)"))
}
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
