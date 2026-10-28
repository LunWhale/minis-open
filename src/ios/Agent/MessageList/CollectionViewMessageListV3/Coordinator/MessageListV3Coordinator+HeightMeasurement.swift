//
//  MessageListV3Coordinator+HeightMeasurement.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Exact height precalc: attributed-string text heights (HeightLRU cache)
//  and user-bubble heights.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +HeightMeasurement" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Accurate Height Measurement

        /// Measure the rendered height of an NSAttributedString using TextKit's
        /// full layout engine (NSLayoutManager + NSTextContainer). This correctly
        /// handles NSTextAttachment subclasses (tables, code blocks, images) by
        /// calling attachmentBounds() during layout, unlike boundingRect() which
        /// uses the attachment's 1×1px placeholder image.
        /// [T-ios-decel-inv-estimate-calibration] Measure with the REAL render
        /// engine: an offscreen SelectableMarkdownTextView (MinisLayoutManager +
        /// 4/4 textContainerInset), exactly what the live cell hosts. The
        /// previous bare-NSLayoutManager measure drifted +4..+21pt on ~30% of
        /// blocks (multi-paragraph / emoji-heading content) — debug.measureCompare
        /// ground truth showed the drift is engine-internal (usesFontLeading was
        /// ruled out: identical results), so no formula over the bare engine can
        /// close it. Measuring with the same engine is exact BY CONSTRUCTION.
        /// Cost: avg 1.4ms/block (vs 0.67ms bare), cached by content in
        /// attrStringHeightCache (see HeightCacheKey — keyed on the markdown
        /// source plus width and font size, NOT the attributed string's
        /// identity), main-thread only (seed loop already is).
        ///
        /// RETURNS the full text-view height INCLUDING its 8pt vertical insets
        /// (4 top + 4 bottom) — callers add only the SwiftUI wrapper's
        /// .padding(.vertical, 2) (+4), NOT the historical +8.
        static func measureAttributedStringHeight(_ attrStr: NSAttributedString, width: CGFloat) -> CGFloat {
            // Watchdog guard: UITextView.sizeThatFits is near-O(n²) in line
            // count (the 29k-char / 8-10s SLOW MEASURE history,
            // T-ios-longreply-boundingRect-watchdog). Above the cap, fall back
            // to the linear bare-NSLayoutManager measure and accept its small
            // drift — on a 10000pt+ cell a ±20pt error is invisible.
            guard attrStr.length <= 8000 else {
                let storage = NSTextStorage(attributedString: attrStr)
                let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                let lm = NSLayoutManager()
                lm.addTextContainer(container)
                storage.addLayoutManager(lm)
                lm.ensureLayout(for: container)
                // +8 = the text view insets the tv path includes natively.
                return ceil(lm.usedRect(for: container).height) + 8
            }
            measureTextView.attributedText = attrStr
            let size = measureTextView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            return ceil(size.height)
        }

        /// Shared offscreen measurement text view (main-thread only).
        private static let measureTextView = SelectableMarkdownTextView()

        /// [T-ios-user-msg-estimate-tail-jitter] Accurate height for a USER
        /// message cell, measured with the SAME font / wrap width / paddings as
        /// `ChatMessageRow.userRow` renders, so the precalc lands the cell at its
        /// true height (the coarse char-count estimator was ~10pt short, which
        /// grew contentSize mid-decel and caused the stop-then-twitch tail jank).
        /// Returns nil for attachment-only / empty text (caller falls back to the
        /// coarse estimate). Cached by content|width|fontsize.
        ///
        /// Layout constants mirror AIChatView.userRow:
        ///   - font: .system(size: scaledMessage(16.5))
        ///   - bubble: .padding(.horizontal,14) .padding(.vertical,10)  → +20 height, -28 width
        ///   - row:   HStack { Spacer(minLength: 60); VStack(spacing:6){ attachments?; bubble } }
        ///   - cell:  .padding(.horizontal, 16) on the whole row
        /// No on-screen view is touched; pure TextKit measurement (usedRect).
        static func measureUserBubbleHeight(for message: ChatMessage, cvWidth: CGFloat,
                                            cache: inout [String: CGFloat]) -> CGFloat? {
            // [T-p3-agent-callback-cell] Callback cards have a fixed height.
            if message.agentCallback != nil { return AgentCallbackCellView.rowHeight }
            // The same text the bubble shows (userDisplayText), so the
            // measured height matches it. [T-user-bubble-reminder-strip]
            let text = SystemReminderStripper.userBubbleText(message.content)

            let attachCount = message.attachments.isEmpty
                ? message.inputAttachments.count : message.attachments.count

            // [T-ios-user-attach-estimate-mismatch] Attachment tile block, from
            // the SAME constants the renderer uses (UserAttachmentList).
            //
            // This was `rows * 70 + 6` with a `70`-pitch row count, while the
            // renderer draws 64pt tiles with 6pt FlowLayout spacing — a +6pt
            // over-estimate per row on EVERY image bubble, and a row-count
            // disagreement near width boundaries. `70` appeared nowhere in the
            // rendering code; it was estimator-only drift.
            let fontSize = FontSettings.shared.scaledMessage(16.5)
            // [T-ios-queued-bubble-withdraw-width] A QUEUED message renders a
            // withdraw button beside the bubble:
            //
            //     HStack(spacing: 6) { Text(...).padding(.horizontal, 14)
            //                          if isQueued { Button(xmark, size 22) } }
            //
            // (ChatMessageViews.swift userRow). That button and its spacing eat
            // ~28pt of the row, so the text actually wraps 28pt NARROWER than
            // this estimate assumed — the estimate counted fewer lines than the
            // render produces, the cell was laid out too short, and SwiftUI
            // truncated the Text to fit (one line + ellipsis, with the
            // attachment tiles spilling over neighbouring rows).
            //
            // This is why the bug looked intermittent and "self-healed": the
            // button exists ONLY while the message is queued. Once the send
            // queue drains, `isQueued` flips false, the button disappears, and
            // any later re-measure lands on the correct height — so scrolling
            // or re-entering the session appeared to fix it, while every newly
            // sent message reproduced it.
            //
            // Under-estimates are the harmful direction (over-estimates merely
            // leave a gap); subtract the button when it is actually rendered.
            let withdrawButtonWidth: CGFloat = message.isQueued ? (22 /*icon*/ + 6 /*HStack spacing*/) : 0
            let usableTextWidth = max(cvWidth - 32 /*cell*/ - 60 /*Spacer*/ - 28 /*bubble pad*/ - withdrawButtonWidth, 80)

            let attachH = UserAttachmentTileMetrics.blockHeight(
                count: attachCount,
                availableWidth: cvWidth - 32 /*cell*/ - 60 /*Spacer*/
            )

            guard !text.isEmpty else {
                // Attachment-only message: return tiles height if any, else nil
                // so the caller uses the coarse estimate (covers oddball cases).
                return attachCount > 0 ? attachH : nil
            }

            // `usableTextWidth` is part of the key, so the queued vs sent forms
            // (which differ by the withdraw button's 28pt) can't share a cached
            // measurement — the entry is invalidated implicitly when the queue
            // drains. Stated here because that is load-bearing, not incidental.
            let key = "\(text.count)|\(Int(usableTextWidth))|\(Int(fontSize))|\(attachCount)|\(text.hashValue)"
            if let cached = cache[key] {
                return cached
            }

            // [T-ios-user-msg-estimate-tail-jitter] Measure with UILabel, NOT raw
            // NSLayoutManager.usedRect. SwiftUI `Text` lays each line at the
            // font's full line-height box (with default leading); a bare
            // NSLayoutManager usedRect is ~2-3pt/line TIGHTER, so it
            // under-estimated by ~7pt on a multi-line bubble — and an
            // UNDER-estimate is exactly what makes the cell lay out short, so
            // SwiftUI Text truncates with "..." during scroll then visibly
            // expands at settle (the user-reported symptom). UILabel
            // (numberOfLines=0, byWordWrapping) reproduces SwiftUI Text's
            // Cheap TextKit measurement (boundingRect). NOTE: this gives the
            // font's TextKit line height (~fontSize×1.21), which is ~2.4pt/line
            // SHORTER than SwiftUI Text's rendered line box — so it slightly
            // under-estimates multi-line bubbles. We accept that here because the
            // real "…→expand" jitter is NOT primarily this residual (proven: every
            // measurement engine still left the symptom); the actual cause is
            // being investigated separately. Keep the measurement cheap.
            let font = UIFont.systemFont(ofSize: fontSize)
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let bounds = attr.boundingRect(
                with: CGSize(width: usableTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let textH = ceil(bounds.height)
            // [T-ios-decel-inv-estimate-calibration → superseded] There used to
            // be a CJK-gated flat +7 here, calibrated from CJK samples that
            // measured +6.3–7.0 taller than this estimate and attributed to
            // "SwiftUI Text gives PingFang-fallback lines a taller box". The
            // row-chrome measurement below shows that reading was wrong: those
            // bubbles were short by the script-independent row constant, and
            // gating the correction on CJK is precisely what left Latin bubbles
            // 7pt short. Superseded by `rowChrome`, applied unconditionally.
            //
            // [T-ios-user-bubble-row-chrome] The row wrapper costs a CONSTANT
            // 7pt that this estimator never accounted for, so a Latin user
            // bubble was seeded 7pt SHORT — the harmful direction (the cell
            // lays out short, so SwiftUI Text truncates / the layout
            // under-reserves, and the correction on re-measure is the blank
            // strip around the message the user reported).
            //
            // Measured on device (iPhone 11), estimate vs the height the cell
            // actually needs, via [BottomGapDiag][user-bubble-estimate] paired
            // with [BottomGapDiag][seed-drift]:
            //
            //   Latin   18ch  1 line : est   42.0 → cell   49.0  (-7.0)
            //   Latin  500ch 20 lines: est  439.0 → cell  445.5  (-6.5)
            //   Latin 1135ch 49 lines: est 1065.0 → cell 1072.0  (-7.0)
            //
            // CONSTANT, not per-line. A throwaway probe isolated where it comes
            // from: boundingRect == UILabel (engineDelta +0.0) and the isolated
            // SwiftUI bubble == textH + 20 exactly (chromeMiss +0.0), while the
            // REAL ChatMessageRow measured textH + 20 + 7 (rowVsEst +7.0). The
            // text engine and the bubble padding were already correct; the miss
            // is entirely the row structure around them.
            //
            // This also explains — and replaces — the old "CJK correction". That
            // was a flat +7 gated on CJK presence, calibrated from a handful of
            // CJK samples that landed +7 taller than the estimate. It was never
            // about the script: those bubbles were short by the SAME row chrome
            // every bubble is short by, and gating it on CJK is exactly why
            // Latin bubbles kept the -7 and produced this report. Proven by
            // adding the row constant while the CJK term was still in: a CJK
            // bubble then over-reserved by precisely 7pt
            // (est 870 → cell 863, `dir=RESERVED-TOO-MUCH`), i.e. the two terms
            // were double-counting one 7pt. So the CJK special case is dropped
            // and the correction becomes unconditional.
            //
            // Why the report says "long messages": the shortfall is the same 7pt
            // at every length, but on a screen-filling bubble the re-measure
            // relayouts a full-height row (visible blank strip), while on a 42pt
            // bubble it is absorbed silently.
            let rowChrome: CGFloat = 7
            // bubble vertical padding (10*2) + row chrome + attachment block + 1pt safety.
            let total = textH + 20 + rowChrome + attachH + 1
            cache[key] = total
            #if DEBUG
            // [BottomGapDiag][user-bubble-estimate] Cheap trace of what this
            // estimator produced; pairs with [BottomGapDiag][seed-drift] at the
            // PLAF site, which prints the height the cell ACTUALLY needs. The
            // two together are what localised the constant 7pt row chrome, and
            // they stay as the regression tripwire (a future +N drift shows up
            // as a non-zero delta immediately).
            AppLogger(category: "BottomGapDiag").info(
                "[BottomGapDiag][user-bubble-estimate] chars=\(text.count) "
                + "textH=\(String(format: "%.1f", textH)) attachH=\(String(format: "%.1f", attachH)) "
                + "total=\(String(format: "%.1f", total)) "
                + "w=\(String(format: "%.0f", usableTextWidth))")
            #endif
            return total
        }
}
