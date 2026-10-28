//
//  QueuedCandidateSpacing.swift
//  MinisApp
//
//  [T-queued-candidate-spacing] The two rules that keep a queued candidate
//  bubble (dashed outline, withdraw button) at the normal distance from the
//  "is thinking…" row and from the tool rows above it. Pure: they see flags and
//  heights only, so they are unit-tested without the list
//  (MinisTests/Standalone/QueuedCandidateSpacingTests).
//

import CoreGraphics

/// Which message the running turn is writing into.
///
/// A prompt sent while the agent is busy is appended to `messages` at once, as
/// a queued candidate, and stays there until the turn takes it. For all that
/// time the LAST message is that bubble, not the reply still being written
/// above it. Everything that asks "is this the message in progress" - the
/// typing indicator, the gap above it, which rows count as streaming - has to
/// look past the candidates, or the reply is treated as finished history the
/// moment the user queues something.
enum LiveTail {
    /// Index of the last row that is not a queued candidate. nil when there is
    /// none (no rows, or nothing but candidates).
    static func index<Row>(in rows: [Row], isQueuedCandidate: (Row) -> Bool) -> Int? {
        rows.lastIndex { !isQueuedCandidate($0) }
    }
}

/// The vertical gap the list puts after one row.
enum MessageRowGap {
    /// - Parameters:
    ///   - height: this row's height.
    ///   - isLast: nothing follows it.
    ///   - nextIsHuggingFooter: the next row is this message's quiet footer
    ///     (usage row, or nothing), which sits right under the content.
    ///   - gapWithheldBefore: the row before this one gave up its gap because
    ///     THIS row is its hugging footer.
    ///   - spacing: the list's normal gap between rows.
    ///
    /// A row with no height draws nothing, so it normally adds no gap either:
    /// the rows around it would end up two gaps apart. The exception is an
    /// empty hugging footer. The row above already withheld its gap for it, so
    /// with none after it either, whatever follows - a queued candidate, the
    /// next user bubble - would touch the reply. It hands the withheld gap on.
    static func after(height: CGFloat, isLast: Bool, nextIsHuggingFooter: Bool,
                      gapWithheldBefore: Bool, spacing: CGFloat) -> CGFloat {
        if isLast || nextIsHuggingFooter { return 0 }
        if height > 0 { return spacing }
        return gapWithheldBefore ? spacing : 0
    }
}
