import Foundation

// [T-config-readable] Human-readable descriptions of minis-config changes.
//
// The confirmation sheet and Logs → Config Changes used to show only the raw
// path and JSON old/new values — for a model group's `entries` that is a list
// of "<instanceUUID>/<modelId>" strings nobody can read. Every writable field
// now declares, at registration, how its values read to a person
// (`ConfigReadable`), and the bridge renders one sentence per change BEFORE the
// confirmation sheet (names of things about to be removed are gone after the
// write). The same rendering is persisted with the audit row.
//
// USER-FACING ONLY. The text is for the person approving the change and
// reviewing the log. It never reaches the model: no CLI response, audit
// list/get output or user_message carries it (see ConfigOffloadBridge
// `auditEntryDict`).
//
// This file is Foundation-only on purpose: standalone tests compile it
// together with ConfigField.swift (see MinisTests/Standalone).

// MARK: - Declaration (per field)

/// How a field's change reads to a person. Required for every `ConfigField`.
struct ConfigReadable {
    /// Localization key for the field noun ("Default thinking level"). nil =
    /// the field's `displayName`, which is then also the key.
    var fieldLabel: String?
    var formatter: ConfigValueFormatter
    /// Set only by `.generic(reason:)`: why this field has no dedicated
    /// template. Launch validation lists every writable field that has one.
    let genericReason: String?

    init(_ formatter: ConfigValueFormatter, label: String? = nil) {
        self.fieldLabel = label
        self.formatter = formatter
        self.genericReason = nil
    }

    private init(genericReason: String) {
        self.fieldLabel = nil
        self.formatter = .generic
        self.genericReason = genericReason
    }

    /// Explicit, greppable opt-out: renders "<field>: <old> → <new>" from the
    /// raw values. Every use must say why; validation logs each writable one.
    static func generic(reason: String) -> ConfigReadable {
        ConfigReadable(genericReason: reason)
    }

    /// For fields that never reach the write path (read-only / hidden).
    static let notWritable = ConfigReadable.generic(reason: "not writable through minis-config")

    var isGeneric: Bool { genericReason != nil }
}

/// What kind of record an id refers to, for id → name resolution.
enum ConfigRefKind {
    case modelEntry
    case group
    case providerInstance
    case subAgent
    case thinkingRule(instanceId: String)
    /// `entry:<id>` / `group:<id>` session model sources.
    case modelSource
}

enum NumberUnit {
    case plain
    case tokens
    case seconds
    case bytes
    case points
}

/// How a value reads. All label arguments are localization keys (English
/// source strings in Localizable.xcstrings).
enum ConfigValueFormatter {
    /// Raw-value fallback; only reachable through `ConfigReadable.generic`.
    case generic
    case bool(on: String = "On", off: String = "Off")
    /// Raw enum value → label key. Must cover every case of the schema.
    case enumLabels([String: String])
    /// `zero` (a key) replaces 0, e.g. "No limit".
    case number(NumberUnit = .plain, zero: String? = nil)
    case text(preview: Int = 40, empty: String = "(empty)")
    /// Long prose: reports added / removed line counts, never the content.
    case longText
    /// Query, fragment and user-info are dropped (they can carry tokens).
    case url(empty: String = "Default")
    case image
    /// Never renders the value. A `$$VAR` reference names the variable only.
    case secret
    case ref(ConfigRefKind, empty: String = "Not set")
    case refList(ConfigRefKind, ordered: Bool)
    /// Plain string lists (DNS servers, modalities); `labels` maps raw → key.
    case stringList(ordered: Bool, labels: [String: String] = [:])
    /// One value → one phrase; composed into the standard change sentence.
    case custom(@MainActor (ConfigValue) -> ReadableArg)
    /// Whole sentences from (old, new); nil falls back to the generic sentence.
    case sentence(@MainActor (_ old: ConfigValue, _ new: ConfigValue) -> [ReadableLine]?)
}

// MARK: - Rendered form (persisted)

/// One sentence: a localization key (English format string using `%@` /
/// `%n$@` placeholders only) plus its arguments. Names are frozen as literal
/// text at write time; labels stay keys so the sentence re-renders in whatever
/// language the UI uses later.
struct ReadableLine: Codable, Hashable {
    let key: String
    let args: [ReadableArg]

    init(_ key: String, _ args: [ReadableArg] = []) {
        self.key = key
        self.args = args
    }
}

indirect enum ReadableArg: Codable, Hashable {
    /// Frozen literal: a group / model / provider name, a number, a URL.
    case text(String)
    /// Localization key, resolved at display time.
    case key(String)
    case line(ReadableLine)
    /// Items joined with the localized ", ".
    case list([ReadableArg])
    /// Clauses joined with the localized "; ".
    case clauses([ReadableArg])
}

/// What the confirm sheet shows and the audit row persists (`readable` column).
struct ReadableSummary: Codable, Hashable {
    /// Schema version of this JSON.
    var v: Int = 1
    /// UI language `text` was rendered in (informational).
    let locale: String
    /// Pre-rendered text; used when `lines` cannot be rendered.
    let text: String
    let lines: [ReadableLine]
    /// Groups rows about the same record in the batch summary, e.g.
    /// "groups:<id>". nil = a global setting.
    let subject: String?

    func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(json: String?) -> ReadableSummary? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReadableSummary.self, from: data)
    }
}

// MARK: - Redaction guarantee

/// A value that has been through the same masking the audit log and the
/// confirmation sheet apply: credential keys (`apiKey`, `oauthToken`, …)
/// collapse to a fixed mask unless they are a `$$VAR` reference, and an inline
/// image data URI collapses to "<image>". The renderer only accepts this type,
/// so an unmasked secret cannot be passed to it by mistake — every initializer
/// masks.
struct RedactedConfigValue {
    let value: ConfigValue

    /// A single field's value; `fieldLeaf` is the last path segment.
    init(fieldLeaf: String, value: ConfigValue) {
        var v = value
        if ConfigValue.secretObjectKeys.contains(fieldLeaf),
           case .object(let masked) = ConfigValue.object([fieldLeaf: value]).redactingSecrets(),
           let mv = masked[fieldLeaf] {
            v = mv
        }
        if case .string(let s) = v, Self.isInlineImage(s) {
            v = .string("<image>")
        }
        self.value = v
    }

    /// A collection `add` payload: every nested credential key is masked.
    init(payload: ConfigValue) {
        self.value = Self.maskImages(payload.redactingSecrets())
    }

    static func isInlineImage(_ s: String) -> Bool {
        s.hasPrefix("data:image/")
    }

    private static func maskImages(_ v: ConfigValue) -> ConfigValue {
        switch v {
        case .string(let s) where isInlineImage(s): return .string("<image>")
        case .array(let a): return .array(a.map(maskImages))
        case .object(let o): return .object(o.mapValues(maskImages))
        default: return v
        }
    }
}

// MARK: - Pure helpers (no app state; covered by standalone tests)

enum ReadableCore {
    /// At most this many names are listed per clause; the rest are counted.
    static let maxListedNames = 5
    /// Localized separators ("、" / "；" in Chinese).
    static let listSeparatorKey = ", "
    static let clauseSeparatorKey = "; "

    struct ListItem: Equatable {
        let id: String
        let count: Int
    }

    struct ListDiff: Equatable {
        /// The new first element, when ordered and it changed.
        var newFirst: String?
        var added: [ListItem]
        var removed: [ListItem]
        /// The elements present in both lists are in a different order.
        var reordered: Bool
        /// How many elements are present in both lists.
        var keptCount: Int

        var isEmpty: Bool { newFirst == nil && added.isEmpty && removed.isEmpty && !reordered }
    }

    // BEGIN listDiff
    /// Multiset diff of two id lists. Duplicates count: [a, a] → [a] removes
    /// one a. Kept elements are compared by relative order only, so an add or
    /// remove never reads as a reorder.
    static func listDiff(old: [String], new: [String], ordered: Bool) -> ListDiff {
        var oldCount: [String: Int] = [:]
        var newCount: [String: Int] = [:]
        for id in old { oldCount[id, default: 0] += 1 }
        for id in new { newCount[id, default: 0] += 1 }

        var added: [ListItem] = []
        var seen = Set<String>()
        for id in new where seen.insert(id).inserted {
            let d = newCount[id, default: 0] - oldCount[id, default: 0]
            if d > 0 { added.append(ListItem(id: id, count: d)) }
        }
        var removed: [ListItem] = []
        seen.removeAll()
        for id in old where seen.insert(id).inserted {
            let d = oldCount[id, default: 0] - newCount[id, default: 0]
            if d > 0 { removed.append(ListItem(id: id, count: d)) }
        }

        func kept(_ list: [String]) -> [String] {
            var budget: [String: Int] = [:]
            for (id, n) in oldCount { budget[id] = min(n, newCount[id, default: 0]) }
            var out: [String] = []
            for id in list where budget[id, default: 0] > 0 {
                budget[id]! -= 1
                out.append(id)
            }
            return out
        }
        let keptOld = kept(old)
        let keptNew = kept(new)

        var newFirst: String?
        if ordered, let first = new.first, first != old.first { newFirst = first }
        return ListDiff(newFirst: newFirst, added: added, removed: removed,
                        reordered: keptOld != keptNew, keptCount: keptNew.count)
    }
    // END listDiff

    // BEGIN placeholderCount
    /// Number of arguments a `%@` / `%n$@` format consumes; `%%` is literal.
    /// Any other conversion makes the format unusable here (returns -1).
    static func placeholderCount(_ format: String) -> Int {
        let chars = Array(format)
        var sequential = 0
        var maxPositional = 0
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else { i += 1; continue }
            i += 1
            guard i < chars.count else { return -1 }
            if chars[i] == "%" { i += 1; continue }
            if chars[i] == "@" { sequential += 1; i += 1; continue }
            var digits = ""
            while i < chars.count, chars[i].isNumber { digits.append(chars[i]); i += 1 }
            guard !digits.isEmpty, i + 1 < chars.count, chars[i] == "$", chars[i + 1] == "@",
                  let n = Int(digits) else { return -1 }
            maxPositional = max(maxPositional, n)
            i += 2
        }
        if sequential > 0 && maxPositional > 0 { return -1 }
        return max(sequential, maxPositional)
    }
    // END placeholderCount

    // BEGIN render
    /// Render with `localize` (key → format in the current language). A
    /// translation whose placeholders do not match the arguments is ignored in
    /// favour of the English key, so a bad translation can never crash
    /// `String(format:)` or drop an argument.
    static func render(_ line: ReadableLine, localize: (String) -> String) -> String {
        let args = line.args.map { render($0, localize: localize) }
        var format = localize(line.key)
        if placeholderCount(format) != args.count { format = line.key }
        guard placeholderCount(format) == args.count else {
            return ([line.key] + args).joined(separator: " ")
        }
        return String(format: format, arguments: args.map { $0 as NSString })
    }

    static func render(_ arg: ReadableArg, localize: (String) -> String) -> String {
        switch arg {
        case .text(let s): return s
        case .key(let k): return localize(k)
        case .line(let l): return render(l, localize: localize)
        case .list(let items): return items.map { render($0, localize: localize) }.joined(separator: localize(listSeparatorKey))
        case .clauses(let items): return items.map { render($0, localize: localize) }.joined(separator: localize(clauseSeparatorKey))
        }
    }
    // END render

    // BEGIN valueHelpers
    /// Quote and shorten free text for a sentence.
    static func quoted(_ s: String, preview: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        let short = flat.count > preview ? String(flat.prefix(preview)) + "…" : flat
        return "“\(short)”"
    }

    /// Lines added / removed between two texts (multiset of lines).
    static func lineDelta(old: String, new: String) -> (added: Int, removed: Int) {
        let o = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let n = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let d = listDiff(old: o, new: n, ordered: false)
        return (d.added.reduce(0) { $0 + $1.count }, d.removed.reduce(0) { $0 + $1.count })
    }

    /// Drops user-info, query and fragment: any of them can carry a token.
    static func safeURL(_ s: String) -> String {
        guard var c = URLComponents(string: s), c.scheme != nil else {
            return s.split(separator: "?").first.map(String.init) ?? s
        }
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        return c.string ?? s
    }

    /// 64000 → "64K", 131072 → "128K", 1_048_576 → "1M", 1500 → "1,500".
    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000, n % 1_000_000 == 0 { return "\(n / 1_000_000)M" }
        if n >= 1_048_576, n % 1_048_576 == 0 { return "\(n / 1_048_576)M" }
        if n >= 1_000, n % 1_000 == 0 { return "\(n / 1_000)K" }
        if n >= 1_024, n % 1_024 == 0 { return "\(n / 1_024)K" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Up to two decimals, no trailing zeros.
    static func plainNumber(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.minimumIntegerDigits = 1
        return f.string(from: NSNumber(value: d)) ?? String(d)
    }
    // END valueHelpers
}
