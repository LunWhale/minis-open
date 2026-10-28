#!/usr/bin/env swift
// [T-scroll-first-build-once] A finished assistant text block that has not
// been measured is seeded with its exact height instead of being measured
// through SwiftUI, because a row measured before its first display has its
// text view built twice (on-device A/B, 2026-10-03: 40-65 ms per long reply).
//
// A seed is the cell's hard height, so the guards that keep it exact are the
// point of this test: finished blocks only, no attachment other than tables,
// the same attributed string and rounding as sizeThatFits, the same text
// column and padding as the cell, and never for a block that is still
// streaming or already has a measured height.
//
// Run: swift FirstDisplaySeedTests.swift
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let seed = source("Views/Chat/Markdown/Bridge/SelectableMarkdownView+FirstSeed.swift")
let view = source("Views/Chat/Markdown/Bridge/SelectableMarkdownView.swift")
let sizing = source("Views/Chat/Markdown/Bridge/SelectableMarkdownView+Sizing.swift")
let coordinator = source("Views/Chat/Markdown/Bridge/SelectableMarkdownView+Coordinator.swift")
let list = messageListV3Source()
guard !seed.isEmpty, !list.isEmpty else { print("❌ sources not found"); exit(1) }

print("Exact height")
check("finished blocks only",
      seed.contains("guard cachedAttributedString != nil || cachedContent != nil else { return nil }"))
check("prebuilt string only when it has no table (same rule as updateUIView)",
      seed.contains("if let prebuilt = cachedAttributedString, !containsTable(prebuilt) {")
      && view.contains("if let prebuilt = cachedAttributedString, !fontChanged, !prebuiltHasTable, !_hasPlainSuffix {"))
check("tables otherwise rendered by the message's shared renderer",
      seed.contains("let renderer = sharedRenderer(for: messageId)")
      && view.contains("static func sharedRenderer(for messageId: UUID) -> MarkdownNSRenderer"))
check("only tables and thematic breaks are allowed; any other attachment falls back to measuring",
      seed.contains("if value is TableAttachment || value is ThematicBreakAttachment {")
      && seed.contains("guard !hasOtherAttachment else { return nil }"))
let breakSrc = source("Views/Chat/Markdown/Attachments/ThematicBreakAttachment.swift")
check("a thematic break is still a fixed-height line",
      breakSrc.contains("CGRect(x: 0, y: 0, width: lineFrag.width, height: 1 + Self.verticalMargin * 2)"))
check("rounded like sizeThatFits: ceil without attachments, raw with any",
      seed.contains("return hasAttachment ? height : ceil(height)")
      && sizing.contains("h = ceil(mtv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)")
      && sizing.contains("return CGSize(width: width, height: size.height)"))
check("scratch view configured like measureTextView",
      seed.contains("textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)")
      && seed.contains("textView.textContainer.lineFragmentPadding = 0")
      && coordinator.contains("tv.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)")
      && coordinator.contains("tv.textContainer.lineFragmentPadding = 0"))
check("scratch view releases the string after measuring",
      seed.contains("defer { textView.attributedText = NSAttributedString() }"))

print("Cell wiring")
check("seeded only when there is no measured height and the block is not streaming",
      list.contains("if let memo {\n                    cell.seedMeasuredHeight(memo, width: cvW)\n                } else if !isStreamingCell,\n                          let seed = firstDisplaySeed("))
check("the seed is memoized like a measure",
      list.contains("cell.seedMeasuredHeight(seed, width: cvW)\n                    layout.recordMeasuredHeight(forKey: memoKey, height: seed, boundsWidth: cvW)"))
check("assistant text blocks only, above the size where it pays",
      list.contains("case .text = block.kind,\n                  block.content.count >= Self.firstSeedMinChars else { return nil }")
      && list.contains("private static let firstSeedMinChars = 200"))
check("text column = collection width - 32, capped at maxWidth",
      list.contains("var textWidth = collectionWidth - 32\n            if maxWidth > 0 { textWidth = min(textWidth, maxWidth) }"))
check("cell height = text height + 2 pt above and below",
      list.contains("return height + 4"))
let blockView = source("Views/Chat/AssistantBlockView.swift")
check("AssistantBlockView still pads text blocks by 2 pt vertically",
      blockView.contains("textBlockView\n                    .padding(.vertical, 2)"))
check("BridgedAssistantBlockV3 still pads 16 pt horizontally",
      list.contains(".frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)\n        .frame(maxWidth: .infinity)\n        .padding(.horizontal, 16)"))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
