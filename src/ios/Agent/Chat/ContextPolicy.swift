import Foundation

/// Determines offload / compact / exhausted thresholds based on model context window size.
///
/// Tiers:
/// - **< 32K**: No auto-offload, no auto-compact. Prompt "start new / clear" when full.
/// - **32K–64K**: Auto-offload when remaining ≤ 10K. No auto-compact (user can manually).
///   Prompt "start new / clear" when exhausted.
/// - **64K–128K**: Auto-offload when remaining ≤ 20K. Auto-compact when remaining ≤ 10K.
/// - **≥ 128K**: Auto-offload when remaining ≤ 40K. Auto-compact when remaining ≤ 20K.
struct ContextPolicy {
    /// Tokens used must exceed this to trigger auto-offload. 0 = offload disabled.
    let offloadThreshold: Int
    /// Target token count after offloading. 0 = offload everything eligible.
    let offloadTarget: Int
    /// Tokens used must exceed this to trigger auto-compact. 0 = auto-compact disabled.
    let compactThreshold: Int
    /// When true, reaching the limit shows "start new session / clear" instead of compact.
    let exhaustedOnly: Bool
    /// Whether user-initiated manual compact is allowed.
    let manualCompactAllowed: Bool

    /// [T-ctx-user-cap] A user-chosen group cap is NOT the same thing as a
    /// model's native window, and the tier table below only makes sense for the
    /// latter. The fixed 10K/20K/40K headroom subtractions — and the decision to
    /// disable auto-compact entirely under 64K — exist because a genuinely small
    /// model cannot afford a summary plus re-appended warm-up turns. When the
    /// user caps a 1M model at 32K none of that holds: the model has room to run
    /// the compaction call, and "I want this group to stay under 32K" is an
    /// instruction to compact, not a reason to stop compacting. So a user cap
    /// gets proportional thresholds and always keeps auto-compact available.
    init(contextWindow: Int, isUserCap: Bool = false) {
        if isUserCap {
            // Proportional: compact at 85%, offload at 70%, settle back to 55%.
            // Percentages (not fixed subtractions) keep the headroom sane across
            // the whole 32K…1M slider ladder — at 32K a 20K subtraction would
            // leave a threshold below the floor, and at 1M it would be noise.
            offloadThreshold = Int(Double(contextWindow) * 0.70)
            offloadTarget = Int(Double(contextWindow) * 0.55)
            compactThreshold = Int(Double(contextWindow) * 0.85)
            exhaustedOnly = false
            manualCompactAllowed = true
            return
        }
        if contextWindow < 32_000 {
            // < 32K: no offload, no compact
            offloadThreshold = 0
            offloadTarget = 0
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = false
        } else if contextWindow < 64_000 {
            // 32K–64K: offload when remaining ≤ 10K, no auto-compact
            offloadThreshold = contextWindow - 10_000
            offloadTarget = contextWindow - 15_000
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = true
        } else if contextWindow < 128_000 {
            // 64K–128K: offload when remaining ≤ 20K, compact when remaining ≤ 10K
            offloadThreshold = contextWindow - 20_000
            offloadTarget = contextWindow - 30_000
            compactThreshold = contextWindow - 10_000
            exhaustedOnly = false
            manualCompactAllowed = true
        } else {
            // ≥ 128K: offload when remaining ≤ 40K, compact when remaining ≤ 20K
            offloadThreshold = contextWindow - 40_000
            offloadTarget = contextWindow - 60_000
            compactThreshold = contextWindow - 20_000
            exhaustedOnly = false
            manualCompactAllowed = true
        }
    }

    // MARK: - Pre-send Check

    /// Pre-send context check result.
    enum CheckResult {
        /// Context is fine, proceed normally.
        case ok
        /// Context is near capacity — auto-compact before sending.
        case needsCompact
        /// Context is exhausted — prompt user to start new session or clear chat.
        case exhausted
    }

    /// Evaluate current token usage against policy thresholds.
    func check(estimatedTokens: Int, contextWindow: Int) -> CheckResult {
        // Check compact threshold first (only for tiers that support auto-compact)
        if compactThreshold > 0, estimatedTokens >= compactThreshold {
            return .needsCompact
        }

        // [T-ctx-overflow-hard-stop] Already at or past the ceiling. Whatever the
        // tier says about headroom economics is moot — the next request does not
        // fit. Compact if this tier can (manual compaction being allowed is the
        // signal that a summary is viable at all), otherwise report exhausted so
        // the caller prompts instead of sending a request that cannot succeed.
        // Without this, an exhausted-only tier answered `.ok` right up to its
        // advisory line and then kept answering `.ok` past 100%.
        if contextWindow > 0, estimatedTokens >= contextWindow {
            return manualCompactAllowed ? .needsCompact : .exhausted
        }

        // For tiers where auto-compact is disabled, check if context is exhausted
        if exhaustedOnly {
            let exhaustedThreshold = offloadThreshold > 0
                ? offloadThreshold
                : Int(Double(contextWindow) * 0.90)
            if estimatedTokens >= exhaustedThreshold {
                return .exhausted
            }
        }

        return .ok
    }

    /// Whether auto-offload should trigger at the given token count.
    func shouldOffload(estimatedTokens: Int) -> Bool {
        offloadThreshold > 0 && estimatedTokens >= offloadThreshold
    }

    /// What the agent loop does with its next request (see `inLoopStep`).
    enum InLoopStep: Equatable {
        /// Under the compact line — send.
        case proceed
        /// Compact in place, then re-check.
        case compact
        /// Compaction can do no more, but the request fits the window — send.
        case sendWithinWindow
        /// Over the window only by the calibrated extrapolation — send once for the provider to decide.
        case sendUncalibratedOnce
        /// Does not fit and nothing left to try.
        case stop
    }

    /// [T-ctx-measure-outbound] The in-loop guard's decision table, shared with
    /// Android `ContextPolicy.inLoopStep`. Every branch that is not `.compact`
    /// or `.stop` exists to keep a session from wedging: above the compact line
    /// is still sendable, and an "over the window" that rests only on a ratio
    /// (learned on other content, or borrowed from another model) gets one real
    /// request, whose answer or rejection then corrects the ratio.
    ///
    /// `canCompact` = compaction budget left AND the last pass made progress.
    /// `rawTokens` = the same request with no calibration applied.
    /// A window of 0 (unknown) never stops a request.
    static func inLoopStep(verdict: CheckResult, measured: Int, rawTokens: Int, window: Int,
                           canCompact: Bool, ratio: Double, uncalibratedSendUsed: Bool) -> InLoopStep {
        switch verdict {
        case .ok: return .proceed
        case .exhausted: return .stop
        case .needsCompact:
            if canCompact { return .compact }
            if window <= 0 || measured < window { return .sendWithinWindow }
            if !uncalibratedSendUsed, ratio > 1.0, rawTokens < window { return .sendUncalibratedOnce }
            return .stop
        }
    }
}

// MARK: - Outbound context measurement [T-ctx-measure-outbound]

/// Sizes the request that is ABOUT to be sent, so every capacity decision
/// (compact, offload, `max_tokens`) judges the context the model will actually
/// receive — not the size of some earlier request.
///
/// Why this exists: the guards used to take `max(localEstimate, lastAPIReport)`.
/// The API report is exact but describes the PREVIOUS request, and nothing
/// short of another successful call ever replaced it. So after a compaction
/// (or an offload) the stale pre-compaction number kept winning the `max()`,
/// the in-loop guard — which runs BEFORE the next call — re-compacted on it
/// until its cap, and the turn stopped with "Context is full and could not be
/// compacted further" having made zero API calls. Reopening the session
/// re-seeded the same number from the message it was stamped on, so the
/// session stayed wedged. The opposite happened after a revert: the last
/// report came from the compacted context, and under-read the restored history.
///
/// The fix is to stop treating the API number as a measurement of NOW and use
/// it for what it is good at — calibration:
///
///     size(now) = calibration × (estimate(outbound history) + estimate(system prompt + tools))
///
/// where `calibration = lastReported / estimate(that same request)`. Both sides
/// of the ratio describe ONE request, so it stays valid across compaction,
/// offload, revert and relaunch; whatever changes the outbound history changes
/// `estimate(outbound history)`, and the decision follows automatically.
enum ContextSizeMeter {

    /// Token estimate for a string, by character class.
    ///
    /// Fitted against cl100k_base on Chinese, Japanese, English prose, Swift,
    /// JSON, git logs and `ls -la` output: 0.66–1.18x the real count, versus
    /// 0.30–1.21x for the previous flat `chars / 3.5` — which read CJK text at
    /// under a third of its real size. The residual is per-session and is
    /// absorbed by the calibration ratio after the first response.
    ///
    /// Scans UTF-8 bytes rather than `unicodeScalars`: identical counts (a
    /// non-ASCII scalar is counted once, at its lead byte) at about half the
    /// cost — which matters because the measurement runs several times per
    /// loop iteration on the main actor, and dev builds are Debug (~45ms per
    /// pass over a 1M-token history via scalars, ~21ms via bytes).
    static func estimateTokens(_ text: String) -> Int {
        var letters = 0, digits = 0, asciiOther = 0, nonASCII = 0
        var copy = text
        copy.withUTF8 { bytes in
            for b in bytes {
                if b >= 0x80 {
                    if b & 0xC0 != 0x80 { nonASCII += 1 }   // lead byte = one scalar
                } else if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) {
                    letters += 1
                } else if b >= 48 && b <= 57 {
                    digits += 1
                } else {
                    asciiOther += 1
                }
            }
        }
        let tokens = Double(letters) / 4.5 + Double(digits) / 2.0
            + Double(asciiOther) * 0.35 + Double(nonASCII)
        return Int(tokens.rounded(.up))
    }

    // MARK: Wire framing [T-ctx-count-wire-framing]
    //
    // A message is not only its text. On the wire every tool call carries its
    // id (twice: on the call and on the result), its arguments as a JSON
    // string INSIDE the JSON body (so every quote and backslash is escaped
    // again), and the keys and punctuation that frame the message.
    //
    // On-device run 2026-10-07 (DeepSeek, session 38D5C536, the request after
    // the first trim: 235 messages, 130 tool calls): the provider counted
    // 70,277; this estimator over the raw body as sent gives 71,208; the
    // structured estimate was 60,980. The 9.3K it left out: call ids 2,660
    // (20.5 per call), argument escaping 1,557 (12 per call), text escaping
    // 758, framing 3,849 beyond the old 4 + 4 constants. Because that share
    // grows with the number of messages, not with their size, the calibration
    // ratio drifted 1.009 -> 1.194 as the run went on, and jumped at every trim
    // (the trim removes text and leaves the framing).
    //
    // The constants are the estimator applied to the compact Chat Completions
    // framing; Anthropic's tool_use / tool_result blocks are about the same
    // size, and what differs per provider stays with the calibration ratio.

    /// `{"role":"user","content":""}`
    static let perMessageOverhead = 8
    /// `"tool_calls":[{"id":"","type":"function","function":{"name":"","arguments":""}}]`
    static let perToolUseOverhead = 22
    /// What a tool message adds to a plain one: `"tool_call_id":""`.
    static let perToolResultOverhead = 6
    /// `"reasoning_content":""` on an assistant turn, sent even when empty.
    static let reasoningFieldOverhead = 6

    /// Extra tokens a string costs once it is a JSON string value: each quote,
    /// backslash and control character gains a backslash.
    static func wireEscapeTokens(_ text: String) -> Int {
        var escaped = 0
        var copy = text
        copy.withUTF8 { bytes in
            for b in bytes where b == 0x22 || b == 0x5C || b == 0x0A || b == 0x0D || b == 0x09 { escaped += 1 }
        }
        return Int((Double(escaped) * 0.35).rounded(.up))
    }

    /// A string as it is sent: its tokens plus its escaping.
    static func estimateWireTokens(_ text: String) -> Int {
        text.isEmpty ? 0 : estimateTokens(text) + wireEscapeTokens(text)
    }

    static func estimateTokens(_ part: AgentContentPart) -> Int {
        switch part {
        case .text(let text):
            return estimateWireTokens(text)
        case .toolUse(let id, let name, let input, _):
            var total = estimateTokens(name) + estimateTokens(id) + perToolUseOverhead
            if let data = try? JSONSerialization.data(withJSONObject: input),
               let json = String(data: data, encoding: .utf8) {
                total += estimateWireTokens(json)
            }
            return total
        case .toolResult(let id, _, let content, _, let imageData, _, _, _, _):
            // The tool's name is not repeated on the result.
            var total = estimateWireTokens(content) + estimateTokens(id) + perToolResultOverhead
            if let imageData { total += imageTokens(imageData) }
            return total
        case .imageData(let data, _, _):
            return imageTokens(data)
        }
    }

    /// [T-ctx-count-reasoning] Bumped whenever the estimate starts counting
    /// something it did not before. A calibration pair is only valid against
    /// the estimator that produced its `estimated` side: a ratio learned while
    /// reasoning was NOT counted (3-7x on DeepSeek) multiplied onto an estimate
    /// that now includes it reads a 22K request as 229K. Pairs stamped with an
    /// older version are skipped on replay (see `replayCalibration`).
    ///   1 = message parts only.   2 = plus echoed reasoning.
    ///   3 = plus wire framing: call ids, JSON-string escaping, per-message
    ///       and per-tool-call keys ([T-ctx-count-wire-framing]).
    static let estimatorVersion = 3

    /// `includeReasoning`: also count each assistant turn's `reasoningContent`,
    /// which Chat Completions (and the Anthropic compat-proxy path) send back
    /// on EVERY past turn. Pass what the live provider's
    /// `echoesReasoningContent` says, so the meter counts it exactly when it
    /// is on the wire.
    static func estimateTokens(_ messages: [AgentMessage], includeReasoning: Bool = false) -> Int {
        messages.reduce(0) { $0 + estimateTokens(message: $1, includeReasoning: includeReasoning) }
    }

    /// Persisted messages are cached: without it every measurement re-scans the
    /// whole history, several times per iteration. The key carries the
    /// message's content SHAPE as well as its id, because offload rewrites a
    /// persisted message in place (tool result → stub, argument → notice): a
    /// changed length or offload flag is a new key, so a shrunk message is
    /// re-measured instead of keeping its old size. In-flight messages (no
    /// dbMessageId yet) are always measured.
    ///
    /// [T-ctx-count-reasoning] The key also carries the reasoning length (a
    /// trimmed copy with its reasoning emptied keeps the same id and parts) and
    /// the summed length of a call's string arguments (a shortened argument
    /// keeps the same key count).
    static func estimateTokens(message msg: AgentMessage, includeReasoning: Bool = false) -> Int {
        let reasoning = includeReasoning && msg.role == .assistant ? (msg.reasoningContent ?? "") : ""
        let echoesField = includeReasoning && msg.role == .assistant && msg.reasoningContent != nil
        guard let id = msg.dbMessageId else { return uncachedEstimate(msg, reasoning: reasoning, echoesField: echoesField) }
        var shape = "\(id)|\(msg.parts.count)"
        if includeReasoning { shape += "|R\(reasoning.utf8.count)\(echoesField ? "f" : "")" }
        for part in msg.parts {
            switch part {
            case .text(let t): shape += "|t\(t.utf8.count)"
            case .toolUse(_, _, let input, let offloaded): shape += "|u\(input.count)/\(argumentFingerprint(input))\(offloaded ? "o" : "")"
            case .toolResult(_, _, let content, _, let img, _, _, _, _): shape += "|r\(content.utf8.count)/\(img?.count ?? 0)"
            case .imageData(let d, _, _): shape += "|i\(d.count)"
            }
        }
        let key = shape as NSString
        if let hit = messageEstimateCache.object(forKey: key) { return hit.intValue }
        let tokens = uncachedEstimate(msg, reasoning: reasoning, echoesField: echoesField)
        messageEstimateCache.setObject(NSNumber(value: tokens), forKey: key)
        return tokens
    }

    /// Cheap stand-in for "did an argument change": the total length of the
    /// top-level string values. No serialization, no hashing of the payload.
    static func argumentFingerprint(_ input: [String: Any]) -> Int {
        var total = 0
        for value in input.values { if let s = value as? String { total += s.utf8.count } }
        return total
    }

    private static let messageEstimateCache: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 20_000
        return c
    }()

    private static func uncachedEstimate(_ msg: AgentMessage, reasoning: String, echoesField: Bool) -> Int {
        perMessageOverhead + msg.parts.reduce(0) { $0 + estimateTokens($1) }
            + estimateWireTokens(reasoning) + (echoesField ? reasoningFieldOverhead : 0)
    }

    /// System prompt plus tool schemas — the part of every request that the
    /// history-only estimate used to leave out entirely.
    static func estimateFixedTokens(systemPrompt: String, tools: [AgentToolDefinition]) -> Int {
        var total = estimateTokens(systemPrompt)
        for tool in tools {
            total += estimateTokens(tool.name) + estimateTokens(tool.description) + 10
            for (name, param) in tool.parameters {
                total += estimateTokens(name) + estimateTokens(param.description) + 4
                if let schema = param.schema { total += estimateTokens(schema.estimationText) + 8 }
                if let values = param.enumValues {
                    total += values.reduce(0) { $0 + estimateTokens($1) + 1 }
                }
            }
        }
        return total
    }

    // MARK: Calibration

    /// Bounds on reported / estimated. Outside this band the report is more
    /// likely to describe something other than the request we estimated (a
    /// relay that bills differently, a provider that omits cached tokens) than
    /// a real tokenizer difference, so it is clamped rather than trusted.
    ///
    /// The floor is deliberately tight. The estimator's worst measured
    /// over-read is 1.18x, so a genuine ratio never drops much below 0.85; a
    /// lower one means an under-reporting upstream, and following it down
    /// would let an over-length request through — the old max() at least kept
    /// the estimate as a floor. The ceiling is loose because under-reads are
    /// real: denser tokenizers, plus content we do not measure (provider-side
    /// framing, images a relay re-encodes).
    ///
    /// [T-ctx-count-reasoning] 3.0 -> 8.0. With echoed reasoning now counted a
    /// normal ratio sits at 1.0-1.3, so the ceiling is only a backstop, and at
    /// 3.0 it was the thing that hid a 3-7x under-read: the clamp held the
    /// meter at 146,874 while the provider counted 341,873 on a 128K window.
    static let calibrationRange: ClosedRange<Double> = 0.8...8.0

    /// Ratio of what the provider counted to what we estimated for the SAME
    /// request, or nil when either side is missing.
    static func calibrationRatio(reported: Int, estimated: Int) -> Double? {
        guard reported > 0, estimated > 0 else { return nil }
        let raw = Double(reported) / Double(estimated)
        return min(max(raw, calibrationRange.lowerBound), calibrationRange.upperBound)
    }

    static func calibrated(_ estimated: Int, ratio: Double) -> Int {
        Int((Double(estimated) * ratio).rounded(.up))
    }

    /// Applied when the current model has no calibration of its own and we are
    /// borrowing another model's ratio. Tokenizers differ by roughly 10–30%
    /// (e.g. a session run on one vendor, then switched to one whose tokenizer
    /// is denser): judging the new model by the old ratio under-reads it, and a
    /// session sitting near the old model's limit can then be sent over the new
    /// one's. Leaning high for that one request costs, at worst, an early
    /// compaction; its first response replaces the borrowed ratio.
    static let uncalibratedModelMargin = 1.2

    /// Where `ratio(for:known:lastLearned:)` got its answer, for logs.
    static func ratioSource(for modelId: String?, known: [String: Double], lastLearned: Double?) -> String {
        if let modelId, known[modelId] != nil { return "own" }
        return lastLearned == nil ? "default" : "borrowed"
    }

    // MARK: Smoothing [T-ctx-ratio-smoothing]

    /// Share of the gap closed per sample when a new sample says the ratio
    /// should come DOWN. Recent samples then weigh 0.3, 0.21, 0.147, …
    static let calibrationFallRate = 0.3

    /// Fold one sample into a model's ratio — an asymmetric weighted average.
    ///
    /// The two directions of error are not equally dangerous. A ratio that is
    /// too LOW under-reads the context and can send a request over the window
    /// (a rejection); one that is too high only compacts a little early. So a
    /// sample that says "higher" applies at once — the safety property the
    /// unsmoothed ratio had — while one that says "lower" moves the ratio only
    /// part of the way. A single anomalous low report (a relay that under-counts
    /// once) then barely moves it, where before it replaced it outright; a real
    /// drop (the conversation's content changed) settles within 3–4 responses.
    static func smoothed(previous: Double?, sample: Double) -> Double {
        guard let previous else { return sample }
        if sample >= previous { return sample }
        return previous + calibrationFallRate * (sample - previous)
    }

    /// The ratio to judge `modelId` by: its own if it has one; otherwise the
    /// most recently learned ratio (any model) with the margin above; otherwise
    /// 1.0 for a session that has never reported usage.
    static func ratio(for modelId: String?, known: [String: Double], lastLearned: Double?) -> Double {
        if let modelId, let own = known[modelId] { return own }
        guard let lastLearned else { return 1.0 }
        return min(max(lastLearned, 1.0) * uncalibratedModelMargin, calibrationRange.upperBound)
    }

    // MARK: Provider rejections

    /// Phrases providers use to refuse an over-length request. Matches Android's
    /// ContextOverflowGuard, plus the wording in OpenMinis#133.
    static let overflowMarkers = [
        "maximum context length", "context length exceeded", "context_length_exceeded",
        "reduce the length of the messages", "too many tokens", "prompt is too long",
        "request too large", "exceeds the maximum", "input is too long",
        "exceeds the context window", "input exceeds the context",
        // Anthropic: "input length and `max_tokens` exceed context limit: A + B > W"
        "exceed context limit",
        "上下文长度", "超出最大长度", "内容过长",
    ]

    /// Whether an error text is a context-length rejection. The status must be
    /// 400/413 when one is present in the text (`[400] …`): other statuses with
    /// similar words (a 429 "too many tokens per minute") are rate limits.
    ///
    /// A group-exhausted error lists one reason per member ("A: [429] … B: [400]
    /// prompt is too long"), so it counts when ANY stated status is 400/413.
    static func isContextOverflow(_ text: String) -> Bool {
        let lower = text.lowercased()
        let codes = (try? NSRegularExpression(pattern: #"\[(\d{3})\]"#))?
            .matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            .compactMap { Range($0.range(at: 1), in: lower).flatMap { Int(lower[$0]) } } ?? []
        if !codes.isEmpty && !codes.contains(where: { $0 == 400 || $0 == 413 }) { return false }
        let hits = overflowMarkers.filter { lower.contains($0) }
        // [T-ctx-byte-413-not-overflow] Anthropic's 413 "Request exceeds the
        // maximum allowed number of bytes" is a payload-SIZE limit (images,
        // attachments), not a token count. Matched by the generic markers
        // alone it raised the calibration ratio toward 3x on a request far
        // under the window and made the session compact early for many
        // turns. With byte wording, only a token-specific marker counts.
        if lower.contains("bytes") {
            return hits.contains { !Self.byteAmbiguousMarkers.contains($0) }
        }
        return !hits.isEmpty
    }

    /// Markers that a byte-size rejection also matches.
    static let byteAmbiguousMarkers: Set<String> = ["exceeds the maximum", "request too large"]

    /// The token count the provider says the rejected request had, when its
    /// message states one. Rejections name two numbers — the limit and the
    /// request — and the request is the larger, since it overflowed. Numbers
    /// under 1000 are status codes and the like, not token counts.
    static func requestedTokens(inOverflowMessage text: String) -> Int? {
        let cleaned = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
        let regex = try? NSRegularExpression(pattern: #"\d{4,}"#)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let values = regex?.matches(in: cleaned, range: range).compactMap {
            Range($0.range, in: cleaned).flatMap { Int(cleaned[$0]) }
        } ?? []
        return values.filter { $0 >= 1000 }.max()
    }

    /// Ratio after a rejection: the provider's stated count ÷ our estimate of
    /// the same request when it gave one; otherwise just enough to put that
    /// request at the window. Never lower than the current ratio — a rejection
    /// only ever says we under-read.
    static func ratioAfterOverflow(current: Double, estimated: Int, requested: Int?, window: Int) -> Double {
        guard estimated > 0 else { return current }
        // A stated count is only trusted when it is plausible for this window:
        // a request id or byte size in the same message would otherwise read as
        // a huge "token count" and pin the ratio at its ceiling.
        let plausible = requested.flatMap { r -> Int? in
            guard window > 0 else { return r }
            return (Double(r) >= Double(window) * 0.9 && Double(r) <= Double(window) * 4) ? r : nil
        }
        let target = plausible.map(Double.init) ?? Double(max(window, 1)) * 1.02
        let implied = target / Double(estimated)
        return min(max(current, implied), calibrationRange.upperBound)
    }

    // MARK: Session calibration: replay and reload

    /// One persisted (report, estimate) pair — an assistant turn's usage.
    ///
    /// `estimatorVersion` is the version of the estimator that produced
    /// `estimated`; nil on rows written before the field existed (= version 1).
    struct CalibrationSample: Equatable {
        let reported: Int, estimated: Int, fixedTokens: Int, modelId: String?
        var estimatorVersion: Int? = nil

        /// Whether `estimated` is comparable with what the estimator returns now.
        var isCurrent: Bool { (estimatorVersion ?? 1) >= ContextSizeMeter.estimatorVersion }
    }

    /// A session's calibration: per-model ratios, the newest learned one, and the fixed share.
    struct CalibrationState: Equatable {
        var ratios: [String: Double] = [:]
        var lastLearned: Double? = nil
        var fixedTokens = 0
        var samples = 0

        /// Reloading the SAME session keeps what was learned in memory: a ratio
        /// raised by a rejection exists nowhere else (a rejected request stamps
        /// no pair), and in-memory values are never older than the transcript's.
        /// So they win, key by key; the transcript fills in models memory has
        /// not seen.
        func carryingOver(_ learned: CalibrationState) -> CalibrationState {
            var merged = self
            merged.ratios.merge(learned.ratios) { _, inMemory in inMemory }
            if let last = learned.lastLearned { merged.lastLearned = last }
            if learned.fixedTokens > 0 { merged.fixedTokens = learned.fixedTokens }
            return merged
        }
    }

    /// [T-ctx-ratio-smoothing] Rebuild calibration from persisted samples in
    /// conversation order, through the same `smoothed` rule the live path uses,
    /// so a reload reproduces the ratio the session had in memory rather than
    /// jumping to the newest raw sample. A sample with no model id (older rows)
    /// informs only `lastLearned`.
    static func replayCalibration(_ samples: [CalibrationSample]) -> CalibrationState {
        var state = CalibrationState()
        for s in samples {
            // [T-ctx-count-reasoning] A pair from an older estimator would
            // replay its (too high) ratio onto an estimate that already
            // contains what the ratio was compensating for.
            guard s.isCurrent else { continue }
            guard let sample = calibrationRatio(reported: s.reported, estimated: s.estimated) else { continue }
            state.samples += 1
            if let model = s.modelId {
                let updated = smoothed(previous: state.ratios[model], sample: sample)
                state.ratios[model] = updated
                state.lastLearned = updated
            } else {
                state.lastLearned = sample
            }
            state.fixedTokens = s.fixedTokens
        }
        return state
    }

    /// [T-ctx-warmup-fit] How many leading warm-up messages to drop so that
    /// warm-up + `restTokens` is under `budget`. Drops whole turns: after each
    /// cut it keeps dropping until the slice starts on a user-TEXT message
    /// (`startsTurn`), so a tool call is never separated from its result.
    /// 0 when it already fits; `sizes.count` when nothing does.
    static func warmUpDrop(sizes: [Int], startsTurn: [Bool], restTokens: Int, budget: Int) -> Int {
        precondition(sizes.count == startsTurn.count)
        var total = sizes.reduce(0, +)
        var drop = 0
        while drop < sizes.count, total + restTokens >= budget {
            total -= sizes[drop]; drop += 1
            while drop < sizes.count, !startsTurn[drop] { total -= sizes[drop]; drop += 1 }
        }
        return drop
    }

    // MARK: Images

    /// `countImageTokens` decodes the image to read its dimensions, and the
    /// measurement runs several times per loop iteration, so results are
    /// cached by a cheap content fingerprint.
    private static let imageTokenCache = NSCache<NSString, NSNumber>()

    static func imageTokens(_ data: Data) -> Int {
        let key = "\(data.count)-\(data.prefix(64).hashValue)-\(data.suffix(64).hashValue)" as NSString
        if let cached = imageTokenCache.object(forKey: key) { return cached.intValue }
        let tokens = BPETokenizer.shared.countImageTokens(data)
        imageTokenCache.setObject(NSNumber(value: tokens), forKey: key)
        return tokens
    }
}

// MARK: - Trim ladder [T-ctx-trim-ladder]

/// Brings an outbound history down to a safe watermark by trimming in order of
/// cost, re-measuring every candidate and taking the least that fits.
///
/// Why: a long agent run on a thinking model replays every past turn's
/// reasoning. Android field run 2026-10-07: the request reached 341,873 prompt
/// tokens on a 128K window. Compaction kept triggering and freed nothing,
/// because the slice it keeps (the last 3 user turns) WAS the whole task - one
/// "continue" driving dozens of tool rounds - and nothing trimmed inside it.
///
/// Levels, cheapest first (each takes an oldest-first prefix of iterations):
///  - L1    reasoning of older assistant turns emptied (the field stays:
///          DeepSeek / MiMo require its presence).
///  - L2L3  large tool results and large tool arguments moved to disk and
///          replaced by the existing offload stub / pruned-argument notice.
///  - SK    "skeleton": the call stays, its result becomes one line.
///  - L4    oldest iterations collapsed into an index appended to the request.
///
/// The outcome is a `State` of cut-off keys, not a trimmed list: re-applying
/// the same State to a history that only grew gives byte-identical output for
/// the old part, so the provider's prefix cache keeps hitting until the next
/// re-plan (Android: 84-93% cache hits between re-plans).
///
/// Pure apart from `Offloader`, which the caller backs with real disk writes.
/// Works on a copy: the stored history is never modified.
/// Port of Android `ContextTrimPlanner` (2e13ae7b6, aa38023a9).
enum ContextTrimPlanner {

    // MARK: Watermarks

    enum Mode: String { case normal = "NORMAL", tight = "TIGHT", unusable = "UNUSABLE" }

    /// All values in measured (calibrated) tokens.
    struct Watermarks: Equatable {
        let window: Int, fixed: Int, reserve: Int, hard: Int, usable: Int, trigger: Int, target: Int
        let mode: Mode
    }

    static let triggerShare = 0.90
    static let targetShare = 0.50
    /// Ceiling of the ratio applied to the fixed share (system prompt + tool
    /// schemas). That share is plain text, where the estimator is within
    /// 0.66-1.18x; a ratio learned on history must not inflate it into an
    /// "unusable" window.
    static let fixedRatioMax = 1.5

    /// Watermarks from the space history can really use: the window minus the
    /// output reserve minus the fixed share. A share of the raw window does not
    /// work for small windows - with a ~21K prompt, half of a 32K window is
    /// below the fixed cost itself. nil when the window is unknown.
    static func watermarks(window: Int, fixed: Int, maxOutput: Int) -> Watermarks? {
        guard window > 0 else { return nil }
        let reserve = min(max(maxOutput, 1), max(4096, Int(Double(window) * 0.15)))
        let hard = window - reserve
        let usable = hard - fixed
        let trigger = fixed + Int(Double(usable) * triggerShare)
        let target = fixed + Int(Double(usable) * targetShare)
        let mode: Mode
        if usable <= 0 { mode = .unusable }
        else if usable < max(8192, Int(Double(window) * 0.25)) { mode = .tight }
        else { mode = .normal }
        return Watermarks(window: window, fixed: fixed, reserve: reserve, hard: hard, usable: usable,
                          trigger: trigger, target: target, mode: mode)
    }

    /// [T-ctx-trim-trigger-margin] Where a re-plan starts: the tier's explicit
    /// compaction line when it has one, but never above the watermark trigger
    /// (fixed + 0.9 x usable), which itself sits below the hard line.
    ///
    /// The compaction line alone leaves no room on some tiers. A capped group
    /// compacts at 85% of its window and the output reserve is 15%, so the
    /// line IS the hard watermark: on-device run 2026-10-07 (128K cap), trigger
    /// = hard = 108,800 and the request peaked at 108,646, 154 tokens short.
    /// On a 1M window the line (window - 20K) is even above hard.
    static func trigger(policyLine: Int?, watermarks wm: Watermarks) -> Int {
        guard let policyLine, policyLine > 0 else { return wm.trigger }
        return min(policyLine, wm.trigger)
    }

    /// [T-ctx-trim-plan-window] Whether a frozen plan made for `planWindow`
    /// still belongs to the window the next request is judged by. A plan is
    /// sized for one window: its target is half of THAT window's usable space.
    /// Keeping it after the window changed applies the wrong amount of trim.
    ///
    /// On-device 2026-10-07 (session 38D5C536): a plan made under a 128K cap
    /// (reasoning emptied on 343 of 345 iterations, 342 shortened, 179
    /// collapsed) stayed in force after the session moved to a group with the
    /// model's own 1M window. Nothing re-planned, because the request was far
    /// below the new trigger, so 560 steps went out as 81K of a 1M window.
    static func planFitsWindow(planWindow: Int?, window: Int) -> Bool {
        planWindow == window
    }

    /// [T-ctx-trim-escalate] Whether a re-plan that was not allowed to
    /// collapse recovered so little that the next level - a model summary, or
    /// collapse-first - is due now: it ended above the midpoint between target
    /// and trigger, i.e. it won back less than half of the room.
    ///
    /// With the trigger below the compaction line, a plan that can no longer
    /// reach the target keeps the request just under that line, so the
    /// compaction check never fires and the loop re-plans every few requests
    /// for less and less. On-device run 2026-10-07 (session 38D5C536): a
    /// re-plan at 100,967 came back to only 83,919 against a target of 63,279,
    /// with 189 of 192 iterations already shortened.
    static func shouldEscalate(after: Int, target: Int, trigger: Int) -> Bool {
        after > target && after > (target + trigger) / 2
    }

    // MARK: Collapse-first and sticky collapse [T-ctx-trim-collapse-first]

    /// Size assumed for a model summary when a compaction is simulated.
    static let simulatedSummaryTokens = 3_000

    /// Whether a model summary would free less than half of what the request
    /// must lose to reach the target - in which case its model call is not
    /// worth paying before the ladder has tried collapsing.
    ///
    /// Inside one long user turn the turn itself IS the slice a compaction
    /// keeps, so the summary replaces almost nothing. Android replay
    /// 2026-10-07: two in-loop compactions cost a model call each and took
    /// the history only 244K -> 226K; the collapse that followed did the work.
    static func summaryFreesLittle(gain: Int, measured: Int, target: Int) -> Bool {
        gain < (measured - target) / 2
    }

    /// Where collapse was last allowed. Once it has been (after a compaction,
    /// when one failed, collapse-first, or a tight window) later re-plans for
    /// the same session and compaction marker keep allowing it. Without that,
    /// the next plain in-loop re-plan - which does not allow collapse while a
    /// compaction is still available - rebuilt the plan without it and the
    /// collapsed iterations came back: Android replay, 72K -> 92K, crossing the
    /// trigger again sooner and changing the request prefix (cache misses).
    struct CollapseUnlock: Equatable {
        let sessionId: String?
        let markerId: String?

        func holds(sessionId: String?, markerId: String?) -> Bool {
            self.sessionId == sessionId && self.markerId == markerId
        }
    }

    /// Whether this re-plan may collapse, given what was asked, the window
    /// mode and an earlier unlock.
    static func collapseAllowed(requested: Bool, tight: Bool, unlock: CollapseUnlock?,
                                sessionId: String?, markerId: String?) -> Bool {
        requested || tight || (unlock?.holds(sessionId: sessionId, markerId: markerId) ?? false)
    }

    /// The fixed share in measured tokens, with the ratio capped (see `fixedRatioMax`).
    static func calibratedFixed(_ fixedEstimate: Int, ratio: Double) -> Int {
        ContextSizeMeter.calibrated(fixedEstimate, ratio: min(ratio, fixedRatioMax))
    }

    /// [T-ctx-trim-no-wedge] Stop as "context full" only when the trimmed
    /// request is over the hard line by BOTH the calibrated size and the raw
    /// estimate. When only the ratio says "over", the request must still go
    /// out once so the provider's count can correct the ratio; stopping there
    /// would never send, never recalibrate, and stop every later turn too
    /// (Android regression c736c9737).
    static func isOverHard(calibrated: Int, raw: Int, hard: Int) -> Bool {
        calibrated > hard && raw > hard
    }

    // MARK: Plan state

    /// Prefix of a cut-off that INCLUDES the named iteration. Used when a level
    /// covers every iteration that existed at plan time: iterations added later
    /// must stay untouched until the next re-plan, which "all" would not give.
    static let through = "<="

    /// Each field names where that level stops: the key of the first iteration
    /// NOT affected, or `through` + the key of the last one affected.
    /// nil = level off.
    struct State: Equatable, CustomStringConvertible {
        var reasoningBefore: String? = nil
        var shrinkBefore: String? = nil
        var skeletonBefore: String? = nil
        var collapseBefore: String? = nil

        var isEmpty: Bool {
            reasoningBefore == nil && shrinkBefore == nil && skeletonBefore == nil && collapseBefore == nil
        }
        var description: String {
            func s(_ k: String?) -> String { k.map { String($0.prefix(14)) } ?? "-" }
            return "L1<\(s(reasoningBefore)) L2L3<\(s(shrinkBefore)) SK<\(s(skeletonBefore)) L4<\(s(collapseBefore))"
        }
    }

    /// `reasoningFloor`: newest iterations whose reasoning L1 never empties (1
    /// normally - the reasoning behind the step in flight; 0 on a tight window).
    /// `keepRecentIterations`: newest iterations L2/L3, skeleton and collapse
    /// never touch (3 normally, 1 tight).
    struct Options: Equatable {
        var stripReasoning: Bool
        var reasoningFloor = 1
        var keepRecentIterations = 3
        var allowCollapse = false
    }

    struct Result {
        let state: State
        let messages: [AgentMessage]
        let before: Int, after: Int, target: Int
        let steps: [String]
        var reachedTarget: Bool { after <= target }
    }

    /// Writes `content` to disk and returns its guest path, or nil when it could not.
    typealias Offloader = (_ content: String, _ toolId: String, _ toolName: String) -> String?

    static let shrinkChars = 2_000
    static let skeletonChars = 200
    static let indexMaxLines = 60

    // MARK: Iterations

    /// One iteration: an assistant message plus the user-role messages that
    /// carry ITS tool results. `pinned` when a carrier also holds something
    /// else (the `<context-summary>`, a queued user text): it can be shortened
    /// but never removed.
    struct Iteration: Equatable {
        let key: String
        let assistantIdx: Int
        let carrierIdx: [Int]
        let pinned: Bool
    }

    static func toolUseIds(_ m: AgentMessage) -> [String] {
        m.parts.compactMap { if case .toolUse(let id, _, _, _) = $0 { return id }; return nil }
    }

    static func iterations(_ messages: [AgentMessage]) -> [Iteration] {
        var out: [Iteration] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            guard m.role == .assistant else { i += 1; continue }
            let ids = toolUseIds(m)
            let idSet = Set(ids)
            let key = ids.first ?? "msg:\(m.dbMessageId ?? "\(i)")"
            var carriers: [Int] = []
            var pinned = false
            var j = i + 1
            while !idSet.isEmpty, j < messages.count {
                let c = messages[j]
                guard c.role == .user else { break }
                var hasOwnResult = false, hasOther = false
                for part in c.parts {
                    if case .toolResult(let id, _, _, _, _, _, _, _, _) = part {
                        if idSet.contains(id) { hasOwnResult = true }
                    } else {
                        hasOther = true
                    }
                }
                guard hasOwnResult else { break }
                carriers.append(j)
                if hasOther { pinned = true }
                j += 1
            }
            out.append(Iteration(key: key, assistantIdx: i, carrierIdx: carriers, pinned: pinned))
            i = max(i + 1, j)
        }
        return out
    }

    /// Position of `key` among `its`; nil when a stored key no longer exists.
    private static func cut(_ key: String?, _ its: [Iteration]) -> Int? {
        guard let key else { return 0 }
        if key.hasPrefix(through) {
            let k = String(key.dropFirst(through.count))
            return its.firstIndex { $0.key == k }.map { $0 + 1 }
        }
        return its.firstIndex { $0.key == key }
    }

    /// Key that affects iterations [0, n) of `its` - and no iteration added later.
    static func keyFor(_ n: Int, _ its: [Iteration]) -> String? {
        guard n > 0, let last = its.last else { return nil }
        return n >= its.count ? through + last.key : its[n].key
    }

    // MARK: Apply

    /// Re-applies `state`; nil when one of its keys is gone (the caller re-plans).
    static func apply(_ messages: [AgentMessage], state: State, offloader: Offloader) -> [AgentMessage]? {
        if state.isEmpty { return messages }
        let its = iterations(messages)
        guard let rB = cut(state.reasoningBefore, its), let shB = cut(state.shrinkBefore, its),
              let skB = cut(state.skeletonBefore, its), let cB = cut(state.collapseBefore, its) else { return nil }

        var iterOf: [Int: Int] = [:]
        for (n, it) in its.enumerated() {
            iterOf[it.assistantIdx] = n
            for c in it.carrierIdx { iterOf[c] = n }
        }

        var collapsed: [Iteration] = []
        var out: [AgentMessage] = []
        out.reserveCapacity(messages.count)
        var indexHostAt = -1
        for (idx, m) in messages.enumerated() {
            guard let n = iterOf[idx] else {
                out.append(m)
                // The index lands on the last plain user message before the collapsed range.
                if m.role == .user, collapsed.isEmpty { indexHostAt = out.count - 1 }
                continue
            }
            let it = its[n]
            if n < cB, !it.pinned {
                if idx == it.assistantIdx { collapsed.append(it) }
                continue
            }
            out.append(transform(m, n: n, rB: rB, shB: shB, skB: skB, offloader: offloader))
        }
        guard !collapsed.isEmpty else { return out }
        let index = indexText(collapsed.map { it in (messages[it.assistantIdx], it.carrierIdx.map { messages[$0] }) })
        if indexHostAt >= 0 {
            out[indexHostAt].parts.append(.text(index))
        } else {
            out.insert(AgentMessage(role: .user, parts: [.text(index)]), at: 0)
        }
        return out
    }

    private static func transform(_ m: AgentMessage, n: Int, rB: Int, shB: Int, skB: Int, offloader: Offloader) -> AgentMessage {
        var msg = m
        if n < rB, m.role == .assistant, let rc = m.reasoningContent, !rc.isEmpty {
            msg.reasoningContent = ""
        }
        let skeleton = n < skB, shrink = n < shB
        guard skeleton || shrink else { return msg }
        // Levels stack: a skeleton is built on the shrunk part, so it is never
        // larger than what shrink alone produced.
        msg.parts = msg.parts.map { part in
            switch part {
            case .toolUse:
                let shrunk = shrink ? shortenArgs(part, limit: shrinkChars, offloader: offloader) : part
                return skeleton ? shortenArgs(shrunk, limit: skeletonChars, offloader: offloader) : shrunk
            case .toolResult:
                let shrunk = shrink ? shrinkResult(part, offloader: offloader) : part
                return skeleton ? skeletonResult(shrunk, offloader: offloader) : shrunk
            default:
                return part
            }
        }
        return msg
    }

    static func isStub(_ text: String) -> Bool { AIChatViewModel.isOffloadedStub(text) }

    /// The existing result stub, byte for byte what offloadContextIfNeeded writes.
    static func resultStub(tokens: Int, bytes: Int, path: String) -> String {
        "\(AIChatViewModel.offloadedStubPrefix) Content (~\(tokens) tokens, \(bytes) bytes) saved to: \(path)\nUse file_read tool to retrieve if needed."
    }

    private static func savedPath(in text: String) -> String? {
        guard let r = text.range(of: #"saved to: (\S+)"#, options: .regularExpression) else { return nil }
        return String(text[r].dropFirst("saved to: ".count))
    }

    private static func shrinkResult(_ part: AgentContentPart, offloader: Offloader) -> AgentContentPart {
        guard case .toolResult(let id, let name, let content, let isError, let img, let mime, let url, let imgPath, let readback) = part else { return part }
        // A read-back of an offloaded file is already on disk under the path
        // the model asked for; writing it again is how GH#343 looped. The
        // skeleton level shortens it without a second copy.
        guard content.count > shrinkChars, !isStub(content), !readback else { return part }
        let text: String
        if let path = offloader(content, id, name), !path.isEmpty {
            text = resultStub(tokens: ContextSizeMeter.estimateTokens(content), bytes: content.utf8.count, path: path)
        } else {
            let keep = shrinkChars / 2
            text = String(content.prefix(keep)) + "\n… [\(content.count - keep) chars omitted from context]"
        }
        guard text.count < content.count else { return part }
        return .toolResult(id: id, name: name, content: text, isError: isError, imageData: img, imageMimeType: mime,
                           pageURL: url, imageLinuxPath: imgPath, isOffloadReadback: readback)
    }

    private static func skeletonResult(_ part: AgentContentPart, offloader: Offloader) -> AgentContentPart {
        guard case .toolResult(let id, let name, let content, let isError, let img, _, let url, _, let readback) = part else { return part }
        func noImage(_ text: String) -> AgentContentPart {
            .toolResult(id: id, name: name, content: text, isError: isError, imageData: nil, imageMimeType: nil,
                        pageURL: url, imageLinuxPath: nil, isOffloadReadback: readback)
        }
        if content.count <= skeletonChars + 100, img == nil { return part }
        // An offload stub is already as small as a skeleton; rewriting it would only grow it.
        if isStub(content) { return img == nil ? part : noImage(content) }
        let path = readback ? nil : offloader(content, id, name)
        let first = content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix(AIChatViewModel.offloadedStubPrefix) }
            .map { String($0.prefix(skeletonChars)) } ?? ""
        let location = (path?.isEmpty == false) ? "full output: \(path!)" : "full output kept in the chat history"
        let image = img != nil ? " (image omitted)" : ""
        let text = "\(first)\n[shortened for context\(image); \(location)]"
        if text.count >= content.count { return img == nil ? part : noImage(content) }
        return noImage(text)
    }

    /// The notice for an argument shortened without a disk copy. Detected by
    /// `AIChatViewModel.isOffloadedStub`, so the write tools refuse to reuse it.
    static func shortenedArgumentNotice(_ value: String) -> String {
        "\(AIChatViewModel.offloadedStubEnvelope)\n\(AIChatViewModel.offloadedStubNoticeTag) Argument shortened for context "
            + "(\(value.count) chars). NOT the real value - never reuse it. Starts with: «\(value.prefix(120))»\n</system-reminder>"
    }

    private static func shortenArgs(_ part: AgentContentPart, limit: Int, offloader: Offloader) -> AgentContentPart {
        guard case .toolUse(let id, let name, let input, let offloaded) = part else { return part }
        var copy = input
        var changed = false
        for key in input.keys.sorted() {
            guard let v = input[key] as? String, v.count > limit, !isStub(v) else { continue }
            let notice = shortenedArgumentNotice(v)
            // The notice is ~330 chars: on a short value it would GROW the
            // request (Android field: 25 of 71 shortened shell commands).
            guard notice.count < v.count else { continue }
            var replacement = notice
            if limit >= shrinkChars, let path = offloader(v, id, "args-\(name)"), !path.isEmpty {
                replacement = AIChatViewModel.offloadedStubNotice(tokens: ContextSizeMeter.estimateTokens(v),
                                                                  bytes: v.utf8.count, linuxPath: path)
            }
            guard replacement.count < v.count else { continue }
            copy[key] = replacement
            changed = true
        }
        _ = offloaded
        return changed ? .toolUse(id: id, name: name, input: copy, isOffloadedArgument: true) : part
    }

    /// Index of collapsed iterations: the newest `indexMaxLines` listed, the rest counted.
    static func indexText(_ collapsed: [(AgentMessage, [AgentMessage])]) -> String {
        var lines: [String] = []
        var counts: [(name: String, count: Int)] = []
        for (n, pair) in collapsed.enumerated() {
            let (asst, carriers) = pair
            var results: [String: (content: String, isError: Bool)] = [:]
            for c in carriers {
                for p in c.parts {
                    if case .toolResult(let id, _, let content, let isError, _, _, _, _, _) = p { results[id] = (content, isError) }
                }
            }
            var hadUse = false
            for p in asst.parts {
                guard case .toolUse(let id, let name, let input, _) = p else { continue }
                hadUse = true
                if let i = counts.firstIndex(where: { $0.name == name }) { counts[i].count += 1 } else { counts.append((name, 1)) }
                let rawTitle = (input["tool_title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (input["title"] as? String) ?? ""
                let title = String(rawTitle.prefix(60))
                let r = results[id]
                let status = r == nil ? "no result" : (r!.isError ? "error" : "ok")
                let path = r.flatMap { savedPath(in: $0.content) }
                lines.append("#\(n + 1) \(name)\(title.isEmpty ? "" : " «\(title)»") → \(status)\(path.map { " (\($0))" } ?? "")")
            }
            if !hadUse {
                let note = asst.parts.compactMap { p -> String? in if case .text(let t) = p { return t }; return nil }.joined(separator: " ")
                let first = note.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
                if !first.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("#\(n + 1) note: \(first.prefix(100))") }
            }
        }
        let shown = lines.suffix(indexMaxLines)
        let hidden = lines.count - shown.count
        var s = "\(AIChatViewModel.offloadedStubEnvelope)\n"
        s += "[Minis context] \(collapsed.count) earlier step(s) of this task were collapsed to save context. "
        s += "Their full records stay in the chat history; large outputs are on disk at the paths shown. "
        s += "Do not redo a step listed as ok - read its output path if you need the details.\n"
        s += "Tool calls collapsed: \(counts.map { "\($0.name) \($0.count)" }.joined(separator: ", "))\n"
        if hidden > 0 { s += "(\(hidden) older line(s) not listed)\n" }
        for l in shown { s += l + "\n" }
        s += "</system-reminder>"
        return s
    }

    // MARK: Plan

    /// Cheapest level first. Each level affects the SMALLEST oldest-first
    /// prefix of iterations that reaches `target` (binary search, re-measuring
    /// every candidate); only a level that cannot reach it alone runs at full
    /// extent and hands over to the next one. A restore pass then shrinks the
    /// earlier, full-extent levels back as far as the result still fits, so as
    /// much context as possible survives. `measure` returns measured tokens for
    /// a history (fixed share included).
    static func plan(_ messages: [AgentMessage], target: Int, options: Options,
                     measure: ([AgentMessage]) -> Int, offloader: Offloader) -> Result {
        let its = iterations(messages)
        let before = measure(messages)
        var steps: [String] = []
        if before <= target || its.isEmpty {
            return Result(state: State(), messages: messages, before: before, after: before, target: target, steps: steps)
        }

        let older = max(its.count - min(max(options.keepRecentIterations, 0), its.count), 0)
        let labels = ["L1", "L2L3", "SK", "L4"]
        let maxExtent = [
            options.stripReasoning ? max(its.count - max(options.reasoningFloor, 0), 0) : 0,
            older, older,
            options.allowCollapse ? older : 0,
        ]
        func stateOf(_ ext: [Int]) -> State {
            State(reasoningBefore: keyFor(ext[0], its), shrinkBefore: keyFor(ext[1], its),
                  skeletonBefore: keyFor(ext[2], its), collapseBefore: keyFor(ext[3], its))
        }
        var memo: [[Int]: ([AgentMessage], Int)] = [:]
        func eval(_ ext: [Int]) -> ([AgentMessage], Int) {
            if let hit = memo[ext] { return hit }
            let applied = apply(messages, state: stateOf(ext), offloader: offloader) ?? messages
            let value = (applied, measure(applied))
            memo[ext] = value
            return value
        }
        var extent = [0, 0, 0, 0]
        /// Smallest n in [lo, hi] for level `li` that fits, others as in `extent`; assumes hi fits.
        func smallest(_ li: Int, _ lo: Int, _ hi: Int) -> Int {
            var a = lo, b = hi
            while a < b {
                let mid = (a + b) / 2
                var e = extent; e[li] = mid
                if eval(e).1 <= target { b = mid } else { a = mid + 1 }
            }
            return b
        }

        var size = before
        var last = -1
        for li in labels.indices {
            guard maxExtent[li] > 0 else { continue }
            last = li
            var full = extent; full[li] = maxExtent[li]
            let fullSize = eval(full).1
            // A level with nothing to take here (no reasoning, no large output) is skipped, not logged.
            if fullSize >= size { continue }
            if fullSize > target {
                extent[li] = maxExtent[li]
                steps.append("\(labels[li])(n=\(extent[li])/\(its.count)):\(size - fullSize)")
                size = fullSize
                continue
            }
            extent[li] = smallest(li, 1, maxExtent[li])
            let m = eval(extent).1
            steps.append("\(labels[li])(n=\(extent[li])/\(its.count)):\(size - m)")
            size = m
            break
        }
        // Restore: the level that closed the gap may have freed more than the
        // earlier ones needed to give up. Most informative first: skeleton,
        // then offload, then reasoning.
        if size <= target, last > 0 {
            for li in (0..<last).reversed() where extent[li] != 0 {
                let was = extent[li]
                var zero = extent; zero[li] = 0
                extent[li] = eval(zero).1 <= target ? 0 : smallest(li, 0, was)
                if extent[li] == was { continue }
                let m = eval(extent).1
                steps.append("\(labels[li])-restore(n=\(extent[li])/\(its.count)):\(size - m)")
                size = m
            }
        }
        let (current, after) = eval(extent)
        return Result(state: stateOf(extent), messages: current, before: before, after: after, target: target, steps: steps)
    }
}
