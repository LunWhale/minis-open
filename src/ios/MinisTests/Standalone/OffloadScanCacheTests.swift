// [T-offload-scan-cache] Typing froze for 7-9 s every few minutes in two long
// chats (device log 2026-09-27: 14 main-thread hangs, all under
// offloadContextIfNeeded → BPETokenizer.countPartTokens).
//
//   1. The scan ran over the RAW history (2252 msgs) although only 1104 reach
//      the model after compact-v2 — now it starts after the anchor.
//   2. It BPE-encoded all 578 candidates (~610k tokens) just to rank them —
//      now it ranks and accounts with ContextSizeMeter's cheap estimate
//      (calibrated like the context meter); no BPE at all. Not bytes: images
//      are MBs but ~1-2k tokens, and CJK is 3 bytes per ~1 token.
//   3. Every trigger re-judged the whole history — now per-part verdicts are
//      cached (fingerprint-validated, LRU-bounded, rebuildable).
//
// The cache class below is copied from AIChatViewModel+Offloading.swift; the
// drift check in section 4 fails if the shipping copy changes.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift OffloadScanCacheTests.swift`

import Foundation

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
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let off = (try? String(contentsOf: root.appendingPathComponent("Agent/Chat/AIChatViewModel+Offloading.swift"), encoding: .utf8)) ?? ""
let thisFile = (try? String(contentsOfFile: #filePath, encoding: .utf8)) ?? ""
check("source found", !off.isEmpty)

// ---- copy of OffloadScanCache ----
@MainActor
final class OffloadScanCache {
    enum Verdict: UInt8 { case readback, alreadyOffloaded, tooSmall, candidate }

    struct Entry {
        var fingerprint: Int
        var verdict: Verdict
        /// Candidates only (0 otherwise).
        var bytes: Int
        /// ContextSizeMeter estimate, uncalibrated. Candidates only.
        var tokens: Int
        /// Scan generation of the last use, for LRU eviction.
        var lastUsed: UInt32
    }

    static let capacity = 4096

    private var entries: [String: Entry] = [:]
    private var generation: UInt32 = 0
    private(set) var hits = 0
    private(set) var misses = 0

    var count: Int { entries.count }

    func beginScan() {
        generation &+= 1
        hits = 0
        misses = 0
    }

    func lookup(_ key: String, fingerprint: Int) -> Entry? {
        guard var entry = entries[key], entry.fingerprint == fingerprint else {
            misses += 1
            return nil
        }
        hits += 1
        entry.lastUsed = generation
        entries[key] = entry
        return entry
    }

    func store(_ key: String, fingerprint: Int, verdict: Verdict, bytes: Int = 0, tokens: Int = 0) {
        entries[key] = Entry(fingerprint: fingerprint, verdict: verdict, bytes: bytes,
                             tokens: tokens, lastUsed: generation)
    }

    /// Evicts least-recently-used entries once over capacity.
    func endScan() {
        guard entries.count > Self.capacity else { return }
        let keep = Self.capacity * 3 / 4
        let victims = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(entries.count - keep)
        for (key, _) in victims { entries.removeValue(forKey: key) }
    }

    func removeAll() { entries.removeAll() }

    /// Cheap: UTF-8 length (O(1) for native strings) plus the first and last
    /// 32 bytes — an offload rewrite changes all of them.
    nonisolated static func fingerprint(content: String, extraBytes: Int, flag: Bool) -> Int {
        var h = Hasher()
        let utf8 = content.utf8
        h.combine(utf8.count)
        h.combine(extraBytes)
        h.combine(flag)
        h.combine(utf8.prefix(32).reduce(0) { $0 &* 31 &+ Int($1) })
        h.combine(utf8.suffix(32).reduce(0) { $0 &* 31 &+ Int($1) })
        return h.finalize()
    }

    /// Size plus both ends: image headers (e.g. JPEG/JFIF) are often identical
    /// across files, so the tail carries most of the distinction.
    nonisolated static func fingerprint(data: Data) -> Int {
        var h = Hasher()
        h.combine(data.count)
        h.combine(data.prefix(32))
        h.combine(data.suffix(32))
        return h.finalize()
    }
}
// ---- end copy ----

@MainActor func run() {
    print("\n▶️  1. hit / miss / fingerprint invalidation")
    let c = OffloadScanCache()
    let big = String(repeating: "x", count: 900)
    let fp = OffloadScanCache.fingerprint(content: big, extraBytes: 0, flag: false)
    c.beginScan()
    check("first scan misses", c.lookup("r:t1", fingerprint: fp) == nil && c.misses == 1)
    c.store("r:t1", fingerprint: fp, verdict: .candidate, bytes: 900)
    c.beginScan()
    check("next scan hits with the same fingerprint", c.lookup("r:t1", fingerprint: fp)?.verdict == .candidate && c.hits == 1)
    let stub = "<system-reminder>offloaded</system-reminder> saved to /var/minis/offloads/tools/x"
    let fpStub = OffloadScanCache.fingerprint(content: stub, extraBytes: 0, flag: false)
    check("offloaded (rewritten) part misses → re-judged", c.lookup("r:t1", fingerprint: fpStub) == nil)
    let sameLen = "y" + String(repeating: "x", count: 899)
    check("same length, different leading bytes → different fingerprint",
          OffloadScanCache.fingerprint(content: sameLen, extraBytes: 0, flag: false) != fp)
    check("flag flip (argument pruned / readback) → different fingerprint",
          OffloadScanCache.fingerprint(content: big, extraBytes: 0, flag: true) != fp)

    print("\n▶️  2. stored estimate")
    c.store("r:t2", fingerprint: 7, verdict: .candidate, bytes: 900, tokens: 250)
    check("candidate keeps its bytes and estimate", c.lookup("r:t2", fingerprint: 7).map { $0.bytes == 900 && $0.tokens == 250 } == true)
    c.store("r:t2", fingerprint: 8, verdict: .alreadyOffloaded)
    check("a re-judged part replaces the entry (no stale estimate)", c.lookup("r:t2", fingerprint: 8).map { $0.verdict == .alreadyOffloaded && $0.tokens == 0 } == true)
    let jpegHead = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 60))
    let imgA = jpegHead + Data(repeating: 1, count: 2000), imgB = jpegHead + Data(repeating: 2, count: 2000)
    check("same size + same header, different images → different fingerprints (tail bytes)",
          OffloadScanCache.fingerprint(data: imgA) != OffloadScanCache.fingerprint(data: imgB))
    let tailA = String(repeating: "a", count: 600) + "END-1", tailB = String(repeating: "a", count: 600) + "END-2"
    check("same length + same head, different tail → different fingerprints",
          OffloadScanCache.fingerprint(content: tailA, extraBytes: 0, flag: false) != OffloadScanCache.fingerprint(content: tailB, extraBytes: 0, flag: false))

    print("\n▶️  3. LRU bound")
    let l = OffloadScanCache()
    l.beginScan()
    for i in 0..<OffloadScanCache.capacity { l.store("old\(i)", fingerprint: i, verdict: .tooSmall, bytes: 0) }
    l.endScan()
    check("at capacity: nothing evicted", l.count == OffloadScanCache.capacity)
    l.beginScan()
    _ = l.lookup("old0", fingerprint: 0)          // touched this scan → recent
    for i in 0..<100 { l.store("new\(i)", fingerprint: i, verdict: .tooSmall, bytes: 0) }
    l.endScan()
    check("over capacity: trimmed to 3/4", l.count == OffloadScanCache.capacity * 3 / 4)
    check("recently used survive", l.lookup("old0", fingerprint: 0) != nil && l.lookup("new99", fingerprint: 99) != nil)
    // All other "old" entries share one (older) generation, so which of them go
    // is arbitrary — the property is that only that generation is evicted.
    let newSurvivors = (0..<100).filter { l.lookup("new\($0)", fingerprint: $0) != nil }.count
    let oldSurvivors = (1..<OffloadScanCache.capacity).filter { l.lookup("old\($0)", fingerprint: $0) != nil }.count
    check("evictions came only from the least recently used generation",
          newSurvivors == 100 && oldSurvivors == OffloadScanCache.capacity * 3 / 4 - 101)
    l.removeAll()
    check("removeAll empties (rebuild path)", l.count == 0)
}
MainActor.assumeIsolated { run() }

print("\n▶️  4. scanner wiring (source invariants)")
func classBody(_ text: String) -> String {
    guard let a = text.range(of: "final class OffloadScanCache {"),
          let b = text.range(of: "\n}\n", range: a.upperBound..<text.endIndex) else { return "" }
    return String(text[a.lowerBound..<b.upperBound])
}
check("test copy matches the shipping cache", !classBody(off).isEmpty && classBody(off) == classBody(thisFile))
check("scan starts after the compaction anchor",
      off.contains("let scanStart = min(offloadScanStartIndex(), agentHistory.count - protectedCount)")
      && off.contains("let candidateRange = scanStart..<(agentHistory.count - protectedCount)"))
check("anchor resolution mirrors effectiveAgentHistory (v2, lastIndex by dbMessageId)",
      off.contains("guard let marker = cachedLatestMarker, marker.version >= 2,")
      && off.contains("let anchorIdx = agentHistory.lastIndex(where: { $0.dbMessageId == anchorId }) else { return 0 }"))
check("ranking is by estimated tokens (not bytes: images / CJK would rank far too high)",
      off.contains("candidates.sort { $0.tokens > $1.tokens }") && !off.contains("candidates.sort { $0.bytes > $1.bytes }"))
check("candidates are estimated with ContextSizeMeter, only on a cache miss",
      off.components(separatedBy: "let tokens = ContextSizeMeter.estimateTokens(part)").count - 1 == 2
      && off.contains("tokens = ContextSizeMeter.estimateTokens(part)\n                        cache.store(key, fingerprint: fp, verdict: .candidate, bytes: data.count, tokens: tokens)"))
check("no BPE anywhere in the offload scan or loop", !off.contains("BPETokenizer.shared.countPartTokens"))
check("freed tokens use the context meter's calibration",
      off.contains("let calibrationRatio = contextCalibrationRatio(for: model.id)")
      && off.contains("let candidateTokens = ContextSizeMeter.calibrated(candidate.tokens, ratio: calibrationRatio)"))
let pers = (try? String(contentsOf: root.appendingPathComponent("Agent/Chat/AIChatViewModel+Persistence.swift"), encoding: .utf8)) ?? ""
check("cache is emptied when the VM loads a session",
      pers.contains("func loadSession() async {\n        // [T-offload-scan-cache]") && pers.contains("offloadScanCache.removeAll()"))
// An unfinished call (no tool_result yet) is neither offloaded nor cached: the
// answered check comes before ANY cache access in the toolUse branch.
func toolUseBranch(_ text: String) -> String {
    guard let a = text.range(of: "case .toolUse(let id, let name, let input, let isOffloadedArgument):"),
          let b = text.range(of: "case .imageData(let data, _, _):", range: a.upperBound..<text.endIndex) else { return "" }
    return String(text[a.lowerBound..<b.lowerBound])
}
let tu = toolUseBranch(off)
if let g = tu.range(of: "guard answeredToolUseIds.contains(id) else {"),
   let firstCache = tu.range(of: "cache.") {
    check("unfinished tool call: answered check precedes every cache access", g.lowerBound < firstCache.lowerBound)
} else {
    check("unfinished tool call: answered check precedes every cache access", false)
}
check("…and the unanswered path stores nothing",
      tu.contains("guard answeredToolUseIds.contains(id) else {\n                        skippedUnanswered += 1\n                        continue\n                    }"))
check("tool results enter history only after the whole batch finishes (why .toolResult may be cached)",
      (chatViewModelSource())
        .contains("let toolResultMessage = AgentMessage(role: .user, parts: toolResultParts)"))

print("\n▶️  5. no stall past a second")
check("offload loop has a time budget (≥1 part always taken)",
      off.contains("let offloadBudget: CFAbsoluteTime = 0.3")
      && off.contains("if offloadedCount > 0, CFAbsoluteTimeGetCurrent() - offloadStart > offloadBudget {"))
check("offload directory is counted, not stat'ed and sorted",
      !off.contains("includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]")
      && off.contains("contentsOfDirectory(atPath: toolsDir.path).count"))
check("no-baseline (FORCE) path uses the cached outbound meter",
      off.contains("if lastContextTokens == 0 {\n            effectiveTokens = measureOutboundContextTokens()"))
check("every call logs its wall-clock", off.contains("[OffloadTiming]"))
check("eviction runs every scan", off.contains("cache.endScan()"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
