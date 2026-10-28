//
//  AIChatView+ShareInjection.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, incoming content: injects items handed over by the share
//  extension (text, files; Provider-export JSON is offered as an import) and
//  content transferred by "Move to Session" into this chat's composer.
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

private let minisLogger = AppLogger(category: "MinisURL")

extension AIChatView {
    // MARK: - Share Injection

    /// A shared/opened JSON file detected as a Provider export, pending the
    /// user's import-vs-attach choice. [T-ios-json-open-provider-import-prompt]
    struct PendingProviderImport: Identifiable {
        let id = UUID()
        /// The raw JSON string, fed directly to `importInstanceJSON`.
        let json: String
        /// A temp copy of the file for the "add as attachment" branch (the
        /// shared original is cleaned up right after ingestion).
        let fileURL: URL
    }

    /// Returns the file's JSON string iff it is a Provider export — i.e. its
    /// top-level object carries `providerType` (a valid `ProviderType`),
    /// `credentialType` (String), and `models` (array). Same required fields
    /// `ProviderConfigStore.importInstanceJSON` keys on, so a hit reliably
    /// imports. Returns nil for non-JSON or ordinary JSON. [T-ios-json-open-provider-import-prompt]
    static func providerExportJSON(at url: URL) -> String? {
        guard url.pathExtension.lowercased() == "json",
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerTypeRaw = dict["providerType"] as? String,
              ProviderType(rawValue: providerTypeRaw) != nil,
              dict["credentialType"] is String,
              dict["models"] is [Any] else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func injectPendingShareIfNeeded() {
        // [T-share-routes-to-background-session] Only the session the share was
        // ROUTED TO may consume it. Both entry points (onAppear and the
        // bufferVersion observer) funnel through here, so the check sits at the
        // single place that actually takes the buffer.
        //
        // Previously any mounted chat consumed the buffer on a version bump.
        // Device log 2026-08-18 23:55:42: a share arriving while the user was
        // looking at session 87B79110 — a conversation running an agent loop in
        // the BACKGROUND — was injected straight into its composer, because
        // that view simply happened to be on screen. ContentView now stamps the
        // destination on the buffer before navigating; a nil stamp (cold
        // launch, where the launch flow owns the choice) still passes.
        guard shareCoordinator.bufferTargets(sessionId, draftId: draftId) else {
            minisLogger.info("[Share] injectPendingShareIfNeeded — buffer is addressed to another session (mine: sessionId=\(sessionId ?? "nil") draftId=\(draftId ?? "nil")); leaving it")
            return
        }
        guard let pending = shareCoordinator.consumeBuffer() else {
            minisLogger.info("[Share] injectPendingShareIfNeeded — no buffer or expired")
            return
        }
        minisLogger.info("[Share] Injecting \(pending.items.count) items into chat")

        for (i, item) in pending.items.enumerated() {
            switch item.kind {
            case .inlineText:
                minisLogger.info("[Share] item[\(i)] inlineText: \(String(item.value.prefix(100)))")
                // [T-share-one-link] The same text already sitting in the
                // composer as a line of its own is not added a second time.
                guard ShareItemRules.shouldInject(item.value, into: vm.inputText) else {
                    minisLogger.info("[Share] item[\(i)] already in the composer — skipped")
                    continue
                }
                if !vm.inputText.isEmpty { vm.inputText += "\n" }
                let text = item.value
                // Append a trailing space to URLs so the cursor doesn't stick to the link
                if text.hasPrefix("http://") || text.hasPrefix("https://") {
                    vm.inputText += text + " "
                } else {
                    vm.inputText += text
                }
            case .attachment:
                guard let dir = SharedContainerStore.sharedFileDirectory else {
                    minisLogger.error("[Share] item[\(i)] sharedFileDirectory is nil!")
                    continue
                }
                let fileURL = dir.appendingPathComponent(item.value)
                let exists = FileManager.default.fileExists(atPath: fileURL.path)
                minisLogger.info("[Share] item[\(i)] attachment: \(item.value) exists=\(exists) path=\(fileURL.path)")
                guard exists else { continue }
                // [T-ios-json-open-provider-import-prompt] If this is a JSON
                // Provider export, don't silently attach it — ask the user
                // whether to import it as a provider or add it as an attachment.
                // We only intercept the FIRST such file (the prompt is modal);
                // capture the JSON string (for import) + a temp copy of the file
                // (for the attachment path, since cleanSharedFiles() below will
                // delete the shared original) and defer to the dialog.
                if pendingProviderImport == nil, let json = Self.providerExportJSON(at: fileURL) {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("provider-share-\(UUID().uuidString).json")
                    try? FileManager.default.copyItem(at: fileURL, to: tempURL)
                    pendingProviderImport = PendingProviderImport(json: json, fileURL: tempURL)
                    minisLogger.info("[Share] item[\(i)] detected Provider export JSON — prompting import vs attachment")
                    continue
                }
                vm.addFileAttachment(from: fileURL)
                minisLogger.info("[Share] item[\(i)] addFileAttachment done, attachments count=\(self.vm.attachments.count)")
            }
        }

        // Clean up shared files after ingestion
        SharedContainerStore.cleanSharedFiles()

        minisLogger.info("[Share] Injection complete. inputText='\(String(self.vm.inputText.prefix(100)))' attachments=\(self.vm.attachments.count)")

        hasInjectedShareContent = true

        // Focus input if we injected text
        if !vm.inputText.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard self.canRunDelayedComposerFocus("share") else { return }
                inputFocused = true
            }
        }
    }

    // MARK: - Pending Transfer Injection

    func injectPendingTransferIfNeeded() {
        guard let transfer = ViewModelCache.pendingTransfer else { return }

        // [T-ios-moveto-transfer-race] Only the intended target may consume the
        // stash. Previously ANY session that appeared first took it, so a
        // swallowed push meant the content surfaced in whatever session the
        // user opened next. A mismatch is not an error — it just means we are
        // not the target — so leave the stash alone and let the real target
        // claim it. Time-based cleanup is what stops it lingering forever.
        //
        // [T-ios-moveto-new-session] The target may be a NOT-YET-CREATED
        // session. "Move to… → New Chat" stages the synthetic `__new__<UUID>`
        // draft id that ContentView is about to push, but that view is built as
        // `AIChatView(sessionId: nil, draftId: "__new__…")` — the real session
        // row only exists once the user sends. Matching `vm.sessionId` alone
        // therefore NEVER matched for a new-chat target: the stash sat
        // unclaimed until it went stale and was deleted, so the moved text and
        // images vanished with no restore (the source view that owns the
        // restore timer has already been popped by then). Match `draftId` too.
        let isTarget = transfer.targetId == vm.sessionId || transfer.targetId == draftId
        guard isTarget else {
            if transfer.isStale {
                ViewModelCache.discardPendingTransfer(reason: "stale, target \(transfer.targetId) never appeared")
            }
            return
        }
        guard !transfer.isStale else {
            ViewModelCache.discardPendingTransfer(reason: "target \(transfer.targetId) appeared too late")
            return
        }

        ViewModelCache.pendingTransfer = nil
        minisLogger.info("[MoveTo] Injecting transfer: text='\(String(transfer.inputText.prefix(50)))' attachments=\(transfer.attachments.count) existing=\(vm.attachments.count)")
        // Clean up any stale unsent attachments on the target VM before injecting
        if !vm.attachments.isEmpty {
            minisLogger.info("[MoveTo] Clearing \(vm.attachments.count) stale attachments from target session")
            for a in vm.attachments { try? FileManager.default.removeItem(at: a.cacheURL) }
            vm.attachments.removeAll()
        }
        if !transfer.inputText.isEmpty {
            if !vm.inputText.isEmpty { vm.inputText += "\n" }
            vm.inputText += transfer.inputText
        }
        vm.attachments = transfer.attachments
        // Focus input after the view is fully settled and keyboard from
        // the source session has dismissed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard self.canRunDelayedComposerFocus("transfer") else { return }
            inputFocused = true
        }
    }

    /// [T-pop-keyboard-late-autofocus] Guard for every DELAYED composer focus:
    /// the page must still be visible AND not committed to leaving (see
    /// PageLeaveLatch). Immediate, user-driven focus does not go through here.
    func canRunDelayedComposerFocus(_ source: String) -> Bool {
        guard pageLeaveLatch.allowsDelayedFocus(isVisible: isChatViewVisible) else {
            if pageLeaveLatch.isLeaving {
                AppLogger(category: "InputBarLayout").info("delayed composer focus (\(source)) skipped — the page is leaving")
            }
            return false
        }
        return true
    }
}
