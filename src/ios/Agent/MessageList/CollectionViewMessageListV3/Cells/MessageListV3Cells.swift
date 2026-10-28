//
//  MessageListV3Cells.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  One SelfSizingCell subclass per row kind, so UICollectionView reuses a
//  cell only for the same kind of content. Registered in +Setup.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - Per-type Cell Subclasses (enable correct reuse)

final class WholeMessageCellV3: SelfSizingCell {}
final class AssistantHeaderCellV3: SelfSizingCell {}
final class AssistantBlockCellV3: SelfSizingCell {}
final class AssistantFooterCellV3: SelfSizingCell {}
final class ToolGroupCellV3: SelfSizingCell {}
