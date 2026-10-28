import SwiftUI
import PDFKit

private let logger = AppLogger(category: "ChatExport")

// [T-multi-select-share] The share picker: the chat drawn exactly as the session list
// draws it (ChatShareCellContent — the same rows the export renders), one selectable
// row per cell: a user message, each text block of a reply, each tool call, thinking,
// callback cards — so a long tool log can be left out. A selected row gets a tint and a
// check badge floating at its leading edge, vertically centred, so every row keeps the chat's
// layout. Rows are display-only: none of the chat's long-press actions exist here.
//
// Selecting: tap a row; drag down the leading edge to select or deselect a run, like
// Photos; long-press a row for "Select All Below" / "Deselect All
// Below" (WeChat's quick range); Select All in the toolbar. Then "Share (N)" → format
// → a preview that renders at once (long image; PDF, iPad-width layout and dark /
// light on demand), shown 1:1, with the system share button.

struct ChatShareRequest: Identifiable {
    let id = UUID()
    /// Every block as its own row.
    let cells: [ChatShareCell]
    /// [T-share-fold-tools] The same rows with tool runs folded as the chat
    /// folds them.
    var foldedCells: [ChatShareCell]? = nil
    /// Whether the picker opens folded (the chat's own setting), and
    /// `initialSelection` refers to `foldedCells` then.
    var startsFolded = false
    /// The chat's messages when the picker opened (a snapshot: a reply still streaming
    /// is shared as it was then).
    let messages: [ChatMessage]
    let initialSelection: Set<String>
    let title: String
    /// Tool capsules read the chat's view model from the environment.
    let vm: AIChatViewModel
}

/// Row frames for drag-select, kept outside SwiftUI state: they change on every scroll
/// frame and must not re-render the list.
private final class ChatShareRowFrames {
    var byIndex: [Int: CGRect] = [:]
    var viewportHeight: CGFloat = 0

    func index(at y: CGFloat) -> Int? {
        byIndex.first { $0.value.minY <= y && y < $0.value.maxY }?.key
    }
}

private struct ChatShareRowFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ChatShareSelectionView: View {
    let request: ChatShareRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var showOptions = false
    @State private var frames = ChatShareRowFrames()
    /// An active drag-select: the row it started on, whether it selects or
    /// deselects, and the selection before it began (so dragging back undoes).
    @State private var drag: (start: Int, on: Bool, base: Set<String>)?

    /// [T-share-fold-tools] Tool runs folded into "Ran N tools · 9s" rows, by
    /// the chat's own rule. Starts as the chat shows them (Settings →
    /// Appearance → Fold Consecutive Tool Calls); the toggle only affects this
    /// share. It replaces the old hide-tools toggle, which dropped every tool row.
    @State private var foldTools = false
    /// Thinking rows left out: neither shown nor selected (so not shared).
    @AppStorage("chatShare.hideThinking") private var hideThinking = false
    /// [T-share-hide-title] The export starts at the first message, with no title
    /// header (and no title in the PDF footer, metadata or file name). Remembered like
    /// Hide Thinking; off by default.

    /// Width of the leading strip that drag-selects.
    private static let dragStripWidth: CGFloat = 36

    /// Every row of the current fold state, hidden thinking included.
    private var allCells: [ChatShareCell] {
        foldTools ? (request.foldedCells ?? request.cells) : request.cells
    }

    /// The rows on show — everything but hidden thinking.
    private var cells: [ChatShareCell] {
        allCells.filter { !isHidden($0.kind) }
    }

    private func isHidden(_ kind: ChatShareCell.Kind) -> Bool {
        hideThinking && kind == .thinking
    }

    /// Drops rows that are no longer on show from the selection.
    private func deselectHidden() {
        selection.subtract(allCells.filter { isHidden($0.kind) }.map(\.id))
    }

    /// [T-share-fold-tools] Fold or unfold, keeping what was selected: a
    /// selected folded row selects its tools, a selected tool selects its row.
    private func toggleFold() {
        let before = allCells
        foldTools.toggle()
        selection = ChatShareCells.remapSelection(selection, from: before, to: allCells)
        deselectHidden()
    }

    private var byId: [UUID: ChatMessage] {
        Dictionary(request.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let messages = byId
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                            if let message = messages[cell.messageId] {
                                row(cell, index: index, message: message)
                            }
                        }
                    }
                    .padding(.top, 56)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(name: "sharePicker")
                .onPreferenceChange(ChatShareRowFrameKey.self) { frames.byIndex = $0 }
                .background(GeometryReader { g in
                    Color.clear.onAppear { frames.viewportHeight = g.size.height }
                        .onChange(of: g.size.height) { frames.viewportHeight = $0 }
                })
                .overlay(alignment: .leading) { dragStrip(proxy) }
                .overlay(alignment: .top) { floatingActions }
                .onAppear {
                    foldTools = request.startsFolded && request.foldedCells != nil
                    selection = request.initialSelection
                    deselectHidden()
                    if let first = request.cells.first(where: { request.initialSelection.contains($0.id) })?.id {
                        DispatchQueue.main.async { proxy.scrollTo(first, anchor: .center) }
                    }
                }
            }
            .environmentObject(request.vm)
            .navigationTitle(selection.isEmpty
                             ? AppLocalized("Select Messages")
                             : String(format: AppLocalized("%lld Selected"), selection.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    let all = !cells.isEmpty && selection.isSuperset(of: cells.map(\.id))
                    Button(all ? AppLocalized("Deselect All") : AppLocalized("Select All")) {
                        selection = all ? [] : Set(cells.map(\.id))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showOptions = true
                } label: {
                    Label(String(format: AppLocalized("Share (%lld)"), selection.count), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .sheet(isPresented: $showOptions) {
                ChatSharePreviewSheet(
                    groups: ChatShareCells.renderGroups(allCells, selected: selection),
                    count: selection.count,
                    messages: request.messages,
                    title: request.title,
                    vm: request.vm)
            }
        }
    }

    private func row(_ cell: ChatShareCell, index: Int, message: ChatMessage) -> some View {
        let isOn = selection.contains(cell.id)
        return ChatShareCellContent(cell: cell, message: message)
            .allowsHitTesting(false)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Selected: a tint plus a check badge floating at the leading edge
            // (not a column, so the row keeps the chat's layout); unselected rows
            // show nothing extra.
            .background(isOn ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(alignment: .leading) {
                if isOn {
                    // Small, tucked into the 16pt side margin and centred on the row's
                    // height, so it marks the row without covering the reply's text.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(.leading, 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(cell.id) }
            .contextMenu {
                Button {
                    selection = ChatShareCells.setBelow(cell.id, in: cells, selected: selection, on: true)
                } label: {
                    Label(AppLocalized("Select All Below"), systemImage: "arrow.down.to.line")
                }
                Button {
                    selection = ChatShareCells.setBelow(cell.id, in: cells, selected: selection, on: false)
                } label: {
                    Label(AppLocalized("Deselect All Below"), systemImage: "arrow.down.to.line.compact")
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: ChatShareRowFrameKey.self,
                                       value: [index: g.frame(in: .named("sharePicker"))])
            })
            .id(cell.id)
    }

    /// The leading strip: a drag here selects (or, when it starts on
    /// a selected row, deselects) every row between its start and the finger, and
    /// scrolls when the finger nears the top or bottom.
    private func dragStrip(_ proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(width: Self.dragStripWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("sharePicker"))
                    .onChanged { value in
                        guard let current = frames.index(at: value.location.y) else { return }
                        if drag == nil {
                            let start = frames.index(at: value.startLocation.y) ?? current
                            drag = (start, !selection.contains(cells[start].id), selection)
                        }
                        guard let d = drag else { return }
                        var next = d.base
                        for i in min(d.start, current)...max(d.start, current) {
                            let id = cells[i].id
                            if d.on { next.insert(id) } else { next.remove(id) }
                        }
                        if next != selection { selection = next }
                        let edge: CGFloat = 60
                        if value.location.y > frames.viewportHeight - edge, current + 1 < cells.count {
                            proxy.scrollTo(cells[current + 1].id, anchor: .bottom)
                        } else if value.location.y < edge, current > 0 {
                            proxy.scrollTo(cells[current - 1].id, anchor: .top)
                        }
                    }
                    .onEnded { _ in drag = nil }
            )
    }

    /// Actions floating over the top of the list, each its own compact glass button
    /// (no shared container), icon + short single-line label. The row is centred on
    /// its current width, so it re-centres when "Clear Selection" comes and goes; a
    /// row wider than the screen (long languages) scrolls sideways instead.
    ///
    /// The toggles share one visual rule: the icon shows the CURRENT state — for
    /// thinking, plain while the rows show and struck through while they are hidden;
    /// for tools, compressed while folded and expanded while not — and the label
    /// names the action.
    private var floatingActions: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        selectAllBelow()
                    } label: {
                        floatingLabel(AppLocalized("Select Below"), systemImage: "arrow.down.to.line")
                    }
                    .modifier(ChatShareFloatingButtonSurface())
                    if request.foldedCells != nil {
                        // [T-share-fold-tools] The icon shows the current state
                        // (compressed while folded), the label names the action.
                        Button {
                            toggleFold()
                        } label: {
                            floatingLabel(foldTools ? AppLocalized("Expand Tools") : AppLocalized("Fold Tools"),
                                          systemImage: foldTools ? "rectangle.compress.vertical"
                                                                 : "rectangle.expand.vertical")
                        }
                        .modifier(ChatShareFloatingButtonSurface())
                        .accessibilityValue(foldTools ? AppLocalized("Folded") : AppLocalized("Expanded"))
                    }
                    Button {
                        hideThinking.toggle()
                        deselectHidden()
                    } label: {
                        floatingLabel(hideThinking ? AppLocalized("Show Thinking") : AppLocalized("Hide Thinking"),
                                      systemImage: "brain.head.profile", struck: hideThinking)
                    }
                    .modifier(ChatShareFloatingButtonSurface())
                    if !selection.isEmpty {
                        Button {
                            selection = []
                        } label: {
                            floatingLabel(AppLocalized("Clear Selection"), systemImage: "xmark")
                        }
                        .modifier(ChatShareFloatingButtonSurface())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                // At least as wide as the screen, contents centred: fits → centred on
                // the row's own width; wider → scrolls from the leading edge.
                .frame(minWidth: geo.size.width)
                .animation(.easeInOut(duration: 0.2), value: selection.isEmpty)
            }
        }
        .frame(height: 46)
        .padding(.top, 4)
    }

    /// A floating button's content. `struck` draws the same icon with a diagonal
    /// strike (a gap cut through the glyph, then a line — how SF Symbols' `.slash`
    /// variants look), for glyphs that have no system slash variant.
    private func floatingLabel(_ title: String, systemImage: String, struck: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .mask {
                    ZStack {
                        Rectangle()
                        if struck {
                            Capsule()
                                .frame(width: 4.5, height: 26)
                                .rotationEffect(.degrees(-45))
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }
                .overlay {
                    if struck {
                        Capsule()
                            .frame(width: 1.6, height: 20)
                            .rotationEffect(.degrees(-45))
                    }
                }
                .foregroundStyle(Color.accentColor)
            Text(title)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .contentShape(Capsule())
    }

    /// Everything from the first row on screen (under the floating buttons) down to
    /// the end — "from what I am looking at". It used to start at the first SELECTED
    /// row, which after scrolling up was the preselected round further down: all of
    /// that was already selected, so the tap changed nothing.
    private func selectAllBelow() {
        let visible = frames.byIndex
            .filter { $0.value.maxY > Self.floatingBarClearance && $0.value.minY < frames.viewportHeight }
            .map(\.key)
            .filter { cells.indices.contains($0) }
        guard let first = visible.min() ?? (cells.isEmpty ? nil : 0) else { return }
        selection = ChatShareCells.setBelow(cells[first].id, in: cells, selected: selection, on: true)
    }

    /// Height the floating buttons cover at the top of the list.
    private static let floatingBarClearance: CGFloat = 56

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

// MARK: - Preview + export

/// Opens straight into the rendered result: the long image is made as soon as the
/// sheet appears; switching format, the iPad-width layout or the appearance renders
/// that variant, and every render is kept so switching back is instant. The result is
/// shown at 1:1 — one point of the export per point of screen, the size it was drawn
/// at — and pinches down to fit. The toolbar's share button hands the current file to
/// the system share sheet.
private struct ChatSharePreviewSheet: View {
    let groups: [[ChatShareCell]]
    let count: Int
    let messages: [ChatMessage]
    let title: String
    let vm: AIChatViewModel

    private struct RenderKey: Hashable {
        let format: ChatExportOptions.Format
        let wideLayout: Bool
        let dark: Bool
        let adaptiveTables: Bool
        let hideHeader: Bool
    }

    private struct Rendered {
        let url: URL
        let scale: CGFloat
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var appScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("chatShare.format") private var formatRaw = ChatExportOptions.Format.image.rawValue
    /// [T-share-title-toggle] Render without the title header. It is an option of the
    /// rendered result, so it lives in this control strip beside width / tables /
    /// appearance - not in the picker, which only chooses messages.
    /// [T-share-opts-not-remembered] Not remembered, like width / tables / appearance:
    /// every share starts with the title shown.
    @State private var hideHeader = false
    /// Not remembered: tables start as in the chat, and the width at the device's own
    /// ([T-share-opts-not-remembered] iPad width on iPad / Mac, phone width on iPhone).
    @State private var wideLayout = ChatShareDefaults.wideLayoutForDevice
    @State private var adaptiveTables = false
    /// nil = follow the app's current appearance; set once the user picks one.
    @State private var darkChoice: Bool?
    /// [T-share-link-anchor-crash] The app appearance being followed, updated only while
    /// the scene is active (ChatShareAppearance) - not by background snapshot passes.
    @State private var followedDark: Bool?
    /// [T-share-link-anchor-crash] The last finished render the ShareLink offered; keeps
    /// the ShareLink (a presented share sheet's anchor) in place while a new one is made.
    @State private var lastShareURL: URL?
    @State private var rendered: [RenderKey: Rendered] = [:]
    @State private var progress: (done: Int, total: Int)?
    @State private var errorText: String?
    /// The render the progress overlay belongs to: a superseded render finishing its
    /// cancellation must not clear the progress of the one that replaced it.
    @State private var activeKey: RenderKey?
    /// Widths (phone / iPad) whose long image turned out too tall when rendered, in
    /// case the estimate below was low.
    @State private var imageFailedWidths: Set<Bool> = []
    private struct EstimateKey: Hashable {
        let wide: Bool
        let hideHeader: Bool
    }
    /// Per width and title on / off (both can change while the preview is open):
    /// whether the selection is estimated taller than a long image may be.
    private let estimatedTooTall: [EstimateKey: Bool]

    init(groups: [[ChatShareCell]], count: Int, messages: [ChatMessage], title: String,
         vm: AIChatViewModel) {
        self.groups = groups
        self.count = count
        self.messages = messages
        self.title = title
        self.vm = vm
        let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let inputs = ChatExportContent.estimateInputs(groups, messages: byId)
        var tooTall: [EstimateKey: Bool] = [:]
        for wide in [false, true] {
            for hidden in [false, true] {
                let points = ChatShareHeightEstimate.points(inputs, width: ChatExportRenderer.rowWidth(wide: wide),
                                                            includesHeader: !hidden)
                tooTall[EstimateKey(wide: wide, hideHeader: hidden)] = ChatShareHeightEstimate.tooTallForImage(points: points)
            }
        }
        estimatedTooTall = tooTall
    }

    private var dark: Bool { darkChoice ?? followedDark ?? (appScheme == .dark) }

    private func followAppAppearance() {
        followedDark = ChatShareAppearance.followed(previous: followedDark, appDark: appScheme == .dark,
                                                    sceneActive: scenePhase == .active)
    }

    /// Too long for one image at the current width: only a PDF is offered.
    private var imageUnavailable: Bool {
        (estimatedTooTall[EstimateKey(wide: wideLayout, hideHeader: hideHeader)] ?? false)
            || imageFailedWidths.contains(wideLayout)
    }

    private var format: ChatExportOptions.Format {
        imageUnavailable ? .pdf : (ChatExportOptions.Format(rawValue: formatRaw) ?? .image)
    }

    private var key: RenderKey {
        RenderKey(format: format, wideLayout: wideLayout, dark: dark, adaptiveTables: adaptiveTables,
                  hideHeader: hideHeader)
    }

    /// A photo-editor style control strip at the bottom — width, tables, appearance, title —
    /// one icon toggle per option,
    /// showing its current state (icon + short label), accent-coloured when it is on
    /// its non-default side. A tap flips it, re-renders, and a toast says what it
    /// switched to.
    private var controlBar: some View {
        VStack(spacing: 4) {
            // Each label is "dimension: current value", so a glance says what the
            // toggle controls, not just a bare "iPad" or "Adaptive".
            HStack(spacing: 0) {
                let widthLabel = String(format: AppLocalized("Width: %@"),
                                        wideLayout ? AppLocalized("iPad") : AppLocalized("iPhone"))
                controlItem(icon: wideLayout ? "ipad" : "iphone", label: widthLabel, active: wideLayout) {
                    wideLayout.toggle()
                    switched(to: String(format: AppLocalized("Width: %@"),
                                        wideLayout ? AppLocalized("iPad") : AppLocalized("iPhone")))
                }
                let tableLabel = String(format: AppLocalized("Table: %@"),
                                        adaptiveTables ? AppLocalized("Adaptive Width") : AppLocalized("Default Width"))
                controlItem(icon: adaptiveTables ? "arrow.left.and.right.square" : "tablecells",
                            label: tableLabel, active: adaptiveTables) {
                    adaptiveTables.toggle()
                    switched(to: String(format: AppLocalized("Table: %@"),
                                        adaptiveTables ? AppLocalized("Adaptive Width") : AppLocalized("Default Width")))
                }
                let appearanceLabel = String(format: AppLocalized("Appearance: %@"),
                                             dark ? AppLocalized("Dark") : AppLocalized("Light"))
                controlItem(icon: dark ? "moon.fill" : "sun.max", label: appearanceLabel, active: dark) {
                    darkChoice = !dark
                    switched(to: String(format: AppLocalized("Appearance: %@"),
                                        dark ? AppLocalized("Dark") : AppLocalized("Light")))
                }
                // [T-share-title-toggle] Accent-coloured on its non-default side (hidden),
                // like the others; the icon's header band disappears when it is off.
                let titleLabel = String(format: AppLocalized("Title: %@"),
                                        hideHeader ? AppLocalized("Hidden") : AppLocalized("Shown"))
                controlItem(icon: hideHeader ? "rectangle" : "rectangle.topthird.inset.filled",
                            label: titleLabel, active: hideHeader) {
                    hideHeader.toggle()
                    switched(to: String(format: AppLocalized("Title: %@"),
                                        hideHeader ? AppLocalized("Hidden") : AppLocalized("Shown")))
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func controlItem(icon: String, label: String, active: Bool, disabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(height: 26)
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1)
    }

    private func switched(to label: String) {
        MinisToast.show(String(format: AppLocalized("Switched to %@"), label))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    if let result = rendered[key] {
                        if key.format == .pdf {
                            ChatExportPDFPreview(url: result.url)
                        } else {
                            ChatExportImagePreview(url: result.url, scale: result.scale)
                        }
                    }
                    if let progress {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("\(AppLocalized("Creating…")) \(progress.done)/\(progress.total)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                    } else if let errorText, rendered[key] == nil {
                        Text(errorText).foregroundStyle(.red).padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .overlay(alignment: .top) {
                    ChatShareFormatSwitch(
                        format: format,
                        imageUnavailable: imageUnavailable,
                        onSelect: { formatRaw = $0.rawValue },
                        onBlockedImage: {
                            MinisToast.show(AppLocalized("Too long to stitch into one image."),
                                            systemImage: "info.circle.fill")
                        })
                    .padding(.top, 10)
                }
                Divider()
                controlBar
            }
            .navigationTitle(String(format: AppLocalized("Share (%lld)"), count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    // [T-share-link-anchor-crash] One ShareLink for the sheet's lifetime once
                    // anything is rendered: removing it under a presented share sheet traps
                    // in SwiftUI when the sheet re-anchors.
                    if let target = ChatShareLinkTarget.resolve(current: rendered[key]?.url, last: lastShareURL) {
                        ShareLink(item: target.url) { Image(systemName: "square.and.arrow.up") }
                            .disabled(!target.enabled)
                    }
                }
            }
            .task(id: key) { await render(key) }
            .onAppear {
                followAppAppearance()
                // [T-share-opts-not-remembered] Drop values earlier builds stored.
                ChatShareLegacyKeys.purge()
            }
            .onChange(of: appScheme) { _ in followAppAppearance() }
            .onChange(of: scenePhase) { _ in followAppAppearance() }
        }
    }

    private func render(_ key: RenderKey) async {
        guard rendered[key] == nil else { return }
        if rendered.isEmpty { ChatExportRenderer.clearExports() }
        errorText = nil
        activeKey = key
        progress = (0, groups.count)
        defer { if activeKey == key { progress = nil; activeKey = nil } }
        do {
            let renderer = try ChatExportRenderer(vm: vm)
            let options = ChatExportOptions(format: key.format, wideLayout: key.wideLayout, dark: key.dark,
                                            adaptiveTables: key.adaptiveTables, hideHeader: key.hideHeader)
            let result = try await renderer.render(groups: groups, messages: messages, title: title,
                                                   options: options) { done, total in
                if activeKey == key { progress = (done, total) }
            }
            rendered[key] = Rendered(url: result.url, scale: result.scale)
            lastShareURL = result.url
        } catch is CancellationError {
            logger.info("[ChatExport] superseded or cancelled")
        } catch ChatExportError.imageTooLarge {
            // The estimate was low: offer the PDF for this width instead.
            logger.info("[ChatExport] image too tall at wide=\(key.wideLayout) — switching to PDF")
            imageFailedWidths.insert(key.wideLayout)
        } catch {
            logger.error("[ChatExport] failed: \(error.localizedDescription)")
            errorText = error.localizedDescription
        }
    }
}

/// A long image at 1:1: loaded at its render scale so one image point is one screen
/// point, scrollable both ways, pinch out to fit the whole width, in to 4x.
private struct ChatExportImagePreview: UIViewRepresentable {
    let url: URL
    let scale: CGFloat

    func makeUIView(context: Context) -> ZoomView { ZoomView() }

    func updateUIView(_ view: ZoomView, context: Context) {
        guard view.loadedURL != url else { return }
        view.loadedURL = url
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: scale) else { return }
        view.show(image)
    }

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        var loadedURL: URL?
        private let imageView = UIImageView()
        private var needsInitialZoom = false
        /// The double-tap zoom-in factor, from the 1:1 starting size.
        private static let doubleTapScale: CGFloat = 2

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            addSubview(imageView)
            showsHorizontalScrollIndicator = true
            showsVerticalScrollIndicator = true
            decelerationRate = .fast
            // Insets are managed here (switch clearance, centring); no automatic ones.
            contentInsetAdjustmentBehavior = .never
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func show(_ image: UIImage) {
            zoomScale = 1
            imageView.image = image
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            needsInitialZoom = true
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = imageView.image, bounds.width > 0 else { return }
            minimumZoomScale = min(1, bounds.width / image.size.width)
            maximumZoomScale = 4
            if needsInitialZoom {
                needsInitialZoom = false
                zoomScale = 1
                center()
                contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            }
            center()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        /// Like Photos: at the original (1:1) size, zoom in 2x around the tapped point;
        /// at any other scale, go back to the original size.
        @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
            performDoubleTap(at: gesture.location(in: imageView))
        }

        /// `point` is in the image view's (unzoomed) coordinates.
        func performDoubleTap(at point: CGPoint) {
            guard imageView.image != nil else { return }
            if abs(zoomScale - 1) > 0.01 {
                setZoomScale(1, animated: true)
                return
            }
            let size = CGSize(width: bounds.width / Self.doubleTapScale, height: bounds.height / Self.doubleTapScale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }

        /// Centre content smaller than the view — horizontally, and vertically when an
        /// image is shorter than the visible area (a few messages) — and keep it below
        /// the floating format switch.
        private func center() {
            let dx = max(0, (bounds.width - contentSize.width) / 2)
            let clearance = ChatShareFormatSwitch.clearance
            let free = bounds.height - contentSize.height
            let top = max(clearance, free / 2)
            let bottom = max(0, free - top)
            contentInset = UIEdgeInsets(top: top, left: dx, bottom: bottom, right: dx)
        }
    }
}

/// A PDF at 1:1 (one PDF point per screen point), pages stacked, pinch to fit or zoom;
/// double-tap zooms in 2x around the tap and back, like the image preview.
private struct ChatExportPDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.backgroundColor = .secondarySystemBackground
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        context.coordinator.pdfView = view
        context.coordinator.doubleTap = doubleTap
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
        DispatchQueue.main.async {
            view.minScaleFactor = min(view.scaleFactorForSizeToFit, 1)
            view.maxScaleFactor = 4
            view.scaleFactor = 1
            if let first = view.document?.page(at: 0) { view.go(to: first) }
            // Start the first page below the floating format switch.
            if let scroll = view.subviews.compactMap({ $0 as? UIScrollView }).first {
                scroll.contentInset.top = ChatShareFormatSwitch.clearance
                scroll.contentOffset.y = -ChatShareFormatSwitch.clearance
            }
            context.coordinator.yieldBuiltInDoubleTaps(in: view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        weak var doubleTap: UITapGestureRecognizer?

        /// PDFView's own double tap selects a word; make it wait for (and so lose
        /// to) the zoom double tap.
        func yieldBuiltInDoubleTaps(in root: UIView) {
            guard let doubleTap else { return }
            func walk(_ v: UIView) {
                for g in v.gestureRecognizers ?? [] where g !== doubleTap {
                    if let tap = g as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 {
                        tap.require(toFail: doubleTap)
                    }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = pdfView else { return }
            performDoubleTap(at: gesture.location(in: view))
        }

        /// `point` is in the PDF view's coordinates.
        func performDoubleTap(at point: CGPoint) {
            guard let view = pdfView else { return }
            if abs(view.scaleFactor - 1) > 0.01 {
                UIView.animate(withDuration: 0.25) { view.scaleFactor = 1 }
                return
            }
            guard let page = view.page(for: point, nearest: true) else { return }
            let pagePoint = view.convert(point, to: page)
            UIView.animate(withDuration: 0.25) { view.scaleFactor = 2 }
            // Keep the tapped spot in view after the zoom.
            view.go(to: CGRect(x: pagePoint.x - 40, y: pagePoint.y - 40, width: 80, height: 80), on: page)
        }
    }
}

/// One floating picker button's surface. iOS 26: interactive Liquid Glass, like the
/// chat's other floating controls. Earlier: an ultra-thin material capsule with a
/// hairline and a soft shadow — the same light, see-through weight, so the pair reads
/// as floating over the chat rather than as two filled buttons.
private struct ChatShareFloatingButtonSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 6, y: 2)
        }
    }
}

/// The preview's floating "Long Image | PDF" switch: a glass capsule with a sliding
/// selection pill, switched by tapping a segment or swiping across the control. When
/// the selection is too long for one image, "Long Image" is dimmed and a tap on it only
/// explains why.
private struct ChatShareFormatSwitch: View {
    let format: ChatExportOptions.Format
    let imageUnavailable: Bool
    let onSelect: (ChatExportOptions.Format) -> Void
    let onBlockedImage: () -> Void
    @Namespace private var pill

    /// Room the previews leave above their content so the switch (10pt from the top,
    /// ~38pt tall) covers nothing until the user scrolls.
    static let clearance: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            segment(.image, title: AppLocalized("Long Image"), icon: "photo")
            segment(.pdf, title: AppLocalized("PDF"), icon: "doc.richtext")
        }
        .padding(3)
        .modifier(ChatShareFloatingButtonSurface())
        // Swipe across the control: left → the right segment (PDF), right → Long Image.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.width < -20 { select(.pdf) }
                    if value.translation.width > 20 { select(.image) }
                }
        )
    }

    private func segment(_ value: ChatExportOptions.Format, title: String, icon: String) -> some View {
        let isOn = format == value
        let blocked = value == .image && imageUnavailable
        return Button {
            select(value)
        } label: {
            Label(title, systemImage: icon)
                .font(.footnote.weight(isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if isOn {
                        Capsule()
                            .fill(Color(uiColor: .systemBackground).opacity(0.9))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(blocked ? 0.35 : 1)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func select(_ value: ChatExportOptions.Format) {
        if value == .image && imageUnavailable {
            onBlockedImage()
            return
        }
        guard value != format else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { onSelect(value) }
    }
}

/// [T-share-opts-not-remembered] Starting values of the share preview's options that
/// depend on the device. Nothing here is stored.
enum ChatShareDefaults {
    /// iPad and Mac start at iPad width, iPhone at phone width.
    static var wideLayoutForDevice: Bool {
        let idiom = UIDevice.current.userInterfaceIdiom
        return idiom == .pad || idiom == .mac
    }
}
