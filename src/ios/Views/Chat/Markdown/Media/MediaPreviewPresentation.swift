//
//  MediaPreviewPresentation.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  What happens when a media attachment is tapped.
//
//  - ImageTapGesture: routes the tap to the message's image gallery
//    (MarkdownImageTapRouter), or shows a single full-screen preview when the
//    markdown is not inside a message.
//  - VideoTapGesture: full-screen MinisVideoFullscreenPlayer.
//  - AudioTapGesture: MinisAudioPreviewView sheet.
//  - ScrollRestoringDismissWrapper: restores the chat's scroll offset when an
//    image / video preview is dismissed.
//
//  The UIView helpers at the top (nearestViewController(),
//  enclosingScrollView()) must stay `private` to this file: the chat page's
//  UIViewHelpers.swift and ChatInputBar.swift declare a private `nearestViewController`
//  *property*, and an internal method of the same name makes those files
//  ambiguous. Everything that needs the helpers therefore lives here.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

private extension UIView {
    /// Walk the responder chain to find the nearest UIViewController.
    func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }

    /// Walk the superview chain to find the nearest UIScrollView.
    func enclosingScrollView() -> UIScrollView? {
        var current = self.superview
        while let v = current {
            if let sv = v as? UIScrollView { return sv }
            current = v.superview
        }
        return nil
    }
}

/// Tap gesture recognizer that routes a markdown-embedded image tap up to
/// the SwiftUI layer so it can present a paged gallery of **all** inline
/// images in the same assistant message.
///
/// When `messageId` is set, we post a `MarkdownImageTapRouter.tappedNotification`
/// and let `AIChatView` resolve the message → full gallery item list.
/// When `messageId` is nil (standalone preview, e.g. a markdown view outside
/// a chat message), we fall back to the legacy single-image fullscreen
/// preview so nothing breaks.
final class ImageTapGesture: UITapGestureRecognizer {
    var attachedImage: UIImage?
    var sourceURL: String?
    var messageId: UUID?

    @objc func handleTap() {
        // Preferred path: route up to SwiftUI so a paged gallery can be shown.
        if let messageId, let sourceURL {
            MarkdownImageTapRouter.postTap(messageId: messageId, sourceURL: sourceURL)
            return
        }
        // Fallback: no message context — present a single-image fullscreen
        // preview directly, same as before.
        guard let image = attachedImage else { return }
        guard let presenter = self.view?.nearestViewController() else { return }
        let scrollView = self.view?.enclosingScrollView()
        let savedOffset = scrollView?.contentOffset
        let source = sourceURL.map { ImageExport.Source.markdown($0) }
        let preview = ScrollRestoringDismissWrapper(scrollView: scrollView, savedOffset: savedOffset) {
            ImagePreviewView(image: image, source: source)
        }
        let hosting = UIHostingController(rootView: preview)
        hosting.modalPresentationStyle = .overFullScreen
        hosting.modalTransitionStyle = .crossDissolve
        presenter.present(hosting, animated: true)
    }
}

/// Wraps a fullscreen preview view and restores scroll position on disappear.
private struct ScrollRestoringDismissWrapper<Content: View>: View {
    private weak var scrollView: UIScrollView?
    private let savedOffset: CGPoint?
    private let content: Content

    init(scrollView: UIScrollView?, savedOffset: CGPoint?, @ViewBuilder content: () -> Content) {
        self.scrollView = scrollView
        self.savedOffset = savedOffset
        self.content = content()
    }

    var body: some View {
        content
            .onDisappear {
                if let scrollView, let savedOffset {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollView.setContentOffset(savedOffset, animated: false)
                    }
                }
            }
    }
}

final class VideoTapGesture: UITapGestureRecognizer {
    var fileURL: URL?

    @objc func handleTap() {
        guard let url = fileURL else { return }
        guard let presenter = self.view?.nearestViewController() else { return }
        // Save scroll position to restore after dismiss.
        let scrollView = self.view?.enclosingScrollView()
        let savedOffset = scrollView?.contentOffset
        // Reuse the shared MinisVideoFullscreenPlayer from AIChatView.
        let playerView = ScrollRestoringDismissWrapper(scrollView: scrollView, savedOffset: savedOffset) {
            MinisVideoFullscreenPlayer(fileURL: url)
        }
        let hosting = UIHostingController(rootView: playerView)
        hosting.modalPresentationStyle = .overFullScreen
        hosting.modalTransitionStyle = .crossDissolve
        presenter.present(hosting, animated: true)
    }
}

/// Tap gesture to open audio preview sheet.
final class AudioTapGesture: UITapGestureRecognizer {
    static var expandTapKey: UInt8 = 0
    var fileURL: URL?

    @objc func handleTap() {
        guard let url = fileURL else { return }
        guard let presenter = self.view?.nearestViewController() else { return }
        // Playback continues seamlessly — global player is shared with preview
        let preview = MinisAudioPreviewView(fileURL: url)
        let hosting = UIHostingController(rootView: preview)
        if let sheet = hosting.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        presenter.present(hosting, animated: true)
    }
}
