//
//  BridgedToolGroupV3.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Cell content for a folded run of tool calls ("Ran N tools", ToolGroupRowView);
//  expanding / collapsing is handled by +ToolFolding. Hosted by ToolGroupCellV3.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// [T-fold-consecutive-tools] Cell content for a `.toolGroup` row: the
/// folded-run summary line, laid out with the same width cap and gutter as
/// the block cells so it lines up with the capsules it stands in for.
struct BridgedToolGroupV3: View {
    @ObservedObject var message: ChatMessage
    let firstBlockId: UUID
    let group: ToolFoldPlanner.Group
    let duration: TimeInterval?
    let isExpanded: Bool
    var maxWidth: CGFloat

    var body: some View {
        ToolGroupRowView(
            firstBlockId: firstBlockId,
            toolCount: group.toolCount,
            failedCount: group.failedCount,
            cancelledCount: group.cancelledCount,
            duration: duration,
            isExpanded: isExpanded
        )
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantToolGroup")
    }
}
