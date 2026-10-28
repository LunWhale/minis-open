//
//  AIChatViewModel+Send.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, starting a turn: send() (composer, programmatic prompts,
//  edit re-send, compaction gate, queueing while busy), retry() of the failed
//  iteration, resume() of an interrupted loop, and resumeUnansweredUserTurn
//  for a user turn that never got a reply. Each ends by running the agent
//  loop (AIChatViewModel+AgentLoop.swift).
//
//  Map of the AIChatViewModel files: AIChatViewModel.swift.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {
    // MARK: - Send Message

    /// - Parameter overrideText: [T-programmatic-prompt-no-composer] the prompt
    ///   to send, for callers that are not the composer (a job callback, a
    ///   scheduled trigger, the CLI, a Shortcut). nil — the user's own tap —
    ///   means "take the draft", and is the only case that clears it. Passing
    ///   the text here keeps a background turn from reading, overwriting, or
    ///   emptying whatever the user is typing at that moment.
    func send(overrideText: String? = nil) {
        settlePendingStop(before: "send")  // [T-stop-cleanup-before-new-turn]
        // Read-only mode — cannot send messages
        guard remoteDeviceId == nil else { return }
        // Every `inputText = ""` below is guarded by this: the composer is
        // emptied only when the composer is what was sent.
        let usingComposer = overrideText == nil

        // [T-ios-retry-keyboard] A real send clears the retry origin, so the
        // flag can never leak from a retried turn into the next fresh one and
        // suppress a focus the user does want.
        turnStartedByRetry = false

        // [T-ios-photo-pick-placeholder] Drop any non-ready attachments (failed
        // photo loads, or a stray still-loading placeholder) so only fully-loaded
        // files are sent. `canSend` already blocks sending while anything loads,
        // so in practice this just prunes failed chips the user left in place.
        attachments.removeAll { $0.loadState != .ready }

        // [T-paste-mediaref] The draft's `[Pasted#N]` literals are NO LONGER
        // expanded here. They now survive into agentHistory and the stored
        // message; the full text is inlined only when a request is built
        // (applyRequestImageBudget → expandPastedPlaceholdersForRequest) and
        // persisted as a compact `.mediaRef` (buildRawMessage).
        //
        // Why: expanding here put the whole paste into `parts_json` as one
        // giant `.text`, so every later render of that message had to typeset
        // it — the same super-linear CoreText cost behind the 50KB tool-result
        // and 1M-char paste-preview watchdog kills. The model still sees the
        // text inline at the same position; only the local storage differs.
        let text = (overrideText ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        #if DEBUG
        logger.info("🔑DRAFT [vm=\(self.vmInstanceId)] send() text=\(text.count)ch attachments=\(pendingAttachments.count) isProcessing=\(self.isProcessing) sessionId=\(self.sessionId ?? "nil") draftId=\(self.draftId ?? "nil") inputText='\(String(self.inputText.prefix(30)))'")
        #else
        logger.info("🔑DRAFT [vm=\(self.vmInstanceId)] send() text=\(text.count)ch attachments=\(pendingAttachments.count) isProcessing=\(self.isProcessing) sessionId=\(self.sessionId ?? "nil") draftId=\(self.draftId ?? "nil")")
        #endif
        guard !text.isEmpty || !pendingAttachments.isEmpty, !isProcessing else {
            logger.warning("🔑DRAFT [vm=\(self.vmInstanceId)] send() GUARD FAILED — text.isEmpty=\(text.isEmpty) attachments.isEmpty=\(pendingAttachments.isEmpty) isProcessing=\(self.isProcessing)")
            return
        }

        // Don't stop TTS here — let the previous reply finish playing. The stream
        // handler will clear the queue on the FIRST textDelta of the new reply, so
        // the old audio plays until actual new content starts arriving.
        resetReplyTTSEngine()
        // Re-arm the once-per-turn TTS clear: the agent loop creates a fresh
        // StreamResult per iteration, so the "stopped previous TTS" flag must
        // live HERE (per-send), not on the StreamResult — otherwise every loop
        // iteration's first textDelta re-cleared the queue and cut off the
        // previous iteration's still-playing speech mid-sentence.
        hasClearedTTSForCurrentTurn = false

        // [T-voice-mode-memory-refine-ios] The SEND commits the composer mode.
        // "voice" is recorded ONLY here — when a voice-composed message is
        // actually sent — so an accidental mic tap that never leads to a send
        // can't flip the default (mic-start no longer writes "voice"). A typed
        // send with no voice session records "text". Attachment-only sends say
        // nothing about typing. (text is also written eagerly on switch-to-text
        // in the composer; saveInputModePreference no-ops when unchanged.)
        if !text.isEmpty {
            SpeechRecognitionManager.saveInputModePreference(voiceUsedInComposition ? "voice" : "text")
        }

        // [T-voice-correction-productionize] Harvest typed vocabulary from sent
        // messages (cold-start data for the voice corrector, design §3.3).
        // Fire-and-forget at background priority — buildIfNeeded() throttles
        // itself (1h min interval + batch threshold) and the write layer is
        // consent-gated (VoiceCorrectionCollectionConsent, default OFF), so
        // without opt-in this is a cheap early return.
        if !text.isEmpty {
            Task.detached(priority: .background) {
                await TypedVocabularyBuilder.shared.buildIfNeeded()
            }
        }

        // Check if context is near capacity
        if skipCompactCheck {
            skipCompactCheck = false
        } else {
            // [T-ctx-trim-ladder] Trim first, so a request that fits after a
            // trim is neither compacted nor asked about. A tier that can never
            // compact (window under 64K) may collapse at once.
            replanTrim(site: "pre-send", allowCollapse: !contextPolicyAllowsAutoCompact())
            switch checkContextBeforeSend() {
            case .ok:
                break
            case .needsCompact:
                if sessionSource == "shortcut" || autoCompactEnabled {
                    // Shortcut sessions can't show UI prompts; auto-compact
                    // opt-in [T-chat-auto-compact-opt-in] rides the same
                    // no-prompt path — compact and send without asking.
                    logger.info("[Context] Near capacity — auto-compacting (\(sessionSource == "shortcut" ? "shortcut session" : "autoCompactEnabled"))")
                    pendingSendText = text
                    pendingSendAttachments = pendingAttachments
                    pendingSendIsFromComposer = usingComposer
                    if usingComposer { inputText = "" }
                    attachments = []
                    compactAndSend()
                    return
                }
                pendingSendText = text
                pendingSendAttachments = pendingAttachments
                pendingSendIsFromComposer = usingComposer
                if usingComposer { inputText = "" }
                attachments = []
                showCompactBeforeSendPrompt = true
                logger.info("[Context] Near capacity — prompting user to compact before send")
                return
            case .exhausted:
                if sessionSource == "shortcut" {
                    // Shortcut sessions can't show UI — set inline error
                    logger.info("[Context] Exhausted — shortcut session cannot continue")
                    let errMsg = ChatMessage(role: .assistant, content: "", blocks: [])
                    errMsg.error = AppLocalized("Context full. Start a new session to continue.")
                    messages.append(errMsg)
                    return
                }
                pendingSendText = text
                pendingSendAttachments = pendingAttachments
                pendingSendIsFromComposer = usingComposer
                if usingComposer { inputText = "" }
                attachments = []
                showContextExhaustedPrompt = true
                logger.info("[Context] Exhausted — prompting user to start new session or clear chat")
                return
            }
        }

        if !programmaticSilentTurn {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        autoRetryAttempt = 0
        autoRetryCountdown = 0
        canResume = false
        committedBlockCount = 0
        prevCommittedBlockCount = 0
        userDidCancel = false
        delegationResultsMuted = false

        if usingComposer { inputText = "" }

        // If editing a previous message, truncate conversation from that point first
        // [T-bubble-span] An edit is "delete from here" + an ordinary send:
        // cut the edited bubble (from its merged group's first bubble) and its
        // entry with the locator retry and delete use, then fall through and
        // send the new text as a new message. The edited row is never
        // rewritten in place, so the DB and sync see a plain delete + insert.
        if editingMessageIndex != nil {
            let editIdx = resolveEditedBubbleIndex()
            clearEditingState()
            if let editIdx {
                cutAtUserBubble(editIdx, keepBubble: false, site: "edit")
                // Phase B: agentHistory is no longer mutated by compact, so agentHistory.count
                // is 1:1 with the DB row count; passing it as keepCount is semantically correct.
                let persistedKeepCount = agentHistory.count
                let hasMarker = cachedLatestMarker != nil
                logger.info("[DeleteAfter] edit path: sid=\(sessionId?.prefix(8) ?? "nil") keepCount=\(persistedKeepCount) hasMarker=\(hasMarker)")
                if let sessionId {
                    Task { await ChatStore.shared.deleteMessagesAfter(sessionId: sessionId, keepCount: persistedKeepCount) }
                }
                rebuildToolSnapshotsFromMessages()
                logger.info("✏️ send() edit applied: truncated to \(self.messages.count) messages, \(self.agentHistory.count) history entries")
            } else {
                // Nothing to cut: the chat still shows whatever the model keeps,
                // so the new text simply goes out as a new message.
                logger.warning("[BubbleSpan] edit: edited bubble no longer found — sending as a new message")
            }
        }

        // Close any stale tool blocks still showing as streaming/running from a
        // previous interrupted response so the UI stops showing loading indicators.
        for msg in messages where msg.role == .assistant {
            for block in msg.blocks {
                if let status = block.toolStatus {
                    switch status {
                    case .streaming, .running:
                        block.toolStatus = .cancelled
                    default: break
                    }
                }
            }
        }

        // Note: toolSnapshots are NOT cleared here so the floating toolbar shows the full session history
        // [T-paste-live-bubble-card] The bubble text KEEPS the `[Pasted#N]`
        // literal (user requirement: the marker shows where the pasted content
        // sits in the message), and the bubble is BORN with its paste cards —
        // planned here synchronously, files written to the planned ids by
        // consumePastedDraft below. Attaching cards after the first render
        // never showed them on device.
        let pastePlanned = planPastedCards(for: text)
        let displayText = text.isEmpty && pendingAttachments.isEmpty ? "" : text
        let userMsg = ChatMessage(role: .user, content: displayText)
        userMsg.awaitingHistoryEntry = true  // [T-edit-anchor-link] cleared when the entry lands
        userMsg.attachments = pastePlanned.metas
        // [T-ios-user-attach-two-phase-birth] Attach the user's OWN selection before
        // the row is inserted, so the cell is born with its final height.
        //
        // The list's height estimator already prefers `attachments` and falls back to
        // `inputAttachments` (CollectionViewMessageListV3 ~3036 and ~3334), and the tile
        // block is pure geometry — `UserAttachmentTileMetrics.blockHeight(count:availableWidth:)`
        // takes only a COUNT and a width (tile 64pt, gap 6pt). Nothing in `AttachmentMeta`
        // (path / size / modified) feeds the height, so the count is fully known here and
        // never needed the file I/O below.
        //
        // Without this line the fallback always read 0: `attachments` is only assigned
        // after the copy/compress/upload pass (~2500), so the row was inserted as
        // text-only, estimated short, and grew a second time when the metas landed —
        // an UNDER-estimate, the harmful direction (f1304a3e1 measured est=48 at insert
        // vs est=118 some 350ms later). That two-phase birth is the race the mount-time
        // invalidations (988f67b8, 9be8058f) were added to chase; seeding here removes
        // the window itself rather than reacting to it. The later
        // `userMsg.attachments = attachmentMetas` then only adds metadata and no longer
        // changes the height.
        //
        // `enqueuePrompt` (AIChatViewModel+Misc ~72) has always done exactly this before
        // its own append; this is the send path catching up, not a new mechanism.
        userMsg.inputAttachments = pendingAttachments
        messages.append(userMsg)

        // Snapshot and clear attachments synchronously so the UI clears immediately
        clearAttachments()
        scrollToBottomSignal.send()

        isProcessing = true
        errorMessage = nil
        logger.info("🔄SESSION [vm=\(self.vmInstanceId)] send START session=\(self.sessionId ?? "nil")")

        // Ensure kernel is booted before running
        ensureKernelBooted()
        beginBackgroundProcessing()

        currentTask = Task { [weak self] in
            guard let self else { return }

            // Lazily create session before persisting anything
            await self.ensureSession()

            // Defensive: ensure tracker reflects the real session ID after draft→real migration.
            if let sid = self.sessionId, self.isProcessing {
                SessionActivityTracker.shared.setActive(sid, source: "vm=\(self.vmInstanceId) send/ensureSession draft→real")
            }

            // Copy attachment files to session uploads dir and build metadata
            let fm = FileManager.default
            let sid = self.sessionId ?? "unknown"
            let uploadsDir = Self.minisUploadsDir(for: sid)
            try? fm.createDirectory(at: uploadsDir, withIntermediateDirectories: true)

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            let now = Date()
            let nowStr = isoFormatter.string(from: now)

            var attachmentMetas: [AttachmentMeta] = []
            var userParts: [AgentContentPart] = []

            // User attachments always take priority over history images — see
            // the same rationale in buildUserMessageParts. Stale history
            // images will be evicted by the trim pass before the next API
            // call.
            let inlineBudget = Self.kImageContextKeepCount
            var inlinedImages = 0
            // Cumulative BASE64 bytes of all inlined image payloads in this
            // message — i.e. the space they take in the request body, not
            // their decoded size ([T-image-budget-base64]). Once this passes
            // kMessageImageMaxBytes the remaining images are dropped to a text
            // placeholder instead of being base64-inlined.
            // T-imgsize-13b7d81c.
            var cumulativeImageBytes = 0

            logger.info("📎[SEND-ASYNC] Processing \(pendingAttachments.count) attachments, uploadsDir=\(uploadsDir.path), imageBudget=\(inlineBudget) byteBudget=\(Self.kMessageImageMaxBytes)")
            for (i, attachment) in pendingAttachments.enumerated() {
                let fileExists = fm.fileExists(atPath: attachment.cacheURL.path)
                logger.info("📎[SEND-ASYNC] attachment[\(i)] kind=\(String(describing: attachment.kind)) file=\(attachment.fileName) cacheExists=\(fileExists)")

                guard fileExists else {
                    logger.error("📎[SEND-ASYNC]   FAILED — source missing at \(attachment.cacheURL.path)")
                    continue
                }

                // [T-ios-attachment-oom-bg-kill] Read file metadata (date + size)
                // WITHOUT loading the file into memory. Previously this did
                // `Data(contentsOf:)` on every attachment just to copy it to the
                // uploads dir and record its size — for a large attachment (e.g. a
                // 368 MB sysdiagnose) that spiked the app footprint by the file's
                // full size (~370 MB → ~690 MB total) for several seconds per send.
                // Backgrounding inside that window let iOS jetsam-SIGKILL the
                // process (it reclaims high-memory background apps first), which
                // looked like "the message stopped instantly / was never sent".
                let attrs = try? fm.attributesOfItem(atPath: attachment.cacheURL.path)
                // Preserve original file date if available (e.g. PHAsset creation date)
                let fileDate: Date = (attrs?[.modificationDate] as? Date) ?? now
                let fileSize = (attrs?[.size] as? Int) ?? 0

                let safeName = Self.uniqueFileName(for: attachment.fileName, in: uploadsDir)
                let destURL = uploadsDir.appendingPathComponent(safeName)
                // Stream the file on disk (near-zero RAM) instead of materializing
                // it as Data and writing it back out. copyItem won't overwrite, and
                // uniqueFileName already guarantees a fresh name, so no clobber.
                do {
                    try fm.copyItem(at: attachment.cacheURL, to: destURL)
                } catch {
                    logger.error("📎[SEND-ASYNC]   FAILED to copy \(attachment.cacheURL.lastPathComponent) → \(destURL.path): \(error.localizedDescription)")
                    continue
                }
                try? fm.setAttributes([.creationDate: fileDate, .modificationDate: fileDate], ofItemAtPath: destURL.path)
                let linuxPath = "/var/minis/attachments/uploads/\(safeName)"
                let meta = AttachmentMeta(path: linuxPath, size: fileSize, modified: fileDate)
                attachmentMetas.append(meta)
                logger.info("📎[SEND-ASYNC]   saved \(safeName): \(fileSize) bytes → \(linuxPath)")

                // [T-ios-attachment-oom-bg-kill] Only IMAGES need the bytes in
                // memory (for resize/compress/inline below). Non-image attachments
                // are already persisted via the streaming copy above — never load
                // them into RAM. Images are small (camera/screenshot/photo), so
                // loading them here is bounded and safe.
                guard attachment.kind == .image else { continue }
                guard let data = try? Data(contentsOf: attachment.cacheURL) else {
                    logger.error("📎[SEND-ASYNC]   image load failed (kept on disk) \(attachment.cacheURL.path)")
                    continue
                }

                // For images: send a resized + size-budgeted copy to the
                // model. Two budgets layered on top of the existing 20-image
                // count cap:
                //   1. Per-image: if the resize-to-2000px output is still
                //      over 5 MB, run the compressor ladder (smaller edges,
                //      lower JPEG quality) until it fits or until we've
                //      shrunk it as far as we usefully can.
                //   2. Per-message: cap cumulative inlined bytes at 20 MB.
                //      Once that's hit, remaining images fall through to
                //      the same text placeholder the count cap uses.
                // T-imgsize-13b7d81c.
                // (Reaching here implies .image — the non-image guard above
                // already `continue`d. Kept as an explicit guard for clarity.)
                if attachment.kind == .image {
                    if inlinedImages < inlineBudget {
                        // [T-image-real-seams] Resize, compressor ladder and MIME
                        // live in `inlineAttachmentImage(_:ext:route:)`, shared
                        // with the queued-prompt path (route .queue).
                        let ext = attachment.cacheURL.pathExtension.lowercased()
                        let inline = await MainActor.run { Self.inlineAttachmentImage(data, ext: ext, route: .send) }
                        let resized = inline.resized
                        let compressed = inline.final
                        let compressedB64 = Self.estimatedBase64Length(compressed.count)
                        let stillOversize = compressedB64 > Self.kPerImageMaxBytes
                        let wouldOverflowMessage = Self.attachmentImageOverflowsMessage(cumulativeImageBytes: cumulativeImageBytes, compressedB64: compressedB64)
                        if wouldOverflowMessage {
                            // Drop to placeholder rather than risk a 413 on
                            // the whole message — the user keeps the file on
                            // disk and can still reference it via shell tools.
                            let placeholder = Self.imagePlaceholderText(data: data, originalPath: linuxPath, snapshotPath: nil)
                            userParts.append(.text(placeholder))
                            logger.warning("📎[SEND-ASYNC]   image \(i) dropped to placeholder — cumulative \(cumulativeImageBytes) + this \(compressedB64) (base64 of \(compressed.count) raw) > \(Self.kMessageImageMaxBytes) message budget")
                        } else {
                            let mime = inline.mimeType
                            userParts.append(.text("[attached image: \(linuxPath)]"))
                            userParts.append(.imageData(data: compressed, mimeType: mime, linuxPath: linuxPath))
                            inlinedImages += 1
                            cumulativeImageBytes += compressedB64
                            logger.info("📎[SEND-ASYNC]   image \(inlinedImages)/\(inlineBudget) inlined: orig=\(data.count) resized=\(resized.count) final=\(compressed.count) base64=\(compressedB64) cumulative=\(cumulativeImageBytes)/\(Self.kMessageImageMaxBytes) mime=\(mime) stillOversize=\(stillOversize)")
                            if stillOversize {
                                logger.warning("📎[SEND-ASYNC]   image \(i) still over per-image budget after compression ladder — Provider may 413; sent anyway")
                            }
                        }
                    } else {
                        let placeholder = Self.imagePlaceholderText(data: data, originalPath: linuxPath, snapshotPath: nil)
                        userParts.append(.text(placeholder))
                        logger.info("📎[SEND-ASYNC]   image not inlined (count budget \(inlineBudget) exhausted), placeholder for \(linuxPath)")
                    }
                }
            }

            // Clean up cached attachment files now that data has been copied
            Self.cleanupAttachmentFiles(pendingAttachments)

            // Update ChatMessage with structured attachment metadata for UI display
            //
            // [T-ios-user-attach-mount-invalidate] THIRD mount site. 988f67b8
            // covered only the two queued-drain sites (both keyed on
            // `queuedPromptId`); this is the ORDINARY send path, and it has the
            // same two-phase birth: `messages.append(userMsg)` runs
            // synchronously before this Task, so the message is inserted
            // TEXT-ONLY and the tiles arrive here, one attachment-I/O later. If
            // the cell's first real self-size lands in that window it caches a
            // tile-less height, and without an invalidation pair the width-
            // matched cell cache (b4268586) plus the streaming-window
            // short-circuit (81e43b58) serve it for the rest of the turn —
            // the truncated bubble with a seemingly detached tile.
            //
            // Field report 2026-08-09 (image via the system share
            // sheet) reproduced exactly this on a build where `AttachMount` had
            // zero hits across the whole log: est=48 attachCount=0 at insert,
            // est=118 attachCount=1 some 350ms later, and no idx=0 real measure
            // in between. Share/voice sends widen the window precisely because
            // they do more attachment I/O — which 988f67b8's own message called
            // out while still leaving this site unpatched.
            await MainActor.run {
                // [T-paste-live-bubble-card] Keep the birth-time paste cards —
                // a plain assignment here would wipe them.
                userMsg.attachments = attachmentMetas + pastePlanned.metas
                if !attachmentMetas.isEmpty {
                    NotificationCenter.default.post(name: .minisUserAttachmentsMounted,
                                                    object: userMsg.id)
                }
            }

            // Build <user-attached-files> XML metadata for the model (no base64 data)
            if !attachmentMetas.isEmpty {
                var xml = "<user-attached-files>\n"
                for meta in attachmentMetas {
                    xml += "  <file path=\"\(meta.path)\" url=\"\(meta.minisURL)\" size=\"\(meta.size)\" modified=\"\(nowStr)\" />\n"
                }
                xml += "</user-attached-files>"
                userParts.append(.text(xml))
            }

            // Batch-reading tip when images were omitted
            let totalImageAttachments = pendingAttachments.filter { $0.kind == .image }.count
            if totalImageAttachments > inlinedImages {
                let omitted = totalImageAttachments - inlinedImages
                userParts.append(.text(
                    "<system-reminder>Only \(inlinedImages) of \(totalImageAttachments) images are inlined above."
                    + " The remaining \(omitted) are saved to disk — use read_image to view them."
                    + " To stay within the context image limit (\(Self.kImageContextKeepCount)),"
                    + " process images in batches: read a batch, analyze, then summarize your findings"
                    + " before reading the next batch.</system-reminder>"
                ))
            }

            // [T-paste-single-split] Expand `[Pasted#N]` literals HERE, at the
            // draft→AgentMessage boundary, so agentHistory always carries the
            // full pasted content and every downstream provider/compaction/
            // retry path is correct without a request-time expansion step.
            var pastedStoredParts: [String: [ContentPart]] = [:]
            if !text.isEmpty {
                if let consumed = await self.consumePastedDraft(text, sessionId: sid,
                                                               plannedFileIds: pastePlanned.plan) {
                    userParts.append(.text(consumed.modelText))
                    pastedStoredParts[consumed.modelText] = consumed.storedParts
                    // [T-paste-live-bubble-card] The bubble was born with the
                    // planned cards; this only reconciles ids the plan missed
                    // (a chip removed mid-send leaves a dead card at worst).
                    // Never added to attachmentMetas — the paste must not
                    // enter the <user-attached-files> XML the model reads.
                    let extra = consumed.liveCardMetas.filter { meta in
                        !pastePlanned.metas.contains(where: { $0.path == meta.path })
                    }
                    if !extra.isEmpty {
                        await MainActor.run {
                            userMsg.attachments.append(contentsOf: extra)
                            NotificationCenter.default.post(name: .minisUserAttachmentsMounted,
                                                            object: userMsg.id)
                        }
                    }
                } else {
                    userParts.append(.text(text))
                }
            }
            // [T-bubble-span] A Stop followed by an edit or delete-from-here
            // during the awaits above already removed this bubble (see
            // cutAtUserBubble); landing the entry now would put the removed
            // message back behind that cut. Drop this turn — whatever ran the
            // cut owns the session now, so nothing here (isProcessing, slot)
            // is touched.
            if self.abandonedPendingSendIds.remove(userMsg.id) != nil {
                logger.info("[BubbleSpan] send: bubble removed before its history entry landed — dropping the stale turn")
                return
            }
            let userMessage = AgentMessage(role: .user, parts: userParts)
            self.agentHistory.append(userMessage)
            userMsg.historyAnchorId = userMessage.anchorId
            userMsg.awaitingHistoryEntry = false

            // Persist user message and write the DB id back into agentHistory so
            // compact can later resolve boundaries by id.
            // [T-bubble-span] Write back by anchor, not by index: a Stop + edit
            // or delete during this await can cut the entry, and the index
            // would then stamp the id onto whatever took its place.
            if let persistedId = await self.persistAgentMessage(userMessage, pastedParts: pastedStoredParts),
               let i = self.agentHistory.firstIndex(where: { $0.anchorId == userMessage.anchorId }) {
                self.agentHistory[i].dbMessageId = persistedId
            }

            // Wait for kernel to finish booting
            while self.kernelStatus == .booting {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if case .failed(let msg) = self.kernelStatus {
                self.errorMessage = "Kernel not available: \(msg)"
                self.isProcessing = false
                self.endBackgroundProcessing()
                return
            }

            // Concurrency gate: wait for a processing slot
            guard let slotLease = await self.acquireSessionSlot(sid) else { return }
            defer { SessionConcurrencyManager.shared.release(slotLease) }

            do {
                try await self.runAgentLoop()
            } catch is CancellationError {
                logger.info("Agent loop cancelled")
                self.finishStoppedTurn()
            } catch {
                let rawDesc = String(describing: error)
                logger.error("Agent loop error: \(rawDesc)")
                if let llmErr = error as? LLMError {
                    logger.error("Agent loop LLMError detail: \(llmErr.errorDescription ?? "nil")")
                }
                if self.turnWasStopped {   // [T-stop-queued-cancel-error]
                    self.finishStoppedTurn()
                } else {
                    let displayDesc = Self.friendlyErrorMessage((error as? LocalizedError)?.errorDescription ?? rawDesc)
                    // [T-ios-retry-tool-blocks-invisible / T-stream-empty-banner-trace]
                    // Resolve the streaming assistant by the last ASSISTANT row,
                    // not messages.last. A queued .user message (enqueuePrompt
                    // appends one mid-tool) sits AFTER the candidate, so
                    // messages.last would be that user row — the error then fell
                    // through to the top red banner (vm.errorMessage) instead of
                    // attaching to the assistant bubble. Same root cause as the
                    // Stop-loses-content fix.
                    if let last = self.messages.last(where: { $0.role == .assistant }) {
                        last.error = displayDesc
                        last.blocks.removeAll { $0.kind == .text && $0.content.isEmpty }
                        // Cancel stale tool blocks left in streaming/running state
                        for block in last.blocks {
                            if case .streaming = block.toolStatus { block.toolStatus = .cancelled }
                            else if case .running = block.toolStatus { block.toolStatus = .cancelled }
                        }
                        Task { await self.persistErrorInfo(displayDesc) }  // [T-error-persist-ios]
                    } else {
                        self.reportTurnFailure(displayDesc)   // [T-ios-error-banner-lost]
                    }
                }
            }
            // If the user tapped Stop while the loop was finishing, still mark as interrupted.
            if self.userDidCancel { self.handleUserCancelledCleanup() }

            // [T-stop-with-queue-render-desync] Stop hands ownership to cancel():
            // it already set isProcessing=false / endBackgroundProcessing(), and
            // with queued prompts it spawned a fresh drain task that sets
            // isProcessing=true for the continued run. Running this epilogue from
            // the superseded task would drain concurrently and force
            // isProcessing=false mid-run — the chat stops rendering the live tool
            // loop while the preview bar / Live Activity keep updating.
            guard !Task.isCancelled else {
                logger.info("🔄SESSION [vm=\(self.vmInstanceId)] send epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }

            await self.drainQueuedPrompts()

            // Refresh lastKnownDbSortOrder from the actual DB so iCloud sync
            // doesn't mistake our own persisted messages for remote ones.
            // The in-memory += 1 tracking can drift if messages are batched or retried.
            if let sid = self.sessionId {
                let dbMessages = await ChatStore.shared.loadMessages(sessionId: sid)
                self.lastKnownDbSortOrder = dbMessages.last?.sortOrder ?? self.lastKnownDbSortOrder
                self.lastKnownDbCount = dbMessages.count
                // T-baseline-hash-drift: also refresh lastKnownDbOrderHash —
                // otherwise reloadMessagesFromDB's hasReorderedMessages check
                // sees the old (pre-INSERT) hash vs the new (post-INSERT)
                // row set, flags a fake reorder, and fires loadSession()
                // (spinner ON ~460ms) on the next iCloud fetch notification.
                self.lastKnownDbOrderHash = Self.computeOrderHash(of: dbMessages)
            }

            logger.info("🔄SESSION [vm=\(self.vmInstanceId)] send DONE session=\(self.sessionId ?? "nil")")
            self.playCompletionHaptic()
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// Retry the next agent loop iteration (continue from where the error occurred,
    /// keeping all previously completed tool blocks and conversation history).
    func retry() {
        settlePendingStop(before: "retry")  // [T-stop-cleanup-before-new-turn]
        guard !isProcessing else { return }
        guard let lastMsg = messages.last, lastMsg.role == .assistant else { return }

        // [T-ios-retry-keyboard] This turn exists because the user re-sent an
        // old failure, so its completion must not be treated as "a reply
        // arrived" by the auto-focus observer.
        turnStartedByRetry = true

        autoRetryAttempt = 0
        autoRetryCountdown = 0
        canResume = false
        userDidCancel = false
        delegationResultsMuted = false

        // [T-ios-stale-error-banner] The tail row's error used to be cleared
        // here; `clearSupersededErrors` above now does that for every row, not
        // just the last, because a rate-limit fallback appends a NEW carrier row
        // per failure and the earlier ones were never candidates for a
        // tail-only clear. The agentHistory-keyed persisted clear below is kept:
        // it targets the DB row this sweep cannot see.

        // [T-compact-retry-stale-status] Sweep any compact status row left by a
        // FAILED compaction before this retry runs.
        //
        // Those rows ("Compaction failed: …" / "Compaction cancelled.") are
        // in-memory only and describe one finished attempt. Only `compactBefore`
        // swept them, so after `compact → fail → retry` the notice stayed in the
        // transcript while the retried turn streamed underneath it — the chat
        // read as though a compaction were still pending or had just applied
        // here, which is what made a later compact look like it had already run
        // to this point. The retried turn is a fresh state; the old attempt's
        // status does not describe it.
        //
        // Deliberately does NOT touch `.compactDivider` rows or
        // `isCompactedHistory` flags: those record a compaction that genuinely
        // SUCCEEDED, and a failed compaction never sets them (compactBefore
        // returns at its failure branch well before the divider insert), so
        // there is no false "already compacted" state to unwind — only this
        // stale caption.
        clearCompactStatusRows()

        // [T-error-persist-retry-clear-ios] Also clear the PERSISTED error_info,
        // and do it BEFORE agentHistory.removeLast() below severs the only link
        // to the stalled row's dbMessageId. `lastMsg.error = nil` above only
        // clears the in-memory banner: the DB row written by persistErrorInfo at
        // stall time kept its error_info, because the resumed loop persists its
        // turns into NEW rows (the loop-end unconditional error write at
        // [T-error-persist-ios] edge #5 keys off the NEW persistedId, never the
        // orphaned old row). Observed on device (GH#181 family): a DeepSeek
        // stream died silently mid-turn (no finish/[DONE]), the 120s stall
        // watchdog fired and persisted the error, retry() resumed and the
        // conversation completed — but the next session load re-materialised
        // the stale banner from the DB, mid-way through a visibly finished
        // conversation (row: created==updated, untouched since the stall).
        if let staleDbId = agentHistory.last(where: { $0.role == .assistant && $0.dbMessageId != nil })?.dbMessageId {
            Task { await ChatStore.shared.updateMessageErrorInfo(messageId: staleDbId, errorInfo: nil) }
            logger.info("[ErrorPersist] retry() clearing persisted error_info on msg=\(staleDbId.prefix(8))")
        }

        // Remove blocks from the incomplete/interrupted iteration.
        // committedBlockCount tracks how many blocks were fully committed before the
        // interruption. Anything beyond that is partial streaming content that should
        // be discarded so the retry starts cleanly from the last committed state.
        //
        // [T-ios-retry-wipes-prior-text] Use clearUncommittedStreamTail instead of a
        // blind `removeSubrange(committedBlockCount...)`. committedBlockCount is a
        // shared instance property; error-interrupted (non-cancel) paths don't update
        // it, so on retry it can LAG behind the message's actual committed+persisted
        // block count. A blind removeSubrange then wipes already-committed non-empty
        // text/terminal-tool blocks the user had on screen (the "retry makes all prior
        // output vanish" report; DB intact since retry only mutates the in-memory
        // array). The shared helper drops only the uncommitted tail's partial text +
        // streaming/running tools and ALWAYS keeps non-empty text and terminal tool
        // results — identical to the blind trim in the normal case (tail is empty/
        // partial text + in-flight tools), but it never removes committed output.
        AppLogger(category: "RetryDiag").info("[RetryDiag] retry() pre-trim committedBlockCount=\(self.committedBlockCount) blocks=\(lastMsg.blocks.count) kinds=[\(lastMsg.blocks.map { $0.kind == .text ? "t\($0.content.isEmpty ? "0" : "\($0.content.count)")" : "tool(\($0.toolStatus.map { String(describing: $0) } ?? "nil"))" }.joined(separator: ","))]")
        Self.clearUncommittedStreamTail(lastMsg, committedBlockCount: committedBlockCount)
        // Also remove any trailing empty text blocks left by prior iterations
        lastMsg.blocks.removeAll { $0.kind == .text && $0.content.isEmpty }

        // Roll back only the last failed assistant entry from conversation history.
        // The history at this point looks like:
        //   ... user(tool_results) assistant(failed/partial)
        // We need to remove just the trailing assistant entry so the API call retries
        // with the tool results as the last message.
        if agentHistory.last?.role == .assistant {
            agentHistory.removeLast()
        }

        // Clean orphaned tool_results that reference tool_uses no longer in history.
        // This fixes API 400: "unexpected tool_use_id found in tool_result blocks"
        // which occurs after partial cancellation or interrupted streaming.
        var allRetryToolUseIds = Set<String>()
        for msg in agentHistory { for part in msg.parts {
            if case .toolUse(let id, _, _, _) = part { allRetryToolUseIds.insert(id) }
        }}
        for i in (0..<agentHistory.count).reversed() {
            guard agentHistory[i].role == .user else { continue }
            let cleaned = agentHistory[i].parts.filter { part in
                if case .toolResult(let id, _, _, _, _, _, _, _, _) = part { return allRetryToolUseIds.contains(id) }
                return true
            }
            if cleaned.isEmpty { agentHistory.remove(at: i) }
            else if cleaned.count < agentHistory[i].parts.count {
                agentHistory[i].parts = cleaned  // [T-history-rebuild-keeps-ids] keep dbMessageId
            }
        }

        // [T-ios-stale-error-banner] Was a bare `errorMessage = nil`, which cleared
        // only the transient top banner. The row-attached error cards (and their
        // persisted error_info) stayed in the transcript while the continued turn
        // streamed underneath them. Runs BEFORE the index is captured: the sweep
        // can remove empty carrier rows, which would shift `messages.count`.
        clearSupersededErrors(reason: "retry", keeping: lastMsg)
        let existingMsgIdx = messages.count - 1
        let existingBlockCount = lastMsg.blocks.count
        isProcessing = true
        isNearBottom = true
        forceScrollToBottom.send()

        ensureKernelBooted()
        beginBackgroundProcessing()

        currentTask = Task { [weak self] in
            guard let self else { return }

            while self.kernelStatus == .booting {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if case .failed(let msg) = self.kernelStatus {
                self.errorMessage = "Kernel not available: \(msg)"
                self.isProcessing = false
                self.endBackgroundProcessing()
                return
            }

            // Concurrency gate: wait for a processing slot
            let retrySid = self.sessionId ?? "unknown"
            guard let slotLease = await self.acquireSessionSlot(retrySid) else { return }
            defer { SessionConcurrencyManager.shared.release(slotLease) }

            do {
                try await self.runAgentLoop(resumingAt: existingMsgIdx, committedBlocks: existingBlockCount)
            } catch is CancellationError {
                logger.info("Agent loop cancelled (retry)")
                self.finishStoppedTurn()
            } catch {
                let rawDesc = String(describing: error)
                logger.error("Agent loop error (retry): \(rawDesc)")
                if let llmErr = error as? LLMError {
                    logger.error("Agent loop LLMError detail: \(llmErr.errorDescription ?? "nil")")
                }
                if self.turnWasStopped {   // [T-stop-queued-cancel-error]
                    self.finishStoppedTurn()
                } else {
                    let displayDesc = Self.friendlyErrorMessage((error as? LocalizedError)?.errorDescription ?? rawDesc)
                    // [T-ios-retry-tool-blocks-invisible / T-stream-empty-banner-trace]
                    // Resolve the streaming assistant by the last ASSISTANT row,
                    // not messages.last. A queued .user message (enqueuePrompt
                    // appends one mid-tool) sits AFTER the candidate, so
                    // messages.last would be that user row — the error then fell
                    // through to the top red banner (vm.errorMessage) instead of
                    // attaching to the assistant bubble. Same root cause as the
                    // Stop-loses-content fix.
                    if let last = self.messages.last(where: { $0.role == .assistant }) {
                        last.error = displayDesc
                        Task { await self.persistErrorInfo(displayDesc) }  // [T-error-persist-ios]
                        last.blocks.removeAll { $0.kind == .text && $0.content.isEmpty }
                        for block in last.blocks {
                            if case .streaming = block.toolStatus { block.toolStatus = .cancelled }
                            else if case .running = block.toolStatus { block.toolStatus = .cancelled }
                        }
                    } else {
                        self.reportTurnFailure(displayDesc)   // [T-ios-error-banner-lost]
                    }
                }
            }
            if self.userDidCancel { self.handleUserCancelledCleanup() }
            // [T-stop-with-queue-render-desync] See send(): Stop's cancel() owns
            // state teardown; a superseded task must not drain or flip isProcessing.
            guard !Task.isCancelled else {
                logger.info("🔄SESSION [vm=\(self.vmInstanceId)] retry epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }
            await self.drainQueuedPrompts()
            logger.info("🔄SESSION [vm=\(self.vmInstanceId)] retry DONE session=\(self.sessionId ?? "nil")")
            self.playCompletionHaptic()
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// Resume an interrupted agent loop. Injects a "Continue" user message
    /// into agentHistory so the model knows to pick up where it left off.
    func resume() {
        settlePendingStop(before: "resume")  // [T-stop-cleanup-before-new-turn]
        guard !isProcessing, canResume else { return }
        // [T-ios-orphan-user-tail GH#262/#263] A tail of "user turn with no
        // reply at all" has no assistant row to resume INTO — the reply never
        // reached the store, so loadSession rebuilt the transcript ending on
        // the user bubble. Take a separate path that asks for the reply from
        // scratch instead of bailing here, which is what left the session with
        // no recovery affordance whatsoever.
        guard let lastMsg = messages.last else { return }
        if lastMsg.role != .assistant {
            guard lastMsg.role == .user else { return }
            resumeUnansweredUserTurn()
            return
        }

        // [T-ios-retry-keyboard] Same origin as retry(): continuing an
        // interrupted turn is not a fresh send.
        turnStartedByRetry = true

        canResume = false
        userDidCancel = false
        delegationResultsMuted = false

        // Safety: trim any uncommitted blocks (should be no-op with new cancel flow).
        // [T-ios-retry-wipes-prior-text] Same fix as retry(): the blind
        // removeSubrange(committedBlockCount...) here wiped committed post-tool text
        // when committedBlockCount lagged (the warning below literally predicted it).
        // clearUncommittedStreamTail preserves non-empty text + terminal tools while
        // still dropping the uncommitted partial/streaming tail.
        if committedBlockCount < lastMsg.blocks.count {
            logger.info("⏹️[StopDiag] resume() pre-trim committed=\(self.committedBlockCount) blocks=\(lastMsg.blocks.count) — preserving committed text/tools via clearUncommittedStreamTail")
            Self.clearUncommittedStreamTail(lastMsg, committedBlockCount: committedBlockCount)
        } else {
            logger.info("⏹️[StopDiag] resume() no trim (committed=\(self.committedBlockCount) >= blocks=\(lastMsg.blocks.count))")
        }

        // Mark any remaining tool blocks with nil status as cancelled
        for block in lastMsg.blocks {
            if block.toolStatus == nil, block.kind != .text {
                block.toolStatus = .cancelled
            }
        }

        // Inject a "Continue" user message only when history ends with assistant
        // (Case 2a: text streaming cancel). For Case 1 (tool cancel), history already
        // ends with tool_result (user role) and is valid for the next API call.
        if agentHistory.last?.role == .assistant {
            let continueMsg = AgentMessage(role: .user, parts: [
                .text("<system-reminder>The user stopped the previous response but now wants to continue. Pick up exactly where you left off.</system-reminder>")
            ])
            let continueIdx = agentHistory.count
            agentHistory.append(continueMsg)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let pid = await self.persistAgentMessage(continueMsg), continueIdx < self.agentHistory.count {
                    self.agentHistory[continueIdx].dbMessageId = pid
                }
            }
        }

        // [T-ios-stale-error-banner] Was a bare `errorMessage = nil`, which cleared
        // only the transient top banner. The row-attached error cards (and their
        // persisted error_info) stayed in the transcript while the continued turn
        // streamed underneath them. Runs BEFORE the index is captured: the sweep
        // can remove empty carrier rows, which would shift `messages.count`.
        clearSupersededErrors(reason: "resume", keeping: lastMsg)
        let existingMsgIdx = messages.count - 1
        let existingBlockCount = lastMsg.blocks.count
        isProcessing = true

        ensureKernelBooted()
        beginBackgroundProcessing()

        currentTask = Task { [weak self] in
            guard let self else { return }

            while self.kernelStatus == .booting {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if case .failed(let msg) = self.kernelStatus {
                self.errorMessage = "Kernel not available: \(msg)"
                self.isProcessing = false
                self.endBackgroundProcessing()
                return
            }

            let resumeSid = self.sessionId ?? "unknown"
            guard let slotLease = await self.acquireSessionSlot(resumeSid) else { return }
            defer { SessionConcurrencyManager.shared.release(slotLease) }

            do {
                try await self.runAgentLoop(resumingAt: existingMsgIdx, committedBlocks: existingBlockCount)
            } catch is CancellationError {
                logger.info("Agent loop cancelled (resume)")
                self.finishStoppedTurn()
            } catch {
                let rawDesc = String(describing: error)
                logger.error("Agent loop error (resume): \(rawDesc)")
                if let llmErr = error as? LLMError {
                    logger.error("Agent loop LLMError detail: \(llmErr.errorDescription ?? "nil")")
                }
                if self.turnWasStopped {   // [T-stop-queued-cancel-error]
                    self.finishStoppedTurn()
                } else {
                    let displayDesc = Self.friendlyErrorMessage((error as? LocalizedError)?.errorDescription ?? rawDesc)
                    // [T-ios-retry-tool-blocks-invisible / T-stream-empty-banner-trace]
                    // Resolve the streaming assistant by the last ASSISTANT row,
                    // not messages.last. A queued .user message (enqueuePrompt
                    // appends one mid-tool) sits AFTER the candidate, so
                    // messages.last would be that user row — the error then fell
                    // through to the top red banner (vm.errorMessage) instead of
                    // attaching to the assistant bubble. Same root cause as the
                    // Stop-loses-content fix.
                    if let last = self.messages.last(where: { $0.role == .assistant }) {
                        last.error = displayDesc
                        Task { await self.persistErrorInfo(displayDesc) }  // [T-error-persist-ios]
                        last.blocks.removeAll { $0.kind == .text && $0.content.isEmpty }
                        for block in last.blocks {
                            if case .streaming = block.toolStatus { block.toolStatus = .cancelled }
                            else if case .running = block.toolStatus { block.toolStatus = .cancelled }
                        }
                    } else {
                        self.reportTurnFailure(displayDesc)   // [T-ios-error-banner-lost]
                    }
                }
            }
            if self.userDidCancel { self.handleUserCancelledCleanup() }
            // [T-stop-with-queue-render-desync] See send(): Stop's cancel() owns
            // state teardown; a superseded task must not drain or flip isProcessing.
            guard !Task.isCancelled else {
                logger.info("🔄SESSION [vm=\(self.vmInstanceId)] resume epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }
            await self.drainQueuedPrompts()
            // Same baseline refresh as send()'s epilogue. Without it the rows the
            // resumed loop wrote looked like another writer's: the next reload
            // rebuilt the whole chat (FD704863, 12:45:55 "LOAD branch=
            // hasRemovedMessages knownCount=2050 dbCount=2048").
            await self.refreshDbBaselineFromStore()
            logger.info("🔄SESSION [vm=\(self.vmInstanceId)] resume DONE session=\(self.sessionId ?? "nil")")
            self.playCompletionHaptic()
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// [T-ios-orphan-user-tail GH#262/#263] Ask for the reply to a user turn
    /// that never got one.
    ///
    /// Reached only from `resume()`, and only for the tail shape described in
    /// `recheckCanResumeFromHistory` — the user message was persisted, then the
    /// process died (backgrounded app reclaimed by iOS) before any assistant
    /// content reached the store. There is no partial reply to continue, so
    /// this deliberately does NOT reuse resume()'s machinery:
    ///
    ///   * no `<system-reminder>` "the user stopped the previous response" turn
    ///     is injected. That text describes a USER cancelling mid-reply; here
    ///     the reply never began, and telling the model otherwise would make it
    ///     apologise for or "pick up" something that does not exist. It is also
    ///     unnecessary — agentHistory already ends with a user turn, which is
    ///     exactly the shape the API expects.
    ///   * `resumingAt` is nil, so runAgentLoop appends a FRESH assistant row
    ///     rather than resuming into one (there is none to resume into).
    ///
    /// The result is that Resume on this session means "answer my last
    /// message", which is what the user is actually asking for.
    ///
    /// [T-user-ask-notsent-retry] `afterHiddenNudge`: the turn to answer is a
    /// hidden user row the caller just appended to agentHistory (the user_ask
    /// Retry), so the visible transcript ends on the assistant instead.
    func resumeUnansweredUserTurn(afterHiddenNudge: Bool = false) {
        settlePendingStop(before: "resumeUnansweredUserTurn")  // [T-stop-cleanup-before-new-turn]
        if !afterHiddenNudge {
            guard let lastUser = messages.last, lastUser.role == .user else { return }
        }
        logger.info("[OrphanTail] resume on unanswered user turn — requesting a fresh reply session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count)")

        // Same origin marker as retry()/resume(): this turn was started by the
        // user re-running an old message, so the auto-focus observer must not
        // treat its completion as "a reply arrived". [T-ios-retry-keyboard]
        turnStartedByRetry = true

        canResume = false
        userDidCancel = false
        delegationResultsMuted = false
        errorMessage = nil
        // Nothing partial to preserve, so the resume()/retry() block-trimming
        // has no counterpart here: the new reply starts from an empty row.
        committedBlockCount = 0
        isProcessing = true
        isNearBottom = true
        forceScrollToBottom.send()

        ensureKernelBooted()
        beginBackgroundProcessing()

        currentTask = Task { [weak self] in
            guard let self else { return }

            while self.kernelStatus == .booting {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if case .failed(let msg) = self.kernelStatus {
                self.errorMessage = "Kernel not available: \(msg)"
                self.isProcessing = false
                self.endBackgroundProcessing()
                return
            }

            let sid = self.sessionId ?? "unknown"
            guard let slotLease = await self.acquireSessionSlot(sid) else { return }
            defer { SessionConcurrencyManager.shared.release(slotLease) }

            do {
                try await self.runAgentLoop()
            } catch is CancellationError {
                logger.info("Agent loop cancelled (orphan-tail resume)")
                self.finishStoppedTurn()
            } catch {
                let rawDesc = String(describing: error)
                logger.error("Agent loop error (orphan-tail resume): \(rawDesc)")
                if self.turnWasStopped {   // [T-stop-queued-cancel-error]
                    self.finishStoppedTurn()
                } else {
                    let displayDesc = Self.friendlyErrorMessage((error as? LocalizedError)?.errorDescription ?? rawDesc)
                    // runAgentLoop appended the assistant row, so this attaches
                    // to the bubble; reportTurnFailure is the fallback for the
                    // window before that append. [T-ios-error-banner-lost]
                    if let last = self.messages.last(where: { $0.role == .assistant }) {
                        last.error = displayDesc
                        Task { await self.persistErrorInfo(displayDesc) }  // [T-error-persist-ios]
                        last.blocks.removeAll { $0.kind == .text && $0.content.isEmpty }
                    } else {
                        self.reportTurnFailure(displayDesc)
                    }
                }
            }
            if self.userDidCancel { self.handleUserCancelledCleanup() }
            guard !Task.isCancelled else {
                logger.info("🔄SESSION [vm=\(self.vmInstanceId)] orphan-tail resume epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }
            await self.drainQueuedPrompts()
            logger.info("🔄SESSION [vm=\(self.vmInstanceId)] orphan-tail resume DONE session=\(self.sessionId ?? "nil")")
            self.playCompletionHaptic()
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// Retry from a specific user message: roll back UI and history to the state
    /// just after that user message was sent, then re-run the agent loop.
    /// [T-ios-retry-anchor-synthetic-user] True when this agentHistory entry
    /// corresponds to a user bubble in `messages`. The agent loop also appends
    /// user-role entries that have NO bubble: pure tool_result carriers, the
    /// resume() stop-continue `<system-reminder>` message (see resume()), and
    /// the browser-takeover note (text + screenshot, AIChatViewModel+
    /// BackgroundTask.waitIfBrowserTakeover). Counting those against the UI
    /// bubble ordinal made retry/edit truncation anchor one user message too
    /// early — silently dropping the retried message plus the whole last turn,
    /// so the model "re-answered" the previous instruction instead.
    /// A user entry counts as a bubble iff it carries user-visible payload:
    /// a non-synthetic text part, or a non-tool payload (image/attachment)
    /// not accompanied by synthetic text.
    static func isUserBubbleEntry(_ entry: AgentMessage) -> Bool {
        guard entry.role == .user else { return false }
        var hasVisibleText = false
        var hasSyntheticText = false
        var hasNonToolPayload = false
        for part in entry.parts {
            switch part {
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("<system-reminder>") || trimmed.hasPrefix("[Browser takeover]") {
                    hasSyntheticText = true
                } else {
                    hasVisibleText = true
                }
            case .imageData:
                hasNonToolPayload = true
            case .toolUse, .toolResult:
                continue
            }
        }
        return hasVisibleText || (hasNonToolPayload && !hasSyntheticText)
    }
}

// MARK: - One attached image -> what the model is sent [T-image-real-seams]

// BEGIN InlineAttachmentImage
/// Which user-attachment path an image is inlined on. The two paths differ
/// today and this extraction keeps them different: `.send` (send()) runs the
/// compressor ladder and labels any re-encoded output JPEG; `.queue`
/// (processAttachments, prompts queued while the agent is busy) has no ladder
/// and keeps a GIF / WebP label on resized JPEG bytes. Both differences are
/// tracked as known gaps; this is the shared seam, not the fix.
enum AttachmentInlineRoute {
    case send
    case queue
}

/// The bytes and MIME type an attached image is inlined with.
struct AttachmentInlineImage {
    /// After the 2000 px long-edge resize, or the original bytes when the
    /// image was already within it (or could not be decoded).
    let resized: Data
    /// What goes to the model: the compressor ladder's output on `.send`,
    /// `resized` on `.queue`.
    let final: Data
    let mimeType: String
}

extension AIChatViewModel {
    /// Resize, (send route only) compress under the per-image budget, and pick
    /// the MIME type for one attached image. `ext` is the attachment file's
    /// lowercased path extension. Shared by send() and processAttachments
    /// (AIChatViewModel+Attachments.swift).
    static func inlineAttachmentImage(_ data: Data, ext: String, route: AttachmentInlineRoute) -> AttachmentInlineImage {
        let resized = Self.resizedImageData(data, maxLongEdge: 2000) ?? data
        switch route {
        case .send:
            // [T-image-budget-base64] The ladder measures its output
            // in RAW bytes, so hand it the raw equivalent of the
            // per-image base64 budget; every comparison below is
            // then done in base64 bytes, the unit the budgets are in.
            let perImageRawTarget = Self.rawBytesForBase64Budget(Self.kPerImageMaxBytes)
            let compressed = Self.compressedImageDataUnderBudget(resized, targetMaxBytes: perImageRawTarget).data
            let mime: String
            if compressed.count != data.count {
                // We re-encoded (resize or compressor ladder
                // ran). Output is always JPEG.
                mime = "image/jpeg"
            } else {
                switch ext {
                case "png":  mime = "image/png"
                case "gif":  mime = "image/gif"
                case "webp": mime = "image/webp"
                default:     mime = "image/jpeg"
                }
            }
            return AttachmentInlineImage(resized: resized, final: compressed, mimeType: mime)
        case .queue:
            let mime: String
            switch ext {
            case "png": mime = resized.count == data.count ? "image/png" : "image/jpeg"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            default: mime = "image/jpeg"
            }
            return AttachmentInlineImage(resized: resized, final: resized, mimeType: mime)
        }
    }

    /// Send route's per-message budget, in base64 bytes: would inlining an
    /// image of `compressedB64` push the message past `kMessageImageMaxBytes`?
    static func attachmentImageOverflowsMessage(cumulativeImageBytes: Int, compressedB64: Int) -> Bool {
        (cumulativeImageBytes + compressedB64) > Self.kMessageImageMaxBytes
    }
}
// END InlineAttachmentImage

extension AIChatViewModel {
    /// [T-limits-per-parent] The concurrency gate every agent-loop entry
    /// (send / retry / resume / retry-from-message) passes before running.
    ///
    /// A sub agent run (`helperConfig != nil`: a delegate_task child or a
    /// scheduled child-of-current) is exempt - it never takes one of the
    /// session slots and never waits; its own per-parent cap is enforced by
    /// AgentJobRegistry before it starts. Everyone else waits for a slot.
    ///
    /// Returns the lease to hand back with `SessionConcurrencyManager.release`
    /// (callers `defer` it right after), or nil when the wait was cancelled -
    /// the run state has then been reset and the caller must return. A nil
    /// result holds nothing, so there is nothing to release.
    func acquireSessionSlot(_ sid: String) async -> SessionSlotLease? {
        let concurrency = SessionConcurrencyManager.shared
        let exempt = helperConfig != nil
        self.isSuspended = !exempt && concurrency.runningSessions.count >= concurrency.maxConcurrent
        do {
            let lease = try await concurrency.acquire(sessionId: sid, exempt: exempt)
            self.isSuspended = false
            return lease
        } catch {
            self.isSuspended = false
            self.isProcessing = false
            self.endBackgroundProcessing()
            return nil
        }
    }
}
