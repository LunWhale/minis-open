import Foundation
import CoreGraphics

// [T-multi-select-share] Pure model for sharing selected messages as one long image
// or a PDF: which rows form one selectable unit and cell, how a reply's markdown
// splits into prose and tables (for adaptive table width), where PDF pages break, and
// how large a long image may get. No UIKit and no app types, so the standalone test compiles
// this block on its own.

// [T-multi-select-share] BEGIN chat-share-model

/// One selectable row of the share picker.
struct ChatShareUnit: Identifiable, Equatable {
    enum Kind: Equatable { case user, callback, reply }
    let kind: Kind
    /// The messages the unit covers, in chat order; never empty.
    let messageIds: [UUID]
    var id: UUID { messageIds[0] }
}

/// What the grouping needs to know about one chat message.
struct ChatShareUnitSource: Equatable {
    enum Role: Equatable { case user, assistant, other }
    let id: UUID
    let role: Role
    /// A user-role message that is really a sub agent reporting back.
    let isCallback: Bool
    /// Not shown as its own row (queued, internal bridge): skipped without
    /// splitting the reply around it.
    let isHidden: Bool
}

enum ChatShareUnits {
    /// A user message is one unit, a callback card is one unit, and a reply is one
    /// unit: every consecutive assistant message up to the next visible non-assistant
    /// row, the same span the chat groups under one assistant header. Dividers and
    /// system rows are not selectable and end the reply before them.
    static func group(_ sources: [ChatShareUnitSource]) -> [ChatShareUnit] {
        var units: [ChatShareUnit] = []
        var reply: [UUID] = []
        func closeReply() {
            if !reply.isEmpty { units.append(ChatShareUnit(kind: .reply, messageIds: reply)) }
            reply = []
        }
        for s in sources where !s.isHidden {
            switch s.role {
            case .assistant:
                reply.append(s.id)
            case .user:
                closeReply()
                units.append(ChatShareUnit(kind: s.isCallback ? .callback : .user, messageIds: [s.id]))
            case .other:
                closeReply()
            }
        }
        closeReply()
        return units
    }

    static func unit(containing messageId: UUID, in units: [ChatShareUnit]) -> ChatShareUnit? {
        units.first { $0.messageIds.contains(messageId) }
    }
}

/// One selectable row of the share picker: a user message, a callback card, or one
/// piece of a reply (a text block, a tool call, a thinking block, the error line), so
/// a long tool log can be left out while the answer around it is kept.
struct ChatShareCell: Identifiable, Equatable {
    enum Kind: Equatable { case user, callback, text, tool, thinking, note, toolGroup }
    let kind: Kind
    let messageId: UUID
    /// The block for text / tool / thinking cells, the first folded block for a
    /// tool group; nil for whole-message cells.
    let blockId: UUID?
    /// The unit the cell belongs to; selected cells of one unit render together.
    let unitId: UUID
    /// [T-share-fold-tools] For a `.toolGroup`: the folded run it stands for.
    var fold: ChatShareFold? = nil

    var id: String {
        if kind == .toolGroup, let blockId { return "\(messageId.uuidString)/fold/\(blockId.uuidString)" }
        if let blockId { return "\(messageId.uuidString)/\(blockId.uuidString)" }
        return kind == .note ? "\(messageId.uuidString)/error" : messageId.uuidString
    }

    /// [T-share-fold-tools] The block cells this cell covers: a tool group its
    /// folded blocks, any other cell itself. What a selection is carried by
    /// when the picker folds or unfolds.
    var coveredIds: [String] {
        guard let fold else { return [id] }
        return fold.memberIds.map { "\(messageId.uuidString)/\($0.uuidString)" }
    }
}

/// [T-share-fold-tools] One run of tool calls folded into a single row, as the
/// chat folds it (ToolFoldPlanner.foldedRuns): every block it covers (tools,
/// the thinking that led to them, one-line remarks between them) and what the
/// "Ran N tools · 9s" row shows.
struct ChatShareFold: Equatable {
    let memberIds: [UUID]
    let toolCount: Int
    let failedCount: Int
    let cancelledCount: Int
    let duration: TimeInterval?
}

/// What the cell split needs to know about one reply block.
struct ChatShareBlockSource: Equatable {
    enum Kind: Equatable { case text, tool, thinking, hidden }
    let id: UUID
    let kind: Kind
    let isEmpty: Bool
}

enum ChatShareCells {
    /// Cells in chat order: a user or callback unit is one cell; a reply is its blocks
    /// in order (empty and info blocks dropped), each message followed by its error line.
    ///
    /// [T-share-fold-tools] `folds` (per message): runs to show as one
    /// `.toolGroup` cell in place of the blocks they cover, exactly where the
    /// chat shows its folded row (at the run's first block).
    static func cells(units: [ChatShareUnit], blocks: [UUID: [ChatShareBlockSource]],
                      errors: Set<UUID>, folds: [UUID: [ChatShareFold]] = [:]) -> [ChatShareCell] {
        var out: [ChatShareCell] = []
        for unit in units {
            switch unit.kind {
            case .user:
                out.append(ChatShareCell(kind: .user, messageId: unit.id, blockId: nil, unitId: unit.id))
            case .callback:
                out.append(ChatShareCell(kind: .callback, messageId: unit.id, blockId: nil, unitId: unit.id))
            case .reply:
                for mid in unit.messageIds {
                    let messageFolds = folds[mid] ?? []
                    let foldAt = Dictionary(messageFolds.compactMap { f in f.memberIds.first.map { ($0, f) } },
                                            uniquingKeysWith: { a, _ in a })
                    let folded = Set(messageFolds.flatMap(\.memberIds))
                    for b in blocks[mid] ?? [] {
                        if let f = foldAt[b.id] {
                            out.append(ChatShareCell(kind: .toolGroup, messageId: mid, blockId: b.id,
                                                     unitId: unit.id, fold: f))
                            continue
                        }
                        if folded.contains(b.id) || b.isEmpty { continue }
                        let kind: ChatShareCell.Kind
                        switch b.kind {
                        case .text: kind = .text
                        case .tool: kind = .tool
                        case .thinking: kind = .thinking
                        case .hidden: continue
                        }
                        out.append(ChatShareCell(kind: kind, messageId: mid, blockId: b.id, unitId: unit.id))
                    }
                    if errors.contains(mid) {
                        out.append(ChatShareCell(kind: .note, messageId: mid, blockId: nil, unitId: unit.id))
                    }
                }
            }
        }
        return out
    }

    /// Opening the picker from a message selects its whole ROUND: the user message
    /// that starts it and everything up to the next user message — the reply, its
    /// thinking and tool calls, callback cards, errors. A reply with no user message
    /// before it starts its round.
    static func roundSelection(unit: UUID?, in cells: [ChatShareCell]) -> Set<String> {
        guard let unit, let idx = cells.firstIndex(where: { $0.unitId == unit }) else { return [] }
        var start = idx
        while start > 0, cells[start].kind != .user { start -= 1 }
        if cells[start].kind != .user { start = idx }
        var end = start + 1
        while end < cells.count, cells[end].kind != .user { end += 1 }
        return Set(cells[start..<end].map(\.id))
    }

    /// [T-share-fold-tools] The selection carried across a fold / unfold:
    /// a cell is selected when any block it covers was (a folded row selects
    /// all of its tools on unfolding; folding selects the row when any of its
    /// tools was selected).
    static func remapSelection(_ selected: Set<String>, from old: [ChatShareCell],
                               to new: [ChatShareCell]) -> Set<String> {
        let covered = Set(old.filter { selected.contains($0.id) }.flatMap(\.coveredIds))
        return Set(new.filter { cell in cell.coveredIds.contains(where: covered.contains) }.map(\.id))
    }

    /// WeChat-style "select everything from here down" (and its undo).
    static func setBelow(_ id: String, in cells: [ChatShareCell], selected: Set<String>, on: Bool) -> Set<String> {
        guard let start = cells.firstIndex(where: { $0.id == id }) else { return selected }
        let ids = cells[start...].map(\.id)
        return on ? selected.union(ids) : selected.subtracting(ids)
    }

    /// The selected cells in chat order, grouped into runs that belong to one unit —
    /// what the renderer lays out as one block (and keeps apart from the next by a gap).
    static func renderGroups(_ cells: [ChatShareCell], selected: Set<String>) -> [[ChatShareCell]] {
        var groups: [[ChatShareCell]] = []
        for cell in cells where selected.contains(cell.id) {
            if let last = groups.last?.last, last.unitId == cell.unitId {
                groups[groups.count - 1].append(cell)
            } else {
                groups.append([cell])
            }
        }
        return groups
    }
}

/// Splits a reply's markdown into prose and GFM tables, so a full-width export can
/// give each table its own (wider) canvas while prose keeps the reading width.
enum ChatShareMarkdownChunker {
    struct Chunk: Equatable {
        let text: String
        let isTable: Bool
    }

    static func split(_ markdown: String) -> [Chunk] {
        let lines = markdown.components(separatedBy: "\n")
        var chunks: [Chunk] = []
        var prose: [String] = []
        var fence: String?
        func flushProse() {
            let text = prose.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(Chunk(text: text, isTable: false))
            }
            prose = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let lead = line.drop(while: { $0 == " " })
            let indent = line.count - lead.count
            if indent <= 3, let marker = fenceMarker(lead) {
                if fence == nil { fence = marker } else if lead.hasPrefix(fence!) { fence = nil }
                prose.append(line); i += 1; continue
            }
            if fence == nil, indent <= 3, line.contains("|"),
               i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flushProse()
                var table = [line, lines[i + 1]]
                i += 2
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    table.append(lines[i]); i += 1
                }
                // Ends with a newline: rendered on its own, a table's last row is
                // the document's last line, and without one it came out as raw
                // "| … |" text under a table one row short (seen on device).
                chunks.append(Chunk(text: table.joined(separator: "\n") + "\n", isTable: true))
                continue
            }
            prose.append(line); i += 1
        }
        flushProse()
        return chunks
    }

    private static func fenceMarker(_ lead: Substring) -> String? {
        if lead.hasPrefix("```") { return "```" }
        if lead.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    /// `| --- | :---: |`, `---|--:`: cells of dashes with optional colons.
    static func isSeparator(_ line: String) -> Bool {
        var core = line.trimmingCharacters(in: .whitespaces)
        guard core.contains("-") else { return false }
        if core.hasPrefix("|") { core.removeFirst() }
        if core.hasSuffix("|") { core.removeLast() }
        let cells = core.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            var c = cell.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix(":") { c.removeFirst() }
            if c.hasSuffix(":") { c.removeLast() }
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }
}

/// Page breaks for the PDF. Units are placed one after another; a unit that does not
/// fit the rest of the page moves to a new page, and one taller than a page is cut at
/// the lowest break point (a line or block edge) in the lower part of the page, or at
/// the page edge when there is none.
enum ChatSharePagination {
    struct Cursor: Equatable {
        var page = 0
        /// Content-area y of the next free point on `page`.
        var y: CGFloat = 0
    }

    struct Slice: Equatable {
        let page: Int
        /// Top of the slice in the unit's own coordinates.
        let unitY: CGFloat
        let height: CGFloat
        /// Where the slice's top lands in the page's content area.
        let pageY: CGFloat
    }

    /// A break is only taken if it keeps at least this share of the space on the page;
    /// otherwise a hard cut at the page edge wastes less paper than an early break.
    static let minFill: CGFloat = 0.5
    /// A unit that does not fit the rest of the page moves whole to the next page only
    /// when less than this share of the page is left; otherwise it is split.
    static let moveWholeBelow: CGFloat = 0.3

    static func place(height h: CGFloat, breaks: [CGFloat], pageHeight: CGFloat,
                      gap: CGFloat, cursor: inout Cursor) -> [Slice] {
        guard h > 0, pageHeight > 0 else { return [] }
        if cursor.y > 0 {
            cursor.y += gap
            if cursor.y >= pageHeight { cursor = Cursor(page: cursor.page + 1, y: 0) }
        }
        if h <= pageHeight - cursor.y {
            defer { cursor.y += h }
            return [Slice(page: cursor.page, unitY: 0, height: h, pageY: cursor.y)]
        }
        // Moving a whole unit to the next page is only worth it when little of this page
        // is left; with a large remainder (a short question at the top of a page, then a
        // long reply) that left most of the page blank, so the unit is split at a clean
        // break instead (below; it still moves when no break fits the remainder).
        if h <= pageHeight, pageHeight - cursor.y < pageHeight * moveWholeBelow {
            cursor = Cursor(page: cursor.page + 1, y: h)
            return [Slice(page: cursor.page, unitY: 0, height: h, pageY: 0)]
        }
        let sorted = breaks.filter { $0 > 0 && $0 < h }.sorted()
        var slices: [Slice] = []
        var s: CGFloat = 0
        while h - s > 0.5 {
            let avail = pageHeight - cursor.y
            if h - s <= avail {
                slices.append(Slice(page: cursor.page, unitY: s, height: h - s, pageY: cursor.y))
                cursor.y += h - s
                break
            }
            let best = sorted.last { $0 > s + avail * minFill && $0 <= s + avail }
            if best == nil, cursor.y > 0 {
                // No clean break in what is left of this page: start the unit afresh.
                cursor = Cursor(page: cursor.page + 1, y: 0)
                continue
            }
            let end = best ?? (s + avail)
            slices.append(Slice(page: cursor.page, unitY: s, height: end - s, pageY: cursor.y))
            s = end
            cursor = Cursor(page: cursor.page + 1, y: 0)
        }
        return slices
    }
}

enum ChatShareImageBudget {
    /// Bitmap ceiling for one long image (~240 MB at 4 bytes per pixel).
    static let maxPixels: CGFloat = 60_000_000
    /// Tallest long image offered, in pixels: beyond this the image is not made (a
    /// picture that tall is unwieldy to view or send) and the selection goes to PDF.
    static let maxPixelHeight: CGFloat = 50_000
    /// The scale long images are rendered at.
    static let preferredScale: CGFloat = 3

    /// The render scale for a long image of `width` x `height` points: `preferred` when
    /// it fits both budgets, lower when not, nil below 1x (share as PDF).
    static func scale(width: CGFloat, height: CGFloat, preferred: CGFloat = preferredScale) -> CGFloat? {
        guard width > 0, height > 0 else { return preferred }
        let fit = min((maxPixels / (width * height)).squareRoot(), maxPixelHeight / height)
        if fit >= preferred { return preferred }
        let floored = (fit * 4).rounded(.down) / 4
        return floored >= 1 ? floored : nil
    }
}

/// A cheap estimate of an export's height, made before rendering so the share sheet
/// can say up front that a selection is too long for one image. Text is wrapped by
/// character width (CJK one em, other scripts about half), tables and code count
/// rows, the rest are fixed-height rows; it errs a little high rather than low.
struct ChatShareEstimateInput: Equatable {
    let kind: ChatShareCell.Kind
    let text: String
}

enum ChatShareHeightEstimate {
    static let fontSize: CGFloat = 16.5
    static var lineHeight: CGFloat { fontSize * 1.45 }
    /// Header, margins and the gaps between pieces.
    static let headerHeight: CGFloat = 80
    /// [T-share-hide-title] The page's top and bottom margins alone, for an export
    /// without the header.
    static let marginsHeight: CGFloat = 16
    static let perCellGap: CGFloat = 10

    /// Estimated export height in points for rows laid out at `width` (the page width;
    /// rows keep 16pt side padding). `includesHeader`: the title header is drawn.
    static func points(_ inputs: [ChatShareEstimateInput], width: CGFloat,
                       includesHeader: Bool = true) -> CGFloat {
        let content = max(width - 32, 100)
        return inputs.reduce(includesHeader ? headerHeight : marginsHeight) { total, input in
            total + perCellGap + height(of: input, contentWidth: content)
        }
    }

    /// Whether a long image of that height would pass the pixel-height ceiling.
    static func tooTallForImage(points: CGFloat) -> Bool {
        points * ChatShareImageBudget.preferredScale > ChatShareImageBudget.maxPixelHeight
    }

    static func height(of input: ChatShareEstimateInput, contentWidth: CGFloat) -> CGFloat {
        switch input.kind {
        case .user:
            return wrappedHeight(input.text, width: contentWidth * 0.8 - 28) + 20
        case .callback: return 72
        case .tool: return 36
        case .toolGroup: return 30
        case .thinking: return 40
        case .note: return 30
        case .text:
            var total: CGFloat = 0
            var inFence = false
            for line in input.text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); total += 12; continue }
                if inFence { total += 20; continue }
                if trimmed.isEmpty { total += 8; continue }
                if trimmed.hasPrefix("|") || (trimmed.contains("|") && trimmed.contains("---")) {
                    total += trimmed.contains("---") ? 0 : 44
                    continue
                }
                total += wrappedHeight(trimmed, width: contentWidth) * (trimmed.hasPrefix("#") ? 1.3 : 1)
            }
            return total
        }
    }

    static func wrappedHeight(_ text: String, width: CGFloat) -> CGFloat {
        var lines: CGFloat = 0
        for paragraph in text.components(separatedBy: "\n") {
            let visual = paragraph.unicodeScalars.reduce(CGFloat(0)) { w, c in
                w + (c.value >= 0x2E80 ? fontSize : fontSize * 0.55)
            }
            lines += max(1, (visual / max(width, 1)).rounded(.up))
        }
        return max(1, lines) * lineHeight
    }
}

/// [T-share-hide-title] Where the pieces of a long image go: the optional title header,
/// then each rendered group, top to bottom inside the page margin. The header is
/// followed by a short gap, groups by the wider unit gap; with no header the first
/// group starts at the top margin.
enum ChatShareImageLayout {
    struct Placement: Equatable {
        /// Top of each piece (header first when there is one), in page points.
        let ys: [CGFloat]
        /// Height of the whole image, in points (not rounded).
        let height: CGFloat
    }

    static func place(header: CGFloat?, groups: [CGFloat], margin: CGFloat,
                      headerGap: CGFloat, unitGap: CGFloat) -> Placement {
        var ys: [CGFloat] = []
        var y = margin
        if let header {
            ys.append(y)
            y += header + (groups.isEmpty ? 0 : headerGap)
        }
        for (i, h) in groups.enumerated() {
            ys.append(y)
            y += h + (i == groups.count - 1 ? 0 : unitGap)
        }
        return Placement(ys: ys, height: y + margin)
    }
}

/// Canvas widths for adaptive tables. Rows keep the chosen reading width (phone or
/// iPad); a table gets its natural width and the page widens to the widest one, up
/// to a readable cap that scales with the reading width.
enum ChatShareGeometry {
    /// A chat row's side padding (16pt each side) around its content.
    static let rowPadding: CGFloat = 32

    /// A readable page, not an unbounded one: a table wider than this wraps its
    /// cells to fit instead of stretching the page (pages are A4-proportioned at
    /// whatever width they end up). 1000pt from a phone base, 1.4x an iPad one.
    static func maxCanvasWidth(base: CGFloat) -> CGFloat {
        max(1000, (base * 1.4).rounded())
    }

    /// The width a table chunk is laid out at: its natural width (+2 so the table's
    /// usable width, which is 1pt under the line, still fits every column), never
    /// narrower than prose and never so wide that its row passes the page cap.
    static func tableWidth(natural: CGFloat, contentWidth: CGFloat, base: CGFloat) -> CGFloat {
        min(max(contentWidth, (natural + 2).rounded(.up)), maxCanvasWidth(base: base) - rowPadding)
    }

    static func canvasWidth(base: CGFloat, tableRowWidths: [CGFloat]) -> CGFloat {
        min(max(base, tableRowWidths.max() ?? 0), maxCanvasWidth(base: base))
    }
}

/// [T-share-link-anchor-crash] What the preview's toolbar ShareLink offers.
///
/// A presented system share sheet keeps the ShareLink's view as its popover anchor, and
/// SwiftUI traps (SharingActivityPickerBridge.popoverSource) when it re-anchors after that
/// view left the hierarchy. The ShareLink used to exist only while the CURRENT options had a
/// finished render, so any option change while the sheet was up removed it. Now, once any
/// render exists, the ShareLink stays: it offers the current render, or - while that is still
/// being made (or failed) - keeps the last one and is disabled, so nothing stale is shared.
enum ChatShareLinkTarget {
    static func resolve(current: URL?, last: URL?) -> (url: URL, enabled: Bool)? {
        if let current { return (current, true) }
        if let last { return (last, false) }
        return nil
    }
}

/// [T-share-link-anchor-crash] The light / dark appearance the preview follows when the
/// user has not picked one. It is the app's, but only while the scene is active: going to
/// the background, iOS snapshots the app in the other appearance too, and following that
/// flip re-rendered the export (and swapped the ShareLink) behind an open share sheet.
/// Back in the foreground the preview catches up with the real appearance.
enum ChatShareAppearance {
    static func followed(previous: Bool?, appDark: Bool, sceneActive: Bool) -> Bool {
        if let previous, !sceneActive { return previous }
        return appDark
    }
}

/// [T-share-opts-not-remembered] UserDefaults keys earlier builds used for share
/// options that are no longer remembered (the preview's title toggle and iPad
/// width, the old full-width-tables / tool-call / thinking switches). Nothing reads
/// them any more; purging is idempotent and leaves every other key alone.
enum ChatShareLegacyKeys {
    static let keys = ["chatShare.hideTitle", "chatShare.wideLayout", "chatShare.fullWidthTables",
                       "chatShare.hideTools", "chatShare.includeToolCalls", "chatShare.includeThinking"]

    @discardableResult
    static func purge(_ defaults: UserDefaults = .standard) -> [String] {
        let present = keys.filter { defaults.object(forKey: $0) != nil }
        for key in present { defaults.removeObject(forKey: key) }
        return present
    }
}

// [T-multi-select-share] END chat-share-model
