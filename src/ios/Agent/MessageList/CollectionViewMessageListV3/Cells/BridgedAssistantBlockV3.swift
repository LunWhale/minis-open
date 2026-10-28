//
//  BridgedAssistantBlockV3.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Cell content for one assistant block (text / thinking / tool / info), wraps
//  AssistantBlockView, and owns the block's long-press menu (Copy All, Copy as
//  Markdown, Read from Start, Share, Force Sync, the thinking auto-expand
//  toggle, Compact Above). Hosted by AssistantBlockCellV3.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Single block within an assistant turn — text, tool capsule, or info.
/// V3: No GeometryReader — UIKit self-sizing is the sole height source.
struct BridgedAssistantBlockV3: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat
    /// [T-in-chat-search] The "Search in Chat" opener (nil: no search bar).
    @Environment(\.chatSearchHighlights) private var searchHighlights

    private var blockAccessibilityId: String {
        switch block.kind {
        case .text: return "assistantTextBlock"
        case .thinking: return "assistantThinkingBlock"
        case .shellTool: return "assistantShellBlock"
        case .fileReadTool: return "assistantFileReadBlock"
        case .fileWriteTool: return "assistantFileWriteBlock"
        case .fileEditTool: return "assistantFileEditBlock"
        case .browserTool: return "assistantBrowserBlock"
        case .readImageTool: return "assistantReadImageBlock"
        case .memoryTool: return "assistantMemoryBlock"
        case .delegateTool: return "assistantDelegateBlock"
        case .userAskTool: return "assistantUserAskBlock"
        case .info: return "assistantInfoBlock"
        }
    }

    var body: some View {
        AssistantBlockView(
            block: block,
            message: message,
            isActiveMessage: bridge.isActiveMessage,
            commandStartTime: bridge.isActiveMessage ? bridge.commandStartTime : nil,
            onStop: bridge.isActiveMessage ? bridge.onStop : nil,
            onTapBlank: { _ in
                toggleUsage()
            },
            // [#414] Only the text block the capsule sits under responds, and
            // only in its last 5 visual lines (UsageTapBand). Decided at tap
            // time: while streaming, a newly appended block takes over, and a
            // reply ending in a tool / thinking block has no responding text.
            blankTapEligible: { [message, block] in
                Self.isUsageAnchor(block: block, in: message)
            },
            onShareMessages: { bridge.onShareMessages?() },
            // [T-selection-menu-minis-tts] Selection-menu TTS: whole-reply
            // replay is suppressed while this reply is still streaming (same
            // rule as the overlay context menu); Read Selection stays available.
            onReadAloud: bridge.isStreaming ? nil : bridge.onReadAloud,
            onSpeakText: bridge.onSpeakText,
            browserPool: bridge.browserPool,
            toolSnapshots: bridge.toolSnapshots,
            highlightedBlockId: .constant(nil),
            detailBlock: $bridge.detailBlock
        )
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        // [T-in-chat-search] The tool capsule / cards key their highlights by
        // this message; compacted rows use stronger highlight colours.
        .environment(\.chatSearchMessageId, message.id)
        .environment(\.chatSearchDimmed, message.isCompactedHistory)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier(blockAccessibilityId)
        // Context menu on zero-size overlay so it doesn't inflate self-sizing
        // (same pattern as BridgedAssistantFooterV3).
        .overlay {
            Color.clear.frame(width: 0, height: 0)
                .contextMenu {
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(AppLocalized("Copy All"), systemImage: "doc.on.doc")
                    }
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(AppLocalized("Copy as Markdown"), systemImage: "text.quote")
                    }
                    if let onReadAloud = bridge.onReadAloud {
                        Button {
                            onReadAloud()
                        } label: {
                            Label(AppLocalized("Read from Start"), systemImage: "play.circle")
                        }
                        // Greyed out while streaming so it can't clash with the
                        // live streaming TTS of the same reply.
                        .disabled(bridge.isStreaming)
                    }
                    if let onShareMessages = bridge.onShareMessages {
                        Button {
                            onShareMessages()
                        } label: {
                            Label(AppLocalized("Share Chat…"), systemImage: "square.and.arrow.up")
                        }
                    }
                    // [T-in-chat-search]
                    if let open = searchHighlights?.openSearch {
                        Button {
                            open(nil)
                        } label: {
                            Label(AppLocalized("Search in Chat"), systemImage: "magnifyingglass")
                        }
                    }
                    if let onForceSync = bridge.onForceSync {
                        Divider()
                        Button {
                            onForceSync()
                        } label: {
                            Label(AppLocalized("Force Sync"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    // [T-thinking-autoexpand-toggle-longpress] A thinking block's
                    // long-press switches "Expand Thinking While Streaming".
                    // Added to this cell's menu rather than a nested one inside
                    // ThinkingBlockView, which would compete for the same press.
                    if case .thinking = block.kind {
                        Divider()
                        Toggle(isOn: ThinkingAutoExpand.binding(liveBlock: { [bridge, message, block] in
                            bridge.isActiveMessage && message.blocks.last?.id == block.id ? block : nil
                        })) {
                            Label(AppLocalized("Expand Thinking While Streaming"), systemImage: "brain")
                        }
                    }
                    if let onCompact = bridge.onCompact {
                        Divider()
                        Button(role: .destructive) {
                            onCompact()
                        } label: {
                            Label(AppLocalized("Compact Above"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                } preview: {
                    // [T-ios-longpress-menu-preview-background] This .contextMenu
                    // is on a zero-size Color.clear overlay (kept zero-size to
                    // avoid inflating self-sizing), so without an explicit preview
                    // SwiftUI snapshots that transparent overlay → see-through
                    // preview. Supply an opaque card of the message text.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    /// [#414] The block the usage capsule sits right after: the message's LAST
    /// block, and only when it is text. No fallback to an earlier text block.
    static func isUsageAnchor(block: AssistantBlock, in message: ChatMessage) -> Bool {
        guard message.blocks.last?.id == block.id else { return false }
        if case .text = block.kind { return true }
        return false
    }

    private func toggleUsage() {
        guard message.usage != nil else { return }
        if bridge.showUsage {
            withAnimation(.easeInOut(duration: 0.15)) { bridge.usageContentVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                bridge.showUsage = false
                // The footer cell may have been omitted from the snapshot
                // (no content at build time). Notify the coordinator so it
                // re-snapshots and removes the now-empty footer.
                NotificationCenter.default.post(name: .messageListNeedsResnapshot, object: nil)
            }
        } else {
            bridge.showUsage = true
            // The footer cell may not exist yet — notify the coordinator to
            // re-snapshot and insert it.
            NotificationCenter.default.post(name: .messageListNeedsResnapshot, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeInOut(duration: 0.2)) { bridge.usageContentVisible = true }
            }
        }
    }
}
