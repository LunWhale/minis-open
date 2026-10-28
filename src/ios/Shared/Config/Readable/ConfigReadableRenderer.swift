import Foundation

private let readableLogger = AppLogger(category: "ConfigReadable")

// [T-config-readable] App-side half of the readable descriptions: id → name
// resolution against the live stores, sentence assembly per formatter, and the
// launch-time template validation. The pure pieces live in ConfigReadable.swift.
//
// Every sentence produced here is USER-FACING ONLY (confirm sheet + Logs →
// Config Changes). Nothing here may be returned to the CLI or the model.

// MARK: - Id → name

@MainActor
enum ConfigRefResolver {
    /// The user-facing name of a record, frozen as literal text. Unknown ids
    /// read "unknown model 1234abcd…" rather than disappearing.
    static func name(_ kind: ConfigRefKind, _ id: String) -> ReadableArg {
        switch kind {
        case .modelEntry:
            let store = ProviderConfigStore.shared
            let ref = store.normalizeEntryRef(id)
            if let e = store.config.modelEntries.first(where: { $0.id == ref }) {
                return .text(modelLabel(e))
            }
            // A composite "<instance>/<model>" still names the model even
            // after the entry is gone.
            if let slash = id.firstIndex(of: "/") {
                let model = String(id[id.index(after: slash)...])
                let inst = String(id[..<slash])
                if let label = instanceLabel(inst) {
                    return .line(ReadableLine("unknown model %@", [.text("\(model) (\(label))")]))
                }
                return .line(ReadableLine("unknown model %@", [.text(model)]))
            }
            return .line(ReadableLine("unknown model %@", [.text(short(id))]))
        case .group:
            if let g = ProviderConfigStore.shared.group(for: id) { return .text(g.name) }
            return .line(ReadableLine("unknown group %@", [.text(short(id))]))
        case .providerInstance:
            if let label = instanceLabel(id) { return .text(label) }
            return .line(ReadableLine("unknown provider %@", [.text(short(id))]))
        case .subAgent:
            let real = id == SubAgentsCollection.builtInAlias ? SubAgentDefinition.builtInId : id
            if let def = SubAgentStore.shared.subAgent(id: real) { return .text(def.name) }
            return .line(ReadableLine("unknown sub agent %@", [.text(short(id))]))
        case .thinkingRule(let instanceId):
            if let r = ThinkingRuleCache.shared.rules(for: instanceId).first(where: { $0.id == id }) {
                return .text(r.label)
            }
            return .line(ReadableLine("unknown rule %@", [.text(short(id))]))
        case .modelSource:
            if id.hasPrefix("entry:") { return name(.modelEntry, String(id.dropFirst("entry:".count))) }
            if id.hasPrefix("group:") {
                return .line(ReadableLine("group “%@”", [name(.group, String(id.dropFirst("group:".count)))]))
            }
            return .text(id)
        }
    }

    /// "Claude Sonnet 5.5 (Anthropic(53))" — the model qualified by its
    /// provider instance, so two instances of one model stay distinguishable.
    static func modelLabel(_ e: ModelEntry) -> String {
        let model = e.model.displayName.isEmpty ? e.model.id : e.model.displayName
        guard let label = instanceLabel(e.providerInstanceId) else { return model }
        return "\(model) (\(label))"
    }

    static func instanceLabel(_ id: String) -> String? {
        guard let inst = ProviderConfigStore.shared.instance(for: id) else { return nil }
        let label = inst.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? inst.providerType.displayName : label
    }

    static func short(_ id: String) -> String {
        id.count > 12 ? String(id.prefix(8)) + "…" : id
    }
}

// MARK: - Rendering

@MainActor
enum ConfigReadableRenderer {
    /// Localized format for a key, following the in-app language picker.
    nonisolated static func localize(_ key: String) -> String {
        AppBundle.current.localizedString(forKey: key, value: key, table: nil)
    }

    nonisolated static var currentLanguage: String {
        let picked = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        return picked.isEmpty ? (Bundle.main.preferredLocalizations.first ?? "en") : picked
    }

    static func summary(_ lines: [ReadableLine], subject: String?) -> ReadableSummary {
        let text = lines.map { ReadableCore.render($0, localize: localize) }.joined(separator: "\n")
        return ReadableSummary(locale: currentLanguage, text: text, lines: lines, subject: subject)
    }

    // MARK: Field writes (set / .append / .remove)

    /// Sentences for one field write. `.append` / `.remove` arrive as the
    /// whole old and new arrays, so the list diff describes them naturally.
    /// Never fails: anything unexpected falls back to the generic sentence.
    static func forFieldWrite(_ field: ConfigField,
                              old: RedactedConfigValue,
                              new: RedactedConfigValue) -> ReadableSummary {
        let spec = field.readable
        let label = spec.fieldLabel ?? field.displayName
        var phrase: ReadableArg = .key(label)
        var subject: String?
        if let (base, id, _) = ConfigRegistry.splitCollectionPath(field.path),
           let coll = ConfigRegistry.shared.collection(basePath: base),
           let entity = coll.entityLabel(id: id) {
            phrase = .line(ReadableLine(coll.readableSubjectFormat, [.text(entity), .key(label)]))
            subject = "\(base):\(id)"
        }
        let lines = sentences(spec.formatter, phrase: phrase, old: old.value, new: new.value)
            ?? [genericLine(phrase, old: old.value, new: new.value)]
        if spec.isGeneric {
            readableLogger.info("[ConfigReadable] generic sentence for \(field.path) (\(spec.genericReason ?? ""))")
        }
        return summary(lines, subject: subject)
    }

    private static func sentences(_ f: ConfigValueFormatter, phrase: ReadableArg,
                                  old: ConfigValue, new: ConfigValue) -> [ReadableLine]? {
        switch f {
        case .generic:
            return nil
        case .secret:
            if case .string(let s) = new, s.hasPrefix("$$"), s.count > 2 {
                return [ReadableLine("%1$@: now uses the environment variable $%2$@",
                                     [phrase, .text(String(s.dropFirst(2)))])]
            }
            return [ReadableLine("%@: updated (value hidden)", [phrase])]
        case .longText:
            guard let o = stringOrEmpty(old), let n = stringOrEmpty(new) else { return nil }
            if o == n { return [ReadableLine("%@: unchanged", [phrase])] }
            if n.isEmpty { return [ReadableLine("%@: cleared", [phrase])] }
            let d = ReadableCore.lineDelta(old: o, new: n)
            return [ReadableLine("%1$@: edited (+%2$@ / −%3$@ lines, %4$@ characters now)",
                                 [phrase, .text("\(d.added)"), .text("\(d.removed)"), .text("\(n.count)")])]
        case .refList(let kind, let ordered):
            let firstKey: String = {
                if case .modelEntry = kind { return Self.primaryFirstKey }
                return Self.plainFirstKey
            }()
            return listLine(phrase, old: old, new: new, ordered: ordered, firstKey: firstKey) {
                ConfigRefResolver.name(kind, $0)
            }.map { [$0] }
        case .stringList(let ordered, let labels):
            return listLine(phrase, old: old, new: new, ordered: ordered, firstKey: Self.plainFirstKey) {
                labels[$0].map { .key($0) } ?? .text($0)
            }.map { [$0] }
        case .sentence(let make):
            return make(old, new)
        default:
            guard let o = phraseFor(f, old), let n = phraseFor(f, new) else { return nil }
            return [changeLine(phrase, o, n)]
        }
    }

    /// "<field>: <old> → <new>", or "<field>: <value> (unchanged)".
    static func changeLine(_ phrase: ReadableArg, _ old: ReadableArg, _ new: ReadableArg) -> ReadableLine {
        if old == new { return ReadableLine("%1$@: %2$@ (unchanged)", [phrase, new]) }
        return ReadableLine("%1$@: %2$@ → %3$@", [phrase, old, new])
    }

    static func genericLine(_ phrase: ReadableArg, old: ConfigValue, new: ConfigValue) -> ReadableLine {
        changeLine(phrase, genericPhrase(old), genericPhrase(new))
    }

    /// Raw-value phrase for the fallback sentence.
    static func genericPhrase(_ v: ConfigValue) -> ReadableArg {
        switch v {
        case .null: return .key("(none)")
        case .bool(let b): return .key(b ? "On" : "Off")
        case .int(let i): return .text(String(i))
        case .double(let d): return .text(ReadableCore.plainNumber(d))
        case .string(let s): return s.isEmpty ? .key("(empty)") : .text(ReadableCore.quoted(s, preview: 40))
        case .array(let a): return .line(ReadableLine("%@ items", [.text("\(a.count)")]))
        case .object: return .key("(settings object)")
        }
    }

    /// One value → phrase for the value formatters; nil when the value does
    /// not have the shape the formatter expects.
    static func phraseFor(_ f: ConfigValueFormatter, _ v: ConfigValue) -> ReadableArg? {
        switch f {
        case .bool(let on, let off):
            guard case .bool(let b) = v else { return nil }
            return .key(b ? on : off)
        case .enumLabels(let labels):
            guard case .string(let s) = v else { return nil }
            if let k = labels[s] { return .key(k) }
            return s.isEmpty ? .key("(empty)") : .text(s)
        case .number(let unit, let zero):
            let d: Double
            switch v {
            case .int(let i): d = Double(i)
            case .double(let x): d = x
            default: return nil
            }
            if d == 0, let zero { return .key(zero) }
            switch unit {
            case .plain: return .text(ReadableCore.plainNumber(d))
            case .tokens: return .line(ReadableLine("%@ tokens", [.text(ReadableCore.compactCount(Int(d)))]))
            case .seconds: return .line(ReadableLine("%@ s", [.text(ReadableCore.plainNumber(d))]))
            case .points: return .line(ReadableLine("%@ pt", [.text(ReadableCore.plainNumber(d))]))
            case .bytes: return .text(ByteCountFormatter.string(fromByteCount: Int64(d), countStyle: .file))
            }
        case .text(let preview, let empty):
            guard case .string(let s) = v else { return nil }
            return s.isEmpty ? .key(empty) : .text(ReadableCore.quoted(s, preview: preview))
        case .url(let empty):
            guard case .string(let s) = v else { return nil }
            return s.isEmpty ? .key(empty) : .text(ReadableCore.safeURL(s))
        case .image:
            guard case .string(let s) = v else { return nil }
            if s.isEmpty { return .key("Default icon") }
            if s == "<image>" || RedactedConfigValue.isInlineImage(s) { return .key("Custom image") }
            return .text(s)
        case .ref(let kind, let empty):
            guard case .string(let s) = v else { return nil }
            return s.isEmpty ? .key(empty) : ConfigRefResolver.name(kind, s)
        case .custom(let make):
            return make(v)
        case .generic, .secret, .longText, .refList, .stringList, .sentence:
            return nil
        }
    }

    // MARK: Lists

    /// First element of a model list = the group's primary model.
    static let primaryFirstKey = "primary is now %@"
    static let plainFirstKey = "first is now %@"

    static func listLine(_ phrase: ReadableArg, old: ConfigValue, new: ConfigValue,
                         ordered: Bool, firstKey: String,
                         name: (String) -> ReadableArg) -> ReadableLine? {
        guard let o = strings(old), let n = strings(new) else { return nil }
        let d = ReadableCore.listDiff(old: o, new: n, ordered: ordered)
        if d.isEmpty { return ReadableLine("%@: unchanged", [phrase]) }
        var clauses: [ReadableArg] = []
        if let first = d.newFirst { clauses.append(.line(ReadableLine(firstKey, [name(first)]))) }
        if !d.added.isEmpty { clauses.append(.line(ReadableLine("added %@", [nameList(d.added, name)]))) }
        if !d.removed.isEmpty { clauses.append(.line(ReadableLine("removed %@", [nameList(d.removed, name)]))) }
        if d.reordered {
            clauses.append(.key("order changed"))
        } else if ordered, d.keptCount > 0, !clauses.isEmpty {
            clauses.append(.key("rest of the order unchanged"))
        }
        if n.isEmpty { clauses.append(.key("now empty")) }
        return ReadableLine("%1$@: %2$@", [phrase, .clauses(clauses)])
    }

    /// Names merged by what they read as (two ids that name the same thing
    /// count together), "×N" for repeats, the first few then "+N more".
    static func nameList(_ items: [ReadableCore.ListItem], _ name: (String) -> ReadableArg) -> ReadableArg {
        var order: [ReadableArg] = []
        var counts: [ReadableArg: Int] = [:]
        for item in items {
            let n = name(item.id)
            if counts[n] == nil { order.append(n) }
            counts[n, default: 0] += item.count
        }
        let rendered: [ReadableArg] = order.map { n in
            let c = counts[n] ?? 1
            return c > 1 ? .line(ReadableLine("%1$@ ×%2$@", [n, .text("\(c)")])) : n
        }
        let cap = ReadableCore.maxListedNames
        guard rendered.count > cap else { return .list(rendered) }
        return .line(ReadableLine("%1$@ and %2$@ more", [.list(Array(rendered.prefix(cap))),
                                                         .text("\(rendered.count - cap)")]))
    }

    private static func strings(_ v: ConfigValue) -> [String]? {
        switch v {
        case .null: return []
        case .array(let a):
            return a.map { if case .string(let s) = $0 { return s } else { return $0.displayString } }
        default: return nil
        }
    }

    private static func stringOrEmpty(_ v: ConfigValue) -> String? {
        switch v {
        case .null: return ""
        case .string(let s): return s
        default: return nil
        }
    }

    // MARK: Collection add / remove

    static func forCollectionAdd(_ c: ConfigCollection, payload: RedactedConfigValue) -> ReadableSummary {
        var lines = c.readableForAdd(payload)
        if lines.isEmpty { lines = [ReadableLine("%@: new entry added", [.key(c.displayName)])] }
        return summary(lines, subject: "\(c.basePath):new")
    }

    static func forCollectionRemove(_ c: ConfigCollection, childId: String) -> ReadableSummary {
        var lines = c.readableForRemove(id: childId)
        if lines.isEmpty {
            lines = [ReadableLine("%1$@: removed %2$@", [.key(c.displayName),
                                                        .text(c.entityLabel(id: childId) ?? childId)])]
        }
        return summary(lines, subject: "\(c.basePath):\(childId)")
    }

    // MARK: Launch validation

    /// Logs every writable field still on the generic template and, in DEBUG,
    /// stops on an enum label table that misses a case of its schema — the
    /// strong reminder the plan asks for when a new setting lands.
    static func validateRegistry(_ r: ConfigRegistry) {
        var writable = 0
        var generic: [String] = []
        var gaps: [String] = []
        for f in r.allFieldsForValidation() where f.access == .readwrite {
            writable += 1
            let spec = f.readable
            if spec.isGeneric { generic.append("\(f.path) (\(spec.genericReason ?? ""))") }
            if case .enumLabels(let labels) = spec.formatter {
                for c in enumCases(f.valueSchema) where labels[c] == nil {
                    gaps.append("\(f.path): '\(c)'")
                }
            }
        }
        readableLogger.info("[ConfigReadable] validated \(writable) writable fields; generic=\(generic.count)\(generic.isEmpty ? "" : " " + generic.joined(separator: ", "))")
        if !gaps.isEmpty {
            readableLogger.error("[ConfigReadable] enum label gaps: \(gaps.joined(separator: "; "))")
            #if DEBUG
            assertionFailure("[ConfigReadable] enum label gaps: \(gaps.joined(separator: "; "))")
            #endif
        }
    }

    private static func enumCases(_ s: ConfigValueSchema) -> [String] {
        switch s {
        case .stringEnum(let cases): return cases
        case .optional(let inner): return enumCases(inner)
        default: return []
        }
    }
}

// MARK: - Display

extension ReadableSummary {
    /// Rendered in the CURRENT UI language from `lines` (names stay as frozen
    /// at write time); `text` if there are no lines.
    var displayText: String {
        guard !lines.isEmpty else { return text }
        return lines.map { ReadableCore.render($0, localize: ConfigReadableRenderer.localize) }
            .joined(separator: "\n")
    }
}

extension ThinkingLevel {
    /// [T-config-readable] Raw value → the label keys `displayName` uses.
    static let readableLabels: [String: String] = [
        "off": "Off", "low": "Low", "medium": "Med", "high": "High",
        "xhigh": "XHigh", "max": "Max", "ultra": "Ultra",
    ]
}
