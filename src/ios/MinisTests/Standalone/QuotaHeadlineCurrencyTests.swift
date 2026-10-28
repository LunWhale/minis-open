// [ISS-035] One-line quota choice for multi-currency prepaid balances.
//
// User report (iOS, 2026-09-29): a DeepSeek account registered with a foreign
// email holds a CNY balance and a USD balance. The model picker's DeepSeek
// header read "Balance US$0.00" in red, while the detail sheet showed
// CN¥7.62 available next to US$0.00 exhausted - the account looked empty.
//
// Root cause: QuotaHeadline.pick (picker section header) and the member pill's
// `tightest` (Model Group rows, composer quota page) both take the worst
// status first, so an exhausted currency pool always beat a funded one. The
// account-level dot (QuotaLevelRules.level) already judges money balances
// together, so one screen disagreed with itself.
//
// What this checks, compiled from the shipped sources:
//   A. QuotaHeadline.pick over every case in the task:
//      - USD 0 + CNY 7.62 → CNY (the reported case, from a real
//        /user/balance reply), and the mirror USD funded + CNY 0 → USD;
//      - both exhausted → still exhausted (nothing hidden);
//      - both funded → unchanged choice (stable key order, no FX);
//      - USD low + CNY available → unchanged (low is not dropped);
//      - an exhausted usage window still headlines; a funded one beats the
//        dropped USD pool by the usual window-first rule;
//      - non-currency prepaid (credits) at 0 keeps "worst first";
//      - a vendor-rejected account (verdict .rejected) is never hidden.
//   B. The surfaces that read it: section header text, member pill, composer
//      segment, and that the account-level dot is unchanged.
//
// Standalone: `swift QuotaHeadlineCurrencyTests.swift` (needs swiftc), or
// scripts/ios-unit-tests.sh --no-xctest --standalone 'QuotaHeadline*'.

import Foundation

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
    // Run from the script's own directory as a fallback.
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(rel).path
    if let s = try? String(contentsOfFile: here, encoding: .utf8) { return s }
    fatalError("source not found: \(rel)")
}

let pure = ["Providers/Quota/QuotaModels.swift", "Providers/Quota/QuotaRules.swift",
            "Providers/Quota/QuotaAdapters.swift", "Providers/Quota/QuotaPersistence.swift"].map(source)

print("A/B. Multi-currency prepaid headline (compiled as shipped)")

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
let en = Locale(identifier: "en_US")

func balance(_ cur: String, _ amount: String, verdict: QuotaPool.Verdict? = .allowed) -> QuotaPool {
    QuotaPool(id: QuotaPoolKey(subject: sub, family: "balance", qualifier: cur), subjectId: sub,
              kind: .prepaidBalance, unit: .currency(code: cur), vendorLabel: "\(cur) balance",
              amounts: QuotaAmounts(remaining: dec(amount)), windows: [], verdict: verdict,
              unlimited: false, provenance: prov, observedAt: now)
}
func credits(_ amount: String) -> QuotaPool {
    QuotaPool(id: QuotaPoolKey(subject: sub, family: "credits"), subjectId: sub, kind: .prepaidBalance,
              unit: .credits(name: "points"), vendorLabel: nil, amounts: QuotaAmounts(remaining: dec(amount)),
              windows: [], verdict: nil, unlimited: false, provenance: prov, observedAt: now)
}
func usageWindow(used: String) -> QuotaPool {
    QuotaPool(id: QuotaPoolKey(subject: sub, family: "subscription"), subjectId: sub, kind: .usageWindow,
              unit: .percentOnly, vendorLabel: nil, amounts: nil,
              windows: [QuotaWindow(id: "5h", isRolling: true, reportedUsedFraction: dec(used),
                                    observedAt: now, provenance: prov)],
              verdict: nil, unlimited: false, provenance: prov, observedAt: now)
}
/// The headline's pool qualifier ("USD" / "CNY" / family) and status.
func head(_ pools: [QuotaPool], thresholds: QuotaThresholds = QuotaThresholds()) -> (String, QuotaStatus)? {
    QuotaHeadline.pick(pools, now: now, thresholds: thresholds).map {
        (String($0.pool.id.rawValue.split(separator: ":").last!), $0.status.status)
    }
}
func isHead(_ pools: [QuotaPool], _ name: String, _ status: QuotaStatus,
            thresholds: QuotaThresholds = QuotaThresholds()) -> Bool {
    guard let h = head(pools, thresholds: thresholds) else { return false }
    return h.0 == name && h.1 == status
}
var usdLow = QuotaThresholds()
usdLow.lowBalance = [sub: ["USD": dec("1")]]

// ── A. QuotaHeadline.pick ────────────────────────────────────────────────
print("— QuotaHeadline.pick")

// The reported account, parsed from DeepSeek's real reply shape.
let reported = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"7.62","granted_balance":"0.00","topped_up_balance":"7.62"},{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#
let ds = try! DeepSeekQuotaAdapter.parse(Data(reported.utf8), subjectId: sub, now: now)
t("reported reply parses to two currency pools", ds.pools.count == 2)
t("reported: USD 0 + CNY 7.62 → headline is CNY, available", isHead(ds.pools, "CNY", .available))
t("reported, pools in the other order → still CNY", isHead(ds.pools.reversed(), "CNY", .available))

t("mirror: USD 3.50 + CNY 0 → USD, available", isHead([balance("USD", "3.5"), balance("CNY", "0")], "USD", .available))
t("both exhausted → still shows an exhausted balance (nothing hidden)",
  head([balance("USD", "0"), balance("CNY", "0")])?.1 == .exhausted)
t("both exhausted → same pool as before the change (CNY, lower key)",
  isHead([balance("USD", "0"), balance("CNY", "0")], "CNY", .exhausted))
t("both funded → unchanged choice (CNY, lower key; no exchange rate applied)",
  isHead([balance("USD", "3.5"), balance("CNY", "7.62")], "CNY", .available))
t("only USD funded, CNY absent → USD", isHead([balance("USD", "3.5")], "USD", .available))
t("single exhausted USD balance → still exhausted", isHead([balance("USD", "0")], "USD", .exhausted))
t("USD low + CNY available → USD low (low is never dropped; worst-first unchanged)",
  isHead([balance("USD", "0.5"), balance("CNY", "7.62")], "USD", .low, thresholds: usdLow))
t("USD low + CNY 0 → USD low (a low balance is still money)",
  isHead([balance("USD", "0.5"), balance("CNY", "0")], "USD", .low, thresholds: usdLow))
t("exhausted usage window + USD 0 + CNY 7.62 → the window still headlines",
  isHead([balance("USD", "0"), balance("CNY", "7.62"), usageWindow(used: "1")], "subscription", .exhausted))
t("usage window 50% + USD 0 + CNY 7.62 → the window (usual busiest-window rule)",
  isHead([balance("USD", "0"), balance("CNY", "7.62"), usageWindow(used: "0.5")], "subscription", .available))
t("non-currency prepaid (credits) at 0 + CNY 7.62 → credits, exhausted (unchanged)",
  isHead([credits("0"), balance("CNY", "7.62")], "credits", .exhausted))
t("vendor-rejected account (is_available false) → stays exhausted",
  head([balance("USD", "0", verdict: .rejected), balance("CNY", "7.62", verdict: .rejected)])?.1 == .exhausted)
t("USD rejected at 0 next to a funded CNY → the rejection is not hidden",
  isHead([balance("USD", "0", verdict: .rejected), balance("CNY", "7.62")], "USD", .exhausted))

// The rule itself.
t("isCurrencyBalance: currency prepaid yes; credits / window no",
  QuotaHeadline.isCurrencyBalance(balance("USD", "1")) && !QuotaHeadline.isCurrencyBalance(credits("1"))
  && !QuotaHeadline.isCurrencyBalance(usageWindow(used: "0.1")))

// ── B. The surfaces that read it ─────────────────────────────────────────
print("— Section header, member pill, composer, account dot")
var pools: [QuotaPoolKey: QuotaPool] = [:]
for p in ds.pools { pools[p.id] = p }
let picked = QuotaHeadline.pick(ds.pools, now: now)!
let header = QuotaPickerHintRules.headerText(pool: picked.pool, status: picked.status, locale: en)
t("picker header shows the CNY balance, not US$0.00 (\(header ?? "nil"))",
  header.map { $0.contains("7.62") && !$0.contains("0.00") } == true)
t("picker header tone is not the exhausted red", QuotaToneRules.pillTone(picked.status) == QuotaToneRules.pillTone(
    PoolStatus(status: .available, decidingWindowId: nil, utilization: nil, freshness: .fresh)))

let view = QuotaModelResolver.view(instanceId: "i1", modelId: "deepseek-chat", subjectId: sub, pools: pools,
                                   bindings: ds.bindings, manualBindings: [], now: now)
let pill = QuotaPickerHintRules.memberPill(view, pools: pools, locale: en)
t("Model Group member pill shows the CNY balance (\(pill?.text ?? "nil"))", pill.map { $0.text.contains("7.62") } == true)
t("member pill points at the CNY pool", pill?.poolKey.rawValue.hasSuffix(":CNY") == true)
let seg = QuotaComposerHintRules.segment(view, pools: pools, now: now, locale: en)
t("composer quota page shows the CNY balance (\(seg?.text ?? "nil"))", seg.map { $0.text.contains("7.62") } == true)
t("account-level dot unchanged: ¥7.62 + $0 is normal", QuotaLevelRules.level(view, pools: pools) == .normal)

var spent: [QuotaPoolKey: QuotaPool] = [:]
for p in [balance("USD", "0"), balance("CNY", "0")] { spent[p.id] = p }
let spentView = QuotaModelResolver.view(instanceId: "i1", modelId: "deepseek-chat", subjectId: sub, pools: spent,
                                        bindings: ds.bindings, manualBindings: [], now: now)
t("both balances 0 → member pill still shows an exhausted amount",
  QuotaPickerHintRules.memberPill(spentView, pools: spent, locale: en).map { $0.text.contains("0.00") } == true)
t("both balances 0 → account dot depleted", QuotaLevelRules.level(spentView, pools: spent) == .depleted)

print("HARNESS failures=\(hFailures)")
exit(hFailures == 0 ? 0 : 1)
"""#

do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quota-headline-\(UUID().uuidString)")
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
    check("all multi-currency headline scenarios pass", rc == 0 && out.contains("HARNESS failures=0"))
} catch {
    check("harness setup: \(error)", false)
}

// Both one-line surfaces go through the same rule.
let rules = source("Providers/Quota/QuotaRules.swift")
let persistence = source("Providers/Quota/QuotaPersistence.swift")
check("QuotaHeadline.pick applies withoutSpentCurrencyBalances",
      rules.contains("let rated = withoutSpentCurrencyBalances(all, pool: { $0.0 }, status: { $0.1.status })"))
check("memberPill applies the same rule before choosing",
      persistence.contains("QuotaHeadline.withoutSpentCurrencyBalances(\n            v.bound.filter(usable)"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
