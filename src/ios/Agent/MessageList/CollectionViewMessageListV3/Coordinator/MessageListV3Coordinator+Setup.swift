//
//  MessageListV3Coordinator+Setup.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  attach(to:vm:): wires the collection view, diffable data source, cell
//  registrations, layout callbacks and the sheet presenters overlay.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +Setup" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// [split seam] `Section` below means CollectionViewMessageListV3.Section, which
/// was in scope inside the enclosing `extension CollectionViewMessageListV3`;
/// here it would resolve to SwiftUI.Section.
private typealias Section = CollectionViewMessageListV3.Section

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Setup

        func attach(to vc: MessageListViewController, vm: AIChatViewModel) {
            self.viewController = vc
            self.vm = vm
            vc.loadViewIfNeeded()
            guard let collectionView = vc.collectionView else { return }
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            // Disable UIKit's main-thread cell prefetch. Profile (Time Profiler)
            // showed -[UICollectionView _prefetchItemsForPrefetchingContext:]
            // chains through _createPreparedCellForItemAtIndexPath → +UIView
            // performWithoutAnimation → _checkForPreferredAttributesInView →
            // SelfSizingCell.preferredLayoutAttributesFitting →
            // UIHostingContentView.systemLayoutSizeFitting, eating ~44ms (30%)
            // of one main-thread sample for a single off-screen BIG-CELL.
            // That's the 2-3 frame hitch users perceive as a sudden stutter
            // right before scrolling exposes a large text/table cell.
            // Disabling prefetch lets cells be sized only when they actually
            // come on-screen. Heights are still pre-estimated via setEstimatedHeight
            // in applySnapshot / configureCell, so layout positions don't shift.
            collectionView.isPrefetchingEnabled = false
            // [T-rotate-scroll-jank] With prefetch off, the snapshot pass is
            // the only writer of row estimates - so it must run again when a
            // width change wipes them.
            vc.messageListLayout.onWidthCachesPurged = { [weak self] in
                self?.reseedHeightsAfterWidthPurge()
                // [T-in-chat-search] Rotation / split resize re-flows every row.
                self?.keepSearchMatchAfterWidthChange()
            }

            let wholeReg = UICollectionView.CellRegistration<WholeMessageCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let headerReg = UICollectionView.CellRegistration<AssistantHeaderCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let blockReg = UICollectionView.CellRegistration<AssistantBlockCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let footerReg = UICollectionView.CellRegistration<AssistantFooterCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let toolGroupReg = UICollectionView.CellRegistration<ToolGroupCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }

            dataSource = UICollectionViewDiffableDataSource<Section, MessageListItem>(
                collectionView: collectionView
            ) { cv, indexPath, item in
                switch item {
                case .wholeMessage:
                    return cv.dequeueConfiguredReusableCell(using: wholeReg, for: indexPath, item: item)
                case .assistantHeader:
                    return cv.dequeueConfiguredReusableCell(using: headerReg, for: indexPath, item: item)
                case .assistantBlock:
                    return cv.dequeueConfiguredReusableCell(using: blockReg, for: indexPath, item: item)
                case .assistantFooter:
                    return cv.dequeueConfiguredReusableCell(using: footerReg, for: indexPath, item: item)
                case .toolGroup:
                    return cv.dequeueConfiguredReusableCell(using: toolGroupReg, for: indexPath, item: item)
                }
            }

            // Install sheet overlay (outside UIHostingConfiguration cell tree)
            if sheetOverlayHost == nil {
                let overlay = SheetOverlayView(toolPresenter: sheetPresenter, compactPresenter: compactSummaryPresenter)
                let host = UIHostingController(rootView: overlay)
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = true
                host.view.frame = .zero
                vc.addChild(host)
                vc.view.addSubview(host.view)
                host.didMove(toParent: vc)
                sheetOverlayHost = host

                sheetPresenter.onDismiss = { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "sheetDismiss")
                }
            }

            // ContentSize KVO — pin to bottom during autoScrolling
            contentSizeObservation = collectionView.observe(\.contentSize, options: [.new, .old]) {
                [weak self] cv, change in
                guard let self, !self.isFlushing else { return }
                let newH = change.newValue?.height ?? 0
                let oldH = change.oldValue?.height ?? 0
                guard newH != oldH else { return }
                let delta = newH - oldH
                #if DEBUG
                // [T-scroll-jitter-fold-diag] Content size changes with the scroll
                // state they hit (a shrink while the finger is down / decelerating
                // is what reads as a shake).
                if ScrollMetricsRecorder.shared.isEnabled {
                    ScrollMetricsRecorder.shared.record(kind: "csz", a: Double(oldH), b: Double(newH),
                        pos: self.scrollStateTag(cv), offset: Double(cv.contentOffset.y))
                }
                #endif

                // Session load stability: keep pinning to bottom until layout settles.
                // Use time-based deadline only — fire-count was too fragile on iPad
                // where width changes (sidebar) and async image loads produce many
                // contentSize KVO fires before the layout truly stabilizes.
                if self.clampAfterSessionLoad {
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if maxOff > 0 { cv.contentOffset.y = maxOff }
                    if Date() >= self.clampDeadline {
                        self.clampAfterSessionLoad = false
                    }
                    self.vm?.contentSizeDeltaSignal.send(delta)
                    return
                }

                if delta > 0 && self.scrollMode == .autoScrolling {
                    // [T-send-composer-shrink-absorb] Rows appended right after
                    // a send go into the space the composer is giving up.
                    self.absorbPendingComposerShrink(caller: "contentSizeKVO")
                    // Pin to bottom — but if an animated scroll is in flight, directly
                    // mutating contentOffset corrupts UIKit's animation interpolation.
                    // Defer to a coalesced scroll that fires after the animation ends.
                    if self.isAnimatingScrollToBottom {
                        self.scheduleCoalescedScroll()
                    } else {
                        let maxOff = newH - cv.bounds.height + cv.adjustedContentInset.bottom
                        if maxOff > 0 {
                            // [DIAG-3] If tracking/decel, auto-scroll mode is fighting user gesture
                            if cv.isTracking || cv.isDecelerating {
                                AppLogger(category: "StreamDiag").info("[KVO] ⚠️ PIN-WHILE-SCROLLING contentSize grew +\(String(format: "%.0f", delta)) offset \(String(format: "%.0f", cv.contentOffset.y))→\(String(format: "%.0f", maxOff)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) — MODE SHOULD BE userBrowsing")
                            }
                            cv.contentOffset.y = max(cv.contentOffset.y, maxOff)
                        }
                    }
                } else if delta > 0 && self.scrollMode == .userBrowsing {
                    // [DIAG-3b] Content grew while user is browsing — no pin.
                    // If a cell ABOVE viewport grew, all cells below shift down.
                    AppLogger(category: "StreamDiag").info("[KVO] contentSize grew +\(String(format: "%.0f", delta)) IN BROWSE MODE — no pin. offset=\(String(format: "%.0f", cv.contentOffset.y)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating)")
                } else if delta < 0 && self.scrollMode == .autoScrolling {
                    // Content shrank while auto-scrolling — clamp to prevent overscroll.
                    // Skip during deceleration: settleAfterInteraction will handle it.
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y > maxOff && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                } else if delta < 0 && self.scrollMode != .autoScrolling {
                    // Content shrank while user is browsing — clamp to prevent overscroll.
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y > maxOff && !cv.isTracking && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                }
                // After settle, deferred heights are flushed and UIKit re-layouts
                // with real heights. If contentSize shrinks, the current offset may
                // exceed the new max — UIKit will hard-clamp it, causing a visible jump.
                // Pre-emptively clamp with performWithoutAnimation to avoid the jitter.
                if self.settleJustFinished && delta < -1 && !cv.isTracking && !cv.isDecelerating {
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y > maxOff {
                        AppLogger(category: "Settle").debug("[Settle] POST-SETTLE SHRINK clamp offset \(String(format: "%.1f→%.1f", cv.contentOffset.y, maxOff)) contentSize \(String(format: "%.1f→%.1f", oldH, newH))")
                        UIView.performWithoutAnimation {
                            cv.contentOffset.y = maxOff
                        }
                    }
                }
                // Forward contentSize changes to downstream observers.
                self.vm?.contentSizeDeltaSignal.send(delta)

                // Re-evaluate sub-viewport overflow compensation. When content
                // overflows the visible area but UIKit thinks no scroll is
                // needed, this inflates inset.top so we can pin past UIKit's
                // default clamp.
                self.applySubViewportCompensation(caller: "contentSizeKVO")

                // Sync vm.isNearBottom on every contentSize change. UIKit only
                // dispatches scrollViewDidScroll when contentOffset moves; in
                // sub-viewport streaming (offset clamped at -insetTop while
                // contentSize grows past the visible area), the published value
                // would otherwise stay stuck at its prior reading and the
                // scroll-to-bottom button never appears.
                if let vm = self.vm {
                    let nb = self.isNearBottom()
                    if vm.isNearBottom != nb {
                        vm.isNearBottom = nb
                    }
                }
                self.syncScrollFlags()
            }

            bindViewModel(vm)
        }
}
