import Foundation

private let logger = AppLogger(category: "VoiceCorrection")

/// How a transcript actually gets corrected, given the retrieved candidates (design §4.3).
///
/// v1 ships only `LLMCorrectionStrategy`. The protocol exists now so that a
/// `RuleBasedCorrectionStrategy` (skip the LLM entirely when confidence is overwhelming —
/// saves tokens and ~600ms) or an on-device model strategy can be swapped in later
/// without touching the engine (design §8).
protocol CorrectionStrategy: Sendable {
    var strategyIdentifier: String { get }
    func correct(transcript: String,
                 candidates: [CorrectionCandidate],
                 context: ConversationContext,
                 locale: String) async throws -> CorrectionOutcome
}

// ConversationContext moved to CorrectionContextBuilder.swift (2026-07-16): the
// budgeted context builder both produces it and is unit-tested, and the test
// target compiles files individually — keeping the type next to its producer
// lets the tests build without dragging this file's provider-stack imports in.

/// Collects which evidence terms survived `buildPrompt`'s budget clamping.
///
/// A reference type so the builder can fill it in place without changing its return type
/// (every existing caller keeps working, and the value stays `nil` in Release paths that
/// don't ask for it). Not `#if DEBUG`: the type is trivial and keeping it unconditional
/// avoids `#if` noise around the parameter at each call site — only the trace that
/// consumes it is DEBUG-only.
final class PromptDiagnosticsSink: @unchecked Sendable {
    /// Typed-vocabulary terms that fit the 400-char block, in the order presented.
    var vocabTerms: [String] = []
    /// Confusion lines ("Linux→minis（用户已手动纠正2次）") that fit the 800-char block.
    var confusionLines: [String] = []
    /// Per-block character spend, keyed vocab/confusion/digest/context/transcript/total.
    var blockChars: [String: Int] = [:]
    init() {}
}

struct CorrectionOutcome: Sendable {
    let correctedText: String
    /// The model group we actually reached ("sub" / "primary") — surfaced by
    /// `debug.voiceCorrection.runCorrection` so a bad correction can be traced to a model.
    let modelGroupUsed: String
    let durationMs: Int
    /// The prompt that was actually sent, plus which evidence terms survived clamping.
    /// Populated only when the strategy builds a prompt (the LLM one); a future
    /// rule-based strategy leaves it nil. DEBUG tracing is its only consumer.
    var prompt: String? = nil
    var diagnostics: PromptDiagnosticsSink? = nil
}

enum CorrectionError: Error {
    case noModelAvailable
    case emptyResponse
    case timedOut
}

// MARK: - LLM strategy

struct LLMCorrectionStrategy: CorrectionStrategy {
    let strategyIdentifier = "llm"

    func correct(transcript: String,
                 candidates: [CorrectionCandidate],
                 context: ConversationContext,
                 locale: String) async throws -> CorrectionOutcome {
        let started = Date()

        guard let resolved = await CorrectionModelResolver.resolve() else {
            throw CorrectionError.noModelAvailable
        }

        let diagnostics = PromptDiagnosticsSink()
        let profile = CorrectionLanguageProfile.resolve(locale: locale, transcript: transcript)
        let prompt = Self.buildPrompt(transcript: transcript, candidates: candidates,
                                      context: context, profile: profile, diagnostics: diagnostics)
        // [T-opencode-every-entry] A correction belongs to no chat: its own one-off id.
        let provider = await AIChatViewModel.makeAgentProvider(for: resolved.entry, sessionId: OpenCodeChannel.oneOffSessionId())

        // thinkingLevel: .off, exactly like title generation — this is a mechanical
        // rewrite, reasoning traces would only add latency (and on some providers cause
        // an empty text body with finish_reason=tool_calls; see the TitleGen comment).
        let messages = [AgentMessage(role: .user, parts: [.text(prompt)])]
        let stream = try await provider.streamAgentMessage(
            messages: messages,
            systemPrompt: Self.systemPrompt(for: profile),
            tools: [],
            // Output is at most the transcript re-emitted, so budget off its
            // length: floor 512 (a 256 floor once got fully eaten by adaptive
            // thinking_tokens before the explicit-disable fix landed — keep
            // headroom), target 1.2× the input chars, ceiling = the model
            // entry's own max-output limit (group override included).
            maxTokens: Self.correctionMaxTokens(transcriptChars: transcript.count,
                                                modelCap: resolved.entry.model.maxOutputTokens),
            thinkingLevel: .off
        )

        var responseText = ""
        for try await event in stream {
            switch event {
            case .textDelta(let delta): responseText += delta
            default: break
            }
        }

        let cleaned = Self.cleanResponse(responseText)
        guard !cleaned.isEmpty else { throw CorrectionError.emptyResponse }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return CorrectionOutcome(correctedText: cleaned,
                                 modelGroupUsed: resolved.groupKind,
                                 durationMs: ms,
                                 prompt: prompt,
                                 diagnostics: diagnostics)
    }

    /// Output-token budget for one correction call (user decision 2026-07-17):
    /// max(512, ceil(1.2 × transcript chars)), clamped to the resolved model
    /// entry's maxOutputTokens (which already reflects any Model Group
    /// per-entry override) when one is declared.
    static func correctionMaxTokens(transcriptChars: Int, modelCap: Int?) -> Int {
        let target = max(512, Int((Double(transcriptChars) * 1.2).rounded(.up)))
        guard let cap = modelCap, cap > 0 else { return target }
        return min(target, cap)
    }

    /// [T-voice-mixed-term-restore] The rules half of the prompt. Before this, the only
    /// instruction was "fix homophones", and a Chinese recognizer's commonest miss on this
    /// user's speech is not a homophone at all: an English term spoken inside a Chinese
    /// sentence comes back as look-alike hanzi. On device, "下一个 Issue" became
    /// "下一个遗穴"; with "Issue" on screen ten times, the model still answered "议题" —
    /// it searched Chinese words only, and picked the one that MEANS issue.
    ///
    /// Three layers: the output contract; the setting (the transcript is a message to the
    /// agent, usually a reply that picks or names something the agent just offered, so the
    /// agent's own nouns and options are the likeliest reading of a misheard span); and the
    /// way recognition fails, which depends on the language — so that part comes from
    /// `CorrectionLanguageProfile` and each language's rules stay separate. The method
    /// (sound it out, restore the reference's spelling, never translate) is shared.
    static func systemPrompt(for profile: CorrectionLanguageProfile) -> String {
        """
        You fix speech-recognition errors in transcribed text. Output ONLY the corrected text, \
        with no explanation, no quotes, and no preamble. If the text needs no correction, output it unchanged.

        The situation: the user is talking to an AI agent in a chat app by voice, and the \
        transcript is the message they are about to send it. Read the transcript as one whole \
        message to that agent and work out what the user most likely means by it, given the \
        conversation. Most of the time they are answering or acting on what the agent just said: \
        picking one of the options it offered, naming something it mentioned (a noun, a file, an \
        item in a list, an issue number, a step), or referring to content it described. Those \
        names and options are the likeliest words in the transcript, so a misheard span that sounds \
        like one of them almost certainly is that one.

        How recognition goes wrong for this user:
        \(profile.failureModes)

        How to fix it:
        - A span that reads oddly in its sentence is a suspect. Sound it out and compare it with \
        the terms in the reference material: what is on screen, the recent conversation, the rare \
        terms, the user's vocabulary and their past corrections. If a term there, in any language, \
        sounds like the span and fits the sentence, replace the span with that term, written \
        exactly as the reference material writes it (same spelling, letter case and script).
        - Restore the term itself; never translate it into another language or swap it for a \
        word that merely means the same.
        - Use only terms supported by the reference material or common knowledge. Leave natural, \
        plausible wording alone, and do not rephrase or polish.
        """
    }

    /// Design §6 prompt, assembled under the per-block budgets of
    /// `CorrectionContextBudget` (decided BEFORE assembly; every block's spend is
    /// logged under `[CorrectionPrompt]` so prompt composition is auditable).
    /// The evidence blocks are peers — none is presented as outranking the others;
    /// the model weighs them against the sentence. The context block is explicitly
    /// labeled "not the text to process", because otherwise models happily
    /// "correct" the quoted previous turn instead of the transcript.
    ///
    /// `diagnostics` (DEBUG tracing) receives the terms that actually SURVIVED budget
    /// clamping. Those were previously unrecoverable after the fact: the `[CorrectionPrompt]`
    /// log line records only each block's char count, and re-deriving the winners from the
    /// candidate list would duplicate the clamp logic here and silently drift from it.
    /// Knowing which terms won the 400-char vocab budget — and, by omission, which were
    /// pushed out — is the main lever for tuning that budget.
    static func buildPrompt(transcript: String,
                            candidates: [CorrectionCandidate],
                            context: ConversationContext,
                            profile: CorrectionLanguageProfile? = nil,
                            diagnostics: PromptDiagnosticsSink? = nil) -> String {
        let profile = profile ?? CorrectionLanguageProfile.resolve(locale: "zh", transcript: transcript)
        var blocks: [String] = []
        var vocabChars = 0, confusionChars = 0, digestChars = 0, contextChars = 0

        // Hoisted above the vocab block: the vocab filter below needs to know
        // which phonetic keys a confusion record already covers.
        let confusion = candidates.filter { $0.sourceIdentifier == "confusion_dictionary" }

        // Typed vocabulary — clamped to its char budget, not just a term count.
        //
        // [T-correction-low-freq-evidence] Terms whose phonetic key is already
        // answered by a confusion record are dropped here. Listing "Linux" as a
        // high-frequency typed term (56×) alongside "Linux→minis（用户已手动纠正1次）"
        // put the two signals in direct competition and the model kept Linux —
        // frequency read as authority. The confusion record is strictly
        // higher-quality evidence (explicit user correction vs. a typing count),
        // so the vocab echo is pure noise for exactly those keys. Terms with no
        // confusion record are unaffected.
        let confusionKeys = Set(confusion.map(\.phoneticKey))
        let vocab = candidates
            .filter { $0.sourceIdentifier == "typed_vocabulary" }
            .filter { !confusionKeys.contains($0.phoneticKey) }
        if !vocab.isEmpty {
            var kept: [String] = []
            var used = 0
            for term in vocab.map(\.term).uniqued() {
                let cost = term.count + (kept.isEmpty ? 0 : 1)
                guard used + cost <= CorrectionContextBudget.vocabBlock else { break }
                kept.append(term); used += cost
            }
            if !kept.isEmpty {
                vocabChars = used
                diagnostics?.vocabTerms = kept
                blocks.append("以下是该用户的常用词汇（来自历史文字输入，仅供参考）：\n\(kept.joined(separator: "、"))")
            }
        }

        // Confusion history — line-clamped to its char budget.
        if !confusion.isEmpty {
            var kept: [String] = []
            var used = 0
            for c in confusion {
                let line = c.evidence
                let cost = line.count + (kept.isEmpty ? 0 : 1)
                guard used + cost <= CorrectionContextBudget.confusionBlock else { break }
                kept.append(line); used += cost
            }
            if !kept.isEmpty {
                confusionChars = used
                diagnostics?.confusionLines = kept
                blocks.append("以下是该用户过去亲手纠正的语音识别错误（高置信度，ASR 将目标词误识为下方原文，用户主动修改）：\n\(kept.joined(separator: "\n"))")
            }
        }

        // Rare-content digest (builder-capped at 200 chars; defensive re-clamp).
        if let digest = context.rareTermsDigest, !digest.isEmpty {
            let clamped = String(digest.prefix(CorrectionContextBudget.rareDigest))
            digestChars = clamped.count
            blocks.append("以下是近期对话中出现的少见词/专有名词（语音识别容易听错，供参考）：\n\(clamped)")
        }

        // Conversation context: budgeted excerpts preferred, legacy two-field fallback.
        if !context.recentExcerpts.isEmpty {
            let body = context.recentExcerpts.joined(separator: "\n")
            contextChars = body.count
            blocks.append("以下是当前对话的最近上下文（供理解语境使用，不是需要处理的内容）：\n\(body)")
        } else if !(context.lastUserMessage?.isEmpty ?? true) || !(context.lastAgentReply?.isEmpty ?? true) {
            var ctx = "以下是当前对话的最近上下文（供理解语境使用，不是需要处理的内容）："
            if let u = context.lastUserMessage, !u.isEmpty { ctx += "\n【用户上一条消息】：\(u)" }
            if let a = context.lastAgentReply, !a.isEmpty { ctx += "\n【AI上一条回复】：\(a)" }
            contextChars = ctx.count
            blocks.append(ctx)
        }

        // [T-voice-viewport-context] What the user is looking at right now, and the
        // newest reply. Both come after the recent-turns block: the recent turns say what
        // the conversation has been about, these say what the user is reading as they
        // speak — which, in a long session scrolled back, is not the latest turn. The
        // builder already capped and deduplicated them; the clamps here are defensive.
        var viewportChars = 0, latestReplyChars = 0
        if !context.viewportLines.isEmpty {
            let body = String(context.viewportLines.joined(separator: "\n")
                .prefix(CorrectionContextBudget.viewportBlock))
            viewportChars = body.count
            blocks.append("以下是用户此刻在屏幕上看到的对话内容（按屏幕从上到下排列，越靠近屏幕中央越优先保留；供理解语境使用，不是需要处理的内容）：\n\(body)")
        }
        if let reply = context.latestReply, !reply.isEmpty {
            let body = String(reply.prefix(CorrectionContextBudget.latestReplyBlock))
            latestReplyChars = body.count
            let partial = context.mining.viewport?.latestReplyDedup == "partially_on_screen"
            let heading = partial
                ? "以下是本对话最新一条 AI 回复中、未出现在上方屏幕内容里的部分"
                : "以下是本对话最新一条 AI 回复"
            blocks.append("\(heading)（供理解语境使用，不是需要处理的内容）：\n\(body)")
        }

        let evidence = blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n\n"
        // [T-correction-low-freq-evidence] The closing instruction branches on
        // whether any confusion evidence actually made it into the prompt. The
        // single conservative closing ("已经正确…请不要修改") was being applied
        // even when a user-confirmed correction was listed right above it, and a
        // transcript like "去远程Linux开发环境" reads as perfectly valid text — so
        // the model had explicit license to leave it alone. When we DO have a
        // manual-correction record, say plainly that surface validity is not a
        // reason to skip it, since ASR substitutes real look-alike words rather
        // than producing obvious nonsense.
        let closing: String
        if confusionChars > 0 {
            closing = "如果上方纠错记录中的原文出现在转录里，请按记录修正"
                + "（即使转录在字面上语义合法，也可能是 ASR 将目标词误识为了形近词）。"
                + "其他无把握的地方不要修改。只输出修正后的文本，不要输出任何解释。"
        } else {
            closing = "如果转录内容本身已经正确、或者是无法用参考信息判断的正常表达，请不要修改。"
                + "只输出修正后的文本，不要输出任何解释。"
        }
        // With an on-screen block, ask the model to reason from it explicitly: a word the
        // user is looking at is the likeliest thing they just said.
        // [T-voice-mixed-term-restore] "同音字" alone steered the model to Chinese-only
        // substitutes; each language names its own error kinds.
        let errorKinds = profile.errorKinds
        let lead = viewportChars > 0
            ? "请结合以上参考信息，尤其是用户此刻在屏幕上看到的对话内容，推断用户这句要发给 AI 的话的整体意图（常常是在回应、选择或提及 AI 刚提到的名词、内容或选项），据此判断并修正下面这段语音转录文本中可能的\(errorKinds)。"
            : "请结合以上参考信息和对话上下文，推断用户这句要发给 AI 的话的整体意图，判断并修正下面这段语音转录文本中可能的\(errorKinds)。"
        let prompt = """
        \(evidence)\(lead)\
        \(closing)

        原文：\(transcript)
        """
        logger.info("[CorrectionPrompt] profile=\(profile.rawValue) blocks vocab=\(vocabChars)/\(CorrectionContextBudget.vocabBlock) confusion=\(confusionChars)/\(CorrectionContextBudget.confusionBlock) digest=\(digestChars)/\(CorrectionContextBudget.rareDigest) context=\(contextChars) msg_ctx=\(digestChars + contextChars)/\(CorrectionContextBudget.messageContextTotal) viewport=\(viewportChars)/\(CorrectionContextBudget.viewportBlock) latestReply=\(latestReplyChars)/\(CorrectionContextBudget.latestReplyBlock) transcript=\(transcript.count) prompt_total=\(prompt.count)")
        diagnostics?.blockChars = [
            "vocab": vocabChars, "confusion": confusionChars, "digest": digestChars,
            "context": contextChars, "viewport": viewportChars, "latestReply": latestReplyChars,
            "transcript": transcript.count, "total": prompt.count,
        ]
        return prompt
    }

    /// Models like to wrap output in quotes, code fences, or an obliging "修正后：" prefix.
    /// Strip that before the diff check, or a perfectly good correction gets rejected as
    /// "too different" purely because of decoration.
    static func cleanResponse(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
                .drop(while: { $0.hasPrefix("```") })
                .prefix(while: { !$0.hasPrefix("```") })
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["修正后的文本：", "修正后：", "修正：", "Corrected:", "Output:"] {
            if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        // Only strip symmetric wrapping quotes — a quote that's part of the sentence stays.
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("'", "'")]
        for (open, close) in pairs where t.count >= 2 && t.first == open && t.last == close {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Language profiles

/// [T-voice-mixed-term-restore] How speech recognition fails differs by language, so the
/// prompt's failure-mode rules are kept per language instead of one Chinese-centred list
/// applied to everyone. Chosen from what the transcript is written in, with the recognizer
/// locale as the tie-breaker: a user on a zh-CN recognizer who dictates an English sentence
/// gets the Western rules, and a kanji-only Japanese transcript still reads as Japanese
/// because the locale says so.
enum CorrectionLanguageProfile: String, Sendable, CaseIterable {
    case chinese, japanese, korean, western, generic

    static func resolve(locale: String, transcript: String) -> CorrectionLanguageProfile {
        let key = PhoneticNormalizerRegistry.normalizedLocaleKey(locale)
        var han = false, kana = false, hangul = false, western = false
        for scalar in transcript.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: kana = true
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul = true
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han = true
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x370...0x3FF, 0x400...0x4FF: western = true
            default: break
            }
        }
        if hangul { return .korean }
        if kana { return .japanese }
        if han { return key == "ja" ? .japanese : .chinese }
        if western { return .western }
        switch key {
        case "zh", "yue", "wuu": return .chinese
        case "ja": return .japanese
        case "ko": return .korean
        default: return .generic
        }
    }

    /// The "How recognition goes wrong" bullets of the system prompt.
    var failureModes: String {
        switch self {
        case .chinese:
            return """
            - They speak Chinese mixed with English words, product names and code identifiers. \
            A Chinese recognizer often writes such an English word as Chinese characters that only \
            sound like it (for example "遗穴" for "Issue", "扣米特" for "commit", "杰森" for "JSON").
            - Chinese names, product names and jargon come back as common words with the same or a \
            similar sound (同音字 / 近音词), often words that are valid on their own.
            - If the context says "Issue", write "Issue", not a Chinese word with the same meaning \
            such as "议题" or "问题".
            """
        case .japanese:
            return """
            - They speak Japanese mixed with English words, product names and code identifiers. \
            The recognizer often writes such a term in katakana ("イシュー" for "Issue", "コミット" for \
            "commit") or splits it into unrelated words.
            - It picks the wrong kanji among homophones (同音異義語, e.g. 機能/昨日, 公開/後悔) and \
            chooses between kana and kanji inconsistently.
            - Write a term the way the reference material writes it: Latin letters if it is written \
            in Latin letters there, katakana if it is written in katakana there.
            """
        case .korean:
            return """
            - They speak Korean mixed with English words, product names and code identifiers. \
            The recognizer often writes such a term in Hangul ("이슈" for "Issue", "커밋" for \
            "commit") or splits it into unrelated words.
            - It confuses words that sound alike, and misplaces word spacing (띄어쓰기) around \
            terms. Fix spacing only around a term you restore.
            - Write a term the way the reference material writes it: Latin letters if it is written \
            in Latin letters there, Hangul if it is written in Hangul there.
            """
        case .western:
            return """
            - Product names, code identifiers and file names are split into or merged with ordinary \
            words ("get hub" for "GitHub", "cube cuddle" for "kubectl", "read me dot MD" for \
            "README.md"), and lose their letter case and punctuation.
            - Names from other languages (often Chinese) are spelled out phonetically.
            - Homophones and near-homophones are swapped (their/there, accept/except, \
            four/for). Leave spelling variants, grammar and style alone.
            """
        case .generic:
            return """
            - Names, product names, code identifiers and words from other languages are misheard as \
            ordinary words, or spelled out phonetically in the user's script.
            - Words that sound alike are swapped.
            """
        }
    }

    /// What the user prompt's closing line asks the model to fix. The user prompt is
    /// written in Chinese for every language, so this is too.
    var errorKinds: String {
        switch self {
        case .chinese:
            return "同音字、近音词，以及被识别成普通词或音译汉字的专有名词（中文或英文，英文请按参考信息中的原拼写还原，不要翻译成中文）"
        case .japanese:
            return "同音异义的汉字，以及被写成片假名、被拆开或被识别成普通词的术语和专有名词（按参考信息中的写法还原，不要翻译）"
        case .korean:
            return "近音词，以及被写成韩文字母、被拆开或被识别成普通词的术语和专有名词及其周围的空格（按参考信息中的写法还原，不要翻译）"
        case .western:
            return "同音/近音词，以及被拆开、合并或按读音拼写的专有名词、产品名和代码标识符（按参考信息中的原写法还原，包括大小写和符号）"
        case .generic:
            return "同音/近音词，以及被识别成普通词或按读音拼写的专有名词（按参考信息中的写法还原，不要翻译）"
        }
    }
}

// MARK: - Model resolution

/// Sub-model-group → primary-model-group fallback (design §6), but VM-independent so the
/// engine and the debug RPCs can both use it. Mirrors the *intent* of
/// `AIChatViewModel.resolveSubEntry()`: prefer the cheap sub group, degrade to primary
/// rather than failing.
enum CorrectionModelResolver {
    struct Resolved {
        let entry: ModelEntry
        let groupKind: String   // "sub" | "primary"
    }

    @MainActor
    static func resolve() -> Resolved? {
        let store = ProviderConfigStore.shared
        if let subId = store.defaultSubGroupId,
           let group = store.group(for: subId),
           let entryId = ModelGroupRouter.resolve(group: group, sessionId: "voice-correction", store: store),
           let entry = store.entry(for: entryId) {
            return Resolved(entry: entry, groupKind: "sub")
        }
        if let primaryId = store.defaultPrimaryGroupId,
           let group = store.group(for: primaryId),
           let entryId = ModelGroupRouter.resolve(group: group, sessionId: "voice-correction", store: store),
           let entry = store.entry(for: entryId) {
            return Resolved(entry: entry, groupKind: "primary")
        }
        logger.error("[VoiceCorrection][Correct] no sub/primary model group configured — correction unavailable")
        return nil
    }
}

private extension Array where Element == String {
    /// Order-preserving dedup (Set would scramble the "most relevant first" ordering the
    /// retrieval step just established).
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
