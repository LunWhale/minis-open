//
//  MessageListV3Coordinator+HeightEstimation.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Identity / content keys for cached heights and the estimates used for
//  items that have not been measured yet (text, markdown images).
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +HeightEstimation" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Height Estimation

        /// [T-ios-scroll-decel-height-drift] The owning message id for a list
        /// item (used to detect the actively streaming message so its cells are
        /// excluded from the height memo).
        static func messageId(of item: MessageListItem) -> UUID? {
            switch item {
            case .wholeMessage(let id): return id
            case .assistantHeader(let id): return id
            case .assistantFooter(let id): return id
            case .assistantBlock(let mid, _): return mid
            case .toolGroup(let mid, _): return mid
            }
        }

        /// [T-queued-candidate-spacing] The message the running turn writes
        /// into: the last one that is not a queued candidate bubble. See
        /// `LiveTail`.
        static func liveTailMessage(in messages: [ChatMessage]) -> ChatMessage? {
            LiveTail.index(in: messages, isQueuedCandidate: { $0.isQueued }).map { messages[$0] }
        }

        /// [T-ios-earlier-stream-seed-freeze] Ids of every assistant message
        /// whose content can still GROW right now — not just the newest one.
        ///
        /// This is the same rule the layout's `streamingCellRanges` uses
        /// (612dddf7, "[T-stream-hover-earlier-streaming]"): with queued-turn
        /// interrupts, an EARLIER assistant message can still be receiving
        /// content through a running/streaming tool block while a newer turn
        /// streams text. Extracted into one helper because the two places that
        /// need it had drifted apart — the seed/memo exclusion in
        /// `configureCell` still tested only `messages.last`, so a growing
        /// earlier message was treated as settled history and got frozen at a
        /// stale height (see the call site for the resulting overlap).
        static func liveAssistantMessageIds(messages: [ChatMessage], isProcessing: Bool) -> Set<UUID> {
            guard isProcessing else { return [] }
            var ids: Set<UUID> = []
            // [T-queued-candidate-spacing] The live tail, not `messages.last`:
            // with a queued candidate below it the reply in progress was no
            // longer "last", so nothing was live unless a tool happened to be
            // running - its rows lost the streaming range, and the footer's
            // gap with it.
            let tail = liveTailMessage(in: messages)
            if let tail, tail.role == .assistant {
                ids.insert(tail.id)
            }
            for msg in messages where msg.role == .assistant && msg.id != tail?.id {
                let hasLiveTool = msg.blocks.contains { blk in
                    switch blk.toolStatus {
                    case .running, .streaming: return true
                    default: return false
                    }
                }
                if hasLiveTool { ids.insert(msg.id) }
            }
            return ids
        }

        /// [T-ios-scroll-decel-height-drift] Stable per-content key for the
        /// measured-height memo, keyed by item identity AND a cheap content
        /// fingerprint (content length / attachment count). The fingerprint makes
        /// the key CHANGE when the content changes height without changing
        /// identity — streaming append, async image/attachment load, tool output
        /// growth — so a stale (shorter, mid-stream) height can't be seeded onto
        /// a now-taller cell. Combined with the width-gated lookup (rotation) and
        /// clearHeightCache (session switch / font-size change), this closes the
        /// memo's staleness paths. Font size is NOT in the key because a font
        /// change routes through clearHeightCache (wipes the whole memo).
        #if DEBUG
        /// [T-ios-scroll-metrics-ring] Stable content-hash identity for a cell.
        /// Unlike contentKey (built on runtime UUIDs, regenerated when history
        /// paging reloads message objects), this survives object regeneration:
        /// same rendered content → same tag. Used ONLY by the scroll-metrics
        /// ring so one cell's height trajectory can be followed across
        /// seed/measure/inv/flush events and across reload generations.
        static func stableCellTag(for item: MessageListItem, messages: [ChatMessage], messageIndex: [UUID: Int]) -> String {
            func digest(_ s: String) -> String {
                var h: UInt32 = 5381
                for b in s.prefix(96).utf8 { h = (h &* 33) &+ UInt32(b) }
                return String(h, radix: 36)
            }
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id], i < messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let c = msg(id)?.content ?? ""
                return "w#\(digest(c))#\(c.count)"
            case .assistantHeader(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "h#\(digest(c))"
            case .assistantFooter(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "f#\(digest(c))"
            case .assistantBlock(let mid, let bid):
                guard let b = msg(mid)?.blocks.first(where: { $0.id == bid }) else { return "b#?" }
                let c = b.content
                return "b#\(digest(c))#\(c.count)#\(b.kind)"
            case .toolGroup(let mid, let first):
                let c = msg(mid)?.blocks.first(where: { $0.id == first })?.content ?? ""
                return "g#\(digest(c))"
            }
        }
        #endif

        static func contentKey(for item: MessageListItem, messages: [ChatMessage], messageIndex: [UUID: Int]) -> String {
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id], i < messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let n = msg(id)?.content.count ?? 0
                let a = msg(id)?.attachments.count ?? 0
                // [T-queued-bubble-height-after-drain] A queued bubble wraps
                // ~28pt narrower (withdraw button beside it), so it can be a
                // line taller than the same text once sent. Its measured height
                // must not be reused for the sent row: device 2026-10-08 08:03,
                // a 36-char prompt measured 87.3pt (3 lines) while queued kept
                // that frame after delivery, its 2-line bubble centred in ~20pt
                // of extra space until the session was reopened.
                let q = msg(id)?.isQueued == true ? ":q" : ""
                return "w:\(id.uuidString):\(n):\(a)\(q)"
            case .assistantHeader(let id):
                return "h:\(id.uuidString)"
            case .assistantFooter(let id):
                return "f:\(id.uuidString)"
            case .assistantBlock(let mid, let bid):
                let block = msg(mid)?.blocks.first(where: { $0.id == bid })
                let n = block?.content.count ?? 0
                return "b:\(mid.uuidString):\(bid.uuidString):\(n)"
            case .toolGroup(let mid, let first):
                // Identity only — the list uses `itemContentKey`, which adds
                // the group's counts and expanded state.
                return "g:\(mid.uuidString):\(first.uuidString)"
            }
        }

        /// `contentKey(for:)` plus the state a `.toolGroup` row's height and
        /// rendering depend on but its identity does not: member counts and
        /// whether it is expanded. [T-fold-consecutive-tools] A memoized height
        /// must never cross between the collapsed and expanded row, the same
        /// hazard behind [T-thinking-collapse-blank].
        func itemContentKey(for item: MessageListItem, messages: [ChatMessage]) -> String {
            guard case .toolGroup(let mid, let first) = item else {
                return Self.contentKey(for: item, messages: messages, messageIndex: messageIndex)
            }
            let run = toolFoldRunByFirstBlock[first]
            let expanded = run.map { expandedToolGroups.contains($0.key) } ?? false
            let g = run?.group
            return "g:\(mid.uuidString):\(first.uuidString):\(g?.toolCount ?? 0):\(g?.failedCount ?? 0):\(g?.cancelledCount ?? 0):\(run?.memberIds.count ?? 0):\(expanded ? 1 : 0)"
        }

        func stableHeightKey(for item: MessageListItem, messages: [ChatMessage]) -> String? {
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id], i < messages.count else { return nil }
                return messages[i]
            }
            let signature: Int
            let build: () -> String
            switch item {
            case .wholeMessage(let id):
                guard let m = msg(id), m.role == .user else { return nil }
                let content = m.content, attachments = m.attachments.count
                // [T-queued-bubble-height-after-drain] Queued and sent wrap at
                // different widths - never share a cross-load height.
                let queued = m.isQueued
                signature = (content.utf8.count &* 31 &+ attachments) &* 2 &+ (queued ? 1 : 0)
                build = { "w|\(queued ? "q|" : "")\(attachments)|\(content.utf8.count)|\(content.hashValue)" }
            case .assistantBlock(let mid, let bid):
                guard let b = msg(mid)?.blocks.first(where: { $0.id == bid }) else { return nil }
                let expanded: Bool
                switch b.kind {
                case .text: expanded = false
                case .thinking: expanded = b.isThinkingExpanded
                default: return nil
                }
                let content = b.content, kind = b.kind == .text ? "t" : "k"
                signature = content.utf8.count &* 2 &+ (expanded ? 1 : 0)
                build = { "b|\(kind)|\(expanded ? 1 : 0)|\(content.utf8.count)|\(content.hashValue)" }
            default:
                return nil
            }
            if let cached = stableHeightKeyCache[item], cached.signature == signature { return cached.key }
            let key = build()
            stableHeightKeyCache[item] = (signature, key)
            return key
        }

        static func estimateItemHeight(_ item: MessageListItem, messages: [ChatMessage], width: CGFloat) -> CGFloat {
            let scale = FontSettings.shared.scaledMessage(16)
            let lineHeight = scale * 1.4
            // [T-ios-user-attach-estimate-mismatch] The former `hPad` local died
            // with the `.user` branch's coarse tile arithmetic — the attachment
            // block now comes from UserAttachmentTileMetrics, which derives its
            // own available width. `estimateTextBlockHeight` keeps its own copy.

            switch item {
            case .wholeMessage(let msgId):
                guard let msg = messages.first(where: { $0.id == msgId }) else { return 44 }
                switch msg.role {
                case .compactDivider: return 44
                case .systemInfo: return 36
                case .user:
                    // [T-ios-user-msg-estimate-tail-jitter] Use the SAME accurate
                    // UILabel-based measurement as the precalc path, NOT the coarse
                    // char-count heuristic. The heuristic (cpl = tw/(scale*0.55))
                    // under-counts lines — a 3-line message estimated as 2 lines —
                    // so when this estimate is the height used during a fast scroll
                    // / offscreen pass (before precalc lands, or via the
                    // configureCell/prefetch estimate fallback), the
                    // UIHostingConfiguration lays the Text into a 2-line box and
                    // SwiftUI truncates it to "2 lines + …"; at settle the real
                    // measure returns 3 lines and the cell visibly expands, jolting
                    // the whole page. Routing the estimate through the accurate
                    // measurement makes the offscreen height already 3 lines, so the
                    // Text never truncates and there is nothing to expand.
                    var throwaway: [String: CGFloat] = [:]
                    if let h = Self.measureUserBubbleHeight(for: msg, cvWidth: width, cache: &throwaway) {
                        return h
                    }
                    // Fallback (empty/attachment-only): coarse heuristic.
                    //
                    // [T-ios-user-attach-estimate-mismatch] Two fixes here:
                    //  1. Same 70-vs-64 correction as measureUserBubbleHeight —
                    //     use the shared tile metrics rather than a local guess.
                    //  2. Count `inputAttachments` when `attachments` is empty,
                    //     matching measureUserBubbleHeight. A queued image-only
                    //     message (attachments not yet populated) previously
                    //     estimated 0 + 44 = 44pt against a real ~70pt — a 26pt
                    //     UNDER-estimate, the harmful direction and by far the
                    //     largest of the three errors in this path.
                    let attachCount = msg.attachments.isEmpty
                        ? msg.inputAttachments.count : msg.attachments.count
                    let imgH = UserAttachmentTileMetrics.blockHeight(
                        count: attachCount,
                        availableWidth: width - 32 /*cell*/ - 60 /*Spacer*/
                    )
                    return imgH + 44
                case .assistant: return 200
                }
            case .assistantHeader:
                // [T-scroll-estimate-fidelity] Same formula as the snapshot seed.
                return AssistantHeaderMetrics.formulaHeight()
            case .assistantBlock(let msgId, let blockId):
                guard let msg = messages.first(where: { $0.id == msgId }),
                      let block = msg.blocks.first(where: { $0.id == blockId }) else { return 44 }
                switch block.kind {
                case .text:
                    if let attrStr = block.cachedAttributedString {
                        let textWidth = max(width - 32, 100)
                        // [T-ios-longreply-boundingRect-watchdog] CTFramesetter instead
                        // of NSAttributedString.boundingRect. estimateItemHeight runs
                        // in prefetch/scroll-back for every not-yet-measured cell;
                        // boundingRect's TextKit1 layout is near-O(n²) in line count
                        // and could burn hundreds of ms per cell (watchdog risk on
                        // long history). CTFramesetter is 70–700× faster with the same
                        // height (±1pt). This is only a layout ESTIMATE, and the .text
                        // block's cachedAttributedString is attachment-free markdown
                        // text (attachments render as separate blocks), so it's safe.
                        let textH = SelectableMarkdownView.ctFramesetterHeight(for: attrStr, width: textWidth)
                        // +12 = text view insets (8) + SwiftUI wrapper vertical
                        // padding (4). This CT path is the coarse prefetch
                        // fallback; the seed loop's precalc uses the exact
                        // render-engine measure (measureAttributedStringHeight).
                        return textH + 12
                    }
                    return Self.estimateTextBlockHeight(block.content, width: width, scale: scale, lineHeight: lineHeight)
                case .thinking:
                    // Header (icon 14pt or label 13pt) + vPad 10·2 + capsule border ≈ 36pt,
                    // + 4pt block-wrapper vertical padding = 40 (same calibration as tool
                    // capsules, [T-ios-decel-inv-estimate-calibration]).
                    // When expanded, content area adds up to 300pt of inner text + 10pt bottom pad.
                    let headerH: CGFloat = 40
                    guard block.isThinkingExpanded, !block.content.isEmpty else {
                        return headerH
                    }
                    let innerWidth = max(width - 24, 100)         // 12pt horizontal pad each side
                    let innerLineHeight: CGFloat = 13 * 1.4 + 3   // .lineSpacing(3) on 13pt font
                    let lines = block.content.split(separator: "\n", omittingEmptySubsequences: false)
                    var textH: CGFloat = 0
                    let cpl = max(1, innerWidth / 7)              // ~7pt per CJK/wide glyph at 13pt
                    for line in lines {
                        let wrapped = max(1, ceil(CGFloat(line.count) / cpl))
                        textH += wrapped * innerLineHeight
                    }
                    let contentH = min(textH + 10, 300)            // ScrollView capped at 300pt
                    let total = headerH + contentH
                    return total
                // [T-ios-decel-inv-estimate-calibration] Tool capsules measure exactly
                // 36pt: ToolCapsuleView has NO vertical padding (unlike .text/.thinking,
                // which add .padding(.vertical, 2) → +4). The debug.scrollMetrics ring
                // proved the split: with 40 here, every real tool capsule corrected
                // 40→36 (-4) mid-decel; the +4 growths that motivated 40 were actually
                // collapsed THINKING blocks (handled above with headerH = 40).
                case .readImageTool: return 36
                // [T-subagent-control-capsule] A delegateTool block is one of
                // two very different views, and estimating both at 36 left a
                // visible gap under every one of them.
                //
                // A CONTROL call (status / steer / resume / cancel) renders as
                // an ordinary ToolCapsuleView — 36pt, like the default below.
                // A real delegation renders HelperBlockView, a two-line card
                // with 12pt of vertical padding per side, which measures ~58pt.
                // Estimating the card at 36 seeded every delegate cell short;
                // the correction that followed was applied to the cell but the
                // extra space stayed reserved around it.
                case .delegateTool:
                    // `isControlOnly`, not `controlSummary`: same answer, and
                    // this runs per item on a layout hot path — no point
                    // building a localized label just to discard it.
                    return HelperBlockInfo.isControlOnly(block) ? 36 : 58
                case .userAskTool:
                    // [T-user-ask] Pending card ~ question + options + action
                    // bar; an answered one collapses to its summary card.
                    // [T-user-ask-estimate] 64, not 52: the collapsed card
                    // measures 64.0pt on device (34pt icon + two text lines +
                    // padding, sub agent card shape). A loaded card is always
                    // collapsed (the expanded flag is not persisted), so the
                    // collapsed height is the one that matters here.
                    return block.content.isEmpty ? 260 : 64
                case .info:
                    let lineCount = max(1, block.content.components(separatedBy: "\n").count)
                    return CGFloat(20 + lineCount * 16)
                default: return 36  // Tool capsules (execute, browser, etc.): no wrapper pad
                }
            case .assistantFooter:
                return 4
            case .toolGroup:
                return ToolGroupRowView.rowHeight
            }
        }

        static func estimateTextBlockHeight(_ content: String, width: CGFloat, scale: CGFloat, lineHeight: CGFloat) -> CGFloat {
            // [T-ios-empty-textblock-gap] An empty text block renders nothing
            // (EmptyView).
            guard !content.isEmpty else { return 0 }
            // [T-scroll-estimate-fidelity] Follow the renderer's own layout
            // (base 16.5 × the user's message scale, text width = width − 32,
            // +12 — the same basis as the cachedAttributedString path) instead
            // of the old half-em-per-character line model, which under-sized
            // CJK replies by 25–46% and made them jump mid-fling as they were
            // measured. See MarkdownHeightEstimate. `scale` / `lineHeight` are
            // the old model's inputs, kept for the call sites.
            let base = FontSettings.shared.scaledMessage(16.5)
            let textWidth = max(width - 32, 100)
            let metrics = Self.estimateLineMetrics(base)
            let estimate = MarkdownHeightEstimate(
                textWidth: textWidth, baseFontSize: base,
                latinLineHeight: metrics.latin, wideLineHeight: metrics.wide,
                imageHeight: { Self.estimateMarkdownImageHeight(line: $0, containerWidth: textWidth) })
            return estimate.height(of: content)
        }

        /// Line heights at the renderer's base size: the system font, and the
        /// CJK fallback (PingFang) that sets the height of any line with wide
        /// glyphs. Cached per size — this runs for every unrendered block on
        /// every snapshot.
        private static var lineMetricsCache: [CGFloat: (latin: CGFloat, wide: CGFloat)] = [:]
        static func estimateLineMetrics(_ size: CGFloat) -> (latin: CGFloat, wide: CGFloat) {
            if let cached = lineMetricsCache[size] { return cached }
            let latin = UIFont.systemFont(ofSize: size).lineHeight
            let wide = max(latin, UIFont(name: "PingFangSC-Regular", size: size)?.lineHeight ?? size * 1.4)
            let metrics = (latin: latin, wide: wide)
            lineMetricsCache[size] = metrics
            return metrics
        }

        /// Estimate height for a Markdown image line by checking the image cache.
        /// Falls back to 200pt placeholder if the image hasn't been loaded yet.
        private static func estimateMarkdownImageHeight(line: String, containerWidth: CGFloat) -> CGFloat {
            let maxImageWidth: CGFloat = 400
            // Extract URL from ![alt](url)
            guard let openParen = line.range(of: "]("),
                  let closeParen = line.range(of: ")", range: openParen.upperBound..<line.endIndex) else {
                return 200
            }
            let src = String(line[openParen.upperBound..<closeParen.lowerBound])
            if let cached = NativeMediaImageCache.shared.image(for: src) {
                let imgWidth = min(min(containerWidth, cached.size.width), maxImageWidth)
                let aspect = cached.size.height / max(cached.size.width, 1)
                let maxH = UIScreen.main.bounds.height / 2
                return min(imgWidth * aspect, maxH) + 6
            }
            return 200
        }
}
