#!/usr/bin/env swift
// [T-shortcut-envvar] "Save Environment Variable to Minis" Shortcuts action:
// text captured by a Shortcut (e.g. an SMS) is stored as the global
// environment variable MINIS_SHORTCUT_OPT_<SUFFIX>, in the same Keychain-
// backed store as Settings → Environment Variables.
//
//   [1] shortcutKey(forSuffix:) — pure: name normalization / validation
//   [2] sanitizeShortcutValue — pure: keeps CJK, emoji, quotes, newlines;
//       drops control characters (NUL would end the C string)
//   [3] size limit arithmetic (UTF-8 bytes, 32 KiB)
//   [4] source guards: storage order, update-in-place, Settings edit keeps
//       Unicode, Privacy Mode exemption, intent wiring, project + strings
//
// Run: swift ShortcutEnvVarTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

// MARK: - Port (byte-identical with EnvVarStore.swift, guarded in [4])

enum EnvVarStore {
    static let shortcutKeyPrefix = "MINIS_SHORTCUT_OPT_"
    static let shortcutValueMaxBytes = 32 * 1024
    static let shortcutSuffixMaxLength = 64

    // BEGIN shortcutEnvVar
    /// The variable name for a user-typed suffix, or nil when the suffix is
    /// unusable. Trimmed, upper-cased, spaces / hyphens / dots become `_`, and
    /// a prefix the user typed themselves is not doubled. What is left must be
    /// 1…64 of A–Z, 0–9, `_`.
    nonisolated static func shortcutKey(forSuffix raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        s = String(s.map { " -.".contains($0) ? "_" : $0 })
        if s.hasPrefix(shortcutKeyPrefix) { s.removeFirst(shortcutKeyPrefix.count) }
        guard !s.isEmpty, s.count <= shortcutSuffixMaxLength,
              s.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return nil }
        return shortcutKeyPrefix + s
    }

    /// Text captured by a Shortcut, made safe for an environment variable
    /// without losing content: CRLF / CR become LF, and control characters
    /// other than LF and tab are dropped (NUL would end the C string the
    /// shell receives). Everything else — CJK, emoji, quotes, `$` — stays;
    /// the value reaches the shell through the process environment, not as
    /// shell text, so nothing needs escaping.
    nonisolated static func sanitizeShortcutValue(_ value: String) -> String {
        let unified = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(unified.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control
        })
    }
    // END shortcutEnvVar
}
let key = EnvVarStore.shortcutKey(forSuffix:)
let clean = EnvVarStore.sanitizeShortcutValue

// MARK: - [1] names

print("▶️  1. shortcutKey(forSuffix:)")
check("plain suffix", key("SMS") == "MINIS_SHORTCUT_OPT_SMS")
check("lower-case is upper-cased", key("sms_code") == "MINIS_SHORTCUT_OPT_SMS_CODE")
check("surrounding whitespace trimmed", key("  sms \n") == "MINIS_SHORTCUT_OPT_SMS")
check("spaces, hyphens and dots become _", key("bank sms-code.v2") == "MINIS_SHORTCUT_OPT_BANK_SMS_CODE_V2")
check("a typed prefix is not doubled", key("MINIS_SHORTCUT_OPT_SMS") == "MINIS_SHORTCUT_OPT_SMS"
      && key("minis_shortcut_opt_sms") == "MINIS_SHORTCUT_OPT_SMS")
check("digits and a leading digit are fine (the prefix starts with a letter)", key("2FA") == "MINIS_SHORTCUT_OPT_2FA")
check("underscores only is allowed", key("_") == "MINIS_SHORTCUT_OPT__")
check("empty → nil", key("") == nil && key("   ") == nil)
check("just the prefix → nil (no suffix left)", key("MINIS_SHORTCUT_OPT_") == nil)
check("non-ASCII (Chinese) → nil", key("短信") == nil && key("SMS短信") == nil)
check("other symbols → nil", key("SMS$") == nil && key("A/B") == nil && key("a=b") == nil)
check("accented Latin letters → nil (not A–Z)", key("CAFÉ") == nil)
check("64 characters accepted, 65 rejected",
      key(String(repeating: "A", count: 64)) != nil && key(String(repeating: "A", count: 65)) == nil)
check("result always passes the store's key rule (^[A-Za-z][A-Za-z0-9_]*$)", {
    let rule = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_]*$")
    return ["SMS", "2FA", "_", "a b", "x-y.z"].compactMap { key($0) }.allSatisfy {
        rule.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
    }
}())

// MARK: - [2] value cleanup

print("\n▶️  2. sanitizeShortcutValue")
let sms = "【银行】您的验证码是 482913，5 分钟内有效。请勿泄露 🔐"
check("Chinese text and emoji kept verbatim", clean(sms) == sms)
check("quotes, $, backticks, backslashes kept", clean(#"a "b" 'c' $HOME `x` \n"#) == #"a "b" 'c' $HOME `x` \n"#)
check("LF and tab kept", clean("line1\n\tline2") == "line1\n\tline2")
check("CRLF → LF", clean("a\r\nb") == "a\nb")
check("lone CR → LF", clean("a\rb") == "a\nb")
check("NUL dropped (would truncate the C string)", clean("a\u{0}b") == "ab")
check("ESC and C1 CSI (paste artifact) dropped", clean("a\u{1B}[0mb\u{9B}c") == "a[0mbc")
check("other C0 controls dropped", clean("a\u{7}\u{8}\u{7F}b") == "ab")
check("zero-width joiner in emoji sequence kept", clean("👨‍👩‍👧") == "👨‍👩‍👧")
check("empty stays empty", clean("") == "")

// MARK: - [3] size limit

print("\n▶️  3. size limit (UTF-8 bytes)")
let limit = EnvVarStore.shortcutValueMaxBytes
check("limit is 32 KiB", limit == 32768)
check("counted in UTF-8 bytes: a CJK character is 3 bytes", "验".utf8.count == 3)
check("32 KiB of ASCII fits, one byte more does not",
      String(repeating: "a", count: limit).utf8.count <= limit && String(repeating: "a", count: limit + 1).utf8.count > limit)
check("≈10,922 CJK characters fit (32768 / 3)",
      String(repeating: "验", count: 10922).utf8.count <= limit && String(repeating: "验", count: 10923).utf8.count > limit)
check("limit stays below Linux MAX_ARG_STRLEN (128 KiB) including the name", limit + 100 < 131072)

// MARK: - [4] source guards

print("\n▶️  4. source guards")
let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return "" }
    return String(s[r1.upperBound..<r2.lowerBound])
}
let store = source("Shared/EnvVarStore.swift")
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
let appBlock = between(store, "// BEGIN shortcutEnvVar", "// END shortcutEnvVar")
check("port is byte-identical with EnvVarStore", !appBlock.isEmpty && appBlock == between(me, "// BEGIN shortcutEnvVar", "// END shortcutEnvVar"))
check("constants match the port",
      store.contains(#"nonisolated static let shortcutKeyPrefix = "MINIS_SHORTCUT_OPT_""#)
      && store.contains("nonisolated static let shortcutValueMaxBytes = 32 * 1024")
      && store.contains("nonisolated static let shortcutSuffixMaxLength = 64"))

let save = between(store, "func saveFromShortcut(suffix: String, text: String) throws -> (key: String, created: Bool) {", "\n    }\n")
check("validation order: name, cleanup, non-empty, size — then storage", {
    let order = ["Self.shortcutKey(forSuffix: suffix)", "Self.sanitizeShortcutValue(text)", "throw ShortcutSaveError.emptyText",
                 "value.utf8.count", "guard bytes <= Self.shortcutValueMaxBytes", "Self.saveValue(value, forKey: key)"]
    let idx = order.compactMap { save.range(of: $0)?.lowerBound }
    return idx.count == order.count && zip(idx, idx.dropFirst()).allSatisfy { $0 < $1 }
}())
check("Keychain write happens BEFORE any list change (no blank-value entry on failure)", {
    guard let k = save.range(of: "guard Self.saveValue(value, forKey: key) else { throw ShortcutSaveError.storageFailed }"),
          let e = save.range(of: "entries.append(entry)") else { return false }
    return k.lowerBound < e.lowerBound
}())
check("same name again updates in place (no duplicate entry), keeps the note",
      save.contains("if let idx = entries.firstIndex(where: { $0.key == key }) {")
      && !between(save, "if let idx = entries.firstIndex(where: { $0.key == key }) {", "return (key, false)").contains(".note"))
check("both paths persist the key list and queue iCloud sync",
      save.components(separatedBy: "saveEntries()").count - 1 == 2
      && save.components(separatedBy: "markEntryDirty(entryId:").count - 1 == 2)
check("Settings add/update sanitize by key (shortcut values keep Unicode when edited)",
      store.components(separatedBy: "let cleanValue = Self.sanitizeValue(value, forKey: trimmedKey)").count - 1 == 2
      && store.contains("if isShortcutKey(key) { return sanitizeShortcutValue(value) }"))
check("normal variables keep the ASCII-only rule",
      between(store, "private static func sanitizeValue(_ value: String, forKey key: String) -> String {", "\n    }\n")
        .contains("(scalar.value >= 0x20 && scalar.value <= 0x7E) || scalar.value == 0x09"))

check("Privacy Mode does not mask shortcut variables",
      source("Shared/EnvVarRedactor.swift").contains("if EnvVarStore.isShortcutKey(entry.key) { continue }"))
let sheet = source("Views/Settings/EnvironmentVariablesView.swift")
check("Settings edit field is multi-line for shortcut variables",
      sheet.contains("if EnvVarStore.isShortcutKey(key) {") && sheet.contains(#"TextField("Value", text: $value, axis: .vertical)"#))

let intent = source("Agent/Intents/SaveEnvVarIntent.swift")
check("intent title", intent.contains(#"static var title: LocalizedStringResource = "Save Environment Variable to Minis""#))
check("runs in the background", intent.contains("static var openAppWhenRun = false"))
check("text parameter accepts the previous action's output", intent.contains("inputConnectionBehavior: .connectToPreviousIntentResult"))
check("writes through the store on the main actor and returns the variable name",
      intent.contains("try await MainActor.run {\n            try EnvVarStore.shared.saveFromShortcut(suffix: suffix, text: text)")
      && intent.contains("return .result(value: key,"))

let pbx = source("Minis.xcodeproj/project.pbxproj")
check("registered in the Xcode project (file ref, build file, group, sources)",
      pbx.components(separatedBy: "SaveEnvVarIntent.swift").count - 1 == 6)
let xc = source("Localizable.xcstrings")
let howTo = "\\nTo use it, ask Minis in any chat to read $%@.\\nTo view, edit or delete it, open Minis → Settings → Environment Variables."
for k in ["Save Environment Variable to Minis", "Name Suffix", "Save ${text} to Minis as $MINIS_SHORTCUT_OPT_${suffix}",
          "Saved as %@." + howTo, "Updated %@." + howTo,
          "The text is too long to save (%lld KB). The limit is 32 KB.", "There is no text to save."] {
    check("localized: \(k.prefix(40))…", xc.contains("\"\(k)\" : {"))
}
check("superseded bare \"Saved as / Updated\" strings are gone",
      !xc.contains("\"Saved as %@.\" : {") && !xc.contains("\"Updated %@.\" : {"))
// This feature's zh-Hant strings match the Settings page title (環境變量).
// Other features' older strings are out of scope here.
check("zh-Hant for this feature uses the Settings wording 環境變量", {
    guard let data = xc.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = root["strings"] as? [String: Any] else { return false }
    let mine = strings.keys.filter { $0.contains("Environment Variable to Minis") || $0.contains("MINIS_SHORTCUT_OPT_")
        || $0.hasPrefix("Saved as %@.\n") || $0.hasPrefix("Updated %@.\n") || $0.contains("save the variable to the Keychain")
        || $0 == "What name suffix should the variable use?" }
    // JSON text, not `description` (which escapes CJK as \\U… sequences).
    let blob = mine.compactMap { strings[$0] }
        .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        .compactMap { String(data: $0, encoding: .utf8) }.joined()
    return mine.count >= 6 && !blob.contains("變數") && blob.contains("環境變量")
}())

// [T-shortcut-envvar-howto] The completion dialog tells the user how to use
// and where to find the variable; the result value stays the bare name.
check("dialog explains how to read it and where to view / delete it",
      intent.contains("To use it, ask Minis in any chat to read $\\(key).")
      && intent.contains("open Minis → Settings → Environment Variables.")
      && intent.components(separatedBy: "To view, edit or delete it").count - 1 == 2)
// [T-shortcut-envvar-summary] The action line shows the full name shape.
check("summary puts the fixed prefix right before the suffix field",
      intent.contains(#"Summary("Save \(\.$text) to Minis as $MINIS_SHORTCUT_OPT_\(\.$suffix)")"#))
check("summary prefix matches the store's prefix", store.contains(#"shortcutKeyPrefix = "MINIS_SHORTCUT_OPT_""#))
check("old summary string is gone", !xc.contains("\"Save ${text} to Minis as ${suffix}\" : {"))
check("result value is still just the variable name (chainable)", intent.contains("return .result(value: key, dialog:"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
