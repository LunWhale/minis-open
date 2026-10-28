//
//  SelectableMarkdownTextView+SearchHighlight.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - SelectableMarkdownTextView, "Search in Chat" highlights.
//
//  [T-in-chat-search] An assistant text block draws its search matches here.
//  The search counted "occurrence N of the query in this block's visible
//  text" (ChatSearchMarkdownText); this file rebuilds that same visible text
//  from the attributed string on screen - invisible spacers dropped, line
//  separators read as newlines, a code block / table attachment replaced by
//  its text - remembers where each character came from, and finds the same
//  occurrences again.
//
//  Drawing never touches the attributed string or the layout:
//    - text matches are filled under the glyphs by MinisLayoutManager
//      (drawBackground), so a highlight cannot change a line break, a height
//      or what Copy puts on the pasteboard;
//    - a match inside a code block or table is shown as an outline around
//      that block (its view draws above the text, so a fill would be hidden).
//      Highlighting inside those views is not done yet.
//
//  The view observes one ChatSearchHighlightToken (its block's), bound by
//  SelectableMarkdownView.updateUIView. Moving the current result redraws
//  only the two blocks involved.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import Combine
import SwiftUI
import UIKit

/// The search's view of a rendered block: its visible text, and for every
/// UTF-16 unit of that text the storage index it came from.
struct ChatSearchComposite {
    let text: String
    /// Storage index of each UTF-16 unit of `text`.
    let storageIndex: [Int]
    /// Whether that unit came from an attachment (code block / table).
    let fromAttachment: [Bool]

    static func build(_ storage: NSAttributedString) -> ChatSearchComposite {
        var units: [UInt16] = []
        var index: [Int] = []
        var attach: [Bool] = []
        units.reserveCapacity(storage.length)
        index.reserveCapacity(storage.length)
        attach.reserveCapacity(storage.length)
        let ns = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            if value == nil {
                for i in range.location..<NSMaxRange(range) {
                    let u = ns.character(at: i)
                    switch u {
                    case 0x200B, 0x200A, 0xFFFC: continue
                    case 0x2028:
                        units.append(0x0A)
                    default:
                        units.append(u)
                    }
                    index.append(i)
                    attach.append(false)
                }
                return
            }
            let text: String
            if let code = value as? CodeBlockAttachment {
                text = code.code
            } else if let table = value as? TableAttachment {
                text = ChatSearchMarkdownText.tableText(rows: table.rows, columnCount: table.alignments.count)
            } else {
                return
            }
            for u in text.utf16 {
                units.append(u)
                index.append(range.location)
                attach.append(true)
            }
        }
        return ChatSearchComposite(text: String(utf16CodeUnits: units, count: units.count),
                                   storageIndex: index, fromAttachment: attach)
    }

    /// Where a match (a range of `text`) lies in the storage: the text span it
    /// covers, and the attachment it falls in, if any.
    func locate(_ match: NSRange) -> (textRange: NSRange?, attachment: Int?) {
        let lo = max(0, match.location), hi = min(storageIndex.count, NSMaxRange(match))
        guard lo < hi else { return (nil, nil) }
        var minText = Int.max, maxText = -1
        var attachment: Int?
        for i in lo..<hi {
            if fromAttachment[i] {
                attachment = attachment ?? storageIndex[i]
            } else {
                minText = min(minText, storageIndex[i])
                maxText = max(maxText, storageIndex[i])
            }
        }
        let textRange = maxText >= 0 ? NSRange(location: minText, length: maxText - minText + 1) : nil
        return (textRange, attachment)
    }
}

/// One drawn occurrence.
struct ChatSearchHit {
    let textRange: NSRange?
    let attachmentIndex: Int?
}

extension SelectableMarkdownTextView {
    /// Binds this view to the highlight of the block it shows. Called on every
    /// updateUIView; cheap when nothing changed.
    func bindSearchHighlight(center: ChatSearchHighlightCenter?, key: ChatSearchUnitKey?, dimmed: Bool) {
        let token = key.flatMap { center?.token(for: $0) }
        let dimmedChanged = dimmed != searchHighlightDimmed
        searchHighlightDimmed = dimmed
        if token !== searchHighlightToken {
            searchHighlightToken = token
            // @Published emits in willSet: use the delivered value, the
            // token's property still holds the old one at this point.
            searchHighlightSub = token?.$state
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] state in self?.refreshSearchHighlight(state) }
            refreshSearchHighlight()
        } else if dimmedChanged {
            refreshSearchHighlight()
        }
    }

    var minisLayoutManager: MinisLayoutManager? { layoutManager as? MinisLayoutManager }

    /// The text changed (streaming, re-render): find the occurrences again
    /// once the edit has finished.
    func scheduleSearchHighlightRefresh() {
        guard !searchHighlightRefreshScheduled else { return }
        searchHighlightRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.searchHighlightRefreshScheduled = false
            self.refreshSearchHighlight()
        }
    }

    /// Recomputes and redraws this view's highlights from its token
    /// (`incoming`: a state being published, before the token stores it).
    func refreshSearchHighlight(_ incoming: ChatSearchUnitHighlight?? = nil) {
        guard let lm = minisLayoutManager else { return }
        let state: ChatSearchUnitHighlight? = incoming ?? searchHighlightToken?.state
        let hadAny = !lm.searchHighlightRanges.isEmpty || !searchHits.isEmpty
        // Follow edits (streaming) only while there is something to keep
        // highlighted; every chat text view has a token, most never use it.
        lm.onTextStorageEdited = state == nil ? nil : { [weak self] in
            self?.scheduleSearchHighlightRefresh()
        }
        guard let state, textStorage.length > 0 else {
            searchHits = []
            searchHighlightCurrentOrdinal = nil
            lm.searchHighlightRanges = []
            lm.searchHighlightCurrent = nil
            if hadAny { lm.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length)) }
            updateSearchAttachmentOutlines()
            return
        }
        let composite = ChatSearchComposite.build(textStorage)
        let ranges = ChatSearchMatcher.nsRanges(of: state.query, in: composite.text, limit: state.drawLimit)
        let hits = ranges.map { r -> ChatSearchHit in
            let loc = composite.locate(r)
            return ChatSearchHit(textRange: loc.textRange, attachmentIndex: loc.attachment)
        }
        #if DEBUG
        if hits.count != state.count {
            AppLogger(category: "ChatSearch").warning("[ChatSearch][drift] block shows \(hits.count) occurrence(s), search counted \(state.count) — text=\(composite.text.count) chars")
        }
        #endif
        searchHits = hits
        searchHighlightCurrentOrdinal = state.current
        lm.searchHighlightDimmed = searchHighlightDimmed
        lm.searchHighlightRanges = hits.compactMap(\.textRange)
        lm.searchHighlightCurrent = state.current.flatMap { hits.indices.contains($0) ? hits[$0].textRange : nil }
        lm.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        updateSearchAttachmentOutlines()
    }

    /// Outlines around code blocks / tables holding a match. Re-run on
    /// layout, since the attachment's position moves with the text.
    func updateSearchAttachmentOutlines() {
        let attachmentHits = searchHits.enumerated().compactMap { i, hit in
            hit.attachmentIndex.map { (index: $0, isCurrent: i == searchHighlightCurrentOrdinal) }
        }
        guard !attachmentHits.isEmpty else {
            searchHighlightLayer?.removeFromSuperlayer()
            searchHighlightLayer = nil
            return
        }
        let layer: CAShapeLayer
        if let existing = searchHighlightLayer {
            layer = existing
        } else {
            layer = CAShapeLayer()
            layer.fillColor = UIColor.clear.cgColor
            layer.zPosition = 1000
            self.layer.addSublayer(layer)
            searchHighlightLayer = layer
        }
        layer.frame = bounds
        let current = layer.sublayers?.first as? CAShapeLayer ?? {
            let l = CAShapeLayer()
            l.fillColor = UIColor.clear.cgColor
            layer.addSublayer(l)
            return l
        }()
        let others = UIBezierPath()
        let currentPath = UIBezierPath()
        var seen = Set<Int>()
        for hit in attachmentHits.sorted(by: { $0.isCurrent && !$1.isCurrent }) where !seen.contains(hit.index) {
            seen.insert(hit.index)
            guard let rect = searchRect(forStorageRange: NSRange(location: hit.index, length: 1)) else { continue }
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 8)
            (hit.isCurrent ? currentPath : others).append(path)
        }
        layer.path = others.cgPath
        layer.lineWidth = 2
        layer.strokeColor = ChatSearchHighlightStyle.matchColor(dimmed: true).cgColor
        current.frame = layer.bounds
        current.path = currentPath.cgPath
        current.lineWidth = 3
        current.strokeColor = ChatSearchHighlightStyle.currentColor(dimmed: true).cgColor
    }

    /// Rect of `ordinal`'s occurrence in this view's coordinates, for
    /// scrolling a result into view.
    func searchMatchRect(ordinal: Int) -> CGRect? {
        guard searchHits.indices.contains(ordinal) else { return nil }
        let hit = searchHits[ordinal]
        if let r = hit.textRange { return searchRect(forStorageRange: r) }
        if let a = hit.attachmentIndex { return searchRect(forStorageRange: NSRange(location: a, length: 1)) }
        return nil
    }

    private func searchRect(forStorageRange range: NSRange) -> CGRect? {
        guard NSMaxRange(range) <= textStorage.length, range.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerInset.left
        rect.origin.y += textContainerInset.top
        return rect
    }
}

extension MinisLayoutManager {
    /// [T-in-chat-search] Fills the search highlights under the glyphs. Pure
    /// drawing: the storage and the layout are left exactly as they were.
    func drawSearchHighlights(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard !searchHighlightRanges.isEmpty, let tc = textContainers.first,
              let context = UIGraphicsGetCurrentContext() else { return }
        let visibleChars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let match = ChatSearchHighlightStyle.matchColor(dimmed: searchHighlightDimmed)
        let current = ChatSearchHighlightStyle.currentColor(dimmed: searchHighlightDimmed)
        context.saveGState()
        for range in searchHighlightRanges {
            guard NSIntersectionRange(range, visibleChars).length > 0 else { continue }
            let color = range == searchHighlightCurrent ? current : match
            context.setFillColor(color.cgColor)
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: tc) { rect, _ in
                let r = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0)
                context.addPath(UIBezierPath(roundedRect: r, cornerRadius: 3).cgPath)
                context.fillPath()
            }
        }
        context.restoreGState()
    }
}
