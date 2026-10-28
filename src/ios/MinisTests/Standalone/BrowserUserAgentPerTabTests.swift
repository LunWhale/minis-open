#!/usr/bin/env swift
// [T-browser-ua-per-tab] ISS-033: "the browser is set to desktop but the
// session is still mobile".
//
// Root cause: Browser Settings edits the home screen's own BrowserTabPool and
// writes UserDefaults; every chat owns another pool that read UserDefaults
// once, in init. A chat already in memory kept opening tabs with the profile
// it had read when it was created, until the app was relaunched.
//
// Behaviour now:
//   1. a tab that is already open never changes when the global setting does;
//   2. every tab created later - in any chat, old or new, including window.open
//      popups and the replacement for a dead tab - reads the setting as it is;
//   3. set_user_agent switches its target tab only and persists nothing;
//   4. Browser Settings / minis-config set the global default (UserDefaults);
//   5. the browser panel's title icon is the selected tab's own profile;
//   6. a missing / unknown user_agent is an error, not a silent "mobile".
//
// [1] RUNS the shipping code: the functions below are lifted from the app
// sources as text, compiled with a recording stand-in for BrowserUseManager and
// an in-memory stand-in for UserDefaults, and driven through the scenarios.
// [2] pins the wiring that cannot be lifted (executeInner, the SwiftUI views).
//
// Run: swift BrowserUserAgentPerTabTests.swift
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
/// The declaration starting at `marker`, through its matching closing brace.
func block(_ src: String, _ marker: String) -> String {
    guard let start = src.range(of: marker) else { return "/* MISSING: \(marker) */" }
    var depth = 0
    var i = start.lowerBound
    var seenOpen = false
    while i < src.endIndex {
        let c = src[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" {
            depth -= 1
            if seenOpen && depth == 0 { return String(src[start.lowerBound...i]) }
        }
        i = src.index(after: i)
    }
    return "/* UNTERMINATED: \(marker) */"
}
func line(_ src: String, containing needle: String) -> String {
    src.components(separatedBy: "\n").first { $0.contains(needle) } ?? "/* MISSING LINE: \(needle) */"
}

let pool = source("Agent/BrowserUse/BrowserTabPool.swift")
let actions = source("Agent/BrowserUse/BrowserUseActions.swift")
let manager = source("Agent/BrowserUse/BrowserUseManager.swift")
let sheet = source("Agent/BrowserUse/BrowserSheetView.swift")
let settingsView = source("Agent/BrowserUse/BrowserManagementView.swift")
let config = source("Shared/Config/ConfigRegistry+Builtins.swift")

// MARK: - 1. Run the shipping code

let liftedFromPool = [
    "    func acquireTab() -> Int {",
    "    func newTab(url: String? = nil, owner: String? = nil) -> BrowserActionResult {",
    "    func openWithConfiguration(_ configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {",
    "    private func rebuildDeadTab(oldId: Int) -> (newId: Int, deadURL: String) {",
    "    private func makeManager() -> BrowserUseManager {",
    "    func resolvedUserAgentString() -> String? {",
    "    func resolvedViewportSize() -> (width: Int, height: Int) {",
    "    func resolvedViewportSize(for profile: UserAgentProfile) -> (width: Int, height: Int) {",
    "    func syncGlobalDefaultsFromStore() {",
    "    func setGlobalViewport(width: Int, height: Int) {",
    "    func setSessionViewport(width: Int, height: Int) {",
    "    func resetSessionViewport() {",
    "    private func applyViewportToAllTabs() {",
    "    func setUserAgentProfile(_ profile: UserAgentProfile) {",
    "    private func setUserAgent(_ profile: UserAgentProfile, onTab tabId: Int,",
].map { block(pool, $0) }.joined(separator: "\n\n")
let keyLines = ["uaProfileKey = ", "uaCustomStringKey = ", "viewportWidthKey = ", "viewportHeightKey = "]
    .map { line(pool, containing: "private static let " + $0) }.joined(separator: "\n")
let liftedFromActions = [
    block(actions, "enum BrowserAction: String, CaseIterable {"),
    block(actions, "struct BrowserActionInput {"),
    block(actions, "enum UserAgentProfile: String {"),
    block(actions, "extension UserAgentProfile {"),
    block(actions, "struct BrowserActionResult {"),
].joined(separator: "\n\n")

let prelude = #"""
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

/// In-memory stand-in for the app's defaults: nothing here touches a disk.
final class FakeDefaults {
    static let shared = FakeDefaults()
    var store: [String: Any] = [:]
    var writes: [String] = []
    func string(forKey k: String) -> String? { store[k] as? String }
    func integer(forKey k: String) -> Int { store[k] as? Int ?? 0 }
    func set(_ v: Any?, forKey k: String) { store[k] = v; writes.append(k) }
}
struct StubLogger {
    func info(_ s: String) {}
    func warning(_ s: String) {}
    func error(_ s: String) {}
}
let logger = StubLogger()
final class StubPublisher { var sends = 0; func send() { sends += 1 } }
final class WKWebViewConfiguration {}
final class WKWebView {}

/// Records what the pool asks of a tab and keeps the state the real manager
/// keeps (profile, viewport, UA string), with the real manager's rules: a
/// non-empty custom string wins, else the profile's own UA.
final class BrowserUseManager {
    private(set) var currentProfile: UserAgentProfile
    private(set) var currentViewport: (width: Int, height: Int)
    private(set) var effectiveUserAgent: String?
    var calls: [String] = []
    var loaded: [String] = []
    var currentURL = ""
    let webView = WKWebView()
    var viaPopupConfiguration = false

    private static func ua(_ profile: UserAgentProfile, _ custom: String?) -> String {
        if let custom, !custom.isEmpty { return custom }
        return profile.userAgentString ?? UserAgentProfile.mobileSafari.userAgentString!
    }
    init(profile: UserAgentProfile, customString: String?, viewportWidth: Int? = nil, viewportHeight: Int? = nil) {
        currentProfile = profile
        if let w = viewportWidth, let h = viewportHeight, w > 0, h > 0 { currentViewport = (w, h) }
        else { currentViewport = profile.viewportSize }
        effectiveUserAgent = Self.ua(profile, customString)
    }
    convenience init(profile: UserAgentProfile, customString: String?, configuration: WKWebViewConfiguration,
                     viewportWidth: Int? = nil, viewportHeight: Int? = nil) {
        self.init(profile: profile, customString: customString, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        viaPopupConfiguration = true
    }
    func setUserAgent(profile: UserAgentProfile, customString: String? = nil) {
        calls.append("setUserAgent")
        currentProfile = profile
        effectiveUserAgent = Self.ua(profile, customString)
    }
    func setViewport(width: Int, height: Int, profile: UserAgentProfile, customUA: String?) {
        calls.append("setViewport")
        currentProfile = profile
        currentViewport = (width, height)
        effectiveUserAgent = Self.ua(profile, customUA)
    }
    func loadURL(_ u: String) { loaded.append(u); currentURL = u }

    var isDesktop: Bool { (effectiveUserAgent ?? "").contains("Macintosh") }
    var isMobile: Bool { (effectiveUserAgent ?? "").contains("iPhone") }
    func size(_ w: Int, _ h: Int) -> Bool { currentViewport.width == w && currentViewport.height == h }
}

final class BrowserTabPoolRegistry {
    static let shared = BrowserTabPoolRegistry()
    static let globalTabCap = 8
    @discardableResult func requestSlot(for pool: BrowserTabPool) -> Bool { true }
}

final class BrowserTabPool {
    struct Tab {
        let id: Int
        let manager: BrowserUseManager
        var inUse: Bool
        var lastActivityDate = Date()
    }
    static let maxTabs = 10
    static let agentTabQuota = 2
    var tabs: [Tab] = []
    var selectedTabId = 0
    var userAgentProfile: UserAgentProfile = .mobileSafari
    var customUserAgentString: String = ""
    var customViewportWidth: Int = 0
    var customViewportHeight: Int = 0
    private(set) var sessionViewportWidth: Int = 0
    private(set) var sessionViewportHeight: Int = 0
    var tabOwner: [Int: String] = [:]
    var lastTabByOwner: [String: Int] = [:]
    let objectWillChange = StubPublisher()
    var activeManager: BrowserUseManager? { tabs.first { $0.id == selectedTabId }?.manager }

    // The shipping init reads the global defaults the same way (pinned in [2]).
    init() { syncGlobalDefaultsFromStore() }

    func isPrivileged(_ owner: String?) -> Bool { true }
    func tabIds(ownedBy owner: String) -> [Int] { [] }
    func effectiveMaxTabs(requestingOwner: String?) -> Int { Self.maxTabs }
    private func wireManager(_ manager: BrowserUseManager) {}
    private func restoreSavedURL(for tabId: Int, manager: BrowserUseManager) {}
    private func persistURLs() {}

    // Doors to the private shipping methods.
    func manager(_ id: Int) -> BrowserUseManager { tabs.first { $0.id == id }!.manager }
    func agentSetUserAgent(_ profile: UserAgentProfile, tab: Int) -> BrowserActionResult {
        setUserAgent(profile, onTab: tab, manager: manager(tab))
    }
    func replaceDeadTab(_ id: Int) -> Int { rebuildDeadTab(oldId: id).newId }
    func popup() -> BrowserUseManager {
        _ = openWithConfiguration(WKWebViewConfiguration(), url: nil)
        return tabs.last!.manager
    }

    // ---- lifted from BrowserTabPool.swift ----
"""#

let scenarios = #"""

let store = FakeDefaults.shared
func stored(_ k: String) -> String { store.string(forKey: k) ?? "nil" }

print("1a. A tab that is already open does not change when the global setting does")
let home = BrowserTabPool()            // ContentView's pool, the one Browser Settings edits
let chatA = BrowserTabPool()           // a chat that was opened before the change
let chatA2 = BrowserTabPool()          // another one, with no tab yet
_ = home.acquireTab()
_ = chatA.acquireTab()
let a0 = chatA.manager(0)
let h0 = home.manager(0)
check("before: chat A's tab is mobile, 390x844", a0.currentProfile == .mobileSafari && a0.isMobile && a0.size(390, 844))
home.setUserAgentProfile(.desktopSafari)                       // the user taps Desktop Safari
check("Browser Settings writes the global default", stored("BrowserUserAgentProfile") == "desktop_safari")
check("…and its own pool shows it at once (the checkmark)", home.userAgentProfile == .desktopSafari)
check("chat A's open tab: profile, UA and viewport unchanged", a0.currentProfile == .mobileSafari && a0.isMobile && a0.size(390, 844))
check("chat A's open tab: zero setUserAgent / setViewport calls", a0.calls.isEmpty)
check("the settings pool's own open tab is not rebuilt either", h0.calls.isEmpty && h0.currentProfile == .mobileSafari && h0.size(390, 844))

print("1b. Tabs created later in the OLD chat read the setting as it is now")
let r1 = chatA.newTab()
let a1 = chatA.manager(r1.tabId!)
check("new_tab → desktop, 1280x800", a1.currentProfile == .desktopSafari && a1.isDesktop && a1.size(1280, 800))
let aPopup = chatA.popup()
check("window.open popup → desktop, 1280x800", aPopup.viaPopupConfiguration && aPopup.currentProfile == .desktopSafari && aPopup.isDesktop && aPopup.size(1280, 800))
check("the old tab is still untouched after its siblings were created", a0.calls.isEmpty && a0.isMobile && a0.size(390, 844))
let rebuiltId = chatA.replaceDeadTab(0)
let aRebuilt = chatA.manager(rebuiltId)
check("the replacement for a dead tab → desktop, 1280x800", rebuiltId != 0 && aRebuilt.currentProfile == .desktopSafari && aRebuilt.size(1280, 800))
check("a pool created earlier still holds the old default until it creates a tab", chatA2.userAgentProfile == .mobileSafari)
_ = chatA2.acquireTab()
check("acquireTab (its first tab) → desktop, 1280x800", chatA2.manager(0).currentProfile == .desktopSafari && chatA2.manager(0).size(1280, 800))

print("1c. A new chat")
let chatB = BrowserTabPool()
check("a pool created after the change starts on desktop", chatB.userAgentProfile == .desktopSafari)
_ = chatB.acquireTab()
let b0 = chatB.manager(0)
check("its first tab → desktop, 1280x800", b0.isDesktop && b0.size(1280, 800))

print("1d. set_user_agent switches its target tab only")
let b1 = chatB.manager(chatB.newTab().tabId!)
let writesBefore = store.writes.count
let sends = chatB.objectWillChange.sends
let res = chatB.agentSetUserAgent(.mobileSafari, tab: 1)
check("target tab → mobile, viewport recomputed to 390x844", b1.currentProfile == .mobileSafari && b1.isMobile && b1.size(390, 844))
check("one rebuild: a single setViewport, no separate setUserAgent", b1.calls == ["setViewport"])
check("the other tab is untouched", b0.calls.isEmpty && b0.isDesktop && b0.size(1280, 800))
check("the pool's global default is unchanged", chatB.userAgentProfile == .desktopSafari)
check("nothing is persisted", store.writes.count == writesBefore && stored("BrowserUserAgentProfile") == "desktop_safari")
check("the result names the tab and says: this tab only, temporary, back to the default on rebuild",
      res.success && res.tabId == 1 && res.text.contains("Tab 1 switched to mobile_safari (390x844)")
      && res.text.contains("This tab only") && res.text.contains("temporary")
      && res.text.contains("Browser Settings default (desktop_safari)") && res.text.contains("if it is rebuilt"))
check("observers are told once, so the panel icon can follow", chatB.objectWillChange.sends == sends + 1)
let b2 = chatB.manager(chatB.newTab().tabId!)
check("a third tab opened afterwards → the global default (desktop)", b2.currentProfile == .desktopSafari && b2.size(1280, 800))
let b1again = chatB.manager(chatB.replaceDeadTab(1))
check("the switched tab, once rebuilt → back to the global default", b1again.currentProfile == .desktopSafari && b1again.size(1280, 800))
let chatM = BrowserTabPool()
store.set("mobile_safari", forKey: "BrowserUserAgentProfile")
_ = chatM.acquireTab()
let m0 = chatM.manager(0)
_ = chatM.agentSetUserAgent(.desktopSafari, tab: 0)
check("mobile → desktop on a tab moves the viewport to 1280x800 (no half-width screenshot)",
      m0.currentProfile == .desktopSafari && m0.isDesktop && m0.size(1280, 800) && m0.calls == ["setViewport"])
let emptyCustom = chatM.agentSetUserAgent(.custom, tab: 0)
check("custom with no custom UA configured → error, tab unchanged",
      !emptyCustom.success && m0.currentProfile == .desktopSafari && m0.calls == ["setViewport"])
store.set("TestUA/1.0", forKey: "BrowserCustomUserAgentString")
_ = chatM.agentSetUserAgent(.custom, tab: 0)
check("custom reads the custom UA stored now", m0.currentProfile == .custom && m0.effectiveUserAgent == "TestUA/1.0")
store.set("", forKey: "BrowserCustomUserAgentString")
store.set("desktop_safari", forKey: "BrowserUserAgentProfile")

print("1e. minis-config writes UserDefaults only")
store.set("mobile_safari", forKey: "BrowserUserAgentProfile")   // what the config field does
check("no pool was told, no open tab changed", b0.calls.isEmpty && b2.calls.isEmpty && h0.calls.isEmpty)
check("the next tab in an old chat → mobile, 390x844", { let m = chatB.manager(chatB.newTab().tabId!); return m.isMobile && m.size(390, 844) }())
home.syncGlobalDefaultsFromStore()                               // Browser Settings appearing
check("Browser Settings shows the stored value when it appears", home.userAgentProfile == .mobileSafari)

print("1f. The global custom viewport is a default for later tabs as well")
let chatV = BrowserTabPool()
let v0 = chatV.manager(chatV.acquireTab())
home.setGlobalViewport(width: 1024, height: 768)
check("stored", store.integer(forKey: "BrowserCustomViewportWidth") == 1024 && store.integer(forKey: "BrowserCustomViewportHeight") == 768)
check("open tabs keep their size", v0.calls.isEmpty && v0.size(390, 844) && h0.calls.isEmpty)
let v1 = chatV.manager(chatV.newTab().tabId!)
check("a tab opened afterwards uses it", v1.size(1024, 768))
_ = chatV.agentSetUserAgent(.desktopSafari, tab: 0)
check("set_user_agent keeps the precedence: global custom viewport over the profile default", v0.currentProfile == .desktopSafari && v0.size(1024, 768))
home.setGlobalViewport(width: 0, height: 0)

print("1g. The session viewport (set_viewport) still applies to every tab of the session, each keeping its profile")
let chatS = BrowserTabPool()
store.set("desktop_safari", forKey: "BrowserUserAgentProfile")
let s0 = chatS.manager(chatS.acquireTab())
let s1 = chatS.manager(chatS.newTab().tabId!)
_ = chatS.agentSetUserAgent(.mobileSafari, tab: 1)
chatS.setSessionViewport(width: 800, height: 600)
check("both tabs resized", s0.size(800, 600) && s1.size(800, 600))
check("each keeps its own profile and UA", s0.currentProfile == .desktopSafari && s0.isDesktop && s1.currentProfile == .mobileSafari && s1.isMobile)
_ = chatS.agentSetUserAgent(.desktopSafari, tab: 1)
check("set_user_agent under a session viewport keeps the session size", s1.currentProfile == .desktopSafari && s1.size(800, 600))
_ = chatS.agentSetUserAgent(.mobileSafari, tab: 1)
chatS.resetSessionViewport()
check("reset: each tab back to ITS profile's default", s0.size(1280, 800) && s1.size(390, 844) && s1.isMobile)

print("1h. user_agent arguments")
check("raw values", UserAgentProfile.parse("desktop_safari") == .desktopSafari && UserAgentProfile.parse("mobile_safari") == .mobileSafari && UserAgentProfile.parse("custom") == .custom)
check("aliases desktop / mobile", UserAgentProfile.parse("desktop") == .desktopSafari && UserAgentProfile.parse("mobile") == .mobileSafari)
check("case, whitespace and '-' are forgiven", UserAgentProfile.parse(" Desktop-Safari ") == .desktopSafari && UserAgentProfile.parse("MOBILE") == .mobileSafari)
check("unknown, empty and missing → nil, never a profile", UserAgentProfile.parse("banana") == nil && UserAgentProfile.parse("") == nil && UserAgentProfile.parse(nil) == nil)
let bad = BrowserActionInput.parse(from: #"{"action":"set_user_agent","user_agent":"banana"}"#)
check("the tool input keeps the unparsed value for the error", bad?.action == .setUserAgent && bad?.userAgent == nil && bad?.userAgentRaw == "banana")
let alias = BrowserActionInput.parse(from: #"{"action":"set_user_agent","user_agent":"desktop","tab_id":2}"#)
check("the tool input accepts the alias", alias?.userAgent == .desktopSafari && alias?.tabId == 2)
let missing = BrowserActionInput.parse(from: #"{"action":"set_user_agent"}"#)
check("a missing user_agent parses to nil", missing?.userAgent == nil && missing?.userAgentRaw == nil)
let msg = UserAgentProfile.invalidArgumentMessage(raw: "banana")
check("the error names the value, the accepted values and that nothing changed",
      msg.contains("\"banana\"") && msg.contains("desktop_safari") && msg.contains("mobile_safari") && msg.contains("Nothing was changed"))
check("…and says so when the argument is missing", UserAgentProfile.invalidArgumentMessage(raw: nil).contains("user_agent is missing"))

print("1i. The panel's title icon")
check("an open tab: its own profile, whatever the global default is",
      UserAgentProfile.panelProfile(activeTab: .mobileSafari, globalDefault: .desktopSafari) == .mobileSafari
      && UserAgentProfile.panelProfile(activeTab: .desktopSafari, globalDefault: .mobileSafari) == .desktopSafari)
check("no tab: the global default", UserAgentProfile.panelProfile(activeTab: nil, globalDefault: .desktopSafari) == .desktopSafari)
check("the two icons differ", UserAgentProfile.mobileSafari.icon != UserAgentProfile.desktopSafari.icon)

exit(failures == 0 ? 0 : 1)
"""#

print("1. The shipping pool code, run against a recording tab")
let realDefaults = "UserDefaults.standard"
let harness = prelude + "\n" + keyLines + "\n\n" + liftedFromPool.replacingOccurrences(of: realDefaults, with: "FakeDefaults.shared")
    + "\n}\n\n// ---- lifted from BrowserUseActions.swift ----\n" + liftedFromActions + "\n" + scenarios
check("every declaration was found in the sources", !harness.contains("/* MISSING") && !harness.contains("/* UNTERMINATED"))
check("the harness cannot reach real defaults", !harness.contains(realDefaults))
if failures == 0 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserUserAgentPerTab-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? harness.write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text, terminator: "")
    let passed = text.components(separatedBy: "✅").count - 1
    check("harness ran to the end (\(passed) checks) and exited 0", p.terminationStatus == 0 && passed >= 40)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 2. Wiring

print("\n2. Wiring in the shipping sources")
func code(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
let poolCode = code(pool)
let execInner = block(pool, "    private func executeInner(")
func index(_ hay: String, _ needle: String) -> Int {
    hay.range(of: needle).map { hay.distance(from: hay.startIndex, to: $0.lowerBound) } ?? -1
}

check("the pool builds a manager in exactly two places: makeManager and the window.open popup",
      poolCode.components(separatedBy: "BrowserUseManager(profile:").count - 1 == 2)
check("makeManager re-reads the global defaults first",
      block(pool, "    private func makeManager() -> BrowserUseManager {").contains("{\n        syncGlobalDefaultsFromStore()\n        let ua = resolvedUserAgentString()"))
let popup = block(pool, "    func openWithConfiguration(_ configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {")
check("the popup re-reads them before building its manager",
      index(popup, "syncGlobalDefaultsFromStore()") > 0 && index(popup, "syncGlobalDefaultsFromStore()") < index(popup, "BrowserUseManager(profile:"))
check("acquireTab, the UI prefetch, new_tab and the implicit fan-out all go through makeManager",
      poolCode.components(separatedBy: "let manager = makeManager()").count - 1 == 4)
check("a dead tab is replaced through newTab", block(pool, "    private func rebuildDeadTab(oldId: Int) -> (newId: Int, deadURL: String) {").contains("let r = newTab(url: nil)"))
check("init reads the defaults through the same function", block(pool, "    init() {").contains("syncGlobalDefaultsFromStore()"))
check("the sync never walks the tabs", !block(pool, "    func syncGlobalDefaultsFromStore() {").contains("tabs"))

let settingsSetter = code(block(pool, "    func setUserAgentProfile(_ profile: UserAgentProfile) {"))
check("Browser Settings' setter persists and touches no tab",
      settingsSetter.contains("UserDefaults.standard.set(profile.rawValue, forKey: Self.uaProfileKey)")
      && !settingsSetter.contains("tabs") && !settingsSetter.contains("setViewport") && !settingsSetter.contains("setUserAgent("))
check("the old pool-wide switch is gone", !poolCode.contains("persist: false") && !poolCode.contains("persist: Bool"))
check("the global viewport setter touches no tab", !code(block(pool, "    func setGlobalViewport(width: Int, height: Int) {")).contains("applyViewportToAllTabs"))
check("no silent mobile fallback anywhere on this path",
      !poolCode.contains("?? .mobileSafari\n            setUserAgentProfile") && !code(execInner).contains("?? .mobileSafari")
      && !code(manager).contains("profile ?? .mobileSafari") && !code(actions).contains(".flatMap(UserAgentProfile.init)"))

let earlyCheck = "if input.action == .setUserAgent, input.userAgent == nil {\n            return .error(UserAgentProfile.invalidArgumentMessage(raw: input.userAgentRaw))"
check("an invalid user_agent is refused before a tab is picked or created",
      index(execInner, earlyCheck) > 0 && index(execInner, earlyCheck) < index(execInner, "// Determine which tab to target."))
let dispatch = "if input.action == .setUserAgent, let profile = input.userAgent {\n            return setUserAgent(profile, onTab: targetId, manager: manager)"
check("the switch runs on the target tab's manager, inside that tab's serial slot",
      index(execInner, dispatch) > index(execInner, "defer { releaseSerialSlot() }") && index(execInner, "defer { releaseSerialSlot() }") > 0
      && index(execInner, dispatch) < index(execInner, "try await manager.execute(action: input)"))
check("executeInner no longer changes the pool's profile", !code(execInner).contains("setUserAgentProfile("))

check("the real manager's setViewport sets profile and size together and reloads the page",
      { let b = block(manager, "    func setViewport(width: Int, height: Int,")
        return b.contains("currentProfile = profile") && b.contains("currentViewport = (width, height)")
            && b.contains("viewportWidth: width, viewportHeight: height") && b.contains("webView.load(URLRequest(url: url))") }())
check("the manager reports the UA its tab is using", manager.contains("var effectiveUserAgent: String? { webView.customUserAgent }"))
check("the manager refuses a missing profile too",
      manager.contains("guard let profile = input.userAgent else {\n                return .error(UserAgentProfile.invalidArgumentMessage(raw: input.userAgentRaw))"))

check("the panel icon is the selected tab's profile, the global default only without a tab",
      sheet.contains("UserAgentProfile.panelProfile(\n                            activeTab: pool.activeManager?.currentProfile,\n                            globalDefault: pool.userAgentProfile).icon")
      && !code(sheet).contains("pool.userAgentProfile.icon"))
check("Browser Settings: tapping a profile calls the setter; the screen shows the stored value when it appears",
      settingsView.contains("pool.setUserAgentProfile(profile)") && settingsView.contains(".onAppear { pool.syncGlobalDefaultsFromStore() }"))
check("minis-config's comment matches: UserDefaults only, every pool re-reads on tab creation",
      config.contains("BrowserTabPool.syncGlobalDefaultsFromStore") && !config.contains("it reads on\n    // launch"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
