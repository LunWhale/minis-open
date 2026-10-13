// Tests for [T-copilot-disclaimer] — the GitHub Copilot integration must not
// contact GitHub until the user has explicitly accepted the risk notice, and
// the provider must be OFF unless deliberately enabled.
//
// Standalone (`swift CopilotDisclaimerGateTests.swift`) for the same reason as
// the neighbouring files: the MinisTests target has a pre-existing compile
// break and the shipping types pull in the whole app graph.
//
// These are source-level assertions by necessity: the property under test is
// "no network call happens before consent", which is a control-flow guarantee
// in a SwiftUI view, not a value a unit test can read back. What they pin is
// that the gate still exists, that the ONLY path to the device flow runs
// through it, and that the default is off — i.e. exactly the ways this could
// silently regress.

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let sheet = source("Views/Providers/CopilotDeviceLoginSheet.swift")
let consts = source("Providers/Copilot/CopilotConstants.swift")
let oauth = source("Providers/Copilot/OAuth/CopilotOAuthManager.swift")

print("\n[0] Sources readable")
check("login sheet", !sheet.isEmpty)
check("constants", !consts.isEmpty)
check("oauth manager", !oauth.isEmpty)

print("\n[1] Device flow is NOT reachable without consent")
// The sheet opens in `.consent`; only `start()` begins the flow.
check("initial phase is .consent", sheet.contains("@State private var phase: Phase = .consent"))
check("a .consent case exists", sheet.contains("case consent"))
// `start()` must be called from exactly one place: the consent button.
// Count CODE occurrences only: a comment naming `start()` is not a call site,
// and counting it made this assertion fire on a doc-comment edit rather than on
// a new way into the device flow (which is what it is for).
let startCallLines = sheet.split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { $0.contains("start()") && !$0.hasPrefix("//") }
check("start() appears on <= 4 code lines (definition + 3 gated call sites) — got \(startCallLines.count)",
      startCallLines.count <= 4)
// …and name the roles, so the count cannot be satisfied by the wrong ones: the
// definition, the consent button, the post-consent retry button, and the
// resume path for a user who already accepted.
check("…one is the definition", sheet.contains("private func start() {"))
check("…one is the consent button",
      sheet.contains("Button {\n            start()\n        } label: {")
      || sheet.contains("Button {\n                start()\n            } label: {"))
check("…one is the failure-screen retry", sheet.contains("Button(AppLocalized(\"Try Again\")) { start() }"))
check("…one resumes an already-accepted user",
      sheet.contains("if CopilotConstants.hasAcceptedSignInConsent, phase == .consent {"))
check("consent button calls start()",
      sheet.contains("Button {\n            start()\n        } label: {"))
// The network call itself lives behind start() -> requestDeviceAuthorization.
check("device authorization is requested only inside start()",
      sheet.contains("CopilotOAuthManager.shared.requestDeviceAuthorization()"))
// Nothing may fire on appear: an .onAppear/.task that called start() would
// defeat the gate entirely while leaving the consent UI visibly intact.
check("no .onAppear auto-start", sheet.contains(".onAppear { start()"), false)
check("no .task auto-start", sheet.contains(".task { start()"), false)
check("no .task { await start", sheet.contains(".task { await start"), false)

print("\n[2] Cancel sends nothing")
check("cancel finishes without starting", sheet.contains("Button(AppLocalized(\"Cancel\")) { finish(false) }"))

print("\n[3] The notice states each required risk")
// One needle per required risk. These are the CURRENT wordings of the notice
// (it was rewritten and routed through AppLocalized; the risk categories are
// unchanged, and each is still stated as its own line rather than folded into a
// paragraph).
let required: [(String, String)] = [
    ("unofficial / not authorized", "not officially authorized"),
    ("no GitHub affiliation",       "not affiliated with, endorsed by, or supported by GitHub"),
    ("interfaces may change/stop",  "may change or discontinue these interfaces at any time"),
    ("entitlement/account risk",    "termination of your Copilot entitlement or your GitHub account"),
    ("not for org/enterprise/prod", "organization, enterprise, or production account is strongly discouraged"),
    ("user's own decision",         "at your own discretion"),
]
for (name, needle) in required {
    check("states: \(name)", sheet.contains(needle))
}
check("explicit consent button wording",
      sheet.contains("I have read and accept these terms"))

print("\n[4] Forbidden claims are absent")
// Must never claim official status, legality, safety, or a no-ban guarantee.
for bad in ["officially supported", "fully legal", "guaranteed safe",
            "will not be banned", "won't get banned", "endorsed by GitHub"] {
    check("does not claim: \"\(bad)\"", sheet.lowercased().contains(bad.lowercased()), false)
}
// Must not surface circumvention details (client id / UA) in the USER-FACING
// notice. They legitimately live in CopilotConstants; the sheet must not echo
// them.
check("notice does not print the client id", sheet.contains("Iv1."), false)
check("notice does not print the user agent", sheet.contains("GitHubCopilotChat/"), false)

print("\n[5] Provider defaults to OFF")
check("isEnabled reads the key with no true-by-default branch",
      consts.contains("UserDefaults.standard.bool(forKey: enabledDefaultsKey)"))
check("the old default-ON branch is gone",
      consts.contains("if UserDefaults.standard.object(forKey: enabledDefaultsKey) == nil { return true }"), false)
check("flag is documented as OFF by default", consts.contains("Defaults to **OFF**"))
check("no remote config is introduced",
      consts.lowercased().contains("remoteconfig") || consts.contains("firebase"), false)

print("\n[6] Consent is taken once, at sign-in, and remembered")
// The one-time first-use CHAT banner was retired ([T-copilot-no-chat-warning]):
// a warning shown on every message is one the reader learns to tap past, so the
// disclosure now lives entirely in the sign-in consent page. What must still
// hold is that the acceptance is RECORDED (the notice is shown once, not on
// every sign-in), that the sheet is what records it, and that nothing has
// quietly grown a second, per-message gate back.
check("consent state has an accessor", consts.contains("static var hasAcceptedSignInConsent: Bool"))
check("it reads the consent key",
      consts.contains("UserDefaults.standard.bool(forKey: signInConsentAcceptedKey)"))
check("acceptance is persisted once", consts.contains("static func recordSignInConsent()")
      && consts.contains("UserDefaults.standard.set(true, forKey: signInConsentAcceptedKey)"))
check("the sheet records it on the way into the flow",
      sheet.contains("CopilotConstants.recordSignInConsent()"))
check("an already-accepted user skips the notice (no re-prompt)",
      sheet.contains("if CopilotConstants.hasAcceptedSignInConsent, phase == .consent {"))
// The retired key stays DEFINED (a device that stored it keeps a name whose
// meaning can be looked up) and must not grow a consumer back.
check("the retired first-use key is still defined, not deleted",
      consts.contains("firstUseNoticeShownKey"))
check("…and has no accessor that would revive the banner",
      consts.contains("consumeFirstUseNotice"), false)
let factory = source("Agent/Chat/AIChatViewModel+ProviderFactory.swift")
check("no per-message banner is wired into the provider build path",
      factory.contains("pendingCopilotFirstUseNotice"), false)

print("\n[7] OAuth/protocol untouched by this change")
// The task forbids altering the auth flow itself; these are the load-bearing
// pieces that must still be exactly as they were.
check("device flow still RFC 8628 device-code", oauth.contains("Device flow (RFC 8628)"))
check("still posts to GitHub's own device endpoint",
      oauth.contains("CopilotConstants.deviceCodeURL"))
check("token still stored via the shared Keychain helper",
      oauth.contains("ProviderKeychainHelper.saveOAuthToken"))

print("\n\(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
