//
//  BridgedAssistantFooterV3.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Cell content for the assistant footer row: typing indicator (with the
//  retry marker), error, resume banner, token usage, and its long-press menu.
//  Its height shape is tracked by +BridgeUpdates / +FooterHeight. Hosted by
//  AssistantFooterCellV3.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Footer: typing indicator, error, resume banner, token usage.
/// V3: No GeometryReader. Sheet moved to zero-size overlay to prevent
/// inflated self-sizing from sheet-capable view modifiers.
struct BridgedAssistantFooterV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat
    /// [T-retry-log-sheet] Which conversation's retry log the marker reads.
    var retryLogKey: String
    @ObservedObject private var retryLog = RetryLogStore.shared
    @State private var showRetryLog = false
    /// [T-in-chat-search] Highlights for the error line; "Search in Chat".
    @Environment(\.chatSearchHighlights) private var searchHighlights

    // showUsage and usageContentVisible are on bridge, toggled by double-tap on block cells.

    /// [T-ios-typing-indicator-scope] Single source of truth on `ChatMessage`
    /// — see `shouldShowTypingIndicator` for the per-round semantics.
    private var showsTypingIndicator: Bool {
        bridge.isActiveMessage && message.shouldShowTypingIndicator
    }

    /// True when any of the footer's conditional sections will actually
    /// render. When false the footer should collapse to zero height so it
    /// doesn't insert a phantom 4pt gap between the last assistant block
    /// and the next user message.
    private var hasFooterContent: Bool {
        let showTyping = showsTypingIndicator
        let showError = message.error != nil
        let showResume = bridge.canResume && message.error == nil
        let showUsageRow = bridge.showUsage
        return showTyping || showError || showResume || showUsageRow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Typing indicator — "request out, nothing back yet", evaluated per
            // ROUND. See `ChatMessage.shouldShowTypingIndicator`.
            if showsTypingIndicator {
                // [T-retry-log-sheet] A yellow retry marker in front of the
                // indicator, only WHILE a retry is under way (see
                // RetryLogStore.isRetrying). Same line, no extra height, so
                // its appearing needs no footer re-measure.
                HStack(spacing: 6) {
                    if retryLog.isRetrying(key: retryLogKey) {
                        RetryMarkerButton { showRetryLog = true }
                    }
                    TypingIndicator()
                }
            }

            // Inline error
            if let error = message.error {
                inlineError(error)
            }

            // Resume banner
            if bridge.canResume && message.error == nil {
                resumeBanner
            }

            // Token usage
            if bridge.showUsage {
                HStack(spacing: 6) {
                    if let usage = message.usage {
                        usageCapsule(usage)
                            .opacity(bridge.usageContentVisible ? 1 : 0)
                    }
                    Spacer()
                    // [T-usage-capsule-time] The completion clock sits at the
                    // far RIGHT of the row, on its own — not inside the usage
                    // capsule. It answers a different question ("when did this
                    // land") from the capsule's ("what did it cost"), and the
                    // capsule is a variable-width run of numbers, so a time
                    // tacked onto its end drifted horizontally from reply to
                    // reply. Anchored past the Spacer it lines up down the
                    // whole conversation and stays readable as a column.
                    //
                    // Gated on showUsage too, so it reveals and hides with the
                    // capsule rather than lingering on its own after a tap.
                    if bridge.showUsage, let completedAt = message.completedAt {
                        Text(Self.completedAtFormatter.string(from: completedAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(ChatColors.tertiaryText)
                            .opacity(bridge.usageContentVisible ? 1 : 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, hasFooterContent ? 16 : 0)
        .padding(.vertical, hasFooterContent ? 2 : 0)
        .environment(\.chatSearchDimmed, message.isCompactedHistory)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantFooter")
        // Sheet + contextMenu on zero-size overlay so they don't inflate self-sizing.
        // Both .sheet and .contextMenu wrap the view in interaction containers that
        // report inflated heights to systemLayoutSizeFitting, causing height oscillation.
        .overlay {
            Color.clear.frame(width: 0, height: 0)
                // [T-retry-log-sheet] The retry details, on the same zero-size view.
                .sheet(isPresented: $showRetryLog) {
                    RetryLogSheet(key: retryLogKey)
                }
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
                    if let onCompact = bridge.onCompact {
                        Divider()
                        Button(role: .destructive) {
                            onCompact()
                        } label: {
                            Label(AppLocalized("Compact Above"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                } preview: {
                    // [T-ios-longpress-menu-preview-background] Opaque preview
                    // for the footer's zero-size Color.clear contextMenu overlay.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    // MARK: - Footer sub-views

    @ViewBuilder
    private func inlineError(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                SearchHighlightText(error, key: ChatSearchUnitKey(messageId: message.id, blockId: nil, field: .footerError))
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = error
                } label: {
                    Label(AppLocalized("Copy Error"), systemImage: "doc.on.doc")
                }
            }
            Spacer()
            if bridge.autoRetryAttempt > 0 {
                Text("Retry in \(bridge.autoRetryCountdown)s (\(bridge.autoRetryAttempt)/\(AIChatViewModel.retryDelays.count))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
            } else if let onRetry = bridge.onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                        Text(AppLocalized("Retry")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(ChatColors.primaryText.opacity(0.15)).clipShape(Capsule())
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var resumeBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
                Text(AppLocalized("Interrupted — tap Resume to continue")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onResume = bridge.onResume {
                Button(action: onResume) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.caption.weight(.semibold))
                        Text(AppLocalized("Resume")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.orange).clipShape(Capsule())
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// [T-usage-capsule-time] 24-hour HH:mm, locale-pinned.
    ///
    /// `en_US_POSIX` is not cosmetic: a bare `dateFormat = "HH:mm"` is still
    /// resolved against the device locale, and a region on a 12-hour clock
    /// renders it as 12-hour. Static so the DateFormatter alloc is not paid
    /// per message per render pass. Mirrors ChatMessageRow's formatter.
    private static let completedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    @ViewBuilder
    private func usageCapsule(_ usage: TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer").font(.system(size: 9))
            Text(usageSummary(usage)).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(ChatColors.userBubble.opacity(0.6)).clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    private func usageSummary(_ u: TokenUsage) -> String {
        var parts: [String] = []
        if u.latestContextTokens > 0 { parts.append("ctx:\(fmtTok(u.latestContextTokens))") }
        parts.append("in:\(fmtTok(u.inputTokens))")
        parts.append("out:\(fmtTok(u.outputTokens))")
        if u.cacheReadTokens > 0 { parts.append("cache:\(fmtTok(u.cacheReadTokens))") }
        if u.cacheCreationTokens > 0 { parts.append("+cache:\(fmtTok(u.cacheCreationTokens))") }
        return parts.joined(separator: " ")
    }
    private func fmtTok(_ c: Int) -> String {
        c >= 1000 ? (c >= 10000 ? "\(c/1000)k" : String(format: "%.1fk", Double(c)/1000)) : "\(c)"
    }
}
