#!/usr/bin/env swift
// [T-oauth-reauth-mark-loop] Settings › AI Providers stuttered while
// scrolling (a test iPhone, 2026-10-07 19:29-19:31). The log showed
// `mark oauthNeedsReauth instanceId=37D5CC24` 153 times, ~every 0.45 s:
//   markOAuthNeedsReauth → notifyAuthChanged → authRevision += 1
//   → QuotaStore.credentialsChanged → quota re-check of recent instances
//   → on-demand refresh with the already-rejected token → rejected
//   → markOAuthNeedsReauth (same credential) → notify …
// Each round re-rendered every provider row and invalidated the row
// credential cache (Keychain reads on the main thread).
//
// The mark is now idempotent: the same credential already marked → no write,
// no notification. A NEW credential (re-login / Keychain sync) still marks
// and notifies once.
//
// Run: swift OAuthReauthMarkLoopTests.swift
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

let store = source("Providers/ProviderConfigStore.swift")
let mark = between(store, "static func markOAuthNeedsReauth(instanceId: String, caller: String = #function) {",
                   "static func oauthNeedsReauth(instanceId: String) -> Bool {") ?? ""
check("markOAuthNeedsReauth found", !mark.isEmpty)
check("same credential already marked → return before writing or notifying",
      ordered(mark, ["let fingerprint = oauthFingerprint(data)",
                     "if UserDefaults.standard.string(forKey: key) == fingerprint { return }",
                     "UserDefaults.standard.set(fingerprint, forKey: key)",
                     "notifyAuthChanged(instanceId: instanceId)"]))
check("a new credential still marks and notifies (one notification per credential)",
      mark.components(separatedBy: "notifyAuthChanged(").count - 1 == 1)
check("the notification is still what bumps authRevision",
      (between(store, "private static func notifyAuthChanged(instanceId: String) {", "}") ?? "")
        .contains("ProviderConfigStore.shared.authRevision &+= 1"))
check("QuotaStore still re-checks on a real credential change",
      source("Providers/Quota/QuotaStore.swift").contains("authCancellable = ProviderConfigStore.shared.$authRevision.dropFirst()"))
let providers = ["Anthropic/OAuth/ClaudeOAuthManager.swift", "Gemini/OAuth/GeminiOAuthManager.swift",
                 "xAI/OAuth/XAIOAuthManager.swift", "Kimi/OAuth/KimiOAuthManager.swift",
                 "Antigravity/OAuth/AntigravityOAuthManager.swift", "OpenAI/OAuth/CodexOAuthManager.swift"]
check("every OAuth provider marks through this one function (all covered)",
      providers.allSatisfy { source("Providers/" + $0).contains("ProviderKeychainHelper.markOAuthNeedsReauth(instanceId") })

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
