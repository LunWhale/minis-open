import SwiftUI
import UIKit
import PDFKit

private let logger = AppLogger(category: "ChatExport")

// [T-multi-select-share] Renders the selected cells of a chat into one long PNG or a
// paged, vector PDF.
//
// Each group of selected cells (one question, or the selected pieces of one reply) is
// laid out offscreen in its own hosting view using the chat's OWN row views
// (ChatShareCellContent → ChatMessageRow / AssistantBlockView), so the export looks
// like the session list; it is rendered and thrown away before the next group. That
// lets any selection be shared (the old "Copy Screenshot" stitched a live scroll of
// one question + answer), keeps peak memory to one group, and lets the PDF draw text
// as vector glyphs (drawVector).

struct ChatExportOptions: Equatable {
    enum Format: String, CaseIterable { case image, pdf }
    var format: Format = .image
    /// Lay the chat out at iPad width instead of the phone's, so wide tables get room
    /// (they plan their columns exactly as the chat does at that width).
    var wideLayout = false
    /// Dark appearance; the preview starts from the app's current one.
    var dark = false
    /// Adaptive table width: each table at its natural width, the page widening to
    /// the widest (capped); independent of the phone / iPad reading width.
    var adaptiveTables = false
    /// [T-share-hide-title] No title header: the export starts at the first message,
    /// and the title is left out of the PDF footer, its metadata and the file name.
    var hideHeader = false
}

enum ChatExportError: LocalizedError {
    case noWindow
    case nothingToExport
    case imageTooLarge
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noWindow, .writeFailed: return AppLocalized("Couldn't create the file.")
        case .nothingToExport: return AppLocalized("Nothing to share in the selected messages.")
        case .imageTooLarge: return AppLocalized("Too long for one image. Share it as a PDF instead.")
        }
    }
}

extension ChatShareUnitSource {
    init(message m: ChatMessage) {
        let role: Role
        switch m.role {
        case .user: role = .user
        case .assistant: role = .assistant
        default: role = .other
        }
        self.init(id: m.id, role: role, isCallback: m.agentCallback != nil,
                  isHidden: m.isQueued || m.isInternalBridge)
    }
}

/// A text block's markdown split for adaptive tables: prose at the reading width,
/// each table at its own width.
struct ChatShareTableChunk: Equatable {
    let text: String
    let width: CGFloat
    var isTable = false
}

enum ChatExportContent {
    /// The chunks of a text block for adaptive tables, or nil when it has no table
    /// (then it renders exactly as in the chat).
    @MainActor
    static func tableChunks(_ markdown: String, contentWidth: CGFloat, base: CGFloat) -> [ChatShareTableChunk]? {
        let chunks = ChatShareMarkdownChunker.split(markdown)
        guard chunks.contains(where: \.isTable) else { return nil }
        let theme = SelectableMarkdownTheme(baseFontSize: FontSettings.shared.scaledMessage(16.5))
        return chunks.map { chunk in
            guard chunk.isTable,
                  case .table(let alignments, let rows)? = MarkdownContent(chunk.text).blocks.first
            else { return ChatShareTableChunk(text: chunk.text, width: contentWidth) }
            let natural = TableAttachment(alignments: alignments, rows: rows, theme: theme).naturalTableWidth()
            return ChatShareTableChunk(
                text: chunk.text,
                width: ChatShareGeometry.tableWidth(natural: natural, contentWidth: contentWidth, base: base),
                isTable: true)
        }
    }

    /// What the height estimate needs about the selected cells (their text).
    @MainActor
    static func estimateInputs(_ groups: [[ChatShareCell]], messages byId: [UUID: ChatMessage]) -> [ChatShareEstimateInput] {
        groups.joined().compactMap { cell in
            guard let m = byId[cell.messageId] else { return nil }
            let text: String
            switch cell.kind {
            case .user: text = m.content
            case .text, .thinking, .tool:
                text = m.blocks.first(where: { $0.id == cell.blockId })?.content ?? ""
            case .callback: text = m.agentCallback?.title ?? ""
            case .note: text = m.error ?? ""
            case .toolGroup: text = ""
            }
            return ChatShareEstimateInput(kind: cell.kind, text: text)
        }
    }

    /// The one-line title a tool capsule shows.
    static func toolTitle(_ block: AssistantBlock) -> String {
        (block.toolSummary?.isEmpty == false ? block.toolSummary : nil) ?? block.toolDescription
    }

    /// The picker's cells for a chat, from its messages as they are now.
    ///
    /// [T-share-fold-tools] `foldTools`: runs of tool calls become one "Ran N
    /// tools · 9s" row, by the chat's own rule (ToolFoldPlanner.foldedRuns),
    /// and a reply still being written folds only as far as the chat does
    /// (its fold horizon, from `runningMessageId` / `separators`).
    @MainActor
    static func cells(for messages: [ChatMessage], foldTools: Bool = false,
                      runningMessageId: UUID? = nil,
                      separators: [UUID: Set<UUID>] = [:]) -> [ChatShareCell] {
        let units = ChatShareUnits.group(messages.map(ChatShareUnitSource.init(message:)))
        var blocks: [UUID: [ChatShareBlockSource]] = [:]
        var errors: Set<UUID> = []
        for m in messages where m.role == .assistant {
            blocks[m.id] = m.blocks.map { b in
                let kind: ChatShareBlockSource.Kind
                switch b.kind {
                case .text: kind = .text
                case .thinking: kind = .thinking
                case .info: kind = .hidden
                default: kind = .tool
                }
                let empty = kind == .tool
                    ? toolTitle(b).isEmpty
                    : b.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return ChatShareBlockSource(id: b.id, kind: kind, isEmpty: empty)
            }
            if m.error?.isEmpty == false { errors.insert(m.id) }
        }
        var folds: [UUID: [ChatShareFold]] = [:]
        if foldTools {
            for m in messages where m.role == .assistant {
                let horizon = ToolFoldPlanner.foldHorizon(for: m, runningMessageId: runningMessageId,
                                                          separators: separators)
                guard horizon > 0 else { continue }
                let runs = ToolFoldPlanner.foldedRuns(in: Array(m.blocks.prefix(horizon)))
                if !runs.isEmpty {
                    folds[m.id] = runs.map {
                        ChatShareFold(memberIds: $0.memberIds, toolCount: $0.group.toolCount,
                                      failedCount: $0.group.failedCount,
                                      cancelledCount: $0.group.cancelledCount, duration: $0.duration)
                    }
                }
            }
        }
        return ChatShareCells.cells(units: units, blocks: blocks, errors: errors, folds: folds)
    }

}

// MARK: - Views

/// Collects the bottom edge of every item (PDF break points) while the unit lays out.
final class ChatExportBreakSink {
    var itemBottoms: [Int: CGFloat] = [:]
}

/// One picker cell drawn with the chat's own views, so the picker and the export look
/// like the session list: user and callback rows are ChatMessageRow, reply pieces are
/// AssistantBlockView (same markdown renderer, tool capsules and thinking chip), with
/// the list's 16pt side padding. Callers disable hit testing — nothing here is
/// interactive. `tableChunks` (adaptive tables) swaps a text block for its prose and
/// tables laid out at their own widths.
struct ChatShareCellContent: View {
    let cell: ChatShareCell
    @ObservedObject var message: ChatMessage
    var tableChunks: [ChatShareTableChunk]? = nil

    private var block: AssistantBlock? {
        cell.blockId.flatMap { id in message.blocks.first { $0.id == id } }
    }

    var body: some View {
        switch cell.kind {
        case .user:
            ChatMessageRow(message: message, isActiveMessage: false)
        case .callback:
            // The list insets callback cards itself (BridgedWholeMessageV3); without
            // it the card ran edge to edge and was clipped on the right.
            ChatMessageRow(message: message, isActiveMessage: false)
                .padding(.horizontal, AgentCallbackCellView.horizontalInset)
        case .text, .tool, .thinking:
            if let block {
                Group {
                    if let tableChunks {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(tableChunks.enumerated()), id: \.offset) { _, chunk in
                                SelectableMarkdownView(markdown: chunk.text)
                                    .frame(width: chunk.width, alignment: .leading)
                            }
                        }
                    } else {
                        AssistantBlockView(block: block, message: message, isActiveMessage: false,
                                           highlightedBlockId: .constant(nil), detailBlock: .constant(nil))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
        case .toolGroup:
            // [T-share-fold-tools] The chat's own folded row, closed.
            if let fold = cell.fold, let first = cell.blockId {
                ToolGroupRowView(firstBlockId: first, toolCount: fold.toolCount,
                                 failedCount: fold.failedCount, cancelledCount: fold.cancelledCount,
                                 duration: fold.duration, isExpanded: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
        case .note:
            Label(message.error ?? "", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }
    }
}

/// One group of selected cells, as the export lays it out: the chat's rows at the
/// chosen reading width (phone, or iPad for the wide layout). With adaptive tables the
/// page can be wider than a row: the reply (prose, thinking, tools) re-wraps at the
/// page width so its text lines up with the tables, while user bubbles and callback
/// cards keep the reading width (a user bubble stays at the page's right edge).
private struct ChatExportGroupView: View {
    let cells: [ChatShareCell]
    let messages: [UUID: ChatMessage]
    let chunks: [String: [ChatShareTableChunk]]
    let rowWidth: CGFloat
    let canvasWidth: CGFloat
    let sink: ChatExportBreakSink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                if let message = messages[cell.messageId] {
                    ChatShareCellContent(cell: cell, message: message, tableChunks: chunks[cell.id])
                        .frame(width: Self.keepsReadingWidth(cell) ? rowWidth : canvasWidth,
                               alignment: .leading)
                        .frame(width: cell.kind == .user ? canvasWidth : nil, alignment: .trailing)
                        .background(GeometryReader { g -> Color in
                            sink.itemBottoms[index] = g.frame(in: .named("exportUnit")).maxY
                            return Color.clear
                        })
                }
            }
        }
        .frame(width: canvasWidth, alignment: .leading)
        .coordinateSpace(name: "exportUnit")
        .background(Color(uiColor: .systemBackground))
    }

    /// Bubbles and cards are objects with a width of their own; stretching them
    /// across a wide page reads as a layout bug rather than more room.
    private static func keepsReadingWidth(_ cell: ChatShareCell) -> Bool {
        cell.kind == .user || cell.kind == .callback
    }
}

private struct ChatExportHeaderView: View {
    let title: String
    /// The parts of the line under the title (model, date), joined with " · ".
    let subtitle: [String]
    let width: CGFloat

    /// The app icon, loaded the way AboutView does (nil if the asset lookup fails;
    /// the brand name still shows).
    private static let appIcon = UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon")

    private static let avatarSize: CGFloat = 28

    /// The assistant's avatar as the chat header resolves it — the user's SOUL icon
    /// (image or emoji), else the default gradient sparkle — drawn as a ringed circle:
    /// an image fills it, a glyph sits centred on a light disc.
    @ViewBuilder
    private var avatar: some View {
        let icon = SoulStore.cachedMetadata.icon
        let size = Self.avatarSize
        let isImage = SoulIconImage.decode(icon) != nil
        ZStack {
            Circle().fill(Color(uiColor: .secondarySystemBackground))
            SoulIconView(
                icon: icon,
                size: isImage ? size : size * 0.55,
                sparkleGradient: LinearGradient(
                    colors: [Color(red: 0.72, green: 0.69, blue: 0.59),
                             Color(red: 0.6, green: 0.6, blue: 0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                cornerRadius: isImage ? size / 2 : nil
            )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5))
    }

    /// "model · date" on one line when it fits; otherwise one part per line, so a
    /// narrow page never splits the date itself. Chosen by layout rather than by
    /// gluing characters: joiners inside a CJK date made the PDF's text layer map
    /// 月 / 日 to their Kangxi-radical look-alikes, breaking copy and search.
    @ViewBuilder
    private var subtitleLine: some View {
        let font = UIFont.systemFont(ofSize: 13)
        ViewThatFits(in: .horizontal) {
            ExportLabel(text: subtitle.joined(separator: " · "), font: font, color: .secondaryLabel, lines: 1)
                .fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(subtitle.enumerated()), id: \.offset) { i, part in
                    ExportLabel(text: i < subtitle.count - 1 ? part + " ·" : part,
                                font: font, color: .secondaryLabel)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Avatar, title block and brand share one vertical centre line.
            HStack(alignment: .center, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    ExportLabel(text: title, font: .systemFont(ofSize: 16, weight: .semibold), lines: 2)
                    subtitleLine
                }
                // Measured before the Spacer, so "model · date" only wraps when it
                // truly runs into the brand, not when the Spacer claims a share.
                .layoutPriority(1)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    if let icon = Self.appIcon {
                        // The icon is a pale M on white: a hairline keeps its edge
                        // visible on the white page.
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5))
                    }
                    // Product name: not localized.
                    ExportLabel(text: "Open Minis", font: .systemFont(ofSize: 14, weight: .semibold),
                                color: .label, lines: 1)
                        .fixedSize()
                }
            }
            Divider()
        }
        .padding(.horizontal, 16)
        .frame(width: width, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }
}

/// A wrapping UILabel sized by SwiftUI: header text drawable as vector glyphs.
private struct ExportLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    var color: UIColor = .label
    var lines = 0

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), width), height: ceil(size.height))
    }
}

// MARK: - Renderer

@MainActor
final class ChatExportRenderer {
    struct Result {
        let url: URL
        /// Long image: pixel size. PDF: page size in points.
        let size: CGSize
        /// Pixels per point of a long image (1 for a PDF): the preview shows it at 1:1.
        let scale: CGFloat
        let pageCount: Int
        let units: Int
    }

    static let margin: CGFloat = 8
    static let unitGap: CGFloat = 18
    /// The page's content width: the chat list's width on a phone (rows carry their
    /// own 16pt side padding), or a 13-inch iPad's portrait width for the wide layout
    /// (at the 11-inch 834pt a 7-column table still fell into the scrolling plan and
    /// was cut off at the page edge).
    static func rowWidth(wide: Bool) -> CGFloat {
        wide ? 1024 : min(max(UIScreen.main.bounds.width, 360), 460)
    }

    /// The appearance of the current render and its page colour.
    private var style: UIUserInterfaceStyle = .light
    private var pageColor: UIColor = .white

    private let stage: UIView
    /// The chat's view model: the tool capsules read it from the environment.
    private let vm: AIChatViewModel

    init(vm: AIChatViewModel) throws {
        self.vm = vm
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first
        else { throw ChatExportError.noWindow }
        // Off to the left of the window: in the hierarchy (so text views and
        // attachments lay out as on screen) but never visible.
        stage = UIView(frame: CGRect(x: -30_000, y: 0, width: 1, height: 1))
        stage.isUserInteractionEnabled = false
        stage.clipsToBounds = false
        window.addSubview(stage)
    }

    deinit {
        let stage = stage
        Task { @MainActor in stage.removeFromSuperview() }
    }

    /// A laid-out unit, alive until the caller is done drawing it.
    private struct Laid {
        let host: UIHostingController<AnyView>
        let size: CGSize
        /// Clean places to cut a page inside the unit (item and text-line bottoms).
        let breaks: [CGFloat]
    }

    private func layOut<V: View>(_ view: V, width: CGFloat, sink: ChatExportBreakSink?) async -> Laid {
        let host = UIHostingController(rootView: AnyView(
            view.environment(\.colorScheme, style == .dark ? .dark : .light)
                .environment(\.chatSnapshotRendering, true)
                .environmentObject(vm)))
        host.overrideUserInterfaceStyle = style
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.view.backgroundColor = pageColor
        stage.addSubview(host.view)
        func measure() -> CGSize {
            let s = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: max(1, ceil(s.height)))
        }
        var size = measure()
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        // Markdown attachments (tables, code, math) place their views on a later
        // main-queue hop; give them a few turns and re-measure until stable.
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let next = measure()
            if abs(next.height - size.height) < 0.5 { break }
            size = next
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
        }
        var breaks = Array((sink?.itemBottoms.values).map(Array.init) ?? [])
        collectLineBreaks(in: host.view, root: host.view, into: &breaks)
        return Laid(host: host, size: size, breaks: breaks)
    }

    private func collectLineBreaks(in view: UIView, root: UIView, into breaks: inout [CGFloat]) {
        if let tv = view as? UITextView, tv.textLayoutManager == nil {
            let lm = tv.layoutManager
            let glyphs = lm.glyphRange(for: tv.textContainer)
            let inset = tv.textContainerInset.top
            var lineBottoms: [CGFloat] = []
            lm.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                lineBottoms.append(used.maxY + inset)
            }
            breaks += lineBottoms.map { tv.convert(CGPoint(x: 0, y: $0), to: root).y }
            return
        }
        for sub in view.subviews { collectLineBreaks(in: sub, root: root, into: &breaks) }
    }

    private func discard(_ laid: Laid) {
        laid.host.view.removeFromSuperview()
    }

    /// "<model> · <date>" under the title, so a shared export shows which model did
    /// the work. The model is the concrete one the session resolves to (not a group
    /// name); either part is dropped when unavailable.
    private static func subtitle(for messages: [ChatMessage], model: String?) -> [String] {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let date = messages.first.map { f.string(from: $0.timestamp) }
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [model, date].compactMap { $0?.isEmpty == false ? $0 : nil }
    }

    private static var exportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChatExport", isDirectory: true)
    }

    /// Drops earlier exports; the share preview calls it when it opens (its own
    /// renders stay until the next time, so switching format back reuses them).
    static func clearExports() {
        try? FileManager.default.removeItem(at: exportRoot)
    }

    private static func fileURL(title: String, ext: String) throws -> URL {
        // Its own folder per export, so the image and the PDF of one selection can
        // both be kept while the preview switches between them.
        let dir = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let clean = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(60)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return dir.appendingPathComponent("\(clean.isEmpty ? "Chat" : String(clean)) \(f.string(from: Date())).\(ext)")
    }

    /// Renders the selected cells. `groups` is `ChatShareCells.renderGroups`: each group
    /// is the selected part of one unit and is laid out (and page-broken) as one block.
    func render(groups: [[ChatShareCell]], messages: [ChatMessage], title: String,
                options: ChatExportOptions,
                progress: @escaping (Int, Int) -> Void) async throws -> Result {
        let started = Date()
        let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        style = options.dark ? .dark : .light
        pageColor = UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        let base = Self.rowWidth(wide: options.wideLayout)
        let groups = groups.map { $0.filter { byId[$0.messageId] != nil } }.filter { !$0.isEmpty }
        guard !groups.isEmpty else { throw ChatExportError.nothingToExport }
        var chunks: [String: [ChatShareTableChunk]] = [:]
        if options.adaptiveTables {
            for cell in groups.joined() where cell.kind == .text {
                guard let block = byId[cell.messageId]?.blocks.first(where: { $0.id == cell.blockId }),
                      let split = ChatExportContent.tableChunks(
                        block.content, contentWidth: base - ChatShareGeometry.rowPadding, base: base)
                else { continue }
                chunks[cell.id] = split
            }
        }
        // The page follows the widest table, up to ChatShareGeometry.maxCanvasWidth;
        // a table capped below its natural width wraps its cells to fit.
        let canvas = ChatShareGeometry.canvasWidth(
            base: base, tableRowWidths: chunks.values.joined().map { $0.width + ChatShareGeometry.rowPadding })
        // Prose was split at the reading width only to find the table widths; once
        // the page is known it re-wraps at the page's content width, so the text
        // around a table is as wide as the widest table rather than a narrow column
        // beside it. Tables keep their own width (a narrow one is not stretched).
        let proseWidth = canvas - ChatShareGeometry.rowPadding
        chunks = chunks.mapValues { split in
            split.map { $0.isTable ? $0 : ChatShareTableChunk(text: $0.text, width: proseWidth) }
        }
        let contents: [(ChatExportBreakSink) -> AnyView] = groups.map { group in
            { sink in AnyView(ChatExportGroupView(cells: group, messages: byId, chunks: chunks,
                                                  rowWidth: base, canvasWidth: canvas, sink: sink)) }
        }
        let covered = groups.flatMap { $0.map(\.messageId) }.compactMap { byId[$0] }
        // [T-share-hide-title] Hidden: no header, and no title anywhere in the file
        // (an empty title names it "Chat <date>").
        let header = options.hideHeader ? nil
            : ChatExportHeaderView(title: title, subtitle: Self.subtitle(for: covered, model: vm.resolveCurrentEntry()?.model.displayName),
                                   width: canvas)
        let fileTitle = options.hideHeader ? "" : title
        logger.info("[ChatExport] start format=\(options.format.rawValue) groups=\(groups.count) cells=\(groups.joined().count) canvas=\(Int(canvas)) wide=\(options.wideLayout) dark=\(options.dark) adaptiveTables=\(options.adaptiveTables) splitBlocks=\(chunks.count) header=\(!options.hideHeader)")

        let result: Result
        switch options.format {
        case .image:
            result = try await renderImage(contents: contents, header: header, canvas: canvas,
                                           title: fileTitle, progress: progress)
        case .pdf:
            result = try await renderPDF(contents: contents, header: header, canvas: canvas,
                                         title: fileTitle, progress: progress)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
        logger.info("[ChatExport] done format=\(options.format.rawValue) size=\(Int(result.size.width))x\(Int(result.size.height)) pages=\(result.pageCount) bytes=\(bytes) ms=\(ms)")
        return result
    }

    // MARK: Long image

    private func renderImage(contents: [(ChatExportBreakSink) -> AnyView], header: ChatExportHeaderView?,
                             canvas: CGFloat, title: String,
                             progress: @escaping (Int, Int) -> Void) async throws -> Result {
        // Each piece is rendered at 3x into a temp PNG right away, so only one hosting
        // view and one bitmap are alive at a time; the final image is composed after.
        // Text is drawn as glyphs (drawVector), not copied from the views' own
        // screen-scale bitmaps, which is what made a 2x image of a 2x device soft.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChatExportParts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var parts: [(url: URL, size: CGSize)] = []

        func renderPart<V: View>(_ view: V, sink: ChatExportBreakSink?) async throws {
            let laid = await layOut(view, width: canvas, sink: sink)
            defer { discard(laid) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: laid.size, format: format).image { ctx in
                pageColor.setFill()
                ctx.fill(CGRect(origin: .zero, size: laid.size))
                drawVector(laid.host.view, in: ctx.cgContext)
            }
            let url = dir.appendingPathComponent("\(parts.count).png")
            guard let data = image.pngData() else { throw ChatExportError.writeFailed }
            try data.write(to: url)
            parts.append((url, laid.size))
        }

        if let header { try await renderPart(header, sink: nil) }
        for (i, makeView) in contents.enumerated() {
            try Task.checkCancellation()
            let sink = ChatExportBreakSink()
            try await renderPart(makeView(sink), sink: sink)
            progress(i + 1, contents.count)
        }

        let m = Self.margin
        // [T-share-hide-title] With the header, part 0 is it (8pt gap after); without,
        // the first group starts at the top margin.
        let placement = ChatShareImageLayout.place(
            header: header == nil ? nil : parts.first?.size.height,
            groups: parts.dropFirst(header == nil ? 0 : 1).map(\.size.height),
            margin: m, headerGap: 8, unitGap: Self.unitGap)
        let size = CGSize(width: canvas + m * 2, height: ceil(placement.height))
        guard let scale = ChatShareImageBudget.scale(width: size.width, height: size.height) else {
            logger.warning("[ChatExport] image too large \(Int(size.width))x\(Int(size.height))pt")
            throw ChatExportError.imageTooLarge
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let url = try Self.fileURL(title: title, ext: "png")
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            pageColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (part, y) in zip(parts, placement.ys) {
                autoreleasepool {
                    UIImage(contentsOfFile: part.url.path)?.draw(in: CGRect(x: m, y: y, width: part.size.width, height: part.size.height))
                }
            }
        }
        try data.write(to: url)
        return Result(url: url, size: CGSize(width: size.width * scale, height: size.height * scale),
                      scale: scale, pageCount: 1, units: contents.count)
    }

    // MARK: PDF

    private func renderPDF(contents: [(ChatExportBreakSink) -> AnyView], header: ChatExportHeaderView?,
                           canvas: CGFloat, title: String,
                           progress: @escaping (Int, Int) -> Void) async throws -> Result {
        let m = Self.margin
        let footer: CGFloat = 22
        let pageWidth = canvas + m * 2
        // A4 proportions at the export width; a full-width-table page grows with it.
        let pageHeight = (pageWidth * 297 / 210).rounded()
        let contentHeight = pageHeight - m * 2 - footer
        let url = try Self.fileURL(title: title, ext: "pdf")
        var box = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var infoDict: [String: Any] = [kCGPDFContextCreator as String: "Minis"]
        if !title.isEmpty { infoDict[kCGPDFContextTitle as String] = title }
        let info = infoDict as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info) else { throw ChatExportError.writeFailed }

        var openPage = -1
        func ensurePage(_ page: Int) {
            while openPage < page {
                if openPage >= 0 { closePage() }
                openPage += 1
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                // UIKit's top-left, y-down coordinates.
                ctx.translateBy(x: 0, y: pageHeight)
                ctx.scaleBy(x: 1, y: -1)
                ctx.setFillColor(pageColor.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            }
        }
        func closePage() {
            // [T-share-hide-title] Page number only when the title is hidden.
            let label = (title.isEmpty ? "\(openPage + 1)" : "\(title) · \(openPage + 1)") as NSString
            UIGraphicsPushContext(ctx)
            let footerColor = UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            label.draw(at: CGPoint(x: m, y: pageHeight - m - 12),
                       withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: footerColor])
            UIGraphicsPopContext()
            ctx.restoreGState()
            ctx.endPDFPage()
        }

        var cursor = ChatSharePagination.Cursor()
        func draw(_ laid: Laid) {
            let slices = ChatSharePagination.place(height: laid.size.height, breaks: laid.breaks,
                                                   pageHeight: contentHeight, gap: Self.unitGap, cursor: &cursor)
            for slice in slices {
                ensurePage(slice.page)
                ctx.saveGState()
                ctx.translateBy(x: m, y: m + slice.pageY - slice.unitY)
                ctx.clip(to: CGRect(x: 0, y: slice.unitY, width: laid.size.width, height: slice.height))
                drawVector(laid.host.view, in: ctx)
                ctx.restoreGState()
            }
        }

        if let header {
            let head = await layOut(header, width: canvas, sink: nil)
            draw(head)
            discard(head)
        }
        for (i, makeView) in contents.enumerated() {
            try Task.checkCancellation()
            let sink = ChatExportBreakSink()
            let laid = await layOut(makeView(sink), width: canvas, sink: sink)
            draw(laid)
            discard(laid)
            progress(i + 1, contents.count)
        }
        if openPage >= 0 { closePage() }
        ctx.closePDF()
        return Result(url: url, size: CGSize(width: pageWidth, height: pageHeight),
                      scale: 1, pageCount: openPage + 1, units: contents.count)
    }

    /// Draws a laid-out unit into a PDF context with its TEXT as vector glyphs.
    ///
    /// `layer.render(in:)` alone copies each text view's already-rendered bitmap, so a
    /// PDF built that way is a picture of the chat: text not selectable, searchable or
    /// sharp when zoomed. Instead, two passes:
    /// 1. every TextKit 1 text view's private drawing subviews (its glyph canvas, scroll
    ///    indicators) and every label are hidden, and the layer tree is rendered —
    ///    backgrounds, borders, table rules and images, with no text;
    /// 2. each of those text views draws its glyphs through its layout manager, and each
    ///    label through `drawText(in:)`, straight into the context, clipped like on screen.
    /// App-added subviews of a text view (table, code and math attachment views) stay
    /// visible in pass 1, and their own text views are handled in pass 2 like any other.
    /// A text view on TextKit 2 is left alone and comes out as a bitmap, as before.
    private func drawVector(_ root: UIView, in ctx: CGContext) {
        // Dynamic colours (text, code, table rules) resolve against the CURRENT trait
        // collection while drawing — the app's, not the export's. A dark app exporting
        // a light page drew white text on white. Draw under the hosting view's traits.
        root.traitCollection.performAsCurrent { drawVectorInCurrentTraits(root, in: ctx) }
    }

    private func drawVectorInCurrentTraits(_ root: UIView, in ctx: CGContext) {
        var textViews: [UITextView] = []
        var labels: [UILabel] = []
        var hidden: [UIView] = []
        func isPrivate(_ v: UIView) -> Bool { NSStringFromClass(type(of: v)).hasPrefix("_") }
        func walk(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            if let tv = v as? UITextView, tv.textLayoutManager == nil {
                textViews.append(tv)
                for sub in tv.subviews where isPrivate(sub) && !sub.isHidden {
                    sub.isHidden = true
                    hidden.append(sub)
                }
            } else if let label = v as? UILabel {
                labels.append(label)
                label.isHidden = true
                hidden.append(label)
                return
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        defer { hidden.forEach { $0.isHidden = false } }

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        root.layer.render(in: ctx)

        /// The part of `view` its ancestors let show, in root coordinates.
        func visibleRect(_ view: UIView) -> CGRect {
            var rect = view.convert(view.bounds, to: root)
            var v: UIView? = view.superview
            while let a = v, a !== root {
                if a.clipsToBounds { rect = rect.intersection(a.convert(a.bounds, to: root)) }
                v = a.superview
            }
            return rect
        }
        for tv in textViews {
            let clip = visibleRect(tv)
            guard !clip.isEmpty else { continue }
            let lm = tv.layoutManager
            let glyphs = lm.glyphRange(for: tv.textContainer)
            guard glyphs.length > 0 else { continue }
            ctx.saveGState()
            ctx.clip(to: clip)
            let origin = tv.convert(CGPoint.zero, to: root)
            ctx.translateBy(x: origin.x, y: origin.y)
            let inset = CGPoint(x: tv.textContainerInset.left, y: tv.textContainerInset.top)
            lm.drawBackground(forGlyphRange: glyphs, at: inset)
            lm.drawGlyphs(forGlyphRange: glyphs, at: inset)
            ctx.restoreGState()
        }
        for label in labels {
            let clip = visibleRect(label)
            guard !clip.isEmpty else { continue }
            ctx.saveGState()
            ctx.clip(to: clip)
            let origin = label.convert(CGPoint.zero, to: root)
            ctx.translateBy(x: origin.x, y: origin.y)
            label.drawText(in: label.bounds)
            ctx.restoreGState()
        }
    }

    /// DEBUG aid: the text PDFKit extracts from a rendered PDF (proves text stayed vector).
    static func pdfTextSample(_ url: URL, limit: Int = 400) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        return String((doc.string ?? "").prefix(limit))
    }
}

extension Notification.Name {
    /// [T-multi-select-share] Posted by debug.chatShare.openPicker; object is
    /// `(sessionId: String, messageId: UUID)`.
    static let chatShareDebugOpen = Notification.Name("chatShareDebugOpen")
}

#if DEBUG
/// `debug.chatExport.render`: runs the share export headlessly for a loaded session,
/// so a device check does not need the picker UI. The file is copied under
/// Library/Caches/ChatExportDebug/ where `debug.readFile` can fetch it.
@MainActor
enum ChatExportDebugRPC {
    /// `debug.chatShare.openPicker`: opens the share picker on the session on screen, as
    /// a long-press "Share Chat…" on its last user message (or the message given).
    static func openPicker(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String else {
            throw DebugRPCErr(-32602, "Missing required param: sessionId")
        }
        guard let vm = ViewModelCache.shared.get(for: sid) else {
            throw DebugRPCErr(-32602, "session \(sid) is not loaded — open it first (debug.openSession)")
        }
        let target = (params["messageId"] as? String).flatMap(UUID.init(uuidString:))
            ?? vm.messages.last(where: { $0.isUserTurnAnchor })?.id
        guard let target else { throw DebugRPCErr(-32602, "no user message to anchor on") }
        NotificationCenter.default.post(name: .chatShareDebugOpen, object: (sessionId: sid, messageId: target))
        return ["ok": true, "messageId": target.uuidString]
    }

    static func render(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String else {
            throw DebugRPCErr(-32602, "Missing required param: sessionId")
        }
        guard let vm = ViewModelCache.shared.get(for: sid) else {
            throw DebugRPCErr(-32602, "session \(sid) is not loaded — open it first (debug.openSession)")
        }
        let messages = vm.messages
        // [T-share-fold-tools] Fold like the chat unless told otherwise.
        let foldTools = params["foldTools"] as? Bool ?? ToolFoldPlanner.isEnabled
        let cells = ChatExportContent.cells(for: messages, foldTools: foldTools,
                                            runningMessageId: vm.toolFoldRunningMessageId,
                                            separators: vm.toolFoldSeparators)
        let unitIds = cells.reduce(into: [UUID]()) { if $0.last != $1.unitId { $0.append($1.unitId) } }
        var units = unitIds
        if let indexes = params["unitIndexes"] as? [Int] {
            units = indexes.compactMap { unitIds.indices.contains($0) ? unitIds[$0] : nil }
        } else if let last = params["lastUnits"] as? Int, last > 0 {
            units = Array(unitIds.suffix(last))
        }
        let includeTools = params["includeToolCalls"] as? Bool ?? false
        let includeThinking = params["includeThinking"] as? Bool ?? false
        let wanted = Set(units)
        let selected = Set(cells.filter { cell in
            guard wanted.contains(cell.unitId) else { return false }
            switch cell.kind {
            case .tool, .toolGroup: return includeTools
            case .thinking: return includeThinking
            default: return true
            }
        }.map(\.id))
        let groups = ChatShareCells.renderGroups(cells, selected: selected)
        var options = ChatExportOptions()
        options.format = (params["format"] as? String) == "pdf" ? .pdf : .image
        options.wideLayout = params["wideLayout"] as? Bool ?? false
        options.dark = params["dark"] as? Bool ?? false
        options.adaptiveTables = params["adaptiveTables"] as? Bool ?? false
        options.hideHeader = params["hideHeader"] as? Bool ?? false
        let started = Date()
        let result = try await ChatExportRenderer(vm: vm).render(
            groups: groups, messages: messages, title: params["title"] as? String ?? "Debug Export",
            options: options) { _, _ in }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = library.appendingPathComponent("Caches/ChatExportDebug", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(result.url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: result.url, to: dest)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        var out: [String: Any] = [
            "path": "Library/Caches/ChatExportDebug/\(dest.lastPathComponent)",
            "bytes": bytes,
            "width": result.size.width,
            "height": result.size.height,
            "pages": result.pageCount,
            "units": result.units,
            "totalUnits": unitIds.count,
            "cells": groups.flatMap { $0.map { "\($0.kind)" } },
            "ms": ms,
        ]
        if options.format == .pdf { out["pdfText"] = ChatExportRenderer.pdfTextSample(dest) }
        return out
    }
}
#endif
