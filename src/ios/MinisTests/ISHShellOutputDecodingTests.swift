//
//  ISHShellOutputDecodingTests.swift
//  MinisTests
//
//  [T-shell-utf8-partial-lead] ISHShellExecutor.decodeShellOutput(fromPending:isFinal:)
//  is how the stdout/stderr reader turns guest bytes into text. Before this fix, a
//  chunk that did not decode as UTF-8 as a whole was re-decoded as Latin-1 in its
//  entirety: output that merely STARTED mid-character (`tail -c`, `head -c`, `dd`,
//  `cut -b` on Chinese text) came back as mojibake from the first byte to the last.
//  GH #428: a model reading a long pasted .txt with `tail -c 2000` got such a block
//  and invented the answer.
//
//  Every test asserts the exact text. The `reads` helper feeds bytes the way the
//  reader loop does: append each read to `pending`, decode, and flush at EOF.
//

import XCTest
@testable import Minis

final class ISHShellOutputDecodingTests: XCTestCase {

    // MARK: - Helpers

    private func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Decode `reads` in order through one `pending` buffer, as the reader loop
    /// does, then flush at EOF. Returns the concatenated text and, separately,
    /// what each step produced.
    private func decode(_ reads: [[UInt8]], flush: Bool = true) -> (text: String, steps: [String], pending: Int) {
        let pending = NSMutableData()
        var steps: [String] = []
        for r in reads {
            pending.append(r, length: r.count)
            steps.append(ISHShellExecutor.decodeShellOutput(fromPending: pending, isFinal: false))
        }
        if flush {
            steps.append(ISHShellExecutor.decodeShellOutput(fromPending: pending, isFinal: true))
        }
        return (steps.joined(), steps, pending.length)
    }

    // MARK: - Plain cases

    func testPureASCII() {
        let r = decode([utf8("hello world\n$ ls -la\n")])
        XCTAssertEqual(r.text, "hello world\n$ ls -la\n")
        XCTAssertEqual(r.pending, 0)
    }

    func testCompleteChinese() {
        let r = decode([utf8("最后的暗号：海盐柚子77\n")])
        XCTAssertEqual(r.text, "最后的暗号：海盐柚子77\n")
    }

    // MARK: - Output that starts mid-character (the #428 case)

    /// The exact bytes `printf '第一行中文\n最后的暗号：海盐柚子77\n' | tail -c 31`
    /// produced on the iPhone 11: the block starts with the last byte of 最 (E6 9C 80).
    /// Before the fix this came back as "\u{80}å\u{90}\u{8e}ç…" for the whole line.
    func testTailC31FromTheDeviceRepro() {
        let full = utf8("第一行中文\n最后的暗号：海盐柚子77\n")
        let tail31 = Array(full.suffix(31))
        XCTAssertEqual(tail31.first, 0x80, "test premise: the block starts on a continuation byte")
        let r = decode([tail31])
        XCTAssertEqual(r.text, "后的暗号：海盐柚子77\n")
    }

    func testLeadingOneAndTwoOrphanBytesAreDropped() {
        let full = utf8("最后的暗号：海盐柚子77\n")   // 最 = E6 9C 80
        XCTAssertEqual(decode([Array(full.dropFirst(1))]).text, "后的暗号：海盐柚子77\n")
        XCTAssertEqual(decode([Array(full.dropFirst(2))]).text, "后的暗号：海盐柚子77\n")
    }

    func testLeadingOrphanOfAFourByteEmojiIsDropped() {
        // 👍 = F0 9F 91 8D; a block that starts on its last three bytes.
        let full = utf8("👍好的")
        XCTAssertEqual(decode([Array(full.dropFirst(1))]).text, "好的")
    }

    func testChunkOfOnlyOrphanContinuationBytesIsDropped() {
        let r = decode([[0x80, 0x81]], flush: false)
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.pending, 0, "orphans are not a sequence to wait for")
    }

    // MARK: - Output that ends mid-character

    func testTrailingHalfCharacterWaitsForTheNextRead() {
        let zi = utf8("字")                        // E5 AD 97
        let r = decode([utf8("中文") + zi.prefix(2), Array(zi.suffix(1)) + utf8("\n")])
        XCTAssertEqual(r.steps[0], "中文", "complete text first, the half character is held back")
        XCTAssertEqual(r.steps[1], "字\n")
        XCTAssertEqual(r.text, "中文字\n")
    }

    func testIncompleteLeadByteAloneWaitsInsteadOfDecoding() {
        let zhong = utf8("中")                     // E4 B8 AD
        let r = decode([[zhong[0]], Array(zhong.dropFirst())], flush: false)
        XCTAssertEqual(r.steps[0], "", "a lone lead byte must wait, not be decoded as Latin-1")
        XCTAssertEqual(r.steps[1], "中")
        XCTAssertEqual(r.pending, 0)
    }

    func testTrailingHalfCharacterAtEOFBecomesOneReplacementCharacter() {
        let zi = utf8("字")
        let r = decode([utf8("中文") + zi.prefix(2)])
        XCTAssertEqual(r.text, "中文\u{FFFD}")
    }

    // MARK: - Invalid bytes inside otherwise valid UTF-8

    func testInvalidByteInTheMiddleBecomesReplacement() {
        let r = decode([utf8("中") + [0xFF] + utf8("文\n")])
        XCTAssertEqual(r.text, "中\u{FFFD}文\n")
    }

    // MARK: - Split across reads

    func testFourByteEmojiSplitAcrossTwoReads() {
        let e = utf8("👍")
        let r = decode([utf8("a") + e.prefix(2), Array(e.suffix(2)) + utf8("b")])
        XCTAssertEqual(r.steps[0], "a")
        XCTAssertEqual(r.steps[1], "👍b")
        XCTAssertEqual(r.text, "a👍b")
    }

    func testChineseSplitAtEveryByteOffsetReassemblesExactly() {
        let s = "第一行中文\n最后的暗号：海盐柚子77😀\n"
        let b = utf8(s)
        for cut in 0...b.count {
            let r = decode([Array(b.prefix(cut)), Array(b.dropFirst(cut))])
            XCTAssertEqual(r.text, s, "split at byte \(cut)")
        }
    }

    // MARK: - Binary output keeps the old Latin-1 rendering

    func testBinaryOutputFallsBackToLatin1() {
        // A PNG header followed by high bytes: far more than a quarter invalid.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += (0..<56).map { UInt8(0x80 + ($0 * 7) % 0x7F) }
        let r = decode([bytes])
        XCTAssertEqual(r.text, String(data: Data(bytes), encoding: .isoLatin1))
    }
}
