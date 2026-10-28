//
//  MessageListV3Coordinator+Search.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] Bringing a search result into view: find its row,
//  open the folded tool run it sits in, scroll, then correct once the rows
//  around it have measured.
//
//  Navigation is a reading action. It never sets `.autoScrolling`; when the
//  list was following the bottom it moves to `.userBrowsing` exactly as a
//  finger drag would (`scrollViewWillBeginDragging`), because a list left in
//  `.autoScrolling` re-pins to the bottom on the next streamed token and the
//  result would be scrolled away under the user.
//
//  Highlights are not drawn from here: cells observe them on their own (see
//  Search/ChatSearchHighlights.swift), so stepping between results costs no
//  reconfigure, no height-cache change and no re-measure.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine

extension CollectionViewMessageListV3.Coordinator {

        /// Points the conversation's search at this list.
        func bindChatSearch(_ vm: AIChatViewModel) {
            vm.chatSearch.onNavigate = { [weak self] match in
                self?.scrollToSearchMatch(match)
            }
            searchActiveSub = vm.chatSearch.$isActive
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] active in self?.setSearchHidesComposer(active) }
        }

        /// Bottom inset while searching: just breathing room, no composer.
        static let searchBottomInset: CGFloat = 8

        /// The search bar opened or closed. While it is open the hidden
        /// composer's inset goes back to the list (on the bottom-most screen
        /// the last rows move down into that space; elsewhere nothing moves);
        /// on close the inset returns without moving the content.
        func setSearchHidesComposer(_ hidden: Bool) {
            guard hidden != searchHidesComposer else { return }
            searchHidesComposer = hidden
            applySubViewportCompensation(caller: "chatSearch", forceRelax: true)
            syncScrollFlags()
            AppLogger(category: "ChatSearch").info("[ChatSearch] composer inset \(hidden ? "released" : "restored") base=\(Int(baseBottomInset))")
        }

        /// The row that shows `match`.
        static func searchItem(for match: ChatSearchMatch) -> MessageListItem {
            if let blockId = match.key.blockId {
                return .assistantBlock(match.key.messageId, blockId)
            }
            if match.key.field == .footerError {
                return .assistantFooter(match.key.messageId)
            }
            return .wholeMessage(match.key.messageId)
        }

        /// Opens the folded run holding `blockId`, if it is folded and closed.
        /// Unlike `toggleToolGroup` it does not pin the run's row to where it
        /// was on screen - the search scrolls to the member right after.
        /// Leaving search does not fold it back.
        @discardableResult
        func expandToolGroupForSearch(messageId: UUID, blockId: UUID) -> Bool {
            guard let vm,
                  let run = toolFoldRunsByMessage[messageId]?.first(where: { $0.memberIds.contains(blockId) }),
                  !expandedToolGroups.contains(run.key) else { return false }
            expandedToolGroups.insert(run.key)
            applySnapshot(messages: vm.messages, caller: "search")
            // The group row's chevron flips: re-render that one row, as the
            // tap toggle does.
            if let ds = dataSource, let layout = viewController?.messageListLayout,
               let cv = viewController?.collectionView {
                let groupItem = MessageListItem.toolGroup(run.messageId, run.firstBlockId)
                if let idx = ds.snapshot().indexOfItem(groupItem) {
                    (cv.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell)?.clearCachedHeight()
                    layout.invalidateHeight(at: idx)
                    var snap = ds.snapshot()
                    snap.reconfigureItems([groupItem])
                    ds.apply(snap, animatingDifferences: false)
                }
            }
            AppLogger(category: "ChatSearch").info("[ChatSearch] expanded tool group \(run.key.prefix(12)) for block \(blockId.uuidString.prefix(8))")
            return true
        }

        func scrollToSearchMatch(_ match: ChatSearchMatch) {
            guard let cv = viewController?.collectionView, let ds = dataSource, let vm else { return }
            if let blockId = match.key.blockId {
                expandToolGroupForSearch(messageId: match.key.messageId, blockId: blockId)
            }
            let snapshot = ds.snapshot()
            var item = Self.searchItem(for: match)
            if snapshot.indexOfItem(item) == nil {
                // Not a row of its own right now (e.g. the footer was not
                // emitted): fall back to the message's first row.
                guard let first = snapshot.itemIdentifiers.first(where: { Self.messageId(of: $0) == match.key.messageId }) else {
                    AppLogger(category: "ChatSearch").warning("[ChatSearch] no row for message \(match.key.messageId.uuidString.prefix(8))")
                    return
                }
                item = first
            }
            guard let idx = ds.snapshot().indexOfItem(item) else { return }
            let ip = IndexPath(item: idx, section: 0)

            if scrollMode == .autoScrolling {
                // See the file header: same transition a drag makes.
                scrollMode = .userBrowsing
            }
            clampAfterSessionLoad = false
            lastJumpedUserId = nil

            if !isSearchMatchComfortablyVisible(match, at: ip) {
                cv.scrollToItem(at: ip, at: .centeredVertically, animated: false)
                cv.layoutIfNeeded()
            }
            placeSearchMatch(match, at: ip)
            syncScrollFlags()
            // Rows that just came on screen measure on the next passes and can
            // push the result off its spot; correct twice (estimate drift is
            // largest right after a long jump). A finger on the list wins.
            DispatchQueue.main.async { [weak self] in
                guard let self, vm.chatSearch.currentMatch == match, !cv.isTracking else { return }
                self.placeSearchMatch(match, at: ip, item: item)
                self.syncScrollFlags()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, vm.chatSearch.currentMatch == match, !cv.isTracking, !cv.isDecelerating else { return }
                self.placeSearchMatch(match, at: ip, item: item)
                self.syncScrollFlags()
            }
        }

        /// The list changed width (rotation, Split View): every row re-flows
        /// and the offset no longer points at the same content, so bring the
        /// current result back once the new layout has settled.
        func keepSearchMatchAfterWidthChange() {
            guard let vm, vm.chatSearch.isActive, let match = vm.chatSearch.currentMatch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, vm.chatSearch.currentMatch == match,
                      self.viewController?.collectionView.isTracking == false else { return }
                self.scrollToSearchMatch(match)
            }
        }

        /// The visible band, in content coordinates.
        private func visibleContentBand() -> (top: CGFloat, height: CGFloat)? {
            guard let cv = viewController?.collectionView else { return nil }
            let top = cv.contentOffset.y + cv.adjustedContentInset.top
            let height = cv.bounds.height - cv.adjustedContentInset.top - cv.adjustedContentInset.bottom
            return height > 40 ? (top, height) : nil
        }

        /// Where the match is, in content coordinates: the exact line for an
        /// assistant text block, otherwise the row (or, for a row taller than
        /// the screen, an estimate of the line from the match's position in
        /// the text).
        private func searchMatchContentRect(_ match: ChatSearchMatch, at ip: IndexPath) -> CGRect? {
            guard let cv = viewController?.collectionView,
                  let frame = cv.layoutAttributesForItem(at: ip)?.frame else { return nil }
            if let cell = cv.cellForItem(at: ip), match.key.blockId != nil, match.key.field == .body,
               let tv = Self.firstMarkdownTextView(in: cell.contentView),
               let r = tv.searchMatchRect(ordinal: match.ordinal) {
                return tv.convert(r, to: cv)
            }
            guard let band = visibleContentBand(), frame.height > band.height * 0.8,
                  let fraction = searchMatchFraction(match) else { return frame }
            let y = frame.minY + frame.height * fraction
            return CGRect(x: frame.minX, y: y - 12, width: frame.width, height: 24)
        }

        /// How far into its text the match starts (0...1), for tall rows the
        /// list cannot locate exactly (a long pasted user message).
        private func searchMatchFraction(_ match: ChatSearchMatch) -> CGFloat? {
            guard let vm, match.key.blockId == nil, match.key.field == .body,
                  let message = vm.messages.first(where: { $0.id == match.key.messageId }),
                  message.role == .user else { return nil }
            let text = ChatSearchDisplayText.userBubble(message.content)
            let ranges = ChatSearchMatcher.ranges(of: vm.chatSearch.normalizedQuery, in: text,
                                                  limit: match.ordinal + 1)
            guard ranges.count > match.ordinal, !text.isEmpty else { return nil }
            let offset = text.distance(from: text.startIndex, to: ranges[match.ordinal].lowerBound)
            return CGFloat(offset) / CGFloat(max(text.count, 1))
        }

        private func isSearchMatchComfortablyVisible(_ match: ChatSearchMatch, at ip: IndexPath) -> Bool {
            guard let rect = searchMatchContentRect(match, at: ip), let band = visibleContentBand(),
                  viewController?.collectionView.cellForItem(at: ip) != nil else { return false }
            let margin: CGFloat = 40
            return rect.minY >= band.top + margin && rect.maxY <= band.top + band.height - margin
        }

        /// Puts the match a third of the way down the visible band, unless it
        /// is already comfortably on screen.
        private func placeSearchMatch(_ match: ChatSearchMatch, at ipHint: IndexPath, item: MessageListItem? = nil) {
            guard let cv = viewController?.collectionView, let ds = dataSource else { return }
            // Indices move when rows are inserted above; re-resolve.
            var ip = ipHint
            if let item, let idx = ds.snapshot().indexOfItem(item) { ip = IndexPath(item: idx, section: 0) }
            guard let rect = searchMatchContentRect(match, at: ip), let band = visibleContentBand() else { return }
            if isSearchMatchComfortablyVisible(match, at: ip) { return }
            let targetTop = rect.height > band.height * 0.6
                ? rect.minY - 24
                : rect.midY - band.height / 3
            let minOff = -cv.adjustedContentInset.top
            let maxOff = max(minOff, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            let target = min(max(targetTop - cv.adjustedContentInset.top, minOff), maxOff)
            if abs(target - cv.contentOffset.y) > 1 {
                cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
                lastDidScrollOffsetY = target
                cv.layoutIfNeeded()
            }
        }

        private static func firstMarkdownTextView(in view: UIView) -> SelectableMarkdownTextView? {
            if let tv = view as? SelectableMarkdownTextView { return tv }
            for sub in view.subviews {
                if let found = firstMarkdownTextView(in: sub) { return found }
            }
            return nil
        }
}
