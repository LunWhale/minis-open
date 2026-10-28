//
//  SelectableMarkdownView.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Bridge - the module's entry point.
//
//  SelectableMarkdownView is the SwiftUI view chat cells use to show a
//  markdown text block: it owns a SelectableMarkdownTextView, feeds it the
//  attributed string, and reports its height to SwiftUI.
//
//  Module map
//  ==========
//
//  Data flow for one text block:
//
//    markdown String
//      -> MinisMarkdownParser (Agent/Markdown)      [BlockNode] / [InlineNode]
//      -> MarkdownNSRenderer (Rendering/)           NSAttributedString with
//                                                   NSTextAttachments
//      -> SelectableMarkdownTextView (TextKit/)     UITextView; puts a UIView
//                                                   over every attachment
//      -> SelectableMarkdownView (Bridge/)          UIViewRepresentable
//
//  Layers - dependencies point down this list:
//
//    Bridge/       SelectableMarkdownView, +Sizing, +Coordinator,
//                  +WatchdogProbe (DEBUG)
//    TextKit/      SelectableMarkdownTextView (core + 6 extension files),
//                  MinisLayoutManager, SelectionTextExpander
//    Attachments/  CodeBlock, Math, Image, Video, Audio, ThematicBreak,
//                  Table/ (TableAttachment, TableLayoutPlanning,
//                  TableScrollView, TableCellViews)
//    Rendering/    MarkdownNSRenderer
//    Media/        NativeMediaImageCache (+ downsampling helpers),
//                  MediaPreviewPresentation (tap -> full-screen preview)
//    Support/      MarkdownTheme, MarkdownLoggers, MinisLinkResolution,
//                  MarkdownUIKitHelpers, MinisToast (app-wide)
//
//  Edges that go against that order - do not add more:
//    - TextKit -> Bridge: the text view casts its delegate to
//      SelectableMarkdownView.Coordinator to reach the renderer and message id.
//    - No shared attachment protocol yet: the text view (+AttachmentViews,
//      +CellSizing), SelectionTextExpander and the bridge check for concrete
//      attachment classes.
//    - App state: table-cell read aloud uses the voice player and chat view
//      model; minis:// resolution reads the active session id.
//
//  Adding an attachment kind touches:
//    1. Attachments/<Kind>Attachment.swift - NSTextAttachment subclass with
//       attachmentBounds(...) and makeView(width:).
//    2. MarkdownNSRenderer - create it; cache it per renderer if it is costly,
//       like the existing attachment caches.
//    3. SelectableMarkdownTextView+AttachmentViews - create and place its view.
//    4. SelectableMarkdownTextView+CellSizing - if it can change size in
//       place, fold a generation counter into the cell-size fingerprint and the
//       async-render signal.
//    5. SelectionTextExpander - give it a text form, or copy drops it.
//
//  History and conventions
//  =======================
//
//  Until the split this module was a single ~10k-line file,
//  Views/Chat/SelectableMarkdownView.swift. The code was moved verbatim. Apart
//  from location, the only differences are:
//    - every file repeats the original file's import list, so name lookup is
//      unchanged (trim per file when convenient);
//    - declarations used from another file lost `private` / `fileprivate`.
//      They are module-internal now; treat them as private to this module;
//    - SelectableMarkdownTextView keeps all stored properties in its class
//      body (extensions cannot store), in their original order;
//    - extension files wrap their members in `extension <Type> { ... }`.
//  Large types are split into `Type+Concern.swift` extensions. New code goes
//  into the file whose concern it belongs to, not back into a catch-all.
//  Source-scanning tests (MinisTests/Standalone) read every file under
//  Views/Chat/Markdown/, so code can move between these files freely.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - SelectableMarkdownView (UIViewRepresentable)

/// SwiftUI wrapper for the UITextView-based selectable Markdown renderer.
struct SelectableMarkdownView: UIViewRepresentable {
    let markdown: String
    var cachedContent: MarkdownContent?
    var cachedAttributedString: NSAttributedString?
    /// Optional owning assistant message id. When set, inline image tap
    /// gestures route to a paged gallery of all markdown-embedded images in
    /// that message. Leave nil for standalone markdown rendering.
    var messageId: UUID?
    /// Optional block identity for table slot-cache keying. In V3
    /// cell-per-block, each AssistantBlock has its own UUID — using it as
    /// the slot key guarantees uniqueness even when two tables in the same
    /// message have identical content.
    var blockId: UUID?
    /// Called when the user taps a blank (non-link, non-code) area of the text view.
    /// The CGPoint is the tap location in **window coordinates**.
    var onTapBlank: ((CGPoint) -> Void)?
    /// [#414] Gate for `onTapBlank` - see SelectableMarkdownTextView.blankTapEligible.
    var blankTapEligible: (() -> Bool)? = nil
    /// Called when the user picks "Share…" from the text selection menu.
    var onShareMessages: (() -> Void)?
    /// [T-selection-menu-minis-tts] "Read from Start" (whole reply) via Minis TTS.
    var onReadAloud: (() -> Void)?
    /// [T-selection-menu-minis-tts] "Read Selection" (selected text) via Minis TTS.
    var onSpeakText: ((String) -> Void)?
    @Environment(\.openURL) private var openURL
    /// [T-in-chat-search] Search highlights of the chat this block belongs to
    /// (nil outside the message list) and whether the row is dimmed.
    @Environment(\.chatSearchHighlights) private var searchHighlights
    @Environment(\.chatSearchDimmed) private var searchDimmed

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator()
        // [TableIdentityFix] When the same messageId remounts a fresh
        // Coordinator (cell reuse / SwiftUI body re-evaluation), hand the
        // new Coordinator the previously-cached renderer for that message.
        // Without this every cell reuse produces a fresh renderer →
        // fresh TableAttachment objects → layoutManager sees attachments
        // with no identity continuity and keeps the early-stream glyph
        // rects cached.
        if let mid = messageId, let existing = SelectableMarkdownView.rendererCache[mid] {
            coord.renderer = existing
            SelectableMarkdownView.touchRenderer(mid)
        } else if let mid = messageId {
            SelectableMarkdownView.rendererCache[mid] = coord.renderer
            SelectableMarkdownView.touchRenderer(mid)
        }
        return coord
    }

    /// [TableIdentityFix] Per-message renderer cache: keyed by `messageId`,
    /// kept across Coordinator recreations so TableAttachment identity (and
    /// the streaming `update(...)` path) survives SwiftUI body re-evaluations
    /// / cell reuses that throw away the previous Coordinator. Without this
    /// we observed up to 6 distinct Coordinators (each with its own renderer
    /// + fresh attachments) inside a single streaming response — every
    /// throwaway one writing new attachments into textStorage and leaving
    /// the layout manager with stale glyph rects for the early small-table
    /// state. The cache uses a regular dictionary because the keys are
    /// stable across the chat session and entries are cheap; in practice
    /// it grows at the rate of unique assistant messages in the live chat.
    /// [T-renderer-cache-bounded] It used to be exactly that — an unbounded
    /// dictionary with no removal path anywhere in the app. "Entries are cheap"
    /// held per entry, but the map is keyed by MESSAGE id and lives on the
    /// type, so it was reclaimed by nothing: not by leaving a chat, not by
    /// ViewModelCache eviction (which is keyed by session), not by a memory
    /// warning. Every assistant message rendered since launch kept its
    /// renderer, and with it the attachments and layout it had built.
    ///
    /// Now bounded by an LRU cap, and drained explicitly on the three
    /// occasions the owner disappears: a message goes away, a session's VM is
    /// released, or the system asks for memory back.
    @MainActor private static var rendererCache: [UUID: MarkdownNSRenderer] = [:]

    /// LRU order for `rendererCache`, oldest first.
    @MainActor private static var rendererLRU: [UUID] = []

    /// Renderers kept resident. Sized for "a long conversation the user is
    /// actively scrolling" — well past a screenful so scrolling back never
    /// re-parses, but far below the unbounded growth this replaces.
    @MainActor private static let rendererCacheCap = 80

    /// [T-scroll-first-build-once] The renderer a coordinator for `messageId`
    /// adopts in `makeCoordinator`, created and cached here if there is none
    /// yet, so a height computed before the row is displayed renders through
    /// the same renderer (and its table cache) the display will use.
    @MainActor
    static func sharedRenderer(for messageId: UUID) -> MarkdownNSRenderer {
        if let existing = rendererCache[messageId] {
            touchRenderer(messageId)
            return existing
        }
        let renderer = Coordinator().renderer
        rendererCache[messageId] = renderer
        touchRenderer(messageId)
        return renderer
    }

    /// Record a renderer as most-recently-used and trim the tail.
    @MainActor
    private static func touchRenderer(_ id: UUID) {
        if let i = rendererLRU.firstIndex(of: id) { rendererLRU.remove(at: i) }
        rendererLRU.append(id)
        while rendererLRU.count > rendererCacheCap, let oldest = rendererLRU.first {
            rendererLRU.removeFirst()
            rendererCache.removeValue(forKey: oldest)
        }
    }

    /// Drop one message's renderer. Safe to call for an id that was never
    /// cached. Called from `AIChatViewModel.releaseRenderState`.
    ///
    /// Dropping is always safe: the renderer is a CACHE. The next render for
    /// this message simply builds a fresh one — which is the same thing that
    /// happens today for any message that was never rendered. What the cache
    /// buys is attachment identity ACROSS coordinator recreations within one
    /// live message; a message whose VM has been released is not live.
    @MainActor
    static func dropRenderer(for messageId: UUID) {
        guard rendererCache.removeValue(forKey: messageId) != nil else { return }
        if let i = rendererLRU.firstIndex(of: messageId) { rendererLRU.remove(at: i) }
    }

    /// Drop every cached renderer. Wired to the same memory-warning hook
    /// ViewModelCache / BrowserTabPool / ThumbnailCache already use.
    @MainActor
    static func dropAllRenderers() -> Int {
        let n = rendererCache.count
        rendererCache.removeAll()
        rendererLRU.removeAll()
        return n
    }

    func makeUIView(context: Context) -> SelectableMarkdownTextView {
        let textView = SelectableMarkdownTextView()
        textView.delegate = context.coordinator
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        context.coordinator.lastMarkdown = ""
        context.coordinator.openURL = openURL
        textView.onTapBlank = onTapBlank
        textView.blankTapEligible = blankTapEligible
        textView.onShareMessages = onShareMessages
        textView.onReadAloud = onReadAloud
        textView.onSpeakText = onSpeakText
        // [T-in-chat-search] "Search in Chat" in the selection menu, offered
        // only where the chat page has a search bar to open.
        textView.onSearchInChat = searchHighlights?.openSearch
        #if DEBUG
        // [T-ios-markdown-rerender-burst] makeUIView creates a FRESH textView +
        // resets lastMarkdown="", forcing the next updateUIView through a full
        // re-render (the markdown != lastMarkdown dedup can never hit on a brand
        // new view). Log rnd (coordinator's renderer id) so we can count
        // makeUIView churn against the [RND] burst — same rnd across many
        // [MK-VIEW] => SwiftUI is re-creating the view for a reused coordinator.
        let rId = String(ObjectIdentifier(context.coordinator.renderer).hashValue & 0xFFFFFF, radix: 16)
        AppLogger(category: "MarkdownRenderer").info("[MK-VIEW] new textView rnd=\(rId)")
        // [T-scroll-cell-build-diag] Which coordinator / text view is built for
        // which block: two per block on scroll-in means the row is built twice.
        if ScrollMetricsRecorder.shared.isEnabled {
            ScrollMetricsRecorder.shared.record(kind: "mkv", key: Self.diagId(textView),
                note: "coord=\(Self.diagId(context.coordinator)) mid=\(messageId.map { String($0.uuidString.prefix(8)) } ?? "-") blk=\(blockId.map { String($0.uuidString.prefix(8)) } ?? "-") len=\(markdown.count)")
        }
        #endif
        return textView
    }

    #if DEBUG
    static func diagId(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFFFF, radix: 16)
    }

    static func dismantleUIView(_ uiView: SelectableMarkdownTextView, coordinator: Coordinator) {
        if ScrollMetricsRecorder.shared.isEnabled {
            ScrollMetricsRecorder.shared.record(kind: "dsm", a: uiView.window == nil ? 0 : 1, key: diagId(uiView),
                note: "coord=\(diagId(coordinator))")
        }
    }

    #endif

    func updateUIView(_ textView: SelectableMarkdownTextView, context: Context) {
        let updateStart = CFAbsoluteTimeGetCurrent()
        context.coordinator.openURL = openURL
        textView.onTapBlank = onTapBlank
        textView.blankTapEligible = blankTapEligible
        textView.onShareMessages = onShareMessages
        textView.onReadAloud = onReadAloud
        textView.onSpeakText = onSpeakText
        // [T-in-chat-search] "Search in Chat" in the selection menu, offered
        // only where the chat page has a search bar to open.
        textView.onSearchInChat = searchHighlights?.openSearch
        // [T-in-chat-search] Bound before any early return below: the block's
        // highlight must follow the view even when its text is unchanged.
        textView.bindSearchHighlight(
            center: searchHighlights,
            key: messageId.flatMap { mid in blockId.map { ChatSearchUnitKey(messageId: mid, blockId: $0, field: .body) } },
            dimmed: searchDimmed)

        let currentFontSize = FontSettings.shared.scaledMessage(16.5)
        let fontChanged = context.coordinator.lastFontSize != currentFontSize

        // [AttachHotPath] updateUIView entry — only log when this textView has
        // image attachments in its renderer's cache (the only scenario that can
        // trigger the streaming + image re-layout problem). Skips noise from
        // pure-text blocks.
        let imgCacheN = context.coordinator.renderer.imageAttachmentCache.count
        if imgCacheN > 0 {
            let prevLen = context.coordinator.lastMarkdown.count
            let curLen = markdown.count
            let isAppend = curLen > prevLen && markdown.hasPrefix(context.coordinator.lastMarkdown)
            AppLogger(category: "AttachHotPath").info("[UPD] entry imgCache=\(imgCacheN) prevLen=\(prevLen) curLen=\(curLen) Δ\(curLen - prevLen) appendOnly=\(isAppend ? 1 : 0) fontChanged=\(fontChanged ? 1 : 0)")
        }

        // [RotationTableFix] Detect (markdown unchanged + width changed) — the
        // rotation path. SwiftUI calls updateUIView with the textView already
        // at the new textContainer width, but `markdown` is unchanged so the
        // guard below early-returns. Without this branch the TableAttachment
        // cachedLayout never invalidates and the rendered table sticks at the
        // old portrait column widths. We invalidate just the attachment caches
        // (not a full re-render) so the next layout pass asks for fresh
        // `attachmentBounds` at the new width and makeView rebuilds the
        // SelectableTableView with the new columns.
        let _curW = textView.textContainer.size.width
        let _prevW = context.coordinator.lastRenderedWidth
        let _widthChanged = _curW > 1 && _prevW > 1 && abs(_curW - _prevW) > 0.5
        if _widthChanged && markdown == context.coordinator.lastMarkdown && !fontChanged {
            // [WordFade] Width change (rotation) re-lays-out everything; snap
            // any mid-fade words to full opacity so none stick translucent.
            context.coordinator.fadeAnimator.cancelAll()
            if let storage = textView.textStorage as? NSTextStorage, storage.length > 0 {
                var ranges: [NSRange] = []
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
                    if let table = value as? TableAttachment {
                        table.invalidateCachedLayoutForWidthChange()
                        ranges.append(range)
                    }
                }
                if !ranges.isEmpty, let lm = textView.layoutManager as? MinisLayoutManager {
                    for r in ranges {
                        lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
                    }
                }
            }
            context.coordinator.cachedSizes.removeAll(keepingCapacity: true)
            textView.updateAttachmentViews()
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
            textView.invalidateCellSizeIfNeeded()
        }
        if _curW > 1 {
            context.coordinator.lastRenderedWidth = _curW
        }
        guard markdown != context.coordinator.lastMarkdown || fontChanged else {
            let shouldRecover = textView.window != nil
                && textView.needsAttachmentRecovery
                && !textView.hasScheduledRecoveryForCurrentContent

            if shouldRecover {
                textView.hasScheduledRecoveryForCurrentContent = true
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.window != nil else { return }
                    textView.updateAttachmentViews()
                    textView.invalidateIntrinsicContentSize()
                    textView.setNeedsDisplay()
                    textView.setNeedsLayout()
                }
            }
            // [DIAG-RENDER-1] markdown matches lastMarkdown — no re-render.
            // If the cell appears empty, it means the PREVIOUS updateUIView call
            // set lastMarkdown but didn't actually render the text (e.g. was skipped
            // due to background state, or attributedText was empty/truncated).
            if !markdown.isEmpty && (textView.attributedText?.length ?? 0) == 0 {
                AppLogger(category: "StreamDiag").info("[RENDER] ⚠️ EMPTY-DESPITE-MATCH markdown len=\(markdown.count) lastMarkdown len=\(context.coordinator.lastMarkdown.count) attrText len=\(textView.attributedText?.length ?? 0) window=\(textView.window != nil) — CELL APPEARS EMPTY")
            }
            return
        }

        // [DIAG-RENDER-2] Three paths based on application state:
        //   .background                   → defer (always; final streaming
        //                                   frame would otherwise be blank
        //                                   until SwiftUI re-evaluates)
        //   .inactive ≥ 30s               → defer (long-running .inactive is
        //                                   indistinguishable from background
        //                                   for watchdog purposes — commit
        //                                   e6efac23 fixed crashes here)
        //   .inactive < 30s               → render normally (control center
        //                                   swipe, incoming call banner,
        //                                   app-switcher peek — short enough
        //                                   that the scene-transition
        //                                   watchdog window has settled)
        //   .active                       → render normally (falls through)
        //
        // Deferred frames are stashed on the coordinator and replayed by the
        // didBecomeActive observer once applicationState is genuinely
        // `.active` again, so the expensive setAttributedText + ensureLayout
        // pass never runs while the watchdog is timing.
        let appState = UIApplication.shared.applicationState
        let inactiveDuration: TimeInterval = appState == .inactive
            ? (context.coordinator.inactiveEnteredAt.map { Date().timeIntervalSince($0) } ?? 0)
            : 0
        let shouldDefer: Bool = {
            switch appState {
            case .background: return true
            case .inactive: return inactiveDuration >= 30.0
            default: return false
            }
        }()
        if shouldDefer {
            context.coordinator.deferRender(markdown) { [weak textView] in
                guard let textView else { return }
                // Defeat the content-hash skip so the deferred frame actually
                // re-renders even if an intervening pass set the same hash.
                context.coordinator.lastRenderedContentHash = nil
                self.updateUIView(textView, context: context)
            }
            return
        }
        let oldMarkdown = context.coordinator.lastMarkdown
        context.coordinator.lastMarkdown = markdown

        if fontChanged {
            context.coordinator.renderer.updateFontSize(currentFontSize)
            context.coordinator.lastFontSize = currentFontSize
            context.coordinator.lastRenderedContentHash = nil
            // Math images are rendered at a specific font size — clear stale caches.
            context.coordinator.renderer.mathAttachmentCache.removeAll()
            textView.clearAllAttachmentViews()
        }

        // [T-ios-reuse-cachewipe] Identity of what we are about to render.
        // Prefer `blockId` — under V3 cell-per-block a single message spans
        // many text views, so `messageId` alone would report "same content"
        // for two different blocks of one message.
        let contentId = blockId ?? messageId
        let previousContentId = context.coordinator.lastContentId
        context.coordinator.lastContentId = contentId
        // True only when this view is being recycled onto DIFFERENT content.
        // `previousContentId == nil` is a first render, not a reuse.
        let isDifferentContent = contentId != nil
            && previousContentId != nil
            && contentId != previousContentId

        // [T-ios-reuse-cachewipe] `isNewMessage` is a misnomer: it only asks
        // whether the new text is a prefix-extension of the old. That is a
        // sound "content was rewritten" test DURING STREAMING, but it is also
        // trivially true whenever a cell is recycled onto an unrelated message
        // — and recycling is exactly what a large jump (the "previous turn"
        // button) produces en masse.
        //
        // Field evidence (2026-08-13, three separate reports): 9 rapid
        // prevUserTurn taps traversed ~58,000pt; each one recycled cells and
        // tripped this branch, so `oldLen/newLen` jumped between the lengths
        // of entirely different messages (3998→1702, 3866→4014). Every hit
        // dropped the math cache and tore down every attachment view, so all
        // the LaTeX in the newly-shown message had to re-render
        // asynchronously; each completion called back into
        // `updateAttachmentViews + invalidateCellSize`, producing 57
        // FIRST-MEASURE CORRECTIONs oscillating 7733↔8066 without converging.
        // Screenshots caught the midpoint: text laid out for not-yet-rendered
        // formulas while tool-card / table / code-block attachment views still
        // sat at their pre-teardown coordinates — the "collapse".
        //
        // So only take the destructive path for a genuine same-content
        // rewrite. A recycled view gets the rebuild path below instead, which
        // reuses the prebuilt attributed string and lays out synchronously.
        let isContentRewrite = !oldMarkdown.isEmpty
            && !markdown.hasPrefix(oldMarkdown)
            && !isDifferentContent
        if isDifferentContent {
            // Recycled onto different content. The caches are keyed per
            // message/block and the incoming content brings its own, so the
            // previous occupant's attachment VIEWS must go — but we must not
            // strand the text in a laid-out-without-attachments state the way
            // the wipe branch did. `clearAllAttachmentViews` is paired with a
            // synchronous re-layout below (the `cachedAttributedString` fast
            // path), so the very first frame this view presents already has
            // its attachments positioned.
            //
            // Deliberately NOT cleared: the renderer's per-content caches
            // (image/video/audio/code/math). They are keyed by content hash,
            // so the incoming block simply misses them and renders its own;
            // wiping them would throw away entries the PREVIOUS occupant will
            // want the moment it scrolls back into view — that repeated
            // discard-and-re-render is what drove the burst.
            context.coordinator.fadeAnimator.cancelAll()
            textView.clearAllAttachmentViews()
            // Force the render below to actually run: the incoming content may
            // hash-collide with whatever this view last drew.
            context.coordinator.lastRenderedContentHash = nil
        }
        if isContentRewrite {
            // [WordFade] The storage is about to be rebuilt from scratch; any
            // in-flight fade ranges are stale. Drop them before the rewrite.
            context.coordinator.fadeAnimator.cancelAll()
            // [AttachHotPath] If this fires DURING streaming (i.e. between
            // tokens of the same message), it means markdown.hasPrefix(oldMarkdown)
            // returned false despite being the same message — every
            // ImageAttachment is destroyed and recreated on the next render,
            // ObjectIdentifier changes, and updateAttachmentViews rebuilds
            // every UIImageView. This is the smoking gun if it appears in
            // the streaming log stream.
            let imgN = context.coordinator.renderer.imageAttachmentCache.count
            let vidN = context.coordinator.renderer.videoAttachmentCache.count
            let audN = context.coordinator.renderer.audioAttachmentCache.count
            let codeN = context.coordinator.renderer.codeBlockAttachmentCache.count
            let tailOld = String(oldMarkdown.suffix(40)).replacingOccurrences(of: "\n", with: "⏎")
            let headNew = String(markdown.prefix(40)).replacingOccurrences(of: "\n", with: "⏎")
            // [T-ios-reuse-cachewipe] `sameId=true` is the invariant this
            // branch now guarantees: a wipe may only happen for content that
            // kept its identity. A cross-message oldLen/newLen jump here
            // means the identity check regressed.
            let idStr = contentId?.uuidString.prefix(8) ?? "nil"
            AppLogger(category: "AttachHotPath").info("[CACHE-WIPE] contentRewrite id=\(idStr) sameId=true — clearing img=\(imgN) vid=\(vidN) aud=\(audN) code=\(codeN) oldLen=\(oldMarkdown.count) newLen=\(markdown.count) oldTail=\"\(tailOld)\" newHead=\"\(headNew)\"")
            let renderer = context.coordinator.renderer
            renderer.imageAttachmentCache.removeAll()
            renderer.videoAttachmentCache.removeAll()
            renderer.audioAttachmentCache.removeAll()
            renderer.codeBlockAttachmentCache.removeAll()
            renderer.codeBlockContentHashes.removeAll()
            // HangFix(2026-05-14) — DO NOT wipe tableAttachmentCache /
            // tableAttachmentLRU. They are keyed by contentHash with a
            // 64-entry LRU bound; identical tables across messages
            // legitimately share the same TableAttachment instance (and
            // its precomputed `cachedLayout`), which is the only thing
            // that prevents a 6-table cell from costing seconds inside
            // `attachmentBounds` on every typesetter pass.
            renderer.mathAttachmentCache.removeAll()
            textView.clearAllAttachmentViews()
        }

        let prepStart = CFAbsoluteTimeGetCurrent()
        // REPRO-FIX(2026-05-16): split off in-flight table tail before
        // markdown parsing. The plain suffix is appended below after
        // markdown rendering completes; it bypasses cmark entirely so no
        // inline syntax (`*`, `**`, `` ` ``, `_`) inside the partial
        // table cells is parsed during streaming.
        //
        // Don't split once the message has finished streaming — the
        // presence of either a prebuilt `cachedAttributedString` or a
        // prebuilt `cachedContent` is the finalised-message signal sent
        // by `AIChatViewModel.cacheAttributedString(for:)`. After that
        // point cmark must see the full markdown so a trailing
        // un-terminated `|...|` final row (no trailing `\n`) is still
        // rendered as a real table row.
        let _isFinalised = cachedAttributedString != nil || cachedContent != nil
        let _splitForUpdate = _isFinalised ? (prefix: markdown, plainSuffix: "") : splitStreamingTableTail(markdown)
        let _hasPlainSuffix = !_splitForUpdate.plainSuffix.isEmpty
        let prepared = prepareMarkdownForRender(_splitForUpdate.prefix)
        // If we split off a suffix, the prebuilt cache (which was rendered
        // from the full markdown) no longer matches what we'll render —
        // force a fresh MarkdownContent parse and skip cachedContent.
        let content = (_hasPlainSuffix ? nil : cachedContent) ?? MarkdownContent(prepared)
        let prepElapsed = (CFAbsoluteTimeGetCurrent() - prepStart) * 1000
        // Image-related diagnostics — only walk the parsed block tree when
        // the raw markdown actually contains image syntax. The block walk
        // is O(N) over every node in every block, which on long messages
        // becomes a measurable chunk of every updateUIView pass (and
        // updateUIView runs on each SwiftUI body re-evaluation, so it
        // multiplies during streaming and self-sizing measurement loops).
        let imageMatches = markdown.ranges(of: /!\[([^\]]*)\]\(([^)]+)\)/)
        if !imageMatches.isEmpty {
            for match in imageMatches {
                let matchStr = String(markdown[match])
                imgLogger.info("[MinisImage][StreamParse] image markdown found: \(matchStr)")
            }
            let imageBlockCount = content.blocks.flatMap { Self.collectImageNodes(from: $0) }.count
            if imageBlockCount > 0 {
                imgLogger.info("[MinisImage][StreamParse] parsed \(imageBlockCount) image node(s) from \(content.blocks.count) block(s), markdownLen=\(markdown.count)")
            }
        }

        var hasher = Hasher()
        hasher.combine(cachedContent != nil ? cachedContent!.blocks.hashValue : markdown.hashValue)
        hasher.combine(FontSettings.shared.scaledMessage(16.5))
        let contentHash: Int = hasher.finalize()
        if contentHash == context.coordinator.lastRenderedContentHash {
            // [DIAG-RENDER-3] Content hash matches — skip re-render.
            // If text was already set correctly, this is fine. But if
            // attributedText is empty despite matching hash, we have a bug.
            if !markdown.isEmpty && (textView.attributedText?.length ?? 0) == 0 {
                AppLogger(category: "StreamDiag").info("[RENDER] ⚠️ HASH-MATCH-BUT-EMPTY markdown len=\(markdown.count) hash=\(contentHash) attrText len=0 — SKIPPING RENDER OF NON-EMPTY CONTENT")
            }
            if textView.textContainer.size.width > 1 {
                textView.updateAttachmentViews()
            }
            return
        }
        #if DEBUG
        // [T-ios-markdown-rerender-burst] Hash MISS — log why so we can tell if
        // the content hash is genuinely changing each updateUIView (unstable
        // hash input) vs lastRenderedContentHash being reset between calls.
        // Gated to non-streaming messages with prebuilt cache so it only fires
        // on the scroll-rerender case, not live streaming.
        if cachedContent != nil || cachedAttributedString != nil {
            let prev = context.coordinator.lastRenderedContentHash
            let usingBlocks = cachedContent != nil
            AppLogger(category: "MarkdownRenderer").info("[RND-MISS] hash=\(contentHash) prev=\(prev.map(String.init) ?? "nil") src=\(usingBlocks ? "blocks" : "markdown") hasPlainSuffix=\(_hasPlainSuffix) fontChanged=\(fontChanged) mdLen=\(markdown.count)")
        }
        #endif
        context.coordinator.lastRenderedContentHash = contentHash

        let renderStart = CFAbsoluteTimeGetCurrent()
        let renderer = context.coordinator.renderer
        let attributed: NSAttributedString
        let usedCache: Bool
        // [TablePathFix] When the prebuilt attributed string contains a
        // TableAttachment we must NOT use it — the cached path comes from
        // `AIChatViewModel.cacheAttributedString(for:)` which uses a fresh
        // `MarkdownNSRenderer` each call and therefore creates a *new*
        // TableAttachment object every flush. During streaming this
        // detaches the live attachments from the coordinator's
        // `tableAttachmentCache` (which is what `update()` mutates with
        // proper `contentGeneration` bumps and `cachedLayout = nil` resets).
        // The visible symptom is the "table rendered as a single column"
        // / "stale layout cached for old probe width" case logged via
        // [TableDiag]. Falling through to `coord.renderer.render` preserves
        // TableAttachment object identity across renders, so `update()`
        // works as intended and the layout manager sees the correct bounds.
        let prebuiltHasTable: Bool = {
            guard let prebuilt = cachedAttributedString, prebuilt.length > 0 else { return false }
            var found = false
            prebuilt.enumerateAttribute(.attachment, in: NSRange(location: 0, length: prebuilt.length), options: []) { value, _, stop in
                if value is TableAttachment {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }()
        // REPRO-FIX(2026-05-16): when we split off an in-flight plain
        // suffix above, the prebuilt cache covers the wrong content —
        // bypass it and re-render so the appended suffix lives in the
        // current view's storage (the prebuilt was for the full markdown).
        if let prebuilt = cachedAttributedString, !fontChanged, !prebuiltHasTable, !_hasPlainSuffix {
            attributed = prebuilt
            usedCache = true
        } else {
            renderer.messageId = messageId
            renderer.blockId = blockId
            let renderedBody = autoreleasepool {
                renderer.render(blocks: content.blocks)
            }
            if _hasPlainSuffix {
                let mut = NSMutableAttributedString(attributedString: renderedBody)
                let suffixAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: FontSettings.shared.scaledMessage(16.5)),
                    .foregroundColor: UIColor.label,
                ]
                mut.append(NSAttributedString(string: _splitForUpdate.plainSuffix, attributes: suffixAttrs))
                attributed = mut
            } else {
                attributed = renderedBody
            }
            usedCache = false
        }
        // Walk every inline image attachment so we can:
        //   1. patch `messageId` (the cached path via renderMarkdownBlocks
        //      creates attachments without one)
        //   2. invalidate any stale bitmap if the underlying file was
        //      rewritten since the attachment last loaded (size+mtime
        //      fingerprint mismatch). Skips the on-disk stat for
        //      non-minis schemes.
        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: attributed.length),
                                      options: []) { value, _, _ in
            guard let att = value as? ImageAttachment else { return }
            if let messageId { att.messageId = messageId }
            if let loadedFp = att.loadedFingerprint {
                let currentFp = minisMediaCacheKey(for: att.source)
                if loadedFp != currentFp {
                    imgLogger.info("[MinisImage][CachedAttr] FINGERPRINT CHANGED src=\(att.source) old=\(loadedFp) new=\(currentFp) — invalidating cached image")
                    att.invalidateLoadedImage()
                }
            }
        }
        let renderElapsed = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000

        let assignStart = CFAbsoluteTimeGetCurrent()
        // [AttachHotPath] Append-only fast path: when the new attributed string
        // is a strict extension of what's already in textStorage, only replace
        // the tail. The prefix's glyphs / line fragments / attachment bounds
        // stay laid out — TextKit doesn't re-call attachmentBounds for the
        // image attachments in the prefix, which was the per-token hot path
        // (see `[IMG][BOUNDS]` log series climbing into the hundreds during
        // streaming).
        // [WordFade] Compute the freshly-revealed character range BEFORE we
        // mutate storage, using a pure STRING-prefix diff — exactly how
        // Microsoft's SwiftStreamingMarkdown keys its per-word fade
        // (`newContentLength = attr.length - oldLength`). This is deliberately
        // decoupled from the append fast path below: the fade must fire whether
        // or not the attributed-string fast path is taken, and the renderer's
        // attribute churn (CJK NSFont fallback, NSOriginalFont, fresh paragraph
        // styles) must NOT gate it. We only require the OLD text to be a literal
        // prefix of the NEW text — true for every streamed token. [T-ios-word-fade-animation]
        var fadeRevealRange: NSRange? = nil
        if let oldStorage = textView.textStorage as? NSTextStorage,
           oldStorage.length > 0,
           attributed.length > oldStorage.length {
            let oldLen = oldStorage.length
            let oldStr = oldStorage.string as NSString
            let newStr = attributed.string as NSString
            if newStr.length >= oldLen,
               newStr.substring(to: oldLen) == (oldStr as String) {
                fadeRevealRange = NSRange(location: oldLen, length: attributed.length - oldLen)
            }
        }

        var fastPathTaken = false
        var newAttachInTail = 0
        if let oldStorage = textView.textStorage as? NSTextStorage,
           oldStorage.length > 0,
           attributed.length > oldStorage.length {
            let prefixLen = oldStorage.length
            let newPrefix = attributed.attributedSubstring(from: NSRange(location: 0, length: prefixLen))
            // isEqual on NSAttributedString compares both string AND attribute
            // dictionaries (including attachment object identity). Since the
            // renderer reuses ImageAttachment objects via imageAttachmentCache,
            // a token-only append produces an identical prefix here. Ignore the
            // TextKit-injected NSOriginalFont / substituted NSFont so CJK
            // streams (whose laid-out prefix differs only by font fallback)
            // still take the fast path instead of a full re-render.
            let _oldPrefix = oldStorage.attributedSubstring(from: NSRange(location: 0, length: prefixLen))
            if Self.prefixesEqualIgnoringFontSubstitution(newPrefix, _oldPrefix) {
                let tailRange = NSRange(location: prefixLen, length: 0)
                let tail = attributed.attributedSubstring(from: NSRange(location: prefixLen, length: attributed.length - prefixLen))
                tail.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tail.length), options: []) { v, _, _ in
                    if v != nil { newAttachInTail += 1 }
                }
                oldStorage.beginEditing()
                oldStorage.replaceCharacters(in: tailRange, with: tail)
                oldStorage.endEditing()
                fastPathTaken = true
            }
        }
        if !fastPathTaken {
            textView.attributedText = attributed
        }

        // [WordFade] Now that storage holds the final text (via either path),
        // fade the revealed range in word-by-word. Decoupled from fastPathTaken
        // so a full-replace token still animates. A scene-deferred / background
        // frame never reaches here; isNewMessage / rotation already cancelAll'd.
        if let revealRange = fadeRevealRange,
           let liveStorage = textView.textStorage as? NSTextStorage {
            context.coordinator.fadeTextView = textView
            context.coordinator.fadeAnimator.scheduleAnimation(for: revealRange, in: liveStorage)
        }
        let assignElapsed = (CFAbsoluteTimeGetCurrent() - assignStart) * 1000
        textView.rawMarkdown = markdown
        textView.resetAttachmentRecoveryState()
        // [HangRepro] Record the full markdown just assigned to this
        // textView so a subsequent main-thread hang (caught by
        // HangDetector) can dump the actual input that triggered the
        // typesetter feedback loop. Bounded ring of last 10 entries.
        StreamingHangLogger.shared.recordAssignedText(
            messageId: messageId,
            markdown: markdown,
            attrLen: attributed.length,
            path: fastPathTaken ? "fast-append" : "full-assign"
        )

        // Walk attachments that mutated their content in place (currently
        // TableAttachment via `update(...)`) and invalidate JUST those
        // character ranges in the layout manager. With identity-stable
        // attachments TextKit otherwise keeps the cached attachment-bounds
        // (and therefore the wrong rendered height) for the table.
        if let storage = textView.textStorage as? NSTextStorage {
            let storageLen = storage.length
            if storageLen > 0 {
                storage.enumerateAttribute(.attachment,
                                           in: NSRange(location: 0, length: storageLen),
                                           options: []) { value, range, _ in
                    if let table = value as? TableAttachment, table.needsLayoutInvalidation {
                        textView.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                        table.needsLayoutInvalidation = false
                    }
                }
            }
        }

        let layoutStart = CFAbsoluteTimeGetCurrent()
        var ensureLayoutMs: Double = 0
        if fastPathTaken {
            // Prefix is already laid out. Don't ensureLayout the whole range —
            // TextKit will lay out the appended tail on demand. setNeedsLayout
            // is enough so the text view re-draws and re-measures intrinsic size.
            textView.setNeedsLayout()
        } else if (cachedContent != nil || cachedAttributedString != nil) && textView.textContainer.size.width > 1 {
            // Bounded slow-path layout: only ensure the visible glyph range
            // plus a small overscan. Replacing the full-range ensureLayout
            // here was the second prong of the NSTypesetter watchdog fix —
            // even when the fast path is missed (e.g. a new attachment
            // appeared in the prefix), we no longer pay O(N) layout cost
            // synchronously on the main thread for the entire message.
            let tEnsure = CFAbsoluteTimeGetCurrent()
            let containerSize = textView.textContainer.size
            let visibleRect: CGRect
            if textView.bounds.width > 1, textView.bounds.height > 1 {
                visibleRect = CGRect(x: 0, y: 0, width: containerSize.width, height: textView.bounds.height + 800)
            } else {
                visibleRect = CGRect(x: 0, y: 0, width: containerSize.width, height: 1200)
            }
            let visibleGlyphRange = textView.layoutManager.glyphRange(forBoundingRect: visibleRect,
                                                                     in: textView.textContainer)
            if visibleGlyphRange.length > 0 {
                textView.layoutManager.ensureLayout(forGlyphRange: visibleGlyphRange)
            } else {
                textView.setNeedsLayout()
            }
            ensureLayoutMs = (CFAbsoluteTimeGetCurrent() - tEnsure) * 1000
        } else {
            textView.setNeedsLayout()
        }
        textView.invalidateIntrinsicContentSize()
        textView.setNeedsDisplay()
        textView.invalidateCellSizeIfNeeded()
        let layoutElapsed = (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000
        // [WATCHDOG-DIAG] Log when updateUIView's ensureLayout runs long — this
        // is the other hot site that can burn main-thread wall-clock time.
        if ensureLayoutMs >= 50 || attributed.length >= 10_000 {
        }

        let attachStart = CFAbsoluteTimeGetCurrent()
        // When fast path was taken AND no new attachment was introduced in the
        // appended tail, existing attachment views' character indices are
        // unchanged, their boundingRects are stable, and we can skip the full
        // updateAttachmentViews enumeration. If a new attachment did appear
        // (rare during text streaming after an image), fall through to refresh.
        let skipAttachUpdate = fastPathTaken && newAttachInTail == 0
        if skipAttachUpdate {
            // No-op. Existing attachment views remain correctly placed.
        } else if textView.textContainer.size.width > 1 {
            textView.updateAttachmentViews()
        } else {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.updateAttachmentViews()
                textView.invalidateIntrinsicContentSize()
                textView.setNeedsDisplay()
                textView.setNeedsLayout()
                textView.invalidateCellSizeIfNeeded()
            }
        }
        _ = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
        let updateElapsed = (CFAbsoluteTimeGetCurrent() - updateStart) * 1000
        #if DEBUG
        // [T-scroll-jitter-fold-diag] Slow markdown updates (attributed text
        // swap, TextKit layout) — a candidate for scroll-time stalls.
        if updateElapsed >= 2, ScrollMetricsRecorder.shared.isEnabled {
            ScrollMetricsRecorder.shared.record(kind: "mdv", a: updateElapsed,
                b: Double(textView.bounds.height), src: "update",
                note: "chars=\(textView.textStorage.length)")
        }
        #endif

        // [WatchdogProbe] watchdog crash repro lead — the iOS 26 hang stack
        // shows _performTextKit1LayoutCalculation re-running per cell on
        // collection-view bounds change. Emit when a single updateUIView
        // takes >300ms; chain of these in one main-runloop iteration is the
        // direct cause of a 0x8BADF00D termination.
        #if DEBUG
        let msgIdShort = messageId?.uuidString.prefix(8) ?? "—"
        if updateElapsed >= 300 {
            Self.watchdogProbe.warning("[WatchdogProbe][upd] slow updateUIView elapsed=\(String(format: "%.1f", updateElapsed))ms attrLen=\(textView.attributedText?.length ?? 0) markdownLen=\(markdown.count) msgId=\(msgIdShort)")
        }
        Self.recordUpdateUIView(elapsedMs: updateElapsed, attrLen: textView.attributedText?.length ?? 0, msgId: messageId)
        #endif

        // Keep textContainer height unconstrained so subsequent boundingRect
        // queries return correct positions for attachments near the end.
        // Only assign when it's actually clamped — see layoutSubviews.
        if textView.textContainer.size.height < CGFloat.greatestFiniteMagnitude {
            textView.textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        #if DEBUG
        // [T-attachment-zero-origin] Snapshot at end of updateUIView (live uiView).
        MarkdownSnapshotCollector.captureIfEnabled(
            textView: textView,
            phase: "afterUpdateUIView",
            messageId: context.coordinator.renderer.messageId?.uuidString,
            isMeasureView: false
        )
        #endif
    }

    /// Key TextKit injects on laid-out storage to remember the pre-fallback
    /// font (CJK / emoji substitution). It never appears on a freshly-rendered
    /// attributed string, so a literal `isEqual` between the renderer's output
    /// and the already-laid-out storage always differs by exactly this key.
    private static let nsOriginalFontKey = NSAttributedString.Key("NSOriginalFont")

    /// True when `newPrefix` (renderer output) and `oldPrefix` (already
    /// laid-out storage) are equal once TextKit's font-substitution bookkeeping
    /// is normalized away. When TextKit lays out CJK / emoji, it swaps `NSFont`
    /// to a fallback face and stashes the pre-fallback font under
    /// `NSOriginalFont`. The renderer's fresh string has neither — just the
    /// original `NSFont`. A literal `isEqual` therefore fails on every token,
    /// silently disabling the append fast path (and the word-fade) for CJK.
    ///
    /// We accept the run as equal when, after dropping `NSOriginalFont` and
    /// `NSFont` from both sides, all OTHER attributes (color, paragraph style,
    /// attachment identity, …) match exactly AND the fonts are reconcilable:
    /// either the raw `NSFont`s are equal, or the new side's `NSFont` equals the
    /// old side's `NSOriginalFont` (i.e. old is just `new` after fallback).
    /// A genuine font/size change still breaks the match. [T-ios-word-fade-animation]
    private static func prefixesEqualIgnoringFontSubstitution(
        _ newPrefix: NSAttributedString,
        _ oldPrefix: NSAttributedString
    ) -> Bool {
        guard newPrefix.length == oldPrefix.length else { return false }
        guard (newPrefix.string as NSString).isEqual(oldPrefix.string) else { return false }
        let fontKey = NSAttributedString.Key.font
        let full = NSRange(location: 0, length: newPrefix.length)
        var equal = true
        newPrefix.enumerateAttributes(in: full, options: []) { aN, range, stop in
            let aO = oldPrefix.attributes(at: range.location, effectiveRange: nil)
            // Reconcile fonts: equal as-is, or new.NSFont == old.NSOriginalFont.
            let fontN = aN[fontKey] as? UIFont
            let fontO = aO[fontKey] as? UIFont
            let originalO = aO[nsOriginalFontKey] as? UIFont
            let fontsOK = (fontN == fontO) || (fontN != nil && fontN == originalO)
            if !fontsOK { equal = false; stop.pointee = true; return }
            // Compare everything else with font bookkeeping removed.
            var nN = aN; nN.removeValue(forKey: fontKey); nN.removeValue(forKey: nsOriginalFontKey)
            var nO = aO; nO.removeValue(forKey: fontKey); nO.removeValue(forKey: nsOriginalFontKey)
            if !(nN as NSDictionary).isEqual(to: nO) {
                equal = false
                stop.pointee = true
            }
        }
        return equal
    }

    /// Recursively collect `.image` inline nodes from a block tree for logging.
    private static func collectImageNodes(from block: BlockNode) -> [String] {
        var results: [String] = []
        func walkInlines(_ inlines: [InlineNode]) {
            for inline in inlines {
                switch inline {
                case .image(let src, _):
                    results.append(src)
                case .emphasis(let ch), .strong(let ch), .strikethrough(let ch), .link(_, let ch):
                    walkInlines(ch)
                default: break
                }
            }
        }
        func walkBlocks(_ blocks: [BlockNode]) {
            for b in blocks {
                switch b {
                case .paragraph(let inlines), .heading(_, let inlines):
                    walkInlines(inlines)
                case .blockquote(let children):
                    walkBlocks(children)
                case .bulletedList(_, let items):
                    for item in items { walkBlocks(item.children) }
                case .numberedList(_, _, let items):
                    for item in items { walkBlocks(item.children) }
                case .taskList(_, let items):
                    for item in items { walkBlocks(item.children) }
                default: break
                }
            }
        }
        walkBlocks([block])
        return results
    }
}
