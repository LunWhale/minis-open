// [T-ctx-builder] iOS-E runner: runs C01-C32, adds the generic invariant
// checks to every scenario, and writes one JSON file (argv[2]) with the
// checks, metrics, the summary rows (scenario x provider x {live, restart})
// and every RequestView for the golden snapshots. The driver prints and
// compares it.
//
// Generic checks per capture and provider (catalog A8):
//   (4) live vs restart image sha256 - reported, scenario rows assert it
//   (5) the same image attached twice - reported (duplicates column)
//   (6) silent loss: the history produced N images, the request carries
//       fewer and no placeholder accounts for the rest
//   (7) every placeholder path resolves to a file in the session directory
//
// Guarded like Kit.swift.
#if IMAGE_CTX_IOS_E
import Foundation

func placeholderPaths(_ text: String) -> [String] {
    var out: [String] = []
    for pattern in [#"Original at (/var/minis/[^\s]+?) —"#, #"original: (/var/minis/[^\s,;]+)"#] {
        let re = try! NSRegularExpression(pattern: pattern)
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range(at: 1), in: text) { out.append(String(text[r])) }
        }
    }
    return out
}

func runAll(workRoot: URL, resultsURL: URL) async {
    let only = ProcessInfo.processInfo.environment["IOSE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    var out: [[String: Any]] = []
    var summary: [[String: Any]] = []
    var views: [String: Any] = [:]
    for sc in scenarios where only?.contains(sc.id) ?? true {
        let caseRoot = workRoot.appendingPathComponent(sc.id, isDirectory: true)
        try? FileManager.default.removeItem(at: caseRoot)
        try? FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
        HarnessEnv.root = caseRoot
        let c = Ctx(sc.id)
        let t0 = Date()
        await sc.run(c)
        var scViews: [String: Any] = [:]
        for phase in ["live", "restart"] where c.captures[phase] != nil {
            var pv: [String: Any] = [:]
            for p in Provider.allCases {
                let inv = c.inv(phase, p)
                pv[p.rawValue] = viewJSON(c.view(phase, p))
                let lost = c.producedImages - inv.imageCount - inv.placeholders.filter { $0.hasPrefix("[image") }.count
                let allText = c.texts(phase, p)
                let unresolved = placeholderPaths(allText).filter { !FileManager.default.fileExists(atPath: c.session.hostPath(linux: $0).path) }
                summary.append([
                    "scenario": sc.id, "provider": p.rawValue, "phase": phase,
                    "images": inv.imageCount, "maxEdge": inv.maxEdge, "mimes": Array(Set(inv.mimes)).sorted(),
                    "totalBytes": inv.totalBytes, "totalBase64": inv.totalBase64, "compliant": inv.compliant,
                    "flags": Array(inv.flags).sorted(), "adjacency": inv.adjacencyOK, "adjacencyNote": inv.adjacencyNote,
                    "duplicates": inv.duplicateImages, "placeholders": inv.placeholders.count,
                    "silentlyLost": max(0, lost), "unresolvedPlaceholderPaths": unresolved.map(normalized),
                ])
                if !unresolved.isEmpty { c.desired("\(p) \(phase): every placeholder path exists (\(unresolved.count) missing)", false) }
            }
            scViews[phase] = pv
        }
        // Generic (6) as a desired check, once per phase across providers.
        for phase in ["live", "restart"] where c.captures[phase] != nil {
            let losing = Provider.allCases.filter { p in
                let inv = c.inv(phase, p)
                return c.producedImages - inv.imageCount - inv.placeholders.filter { $0.hasPrefix("[image") }.count > 0
            }
            if !losing.isEmpty { c.desired("\(phase): no image silently lost (\(losing.map(\.rawValue).joined(separator: ",")))", false) }
        }
        views[sc.id] = scViews
        out.append([
            "id": sc.id, "title": sc.title, "input": sc.input, "catalogCurrent": sc.catalogCurrent, "desired": sc.desired,
            "checks": c.checks.map { ["label": $0.label, "desired": $0.desired, "ok": $0.ok] },
            "notes": c.notes, "metrics": c.metrics, "producedImages": c.producedImages,
            "seconds": Date().timeIntervalSince(t0),
            "builderLogs": c.captures["live"]?.logs.filter { $0.contains("[ImageBudget]") || $0.contains("[Bridge]") } ?? [],
        ])
        print("ran \(sc.id) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }
    let json: [String: Any] = ["scenarios": out, "summary": summary, "views": views,
                               "headerOnlyFormats": Array(Kit.headerOnlyFormats).sorted()]
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
    try! data.write(to: resultsURL)
}
#endif
