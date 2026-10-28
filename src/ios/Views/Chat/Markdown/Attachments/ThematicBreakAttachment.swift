//
//  ThematicBreakAttachment.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments.
//
//  Horizontal rule (`---`): a one-point line drawn as an attachment view.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Thematic Break Attachment

final class ThematicBreakAttachment: NSTextAttachment {
    let theme: SelectableMarkdownTheme

    init(theme: SelectableMarkdownTheme) {
        self.theme = theme
        super.init(data: nil, ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    /// Spacing controlled by RenderedBlock margins; no extra padding inside attachment
    static let verticalMargin: CGFloat = 0

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: lineFrag.width, height: 1 + Self.verticalMargin * 2)
    }

    func makeView(width: CGFloat) -> UIView {
        let totalHeight = 1 + Self.verticalMargin * 2
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: totalHeight))
        let line = UIView(frame: CGRect(x: 0, y: Self.verticalMargin, width: width, height: 1))
        line.backgroundColor = theme.secondaryLabelColor.withAlphaComponent(0.3)
        container.addSubview(line)
        return container
    }
}
