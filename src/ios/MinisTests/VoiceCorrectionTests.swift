import XCTest
@testable import Minis

/// Unit tests for the pure-logic parts of voice correction: the truncator, the phonetic
/// normalizer, the LCS/word-boundary diff, the vocabulary filter, and confidence math.
///
/// Deliberately no DB / no LLM here — those are exercised on-device through the
/// `debug.voiceCorrection.*` RPCs, where they're actually meaningful. What's tested here is
/// the logic that must hold regardless of environment, including the specific bugs the
/// on-device runs surfaced (CJK numerals scoring as digits; the re-segmentation that made
/// token-level diffs lose the change).
final class VoiceCorrectionTests: XCTestCase {

    // MARK: - SentenceSplitter

    func testSentenceSplit_keepsTerminators() {
        XCTAssertEqual(SentenceSplitter.split("今天很好。明天下雨！"), ["今天很好。", "明天下雨！"])
    }

    func testSentenceSplit_noTerminatorYieldsOneSentence() {
        // Must not return [] — callers diff whatever comes back.
        XCTAssertEqual(SentenceSplitter.split("没有标点的一句话"), ["没有标点的一句话"])
    }

    func testSentenceSplit_emptyAndWhitespace() {
        XCTAssertEqual(SentenceSplitter.split(""), [])
        XCTAssertEqual(SentenceSplitter.split("   \n  "), [])
    }

    // MARK: - ConversationContextTruncator (design §6)

    func testTruncate_underLimit_unchangedAndNoEllipsis() {
        let r = ConversationContextTruncator.truncate("短消息", softLimit: 500)
        XCTAssertEqual(r.text, "短消息")
        XCTAssertFalse(r.wasTruncated)
    }

    func testTruncate_extendsPastSoftLimitToNextTerminator() {
        // 10 chars, then a sentence that ends at char 20. With a soft limit of 10 we must
        // NOT cut at 10 — we run on to the terminator, even though that overshoots.
        let text = String(repeating: "甲", count: 10) + "乙丙丁。戊己"
        let r = ConversationContextTruncator.truncate(text, softLimit: 10, hardCeiling: 100)
        XCTAssertTrue(r.wasTruncated)
        XCTAssertTrue(r.text.hasSuffix("。…"), "should cut at the terminator, inclusive: \(r.text)")
        XCTAssertFalse(r.text.contains("戊"), "must not include content past the terminator")
    }

    func testTruncate_noTerminatorWithinCeiling_hardCutsAtSoftLimit() {
        // Punctuation-free wall of text: the scan must give up at the ceiling rather than
        // let the prompt grow without bound.
        let text = String(repeating: "字", count: 300)
        let r = ConversationContextTruncator.truncate(text, softLimit: 10, hardCeiling: 20)
        XCTAssertTrue(r.wasTruncated)
        XCTAssertEqual(r.text, String(repeating: "字", count: 10) + "…")
    }

    func testTruncate_exactlyAtLimit_isNotTruncated() {
        let text = String(repeating: "字", count: 10)
        let r = ConversationContextTruncator.truncate(text, softLimit: 10)
        XCTAssertFalse(r.wasTruncated)
        XCTAssertEqual(r.text, text)
    }

    // MARK: - PinyinNormalizer

    func testPinyin_homophonesCollapseToSameKey() {
        let n = PinyinNormalizer.shared
        // The entire premise of the feature: the ASR error and the intended word must key
        // to something close enough to retrieve.
        XCTAssertEqual(n.normalize("张三"), n.normalize("章三"))
    }

    func testPinyin_tonelessAndSpaceless() {
        XCTAssertEqual(PinyinNormalizer.shared.normalize("张三"), "zhangsan")
        XCTAssertEqual(PinyinNormalizer.shared.normalize("食堂"), "shitang")
    }

    func testPinyin_emptyInput() {
        XCTAssertEqual(PinyinNormalizer.shared.normalize(""), "")
        XCTAssertEqual(PinyinNormalizer.shared.normalize("   "), "")
    }

    func testPinyinSimilarity_nearHomophonesScoreHigh() {
        let a = PinyinNormalizer.shared.normalize("张山")   // zhangshan
        let b = PinyinNormalizer.shared.normalize("张三")   // zhangsan
        // Near-homophone: this is what the recorder must accept as an ASR fix.
        XCTAssertGreaterThan(PinyinNormalizer.similarity(a, b), 0.6)
    }

    func testPinyinSimilarity_unrelatedWordsScoreLow() {
        let a = PinyinNormalizer.shared.normalize("吃饭")
        let b = PinyinNormalizer.shared.normalize("看电影")
        // A content rewrite: the recorder must NOT learn this as a correction.
        XCTAssertLessThan(PinyinNormalizer.similarity(a, b), 0.6)
    }

    func testLevenshtein_basics() {
        XCTAssertEqual(PinyinNormalizer.levenshtein(Array("abc"), Array("abc")), 0)
        XCTAssertEqual(PinyinNormalizer.levenshtein(Array("abc"), Array("abd")), 1)
        XCTAssertEqual(PinyinNormalizer.levenshtein(Array(""), Array("abc")), 3)
    }

    // MARK: - Confidence (design §3.2)

    func testConfidence_negativeFeedbackWeighsDouble() {
        // 3 confirmations, no pushback → fully trusted.
        XCTAssertEqual(VoiceCorrectionDB.confidence(frequency: 3, negative: 0), 1.0, accuracy: 0.001)
        // 3 confirmations vs 1 rejection → 3/(3+2) — a rejection costs twice a confirmation,
        // because a wrong rule actively corrupts the user's text.
        XCTAssertEqual(VoiceCorrectionDB.confidence(frequency: 3, negative: 1), 0.6, accuracy: 0.001)
        // Repeatedly disproven → drops under the 0.3 retrieval floor and stops being used.
        XCTAssertLessThan(VoiceCorrectionDB.confidence(frequency: 1, negative: 3), 0.3)
    }

    // MARK: - LCS diff

    func testLCSDiff_detectsReplacement() {
        let ops = LCSDiff.diff(["张山", "说", "话"], ["张三", "说", "话"])
        XCTAssertTrue(ops.contains(.replace(old: ["张山"], new: ["张三"])))
    }

    func testLCSDiff_identicalInputsHaveNoChanges() {
        let ops = LCSDiff.diff(["a", "b"], ["a", "b"])
        XCTAssertEqual(ops, [.equal(["a", "b"])])
    }

    // MARK: - tokenPairs (the re-segmentation bug, caught on device)

    func testTokenPairs_survivesResegmentation() {
        // The regression that shipped an empty diffSummary: jieba segments the corrected
        // text differently ("张山|说" → "张三说"), so a token-aligned diff sees a 2-for-1
        // replace. The point of this test is that the change is NOT lost and does NOT
        // degrade to the single-char "山→三" (which reads meaninglessly to the user).
        //
        // [T-correction-diff-wordlevel] Word-level alignment emits the whole
        // re-segmented span as one pair: 张山说→张三说 (["张山","说"]↔["张三说"]).
        // That's a valid, phonetically-close correction pair — coarser than
        // "张山→张三" but never the degenerate single char. Assert both: change
        // is present, and it's at least word-length (≥2 chars), not "山→三".
        let pairs = VoiceCorrectionDiff.tokenPairs(from: "张山说食堂今天关门",
                                                     to: "张三说食堂今天关门")
        XCTAssertFalse(pairs.isEmpty, "must find the change despite re-segmentation")
        XCTAssertTrue(pairs.contains { $0.from.contains("张山") && $0.to.contains("张三") && $0.from.count >= 2 },
                      "must read as a word-level 张山…→张三… pair, not the degenerate 山→三: \(pairs)")
    }

    func testTokenPairs_multipleCorrections() {
        let pairs = VoiceCorrectionDiff.tokenPairs(from: "今天去石塘吃饭遇到张山了",
                                                     to: "今天去食堂吃饭遇到张三了")
        XCTAssertTrue(pairs.contains { $0.from == "石塘" && $0.to == "食堂" }, "\(pairs)")
        XCTAssertTrue(pairs.contains { $0.from == "张山" && $0.to == "张三" }, "\(pairs)")
    }

    func testTokenPairs_identicalTextYieldsNoPairs() {
        XCTAssertTrue(VoiceCorrectionDiff.tokenPairs(from: "今天天气不错", to: "今天天气不错").isEmpty)
    }

    // MARK: - Word-level alignment (acronym expansion + no fragment stitching)
    // [T-correction-diff-wordlevel] tokenPairs aligns TOKEN sequences, so a
    // word that expands into several words maps as one whole pair — no
    // character fragments padding into neighbours, no false positives on
    // boundary insertions.

    func testTokenPairs_acronymExpansion_wholePair() {
        // MediaS (1 token) → Media Server (2 tokens): must surface as the
        // COMPLETE pair, not a fragment like 开发→erver开发.
        let pairs = VoiceCorrectionDiff.tokenPairs(from: "远程 MediaS 开发环境",
                                                     to: "远程 Media Server 开发环境")
        XCTAssertTrue(pairs.contains { $0.from == "MediaS" && $0.to == "Media Server" },
                      "expected clean MediaS→Media Server: \(pairs)")
        // No fragment leaked into the neighbouring word.
        XCTAssertFalse(pairs.contains { $0.from.contains("开发") || $0.to.contains("erver开发") },
                       "no neighbour-word fragment: \(pairs)")
    }

    func testTokenPairs_englishMultiWordEdit() {
        // worker (1 token) → work on (2 tokens): clean whole pair.
        let pairs = VoiceCorrectionDiff.tokenPairs(from: "找个 worker 处理",
                                                     to: "找个 work on 处理")
        XCTAssertTrue(pairs.contains { $0.from == "worker" && $0.to == "work on" }, "\(pairs)")
    }

    func testTokenPairs_punctuationInsertionYieldsNoPair() {
        // Inserting 、 between words is a whole-token insertion — content
        // editing, NOT an in-word change — so it must produce NO pair at all
        // (the old char-LCS wrongly emitted 滚动条→、滚动条).
        let pairs = VoiceCorrectionDiff.tokenPairs(from: "输入框文本滚动条和发送按钮",
                                                     to: "输入框文本、滚动条和发送按钮")
        XCTAssertTrue(pairs.isEmpty, "whole-token punctuation insertion must yield no pair: \(pairs)")
    }

    func testTokenPairs_wholeWordInsertionYieldsNoPair() {
        // Adding a standalone word (not modifying an existing one) is content,
        // not a homophone/abbreviation — no pair.
        let pairs = VoiceCorrectionDiff.tokenPairs(from: "去食堂吃饭",
                                                     to: "去食堂好好吃饭")
        XCTAssertFalse(pairs.contains { $0.from == $0.to }, "no no-op pairs: \(pairs)")
        // "好好" is a pure insertion; it must not pair with an unrelated word.
        XCTAssertFalse(pairs.contains { $0.to.contains("好好") && !$0.from.contains("好好") && $0.from.count < 2 },
                       "inserted word must not fabricate a pair: \(pairs)")
    }

    // MARK: - charChangeRatio (rewrite rejection, design §6)

    func testCharChangeRatio_smallFixIsSmall() {
        let r = VoiceCorrectionDiff.charChangeRatio(from: "张山说食堂今天关门", to: "张三说食堂今天关门")
        XCTAssertLessThan(r, VoiceCorrectionConfig.maxCharChangeRatio)
    }

    func testCharChangeRatio_latinTermRestoreIsOneUnit() {
        // [T-voice-mixed-term-restore] Restoring a transliterated English word is one
        // word swapped, not a rewrite, even in a short utterance.
        XCTAssertLessThanOrEqual(VoiceCorrectionDiff.charChangeRatio(from: "看看遗穴", to: "看看Issue"),
                                 VoiceCorrectionConfig.maxCharChangeRatio)
        XCTAssertLessThan(VoiceCorrectionDiff.charChangeRatio(from: "接下来再看看下一个遗穴。",
                                                              to: "接下来再看看下一个Issue。"),
                          VoiceCorrectionConfig.maxCharChangeRatio)
        XCTAssertEqual(VoiceCorrectionDiff.editUnits("修 Issue 399"), ["修", " ", "Issue", " ", "399"])
    }

    func testCharChangeRatio_rewriteExceedsThreshold() {
        // A model that "helpfully" rewrote instead of correcting must be rejected.
        let r = VoiceCorrectionDiff.charChangeRatio(from: "今天去吃饭",
                                                      to: "明天我们一起去看电影然后逛街买东西")
        XCTAssertGreaterThan(r, VoiceCorrectionConfig.maxCharChangeRatio)
    }

    // MARK: - Vocabulary filter (design §3.3)

    func testVocabFilter_rejectsStopwords() {
        assertRejected("的"); assertRejected("我们"); assertRejected("继续")
    }

    func testVocabFilter_rejectsEnglishFunctionWords() {
        // These dominated the learned vocabulary on device before the English list existed:
        // absent from the zh background list (+2), 2–6 chars (+1), ASCII letters (+1) = 4.
        assertRejected("the"); assertRejected("and"); assertRejected("with"); assertRejected("THE")
    }

    func testVocabFilter_rejectsTooShort() {
        assertRejected("好")
    }

    func testVocabFilter_acceptsProperNouns() {
        // nr = person name → the strongest single signal in §3.3.
        guard case .accepted(let score, let b) = VocabularyFilter.evaluate(term: "李四", posTag: "nr") else {
            return XCTFail("a person name must be accepted")
        }
        XCTAssertEqual(b.posTag, 2)
        XCTAssertGreaterThanOrEqual(score, VoiceCorrectionConfig.vocabMinScore)
    }

    func testVocabFilter_acceptsLatinJargon() {
        guard case .accepted(_, let b) = VocabularyFilter.evaluate(term: "CppJieba", posTag: "eng") else {
            return XCTFail("latin jargon must be accepted")
        }
        XCTAssertEqual(b.hasLatinOrDigit, 1)
    }

    /// The CJK-numeral bug, caught on device: `Character.isNumber` is TRUE for 三/一/十, so
    /// "张三" was scoring a phantom "contains a digit" point, and the no-lexical-content
    /// reject would have discarded genuine words like "三星".
    func testVocabFilter_cjkNumeralsAreNotDigits() {
        guard case .accepted(_, let b) = VocabularyFilter.evaluate(term: "张三", posTag: "nr") else {
            return XCTFail("张三 must be accepted")
        }
        XCTAssertEqual(b.hasLatinOrDigit, 0, "三 is a Unicode Number but NOT an ASCII digit")

        // And a word made entirely of CJK numerals must survive the "no lexical content" gate.
        if case .rejected(let reason) = VocabularyFilter.evaluate(term: "三星", posTag: "nz") {
            XCTFail("三星 was rejected as \(reason) — CJK numerals must not count as digits")
        }
    }

    func testVocabFilter_rejectsBareAsciiDigits() {
        assertRejected("12345")
    }

    private func assertRejected(_ term: String, posTag: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        if case .accepted(let score, _) = VocabularyFilter.evaluate(term: term, posTag: posTag) {
            XCTFail("\(term) should have been rejected but scored \(score)", file: file, line: line)
        }
    }
}

// MARK: - CorrectionContextBuilder (budgeted context, 2026-07-16)

final class CorrectionContextBuilderTests: XCTestCase {

    /// Fake background-word-list: only these count as known-common words.
    private let fakeRank: @Sendable (String) -> Int? = { term in
        ["今天", "可以", "我们", "hello"].contains(term) ? 1 : nil
    }

    // MARK: RareContentScorer

    func testScorer_knownCommonWordScoresZero() {
        XCTAssertEqual(RareContentScorer.score(term: "今天", rank: fakeRank), 0)
    }

    func testScorer_technicalTokens() {
        // camelCase / interior caps
        XCTAssertEqual(RareContentScorer.score(term: "LiveActivity", rank: fakeRank), 90)
        // letters + digits
        XCTAssertEqual(RareContentScorer.score(term: "iphone11", rank: fakeRank), 90)
        // dashed identifier
        XCTAssertEqual(RareContentScorer.score(term: "dns-server", rank: fakeRank), 90)
        // ALL CAPS
        XCTAssertEqual(RareContentScorer.score(term: "ASC", rank: fakeRank), 90)
        // mixed CJK + Latin
        XCTAssertEqual(RareContentScorer.score(term: "用ASC", rank: fakeRank), 90)
    }

    func testScorer_plainLowercaseLatinIsLow() {
        XCTAssertEqual(RareContentScorer.score(term: "world", rank: fakeRank), 20)
    }

    func testScorer_cjkDomainWordOfCommonChars() {
        // 闪/退 are both common hanzi; the word is OOV → baseline 40, digest-eligible
        // but below the strong (sentence-selection) threshold.
        let s = RareContentScorer.score(term: "闪退", rank: fakeRank)
        XCTAssertEqual(s, 40)
        XCTAssertGreaterThanOrEqual(s, RareContentScorer.digestThreshold)
        XCTAssertLessThan(s, RareContentScorer.strongThreshold)
    }

    func testScorer_rareHanziRaisesScore() {
        // 鏖 is far outside any common-character set: single rare char = 75,
        // and a two-char word with one rare char lands mid-scale (40 + 25).
        XCTAssertEqual(RareContentScorer.score(term: "鏖", rank: fakeRank), 75)
        XCTAssertEqual(RareContentScorer.score(term: "鏖战", rank: fakeRank), 65)
    }

    func testScorer_garbageScoresZero() {
        XCTAssertEqual(RareContentScorer.score(term: "", rank: fakeRank), 0)
        XCTAssertEqual(RareContentScorer.score(term: "……", rank: fakeRank), 0)
        XCTAssertEqual(RareContentScorer.score(term: "12345", rank: fakeRank), 0)
        XCTAssertEqual(RareContentScorer.score(term: "的", rank: fakeRank), 0) // common single hanzi
    }

    // MARK: Builder — digest + budget

    func testBuilder_emptyInputGivesEmptyContext() {
        XCTAssertTrue(CorrectionContextBuilder.build(messages: [], rankProvider: fakeRank).isEmpty)
    }

    func testBuilder_digestPicksRareTermsAndRespectsCap() {
        let msgs = [
            CorrectionSourceMessage(role: .user, text: "今天我们聊聊 LiveActivity 的闪退问题。"),
            CorrectionSourceMessage(role: .assistant, text: "可以，dns-server 也有关系。"),
        ]
        let ctx = CorrectionContextBuilder.build(messages: msgs, rankProvider: fakeRank)
        let digest = ctx.rareTermsDigest ?? ""
        XCTAssertTrue(digest.contains("LiveActivity"), "technical term must reach the digest: \(digest)")
        XCTAssertLessThanOrEqual(digest.count, 200)
        // Rarer (90) content sorts ahead of the common-char domain word (40).
        if let li = digest.range(of: "LiveActivity"), let st = digest.range(of: "闪退") {
            XCTAssertLessThan(li.lowerBound, st.lowerBound)
        }
    }

    func testBuilder_recurringPlainLatinWordReachesDigest() {
        // [T-voice-mixed-term-restore] "Issue" scores 20 on its own; recurring in a
        // Chinese conversation it is a term the user is discussing and must reach the
        // digest, ahead of a common-char word (40).
        let msgs = [
            CorrectionSourceMessage(role: .assistant, text: "下一个 Issue 是 闪退 问题。"),
            CorrectionSourceMessage(role: .user, text: "这个 Issue 怎么修"),
            CorrectionSourceMessage(role: .assistant, text: "所有 Issue 都已经 闭环。"),
        ]
        let digest = CorrectionContextBuilder.build(messages: msgs, rankProvider: fakeRank).rareTermsDigest ?? ""
        XCTAssertTrue(digest.contains("Issue"), "recurring Latin word must reach the digest: \(digest)")
        if let a = digest.range(of: "Issue"), let b = digest.range(of: "闪退") {
            XCTAssertLessThan(a.lowerBound, b.lowerBound)
        }
    }

    func testBuilder_englishChatDoesNotPromoteOrdinaryWords() {
        // In an English conversation every recurring word is Latin; none is a term.
        let msgs = [
            CorrectionSourceMessage(role: .assistant, text: "open the file and check the code"),
            CorrectionSourceMessage(role: .user, text: "which file has the code"),
            CorrectionSourceMessage(role: .assistant, text: "this file holds the code"),
        ]
        let digest = CorrectionContextBuilder.build(messages: msgs, rankProvider: fakeRank).rareTermsDigest ?? ""
        XCTAssertFalse(digest.contains("file"), "ordinary English words must stay out: \(digest)")
    }

    func testBuilder_rarePlainLatinWordAndFunctionWordsStayOut() {
        let msgs = [
            CorrectionSourceMessage(role: .assistant, text: "the world and the world"),
            CorrectionSourceMessage(role: .user, text: "the and the and"),
        ]
        let digest = CorrectionContextBuilder.build(messages: msgs, rankProvider: fakeRank).rareTermsDigest ?? ""
        XCTAssertFalse(digest.contains("world"), "two occurrences are below the bar: \(digest)")
        XCTAssertFalse(digest.contains("the"), "English function words never promote: \(digest)")
        XCTAssertFalse(digest.contains("and"), "English function words never promote: \(digest)")
    }

    func testBuilder_expandsBeyondTwoMessagesForRareContent() {
        // Old design stopped at the last user+assistant pair. An older message
        // carrying a rare term must now still contribute an excerpt.
        var msgs: [CorrectionSourceMessage] = [
            CorrectionSourceMessage(role: .user, text: "部署 WGHome 网关的注意事项。这句是老消息。"),
        ]
        msgs.append(CorrectionSourceMessage(role: .assistant, text: "好的。"))
        msgs.append(CorrectionSourceMessage(role: .user, text: "今天可以。"))
        let ctx = CorrectionContextBuilder.build(messages: msgs, rankProvider: fakeRank)
        XCTAssertTrue(ctx.recentExcerpts.joined().contains("WGHome"),
                      "older rare-bearing message should be excerpted: \(ctx.recentExcerpts)")
        // Chronological render: the old message's excerpt comes first.
        XCTAssertTrue(ctx.recentExcerpts.first?.contains("WGHome") ?? false)
    }

    func testBuilder_totalMessageContextStaysUnder5k() {
        // 12 long messages stuffed with rare technical tokens — worst case.
        let long = (0..<40).map { "模块Alpha\($0)Beta 出现鏖战级故障，检查 node-\($0)-cfg 配置。" }.joined()
        let msgs = (0..<12).map { i in
            CorrectionSourceMessage(role: i % 2 == 0 ? .user : .assistant, text: long)
        }
        let ctx = CorrectionContextBuilder.build(messages: msgs, rankProvider: fakeRank)
        let digestChars = ctx.rareTermsDigest?.count ?? 0
        let excerptChars = ctx.recentExcerpts.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(digestChars, 200)
        XCTAssertLessThanOrEqual(digestChars + excerptChars, 5000,
                                 "message context blew its budget: digest=\(digestChars) excerpts=\(excerptChars)")
    }

    func testBuilder_sentenceNeverCutMidway() {
        // Grounding excerpt is built from whole sentences; a sentence set whose
        // total exceeds the cap gets fewer sentences, not a mid-sentence slice.
        let msgs = [
            CorrectionSourceMessage(role: .user,
                text: (0..<60).map { "第\($0)句是一整句完整的话。" }.joined()),
        ]
        let ctx = CorrectionContextBuilder.build(messages: msgs, rankProvider: fakeRank)
        guard let excerpt = ctx.recentExcerpts.first else { return XCTFail("no excerpt") }
        // Every kept sentence still ends with its terminator (or explicit ellipsis).
        let body = excerpt.drop(while: { $0 != "】" }).dropFirst()
        XCTAssertTrue(body.hasSuffix("。") || body.hasSuffix("…"), "excerpt tail: \(body.suffix(12))")
    }
}

// MARK: - [T-voice-viewport-context] On-screen context

/// Centre-out selection, the 2000-char budget and its cut direction, window clipping, and
/// deduplication of the latest reply against the screen. The same scenarios run
/// standalone (no simulator) in MinisTests/Standalone/VoiceViewportContextTests.swift.
/// [T-voice-mixed-term-restore] Which language's failure-mode rules the prompt carries.
final class CorrectionLanguageProfileTests: XCTestCase {

    func testChineseTranscriptWithEnglishTermIsChinese() {
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "zh-CN", transcript: "接下来再看看下一个遗穴。"), .chinese)
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "zh-CN", transcript: "看看 Issue 399"), .chinese)
    }

    func testScriptBeatsLocaleWhenTheyDisagree() {
        // A zh-CN recognizer that returned an English sentence gets the Western rules.
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "zh-CN", transcript: "please fix the get hub issue"), .western)
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "en-US", transcript: "看看这个"), .chinese)
    }

    func testJapaneseAndKorean() {
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "ja-JP", transcript: "次のイシューを見て"), .japanese)
        // Kanji only: the script alone reads as Chinese, the locale says Japanese.
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "ja-JP", transcript: "機能確認"), .japanese)
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "ko-KR", transcript: "다음 이슈 보자"), .korean)
    }

    func testWesternLanguagesAndFallbacks() {
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "fr-FR", transcript: "regarde le problème"), .western)
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "ru-RU", transcript: "посмотри задачу"), .western)
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "ar-SA", transcript: "انظر إلى المشكلة"), .generic)
        XCTAssertEqual(CorrectionLanguageProfile.resolve(locale: "yue-CN", transcript: "123"), .chinese)
    }

    func testEveryProfileHasItsOwnRules() {
        let rules = CorrectionLanguageProfile.allCases.map(\.failureModes)
        XCTAssertEqual(Set(rules).count, rules.count)
        XCTAssertTrue(CorrectionLanguageProfile.chinese.failureModes.contains("\"遗穴\" for \"Issue\""))
        XCTAssertFalse(CorrectionLanguageProfile.western.failureModes.contains("遗穴"))
        XCTAssertTrue(CorrectionLanguageProfile.japanese.failureModes.contains("katakana"))
        XCTAssertTrue(CorrectionLanguageProfile.korean.failureModes.contains("Hangul"))
    }
}

final class ViewportContextBuilderTests: XCTestCase {

    /// Rows stacked top→bottom, each `height` points tall, starting at y = 0.
    private func rows(_ specs: [(ViewportSourceItem.Kind, String, String?, String)], height: Double = 100) -> [ViewportSourceItem] {
        specs.enumerated().map { i, s in
            ViewportSourceItem(kind: s.0, messageId: s.1, blockId: s.2, text: s.3,
                               minY: Double(i) * height, maxY: Double(i + 1) * height)
        }
    }

    func testSelectsWindowAroundCentreAndRendersTopToBottom() {
        // 20 rows of 100pt; visible 800…1200 → centre 1000, window 600…1400.
        let items = rows((0..<20).map { (.user, "m\($0)", nil, "行\($0)") })
        let snap = ViewportSnapshot(items: items, visibleMinY: 800, visibleMaxY: 1200)
        let out = ViewportContextBuilder.build(snapshot: snap, latestReply: nil)
        XCTAssertEqual(out.lines, (6...13).map { "【用户】行\($0)" })
        XCTAssertEqual(out.report.candidateRows, 8)
        XCTAssertEqual(out.report.rows.first?.distance, 0)
    }

    func testBudgetKeepsNearestRowsAndStaysUnder2000() {
        let body = String(repeating: "字", count: 300)
        let items = rows((0..<20).map { (.assistant, "m\($0)", "b\($0)", body) })
        let snap = ViewportSnapshot(items: items, visibleMinY: 800, visibleMaxY: 1200)
        let out = ViewportContextBuilder.build(snapshot: snap, latestReply: nil)
        let total = out.lines.joined(separator: "\n").count
        XCTAssertLessThanOrEqual(total, CorrectionContextBudget.viewportBlock)
        XCTAssertGreaterThan(total, CorrectionContextBudget.viewportBlock - 30)
        // Rows 9 and 10 border the centre (1000): both must be kept whole.
        let kept = Set(out.report.rows.map(\.messageId))
        XCTAssertTrue(kept.isSuperset(of: ["m9", "m10"]))
        // The far edges of the window (rows 6 and 13) are what the budget drops.
        XCTAssertFalse(kept.contains("m6") && kept.contains("m13"))
        XCTAssertEqual(out.report.rows.filter(\.cut).count, 1, "exactly the last row taken is cut")
    }

    func testCutRowAboveCentreKeepsItsEndAndBelowKeepsItsStart() {
        let above = ViewportContextBuilder.cutAround("ABCDEFGHIJ", keep: 5, centerFraction: 1)
        XCTAssertEqual(above, "…GHIJ")
        let below = ViewportContextBuilder.cutAround("ABCDEFGHIJ", keep: 5, centerFraction: 0)
        XCTAssertEqual(below, "ABCD…")
        let middle = ViewportContextBuilder.cutAround("ABCDEFGHIJ", keep: 5, centerFraction: 0.5)
        XCTAssertEqual(middle.count, 5)
        XCTAssertTrue(middle.hasPrefix("…") && middle.hasSuffix("…"))
    }

    func testTallRowIsClippedToTheWindow() {
        // One 10 000pt reply; window 600…1400 is 8% of it.
        let text = (0..<1000).map { String($0 % 10) }.joined()
        let item = ViewportSourceItem(kind: .assistant, messageId: "m", blockId: "b", text: text, minY: 0, maxY: 10_000)
        let out = ViewportContextBuilder.build(
            snapshot: ViewportSnapshot(items: [item], visibleMinY: 800, visibleMaxY: 1200), latestReply: nil)
        let line = out.lines.first ?? ""
        XCTAssertLessThan(line.count, 120, "only the on-window slice, not the whole reply: \(line.count)")
        XCTAssertTrue(line.hasPrefix("【AI】…"))
    }

    func testToolRowsCarryTheirTitle() {
        let items = rows([(.user, "u", nil, "查一下日志"), (.tool, "a", "t1", "搜索日志文件"), (.assistant, "a", "b1", "找到了。")])
        let out = ViewportContextBuilder.build(
            snapshot: ViewportSnapshot(items: items, visibleMinY: 0, visibleMaxY: 300), latestReply: nil)
        XCTAssertEqual(out.lines, ["【用户】查一下日志", "【工具】搜索日志文件", "【AI】找到了。"])
    }

    func testLatestReplyFullyOnScreenIsNotRepeated() {
        let items = rows([(.user, "u", nil, "问题"), (.assistant, "a", "b1", "第一段。"), (.assistant, "a", "b2", "第二段。")])
        let reply = LatestReplySource(messageId: "a", blocks: [.init(id: "b1", text: "第一段。"), .init(id: "b2", text: "第二段。")])
        let out = ViewportContextBuilder.build(
            snapshot: ViewportSnapshot(items: items, visibleMinY: 0, visibleMaxY: 300), latestReply: reply)
        XCTAssertNil(out.latestReply)
        XCTAssertEqual(out.report.latestReplyDedup, "fully_on_screen")
        XCTAssertEqual(out.lines.filter { $0.hasPrefix("【AI·最新回复】") }.count, 2)
        XCTAssertEqual(out.lines.joined().components(separatedBy: "第一段").count - 1, 1)
    }

    func testLatestReplyPartlyOnScreenKeepsOnlyTheRest() {
        // Visible 0…200 → window −100…300: rows 0-2 in, row 3 (b3) out.
        let items = rows([(.user, "u", nil, "问题"), (.assistant, "a", "b1", "甲。"), (.assistant, "a", "b2", "乙。"), (.assistant, "a", "b3", "丙。")])
        let reply = LatestReplySource(messageId: "a", blocks: [.init(id: "b1", text: "甲。"), .init(id: "b2", text: "乙。"), .init(id: "b3", text: "丙。")])
        let out = ViewportContextBuilder.build(
            snapshot: ViewportSnapshot(items: items, visibleMinY: 0, visibleMaxY: 200), latestReply: reply)
        XCTAssertEqual(out.latestReply, "丙。")
        XCTAssertEqual(out.report.latestReplyDedup, "partially_on_screen")
        XCTAssertEqual(out.report.latestReplyBlocksDropped, 2)
    }

    func testLatestReplyOffScreenIsKeptAndCappedFromTheEnd() {
        let long = String(repeating: "旧", count: 1500) + String(repeating: "新", count: 1500)
        let reply = LatestReplySource(messageId: "z", blocks: [.init(id: "bz", text: long)])
        let items = rows([(.user, "u", nil, "很早的问题")])
        let out = ViewportContextBuilder.build(
            snapshot: ViewportSnapshot(items: items, visibleMinY: 0, visibleMaxY: 100), latestReply: reply)
        XCTAssertEqual(out.report.latestReplyDedup, "not_on_screen")
        XCTAssertEqual(out.latestReply?.count, CorrectionContextBudget.latestReplyBlock)
        XCTAssertTrue(out.latestReply?.hasPrefix("…") ?? false)
        XCTAssertTrue(out.latestReply?.hasSuffix("新") ?? false)
        XCTAssertTrue(out.report.latestReplyTruncated)
    }

    func testNoViewportStillSendsLatestReply() {
        let reply = LatestReplySource(messageId: "a", blocks: [.init(id: "b", text: "最新回复")])
        let out = ViewportContextBuilder.build(snapshot: nil, latestReply: reply)
        XCTAssertTrue(out.lines.isEmpty)
        XCTAssertEqual(out.latestReply, "最新回复")
    }
}
