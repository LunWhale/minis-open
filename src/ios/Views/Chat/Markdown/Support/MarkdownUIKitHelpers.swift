//
//  MarkdownUIKitHelpers.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Small extensions used across the module.
//
//  - UIFont.withTraits: bold / italic runs (renderer and table cells).
//  - [InlineNode].plainText: flattens inline nodes for alt text and cells.
//
//  Both were `private` while the module was one file; internal now. The UIView
//  responder-chain helpers that sat next to them stay `private` in
//  Media/MediaPreviewPresentation.swift (see there why).
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - UIFont+Traits

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = fontDescriptor.withSymbolicTraits(combined) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

// MARK: - InlineNode Plain Text Helper

extension Array where Element == InlineNode {
    var plainText: String {
        map { node -> String in
            switch node {
            case .text(let t): return t
            case .code(let c): return c
            case .emphasis(let ch), .strong(let ch), .strikethrough(let ch): return ch.plainText
            case .link(_, let ch), .image(_, let ch): return ch.plainText
            case .softBreak: return " "
            case .lineBreak: return "\n"
            case .html(let h): return h
            case .inlineMath(let latex): return latex
            }
        }.joined()
    }
}
