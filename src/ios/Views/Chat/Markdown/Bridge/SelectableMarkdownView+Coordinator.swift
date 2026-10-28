//
//  SelectableMarkdownView+Coordinator.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Bridge - SelectableMarkdownView.Coordinator.
//
//  The state that survives between updateUIView passes for one view: last
//  rendered markdown / content id / width, the message's renderer, measurement
//  caches, the deferred render while the app is inactive, the word fade-in
//  animator and the off-screen measuring text view. It is also the text view's
//  UITextViewDelegate (link taps and link menus).
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

extension SelectableMarkdownView {
    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastMarkdown: String = ""
        var lastRenderedContentHash: Int? = nil
        /// [T-ios-reuse-cachewipe] Identity of the content this coordinator's
        /// text view is currently showing — `blockId` when the caller renders
        /// per-block (V3 cell-per-block), else `messageId`. Used to tell a
        /// genuine *identity change* (this view was recycled onto different
        /// content) apart from *the same content being rewritten* (streaming
        /// append, regenerate). See `updateUIView`'s wipe branch.
        var lastContentId: UUID? = nil
        /// [FGReload] Markdown whose render was skipped because the app was
        /// not `.active` (see the `!= .active` guard in `updateUIView`). The
        /// skip exists to avoid the expensive `setAttributedText` +
        /// `ensureLayout` pass blocking the main thread during a scene-update
        /// transition, which trips the 0x8BADF00D watchdog (commit e6efac23).
        /// We stash the markdown here instead of dropping it so the foreground
        /// observer can replay it once the app is safely `.active` again —
        /// otherwise the last streaming frame stays blank until SwiftUI
        /// happens to re-evaluate the view body.
        var pendingMarkdown: String? = nil
        /// Re-invokes the live `updateUIView` render path for the deferred
        /// markdown. Captured fresh on every skip so it always closes over the
        /// current textView + render inputs (cachedAttributedString etc.).
        private var replayDeferredRender: (() -> Void)?

        /// Arms the foreground-replay path. Called from the `updateUIView`
        /// skip branch with a closure that re-runs the render for the current
        /// inputs. Lifecycle observers are armed eagerly in `init` — this
        /// just stores the pending state.
        func deferRender(_ markdown: String, replay: @escaping () -> Void) {
            pendingMarkdown = markdown
            replayDeferredRender = replay
        }

        private var foregroundObserver: NSObjectProtocol?
        private var resignActiveObserver: NSObjectProtocol?
        /// Wall-clock timestamp of the most recent `willResignActive` we
        /// observed. Cleared on `didBecomeActive`. The `.inactive` skip path
        /// uses this to distinguish short interruptions (control center
        /// swipe, incoming call banner — safe to render through) from
        /// long-running `.inactive` windows where the watchdog risk that
        /// commit e6efac23 fixed becomes material again. Armed eagerly in
        /// `init` so the timestamp is correct on the very first `.inactive`
        /// skip check, not only after the first deferred render.
        var inactiveEnteredAt: Date?

        override init() {
            super.init()
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.inactiveEnteredAt = nil
                self?.applyDeferredRenderIfNeeded()
            }
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.inactiveEnteredAt = Date()
            }
        }

        private func applyDeferredRenderIfNeeded() {
            // Only render once the app is genuinely `.active`. didBecomeActive
            // fires after the watchdog-sensitive scene-update transition has
            // settled, so the expensive layout pass is safe here.
            guard UIApplication.shared.applicationState == .active else { return }
            guard let pending = pendingMarkdown, let replay = replayDeferredRender else { return }
            pendingMarkdown = nil
            replayDeferredRender = nil
            replay()
        }

        deinit {
            if let foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
            }
            if let resignActiveObserver {
                NotificationCenter.default.removeObserver(resignActiveObserver)
            }
        }
        var lastFontSize: CGFloat = FontSettings.shared.scaledMessage(16.5)
        var openURL: OpenURLAction?
        /// Cached sizeThatFits results keyed by integer width bucket.
        /// Multi-bucket cache is required because SwiftUI layout protocol
        /// may probe the same view at several nearby widths within one
        /// CollectionView self-sizing pass. A single-width cache was being
        /// bypassed on every probe, triggering full TextKit1 relayouts.
        var cachedSizes: [Int: CGFloat] = [:]
        var cachedSizeMarkdownCount: Int = 0
        /// Last textContainer width at which `updateUIView` ran. Used so that
        /// a rotation that arrives as `(markdown unchanged, width changed)`
        /// still invalidates TableAttachment cached layouts so the table
        /// frame re-bakes at the new width instead of sticking at the old
        /// portrait columns. Initialised to a sentinel so the very first
        /// update doesn't spuriously fire the invalidation path.
        var lastRenderedWidth: CGFloat = -1
        /// [WATCHDOG-DIAG] Counters for localizing 0x8BADF00D watchdog crash.
        var sizeThatFitsCallCount: Int = 0
        var sizeThatFitsCacheHitCount: Int = 0
        var sizeThatFitsTotalMs: Double = 0
        var streamRenderCount: Int = 0
        /// HangFix(2026-05-14) — streaming-aware approximate cache.
        /// Track per-character height (height ÷ bindingLen at last real
        /// measurement) so when `sizeThatFits` is called during streaming
        /// with a bindingLen that has only grown by a small amount, we can
        /// return `cachedHeight + (delta × pxPerChar)` without running a
        /// full off-screen render + UITextView.sizeThatFits pass.
        ///
        /// Why this matters: commit 0f58bb3 changed the STF cache key from
        /// textStorage.length to bindingLen, which fixed DeepSeek V4 char
        /// clipping but means every streamed token invalidates the cache.
        /// Each miss spawns a full prepareMarkdownForRender +
        /// renderer.render + off-screen UITextView measure, which on iPhone
        /// 17 Pro Max + 120Hz + CJK + emoji costs ~50-200ms per call.
        /// SwiftUI calls sizeThatFits at two widths per layout pass, so
        /// streaming a single message accumulates main-thread work
        /// faster than it drains -> background watchdog 0x8BADF00D.
        var lastFullMeasureBindingLen: Int = 0
        var lastFullMeasureHeight: [Int: CGFloat] = [:]
        var lastFullMeasureAt: CFAbsoluteTime = 0
        var renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))

        /// [WordFade] The textView whose storage the fade animator mutates.
        /// Set on the append fast path so the animator's redraw closure can
        /// repaint it. Weak — the SwiftUI representable owns the view.
        weak var fadeTextView: SelectableMarkdownTextView?

        /// [WordFade] Drives word-by-word alpha fade-in for streamed tokens.
        /// Created lazily on first append so non-streaming / history cells
        /// (which never hit the fast path) never allocate a CADisplayLink.
        /// Its redraw closure repaints whatever `fadeTextView` currently points
        /// at, so a Coordinator reused across textViews stays correct.
        lazy var fadeAnimator: TextFadeAnimator = TextFadeAnimator { [weak self] in
            self?.fadeTextView?.setNeedsDisplay()
        }

        /// Off-screen textView used by `sizeThatFits` to measure pending
        /// attributedText that hasn't been committed to the on-screen
        /// textView yet. Writing pending text into the live `uiView` from
        /// inside `sizeThatFits` is what caused the watchdog hang seen in
        /// `Minis-2026-05-13-084827.ips`: it rebuilds attachment subviews
        /// and calls `addSubview` → `setNeedsLayout` on the textView
        /// during SwiftUI's measurement pass, which then triggers SwiftUI
        /// to re-invoke `sizeThatFits` indefinitely.
        ///
        /// Configured once and reused across measurement calls. Layout is
        /// driven by `sizeThatFits` — never attached to a window.
        lazy var measureTextView: UITextView = {
            let tv = SelectableMarkdownTextView()
            tv.isScrollEnabled = false
            tv.isEditable = false
            tv.isSelectable = false
            // [ClipFix 2026-05-16] Match the live SelectableMarkdownTextView's
            // textContainerInset (init at line ~3597 sets top=4 bottom=4).
            // Previously this was `.zero`, so mtv.sizeThatFits returned 8pt
            // less than the on-screen UITextView actually rendered, and
            // every attachment-bearing cell (tables, code blocks, images)
            // got a cell.frame 8pt shorter than its content — clipping the
            // last visual line. Verified by the ClipDiag log: BR path
            // (uiView with inset=4/4) returned diff≈-0.5 while HIT path
            // (mtv-written cached value) returned diff=+8.0 for the same
            // text type.
            tv.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
            tv.textContainer.lineFragmentPadding = 0
            tv.backgroundColor = .clear
            return tv
        }()

        @available(iOS 17.0, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { [weak self] _ in
                    if let openURL = self?.openURL {
                        openURL(url)
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
            // [D1 T-ios-table-attachment-tap-preview-ios18] A TableAttachment
            // carries a 1×1 transparent placeholder image (needed for
            // attachmentBounds), so on iOS 18 and below the host UITextView
            // treats a single tap on it as an IMAGE text-item and pops the
            // system "拷贝图像/存入相机胶卷" preview. Suppress that here by
            // returning a no-op action; the real table interaction lives on the
            // overlaid TableScrollView, which still scrolls/selects. iOS 19+
            // changed the system behavior, so leave its default untouched.
            if #available(iOS 19, *) {
                // iOS 19+: default behavior, no change.
            } else if case .textAttachment(let attachment) = textItem.content,
                      attachment is TableAttachment {
                return UIAction { _ in }
            }
            return defaultAction
        }

        @available(iOS 17.0, *)
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            switch textItem.content {
            case .link(let url):
                let copyAction = UIAction(title: AppLocalized("Copy Link"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = url.absoluteString
                }
                let openAction = UIAction(title: AppLocalized("Open in Safari"), image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(url)
                }
                let menu = UIMenu(children: [copyAction, openAction])
                return UITextItem.MenuConfiguration(preview: nil, menu: menu)
            case .textAttachment(let attachment):
                // [D1 T-ios-table-attachment-tap-preview-ios18] On iOS 18 and
                // below, a tap on a table attachment must not present the image
                // preview. Offer a real "Copy Table" menu (tab-separated text,
                // same payload as the TableScrollView copyTable path) instead of
                // the empty menu, and a nil preview so no image sheet appears.
                // iOS 19+ behavior is unchanged (falls through to the logic
                // below).
                if #available(iOS 19, *) {
                    // iOS 19+: no special-casing, use the logic below.
                } else if let tableAttach = attachment as? TableAttachment {
                    let copyTableAction = UIAction(
                        title: AppLocalized("Copy Table"),
                        image: UIImage(systemName: "tablecells")
                    ) { _ in
                        UIPasteboard.general.string = tableAttach.plainText()
                    }
                    return UITextItem.MenuConfiguration(preview: nil, menu: UIMenu(children: [copyTableAction]))
                }
                guard let imageAttach = attachment as? ImageAttachment,
                      let image = imageAttach.loadedImage else {
                    // Suppress system default menu (which would copy/save the
                    // 1×1 transparent placeholder) when no real image is loaded.
                    return UITextItem.MenuConfiguration(preview: nil, menu: UIMenu(children: []))
                }
                // [T-image-save-original] `image` is the display decode (≤2048 px);
                // copy and save the original file behind it.
                let source = ImageExport.Source.markdown(imageAttach.source)
                let copyAction = UIAction(title: AppLocalized("Copy Image"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    Task { await ImageExport.copy(source: source, displayed: image) }
                }
                let saveAction = UIAction(title: AppLocalized("Save to Camera Roll"), image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    ImageExport.saveToPhotos(source: source, displayed: image) { _ in }
                }
                let menu = UIMenu(children: [copyAction, saveAction])
                return UITextItem.MenuConfiguration(preview: nil, menu: menu)
            @unknown default:
                return nil
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? SelectableMarkdownTextView)?.updateSelectionState()
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if interaction == .presentActions {
                let alert = UIAlertController(title: URL.absoluteString, message: nil, preferredStyle: .actionSheet)
                alert.addAction(UIAlertAction(title: AppLocalized("Copy Link"), style: .default) { _ in
                    UIPasteboard.general.string = URL.absoluteString
                })
                alert.addAction(UIAlertAction(title: AppLocalized("Open in Safari"), style: .default) { _ in
                    UIApplication.shared.open(URL)
                })
                alert.addAction(UIAlertAction(title: AppLocalized("Cancel"), style: .cancel))
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    var presenter = root
                    while let presented = presenter.presentedViewController { presenter = presented }
                    if let popover = alert.popoverPresentationController {
                        popover.sourceView = textView
                        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
                        popover.sourceRect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
                    }
                    presenter.present(alert, animated: true)
                }
                return false
            }
            if let openURL {
                openURL(URL)
            } else {
                UIApplication.shared.open(URL)
            }
            return false
        }
    }
}
