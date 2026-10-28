//
//  MessageListV3Coordinator+CellConfiguration.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  The cell provider body (configureCell): picks the bridged view for each
//  MessageListItem, seeds first-display heights, and creates or reuses the
//  per-message CellStateBridgeV2. Also liveAssistantIds (memoized).
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +CellConfiguration" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        /// Ids of assistant messages whose content can still grow. Thin
        /// memoizing wrapper over the shared static rule.
        private func liveAssistantIds(in messages: [ChatMessage], isProcessing: Bool) -> Set<UUID> {
            guard isProcessing else { return [] }
            let key = "\(messages.last?.id.uuidString ?? "-")|\(messages.count)|\(streamGeneration)"
            if let memo = liveIdsMemo, memo.key == key { return memo.ids }
            let ids = Self.liveAssistantMessageIds(messages: messages, isProcessing: isProcessing)
            liveIdsMemo = (key, ids)
            return ids
        }

        // MARK: - Cell Configuration

        private func currentIndex(for item: MessageListItem) -> Int? {
            return itemToIndex[item]
        }

        private static let cellLogger = AppLogger(category: "CellPerf")
        func configureCell(_ cell: SelfSizingCell, item: MessageListItem, indexPath: IndexPath) {
            guard let vm else { return }
            let configStart = CACurrentMediaTime()
            #if DEBUG
            // [T-scroll-jitter-fold-diag] Slow cell configurations, to name the
            // main-thread stalls that show up as gaps in the scroll offsets.
            defer {
                let ms = (CACurrentMediaTime() - configStart) * 1000
                if ms >= 2, ScrollMetricsRecorder.shared.isEnabled {
                    ScrollMetricsRecorder.shared.record(kind: "cfg", idx: indexPath.item, a: ms,
                        b: Double(cell.bounds.height), src: scrollMode == .autoScrolling ? "auto" : "browse",
                        note: String(String(describing: item).prefix(80)))
                }
            }
            #endif
            cellConfigCount += 1
            if cellConfigCount == 1 {
                firstCellConfigTime = CFAbsoluteTimeGetCurrent()
            }
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth

            // [T-viewgraph-race-lifetime 2026-05-20] All 4 cell config sites
            // route through `cell.applyContentConfiguration(_:)` (not raw
            // `cell.contentConfiguration =`) so the SelfSizingCell bumps its
            // configGeneration and clears the height cache when the hosting
            // configuration is swapped. Without it, the preferredLayoutAttributesFitting
            // generation guard never trips (gen never changes) and the
            // broad cache may return a stale height for the swapped content.
            // Both reduce the window for the ViewGraphGeometryObservers race.
            switch item {
            case .wholeMessage(let msgId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { return }
                let message = messages[msgIdx]
                let bridge = getOrCreateBridge(for: message, in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedWholeMessageV3(
                        message: message,
                        bridge: bridge,
                        maxWidth: width
                    )
                    // Suppress SwiftUI async display-link geometry observation
                    // to prevent use-after-free in ViewGraphGeometryObservers
                    // when UICollectionView recycles the cell.
                    .transaction { $0.disablesAnimations = true }
                    // UIHostingConfiguration creates an independent SwiftUI
                    // environment — it does NOT inherit EnvironmentObjects
                    // from the outer AIChatView. Descendant views inside the
                    // cell (notably ToolCapsuleView, which reads
                    // `@EnvironmentObject vm: AIChatViewModel` for its long-
                    // press menu's `vm.isProcessing` check) would trigger
                    // SwiftUI's "No ObservableObject of type AIChatViewModel
                    // found" fatal (EXC_BREAKPOINT) the moment the body
                    // evaluates — symptom: app crashes when waking from
                    // lock + tapping a session-complete notification, since
                    // the deep-link forces an immediate cell rebuild before
                    // any other view layer can re-inject the vm. Re-inject
                    // explicitly on every hosting config.
                    // [T-ios-tool-capsule-vm-envobject-crash]
                    .environmentObject(vm)
                    // [T-in-chat-search] Same reason: the search highlights
                    // must be handed to every hosted cell explicitly.
                    .environment(\.chatSearchHighlights, vm.chatSearch.highlights)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .assistantHeader(let msgId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { return }
                let message = messages[msgIdx]
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantHeaderV3(message: message, maxWidth: width,
                                            onOpenSoulSettings: onOpenSoulSettings)
                        .transaction { $0.disablesAnimations = true }
                        .environmentObject(vm)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .assistantBlock(let msgId, let blockId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else {
                    AppLogger(category: "SnapshotDiag").warning("[SnapshotDiag] configureCell MISS msgId=\(msgId.uuidString.prefix(8)) — messageIndex miss or OOB")
                    return
                }
                let message = messages[msgIdx]
                guard let block = message.blocks.first(where: { $0.id == blockId }) else {
                    AppLogger(category: "SnapshotDiag").warning("[SnapshotDiag] configureCell MISS blockId=\(blockId.uuidString.prefix(8)) in msg blocks=\(message.blocks.count) — block ID mismatch (vm.messages mutated since snapshot?)")
                    return
                }
                let bridge = getOrCreateBridge(for: message, in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantBlockV3(
                        block: block,
                        message: message,
                        bridge: bridge,
                        maxWidth: width
                    )
                    .transaction { $0.disablesAnimations = true }
                    .environmentObject(vm)
                    .environment(\.chatSearchHighlights, vm.chatSearch.highlights)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .toolGroup(let msgId, let firstBlockId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count,
                      let run = toolFoldRunByFirstBlock[firstBlockId] else {
                    AppLogger(category: "ToolFold").warning("[ToolFold] configureCell MISS group=\(firstBlockId.uuidString.prefix(8))")
                    return
                }
                let message = messages[msgIdx]
                let expanded = expandedToolGroups.contains(run.key)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedToolGroupV3(
                        message: message,
                        firstBlockId: firstBlockId,
                        group: run.group,
                        duration: run.duration,
                        isExpanded: expanded,
                        maxWidth: width
                    )
                    .transaction { $0.disablesAnimations = true }
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .assistantFooter(let msgId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { return }
                let message = messages[msgIdx]
                let bridge = getOrCreateBridge(for: message, in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantFooterV3(
                        message: message,
                        bridge: bridge,
                        maxWidth: width,
                        retryLogKey: vm.retryLogKey
                    )
                    .transaction { $0.disablesAnimations = true }
                    .environmentObject(vm)
                    .environment(\.chatSearchHighlights, vm.chatSearch.highlights)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)
            }

            // [T-ios-scroll-decel-height-drift] Seed this cell with the real
            // height the SAME content measured on a prior appearance (if any),
            // so its first self-size after reuse skips the 2.5–3.8ms
            // systemLayoutSizeFitting that produced the decel "settle jitter".
            // Must run AFTER applyContentConfiguration (which clears the seed).
            // Width-matched inside the memo so a stale portrait height isn't
            // reused after rotation. No measurement is performed here.
            if let layout = viewController?.messageListLayout {
                let cvW = viewController?.collectionView.bounds.width ?? 390
                let key = itemContentKey(for: item, messages: messages)

                // [T-ios-scroll-decel-height-drift] Register the index→key map
                // on EVERY cell config, not just snapshot apply. The memo write
                // in invalidationContext keys off contentKeyByIndex[index]; if
                // it's only set during updateMessages (snapshot change), then
                // pure scrolling — where snapshot is unchanged and the jitter
                // actually happens — leaves the map stale/empty, so the measured
                // height is never memoized (observed: memoForKey=none on every
                // re-entry). Setting it here, where index↔item is authoritative
                // for the cell about to be measured, makes the memo actually
                // capture the self-size that follows.
                layout.setContentKey(key, at: indexPath.item)

                #if DEBUG
                // [T-ios-scroll-metrics-ring] Stamp the stable cell tag on the
                // cell and the layout's index map (only while recording — the
                // hash costs a string scan per configure).
                if ScrollMetricsRecorder.shared.isEnabled {
                    let tag = Self.stableCellTag(for: item, messages: messages, messageIndex: messageIndex)
                    cell.metricsTag = tag
                    layout.setMetricsTag(tag, at: indexPath.item)
                }
                #endif

                // [T-ios-scroll-decel-height-drift] STREAMING EXCLUSION. A cell
                // belonging to the actively-streaming (last assistant) message
                // changes height every token (tool capsule + code block grow as
                // output arrives). It must NEVER be seeded or memoized: a seed
                // would short-circuit self-size and freeze the cell at a stale
                // mid-stream height, leaving the tool cell / code block overlapping
                // adjacent content until the NEXT turn reconfigures it (observed
                // regression). The content-length key already differs per token,
                // but seeding ANY prior length is wrong while it's still growing —
                // so gate it out entirely. Non-streaming history cells keep the
                // seed benefit. Clearing contentKey also disables the memo write
                // on this cell's self-size path.
                // [T-ios-earlier-stream-seed-freeze] The exclusion must cover
                // EVERY message that can still grow, not just `messages.last`.
                // A tool block on an earlier assistant turn keeps producing
                // output (status .running/.streaming) while a newer turn
                // streams; that message's cells were therefore treated as
                // settled history here and seeded/memoized at a mid-stream
                // height. The seed short-circuit in
                // `SelfSizingCell.preferredLayoutAttributesFitting` then RETURNS
                // that height and skips the real measure, so the block froze
                // too short and the following blocks were stacked on top of it
                // — the reported "文字与工具卡片重叠交叉". Same rule (and now
                // the same code) as the layout's `streamingCellRanges`.
                let itemMsgId = Self.messageId(of: item)
                // [T-ios-compacting-row-vanishes-on-scroll] Same rule as the
                // streaming-range builder in applySnapshot: the live compact
                // status row grows its text on every delta, so it must not be
                // seeded or memoized either. These two exclusions are required
                // to agree — the last time they drifted apart, a still-growing
                // cell got seeded at a stale height and froze
                // ([T-ios-earlier-stream-seed-freeze]).
                let isLiveCompactRow: Bool = itemMsgId.flatMap { id in
                    messageIndex[id].map { messages[$0] }
                }.map { $0.role == .systemInfo && $0.isCompactLoading } ?? false
                let isStreamingCell = isLiveCompactRow
                    || (itemMsgId.map { liveAssistantIds(in: messages, isProcessing: vm.isProcessing).contains($0) } ?? false)
                if isStreamingCell {
                    cell.contentKey = nil
                    layout.invalidateMemo(forKey: key)
                }
                // [T-first-text-scroll-jump] See SelfSizingCell.rendersNonEmptyText.
                cell.rendersNonEmptyText = {
                    guard case .assistantBlock(let mid, let bid) = item,
                          let i = messageIndex[mid], i < messages.count,
                          let block = messages[i].blocks.first(where: { $0.id == bid }),
                          block.kind == .text else { return false }
                    return !block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }()

                // [T-ios-memo-key-ignores-render-state] Look the memo up under
                // the SAME render-qualified key the measure path writes. Without
                // this the read would use the bare content key and the write the
                // qualified one, so the memo would never hit at all — the seed
                // optimisation would silently die rather than be corrected.
                //
                // Qualifying by render state is what makes the lookup honest: a
                // height measured while this block's formulas were still blank
                // placeholders lives under a DIFFERENT key than the finished
                // layout, so it can no longer be seeded onto a fully rendered
                // cell. That was the 989pt deficit measured on device (cell
                // 6166pt vs canvas 7154.7pt) — the cell was seeded with a
                // pre-render height and the seed short-circuit then skipped the
                // real measure forever.
                let memoKey = SelfSizingCell.renderQualifiedKey(key, for: cell)
                let memo = isStreamingCell ? nil : layout.measuredHeight(forKey: memoKey, width: cvW)
                if !isStreamingCell {
                    cell.contentKey = key
                }
                if let memo {
                    cell.seedMeasuredHeight(memo, width: cvW)
                } else if !isStreamingCell,
                          let seed = firstDisplaySeed(for: item, messages: messages, collectionWidth: cvW, maxWidth: width) {
                    // [T-scroll-first-build-once] A row measured before its
                    // first display is built twice by SwiftUI; a seeded row
                    // skips the measure. The seed is exact (see
                    // SelectableMarkdownView+FirstSeed), so it is also what a
                    // measure would have memoized.
                    cell.seedMeasuredHeight(seed, width: cvW)
                    layout.recordMeasuredHeight(forKey: memoKey, height: seed, boundsWidth: cvW)
                }
                // [T-ios-user-msg-truncate-seed-starve] DO NOT seed from precalc.
                //
                // The seed short-circuit in SelfSizingCell.preferredLayoutAttributes-
                // Fitting RETURNS the seeded height and SKIPS the real
                // systemLayoutSizeFitting — so the seed value becomes the cell's
                // hard height. That is only safe for a height we ACTUALLY MEASURED
                // before (the `memo` above, from a prior real self-size at this
                // width). `precalcHeight` is an ESTIMATE (boundingRect /
                // char-count) that runs ~4-7pt SHORT of the real height for user
                // bubbles (TextKit line height is tighter than SwiftUI Text's
                // rendered line box). Seeding it locked
                // the cell at the short value, so the SwiftUI Text inside was
                // clipped to "…" while processing, and only expanded once a later
                // reconfigure forced a real measure — exactly the user-reported
                // truncate-then-expand. precalc still serves as prepare()'s
                // layout height (set via setPrecalcHeight in applySnapshot) so the
                // cell's initial POSITION is approximately right, but the cell's
                // real height is always decided by an actual measure, never frozen
                // at an estimate. (The first-mount-measure-storm option D was trading
                // correctness for fewer measures here; correctness wins — a too-
                // short estimate that truncates content is worse than a measure.)
            }

            // Height estimation for items not yet measured — skip if we already
            // have a measured height OR a precalculated height from applySnapshot.
            if let layout = viewController?.messageListLayout,
               layout.cachedHeight(at: indexPath.item) == nil,
               !layout.hasPrecalcHeight(at: indexPath.item) {
                let est = Self.estimateItemHeight(item, messages: messages,
                                                  width: viewController?.collectionView.bounds.width ?? 390)
                layout.setEstimatedHeight(est, at: indexPath.item)
            }
        }

        /// [T-scroll-first-build-once] Exact cell height for a finished
        /// assistant text block that has not been measured yet, or nil.
        /// Text below `firstSeedMinChars` is cheap to build twice and keeps
        /// the measured path. The text column is the block's frame inside
        /// BridgedAssistantBlockV3 (16 pt padding each side, capped at
        /// `maxWidth`), and AssistantBlockView adds 2 pt above and below.
        private func firstDisplaySeed(for item: MessageListItem, messages: [ChatMessage],
                                      collectionWidth: CGFloat, maxWidth: CGFloat) -> CGFloat? {
            guard case .assistantBlock(let msgId, let blockId) = item,
                  let msgIdx = messageIndex[msgId], msgIdx < messages.count,
                  let block = messages[msgIdx].blocks.first(where: { $0.id == blockId }),
                  case .text = block.kind,
                  block.content.count >= Self.firstSeedMinChars else { return nil }
            var textWidth = collectionWidth - 32
            if maxWidth > 0 { textWidth = min(textWidth, maxWidth) }
            #if DEBUG
            let seedStart = CACurrentMediaTime()
            #endif
            guard let height = SelectableMarkdownView.firstDisplayHeight(
                markdown: block.content,
                cachedContent: block.cachedMarkdown,
                cachedAttributedString: block.cachedAttributedString,
                messageId: msgId,
                blockId: blockId,
                width: textWidth) else { return nil }
            #if DEBUG
            if ScrollMetricsRecorder.shared.isEnabled {
                ScrollMetricsRecorder.shared.record(kind: "xseed", a: (CACurrentMediaTime() - seedStart) * 1000,
                    b: Double(height), note: "blk=\(blockId.uuidString.prefix(8)) len=\(block.content.count) w=\(Int(textWidth))")
            }
            #endif
            return height + 4
        }

        private static let firstSeedMinChars = 200

        private func getOrCreateBridge(for message: ChatMessage, in messages: [ChatMessage]) -> CellStateBridgeV2 {
            if let existing = cellBridges[message.id] { return existing }
            let bridge = CellStateBridgeV2()
            cellBridges[message.id] = bridge
            updateBridge(bridge, message: message, in: messages, isInitialBridgeSetup: true)
            // Forward detailBlock changes to the VC-level sheet presenter
            bridgeSheetSubs[message.id] = bridge.$detailBlock
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] block in
                    guard let self else { return }
                    if let block {
                        let toolBlocks = message.blocks.filter { $0.toolStatus != nil }
                        self.sheetPresenter.sheetData = ToolSheetPresenter.SheetData(
                            id: block.id,
                            block: block,
                            toolBlocks: toolBlocks,
                            toolSnapshots: bridge.toolSnapshots,
                            browserPool: bridge.browserPool
                        )
                    }
                    // Dismiss is handled by sheetPresenter.onDismiss (set in attach)
                }
            return bridge
        }
}
