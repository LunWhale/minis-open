//
//  AIChatView+Banners.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, banners and overlays above the content: the kernel boot overlay,
//  the stacked top banners under the navigation bar (scheduled task, error
//  card, transient notice), the error card and its DEBUG "copy session data"
//  action, and the DEBUG fork (read-only) banner.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

extension AIChatView {
    // MARK: - Kernel Boot Overlay

    @ViewBuilder
    var kernelBootOverlay: some View {
        switch vm.kernelStatus {
        case .booting:
            ZStack {
                ChatColors.background
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    // Same three-dot language as SessionLoadingCard — this
                    // overlay can appear right after the loading card on a
                    // cold entry, so a system spinner here read as "the old
                    // spinner came back".
                    LoadingDotsView(dotSize: 9, color: ChatColors.secondaryText)
                        .frame(height: 20)
                    Text("Booting Kernel")
                        .font(.subheadline)
                        .foregroundStyle(ChatColors.secondaryText)
                }
            }
            .transition(.opacity)
        case .failed(let msg):
            ZStack {
                ChatColors.background
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    // MARK: - Top banners  [T-error-banner-under-navbar]

    /// Everything pinned under the navigation bar, top to bottom:
    /// 1. the scheduled task's next run — it persists while the task lives,
    ///    so it stays put on top and nothing transient pushes it around;
    /// 2. the error banner — transient, dismissable, next to the content it
    ///    is about;
    /// 3. the transient notice (~4 s).
    /// One stack, one measured height, so the list's top inset covers them
    /// all and they can never overlap each other.
    @ViewBuilder
    var topBanners: some View {
        VStack(spacing: 0) {
            if let sid = vm.sessionId {
                ScheduledTaskBanner(sessionId: sid)
            }
            // [T-in-chat-search] Right under the navigation bar (below the
            // scheduled-task banner when the chat has one).
            if isChatSearchActive {
                ChatSearchBar(search: vm.chatSearch, onDone: {})
            }
            if let error = vm.errorMessage {
                errorBanner(error)
            }
            // Transient notice (e.g. request-level image budget
            // elision). Auto-dismisses after ~4s.
            if let notice = vm.transientNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.75))
                    .onAppear {
                        let captured = notice
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if vm.transientNotice == captured {
                                vm.transientNotice = nil
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        // [T-error-detail-visible issue #368] `.top` alignment and lineLimit(8),
        // was a centered HStack with lineLimit(2). The banner shows the same
        // composed string as the bubble error — a "⚠️ <model> (<instance>):
        // <reason>" line per attempted group entry, then the real upstream
        // description last — so two lines only ever showed the trail and clipped
        // the reason. With a multi-line body the icon and the dismiss button must
        // sit at the top rather than float against the vertical centre.
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
            Button { vm.errorMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
                    // [T-error-card] A ~14 pt glyph was the whole target. The
                    // hit shape grows 16 pt on every side (≈ 46 x 45 pt, past
                    // the 44 pt minimum) while layout and look stay the same.
                    .contentShape(Rectangle().inset(by: -16))
            }
            // [T-ios-voiceover-labels] Otherwise announced as "xmark".
            .accessibilityLabel(Text("Dismiss error", comment: "VoiceOver label for the button that dismisses the error banner"))
        }
        .contentShape(Rectangle())
        .onLongPressGesture {
            UIPasteboard.general.string = error
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
        // [T-error-card] Same card as the scheduled-task banner it stacks
        // with (ScheduledTaskBanner): 12 pt side margins, 14 pt continuous
        // corners, material, hairline, soft shadow — in red instead of amber.
        // The material also keeps list text from showing through on iOS 26,
        // where the list scrolls under the top banners.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.08))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.red.opacity(0.28), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    #if DEBUG
    /// Build a JSON representation of the full agent conversation history and copy it.
    func copySessionDataToClipboard() {
        Task {
            guard let sid = vm.sessionId else {
                UIPasteboard.general.string = "(no session)"
                return
            }
            let rawMessages = await ChatStore.shared.loadMessages(sessionId: sid)
            var entries: [[String: Any]] = []
            for msg in rawMessages {
                var partsJson: [[String: Any]] = []
                for part in msg.parts {
                    switch part {
                    case .text(let text):
                        partsJson.append(["type": "text", "text": text])
                    case .toolUse(let tu):
                        // Parse input JSON string back to dict for clean output
                        let inputObj = (try? JSONSerialization.jsonObject(
                            with: Data(tu.input.utf8))) ?? tu.input
                        partsJson.append(["type": "tool_use", "id": tu.toolUseId,
                                          "name": tu.name, "input": inputObj])
                    case .toolResult(let tr):
                        partsJson.append(["type": "tool_result", "tool_use_id": tr.toolUseId,
                                          "output": tr.output, "is_error": !tr.success])
                    case .mediaRef(let ref):
                        partsJson.append(["type": "media", "mime": ref.mimeType,
                                          "file": ref.originalFileName ?? ref.relativePath])
                    }
                }
                var entry: [String: Any] = [
                    "role": msg.role.rawValue,
                    "parts": partsJson,
                    "created": ISO8601DateFormatter().string(from: msg.createdAt)
                ]
                if let usage = msg.tokenUsage {
                    entry["usage"] = [
                        "input_tokens": usage.inputTokens,
                        "output_tokens": usage.outputTokens,
                        "cache_creation_tokens": usage.cacheCreationTokens,
                        "cache_read_tokens": usage.cacheReadTokens
                    ]
                }
                entries.append(entry)
            }
            if let data = try? JSONSerialization.data(withJSONObject: entries,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                UIPasteboard.general.string = str
            }
        }
    }
    #endif

    // MARK: - Fork Banner (Read-Only Mode)

    #if DEBUG
    var forkBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text("Read-only session from another device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let sid = sessionId, let devId = remoteDeviceId else { return }
                    Task {
                        if let forked = await SessionForkManager.shared.forkSession(
                            remoteSessionId: sid, remoteDeviceId: devId
                        ) {
                            // Navigate to the forked session
                            NotificationCenter.default.post(
                                name: .sessionDidCreate,
                                object: forked.id,
                                userInfo: ["navigate": true]
                            )
                        }
                    }
                } label: {
                    Label("Fork to Continue", systemImage: "arrow.branch")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }
    #endif
}
