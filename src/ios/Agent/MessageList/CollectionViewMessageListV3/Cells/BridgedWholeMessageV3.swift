//
//  BridgedWholeMessageV3.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Cell content for messages rendered as one row: wraps ChatMessageRow for
//  user / compactDivider / systemInfo messages (agent callback cards get their
//  own horizontal inset). Hosted by WholeMessageCellV3.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Wraps the existing ChatMessageRow for user / compactDivider / systemInfo messages.
/// V3: No GeometryReader.
struct BridgedWholeMessageV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat

    var body: some View {
        ChatMessageRow(
            message: message,
            isActiveMessage: false,
            commandStartTime: nil,
            onStop: nil,
            onRetry: bridge.onRetry,
            onEdit: bridge.onEdit,
            onDeleteFrom: bridge.onDeleteFrom,
            onWithdraw: bridge.onWithdraw,
            autoRetryAttempt: 0,
            autoRetryCountdown: 0,
            canResume: false,
            onResume: nil,
            onCompact: bridge.onCompact,
            onShareMessages: bridge.onShareMessages,
            onShowCompactSummary: bridge.onShowCompactSummary,
            browserPool: nil,
            toolSnapshots: []
        )
        // [T-ios-wholemessage-leading] `alignment: .leading`, like every other
        // bridged wrapper (header :291, block :344, footer :517). Without it the
        // frame defaults to `.center`, and in regular size class — where maxWidth
        // caps at 900 — the row's own 16pt horizontal padding is applied INSIDE
        // the cap, so the content measures 868 and gets centred in the 900 column.
        // That left the agent-callback card visibly narrower and inset by an extra
        // 16pt per side compared with the delegate-tool card next to it, which is
        // padded outside its cap. User bubbles keep their trailing look from the
        // `HStack { Spacer(minLength: 60) … }` inside `userRow`, so leading here
        // only removes the stray centring.
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        // [T-agent-callback-card-width] The callback card's inset is applied
        // HERE, after the cap, so the card fills the same 900pt column the
        // delegate-tool card beside it gets (that cell pads after its cap at
        // :346). Padding inside the cap made it 868 — the leftover half of the
        // problem [T-ios-wholemessage-leading] described but only half fixed:
        // that change removed the stray centring, not the lost 32pt.
        //
        // Scoped to the callback: `userRow` keeps its own padding, because its
        // trailing bubble look comes from `HStack { Spacer(minLength: 60) … }`
        // measured against the padded width, and the height precalc
        // (`measureUserBubbleHeight`, :3756) documents that same geometry.
        .padding(.horizontal, message.agentCallback != nil ? AgentCallbackCellView.horizontalInset : 0)
        // [T-in-chat-search] Compacted rows are drawn at half opacity; their
        // search highlights use stronger colours to stay visible.
        .environment(\.chatSearchDimmed, message.isCompactedHistory)
        .accessibilityIdentifier(message.role == .user ? "userMessage" : "wholeMessage")
    }
}
