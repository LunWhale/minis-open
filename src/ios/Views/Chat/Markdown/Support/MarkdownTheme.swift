//
//  MarkdownTheme.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Visual vocabulary of rendered markdown.
//
//  - NSAttributedString.Key extensions: attributes the renderer writes and
//    MinisLayoutManager / the text view read back (inline code background and
//    text, blockquote depth).
//  - minisInlineCodeBackgroundColor: the single source of the inline-code pill
//    colour, shared by the theme, MinisLayoutManager (the paint site) and table
//    cells, so they cannot drift apart.
//  - SelectableMarkdownTheme: UIKit mirror of the `.minisChat` MarkdownUI theme
//    (fonts, colours, spacing). Attachments keep a copy of the theme they were
//    rendered with.
//  - renderMarkdownBlocks: one-shot render for callers outside the view, e.g.
//    AIChatViewModel caching the attributed string of a finished message.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Custom Attributed String Keys

extension NSAttributedString.Key {
    static let inlineCodeBackground = NSAttributedString.Key("minisInlineCodeBackground")
    static let inlineCodeText = NSAttributedString.Key("minisInlineCodeText")
    static let blockquoteDepth = NSAttributedString.Key("minisBlockquoteDepth")
}

// MARK: - SelectableMarkdownTheme

/// [T-inline-code-dark-bg-ios] Inline-code span background, shared by the
/// theme and the layout manager's fillBackgroundRectArray (the actual paint
/// site) so the two can never drift. Light stays EXACTLY .systemGray6
/// (#F2F2F7); dark lifts to #3A3A3C (systemGray4's dark value) — systemGray6
/// resolves to #1C1C1E in dark, indistinguishable from the near-black chat
/// background, which made inline code read as bare orange text.
let minisInlineCodeBackgroundColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1)
        : .systemGray6
}

/// Mirrors the `.minisChat` MarkdownUI theme using UIKit types.
struct SelectableMarkdownTheme {
    let baseFontSize: CGFloat
    let codeBlockCornerRadius: CGFloat = 8
    let inlineCodeCornerRadius: CGFloat = 5

    init(baseFontSize: CGFloat? = nil) {
        self.baseFontSize = baseFontSize ?? 16.5
    }

    var baseFont: UIFont { .systemFont(ofSize: baseFontSize) }
    var labelColor: UIColor { .label }
    var secondaryLabelColor: UIColor { .secondaryLabel }
    var accentColor: UIColor { .systemOrange }
    var linkColor: UIColor { .systemBlue }
    var codeBlockBackground: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1) : .black }
    }
    var codeBlockTextColor: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.55, green: 0.95, blue: 0.55, alpha: 1) : .systemGreen }
    }
    var inlineCodeBackground: UIColor { minisInlineCodeBackgroundColor }
    var inlineCodeColor: UIColor { .systemOrange }
    var blockquoteBarColor: UIColor { UIColor.systemOrange.withAlphaComponent(0.5) }
    var tableBorderColor: UIColor { UIColor.label.withAlphaComponent(0.25) }

    func headingFont(level: Int) -> UIFont {
        let size: CGFloat
        let weight: UIFont.Weight
        switch level {
        case 1: size = baseFontSize * 1.5; weight = .bold
        case 2: size = baseFontSize * 1.3; weight = .bold
        case 3: size = baseFontSize * 1.15; weight = .semibold
        case 5: size = baseFontSize * 0.875; weight = .semibold
        case 6: size = baseFontSize * 0.85; weight = .semibold
        default: size = baseFontSize; weight = .semibold // H4 and fallback
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    var inlineCodeFont: UIFont { inlineCodeFont(matching: nil) }

    /// [T-md-inline-code-context-font] Inline code sized RELATIVE to the text
    /// it sits in — 0.845× the CONTEXT font, the exact ratio body text has
    /// always used (0.845 × baseFontSize), so paragraph rendering is
    /// unchanged while a code span inside an H1/H2 scales with the heading
    /// instead of rendering at body size and reading sunken/undersized.
    func inlineCodeFont(matching contextFont: UIFont?) -> UIFont {
        let size = (contextFont?.pointSize ?? baseFontSize) * 0.845
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var codeBlockFont: UIFont {
        let size = baseFontSize * 0.85
        // Use Menlo as the base monospaced font, with PingFang SC as CJK fallback.
        // PingFang SC's CJK glyphs are exactly 2x the width of Menlo's ASCII glyphs
        // at the same point size, enabling proper table alignment in code blocks.
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Renders markdown blocks into an NSAttributedString using a fresh MarkdownNSRenderer.
/// Intended for one-shot rendering of completed messages (e.g. caching in AIChatViewModel).
@MainActor
func renderMarkdownBlocks(_ blocks: [BlockNode]) -> NSAttributedString {
    let renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))
    return renderer.render(blocks: blocks)
}
