//
//  SessionLockGateOverlay.swift
//  Minis - chat page (AIChatView)
//
//  Face ID gate for locked sessions: its state, overlay and lifecycle observers
//  in one self-contained view, so AIChatView.body references a single type.
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

// MARK: - Face ID Session Lock Overlay
//
// Encapsulates the entire Face ID gate (state + overlay UI + lifecycle
// observers) into a self-contained `View` so that AIChatView's body
// only references it as a single opaque type. This keeps the chat
// body's generic-type depth bounded — earlier inlined attempts pushed
// `__swift_instantiateConcreteTypeFromMangledNameV2` into runtime
// metadata recursion and crashed with EXC_BAD_ACCESS at the stack
// guard region on iOS 26.
struct SessionLockGateOverlay: View {
    let sessionId: String?

    @ObservedObject private var store = SessionLockStore.shared
    @Environment(\.scenePhase) private var scenePhase
    /// True while an LAContext prompt is in flight — suppresses repeated
    /// auto-prompts when the system overlay itself transiently resigns
    /// the chat view.
    @State private var promptInFlight = false
    /// Set after a failed / cancelled prompt so the overlay renders a
    /// tap-to-retry affordance instead of immediately re-prompting.
    @State private var attemptFailed = false

    var body: some View {
        Group {
            if shouldShow {
                gateView
            }
        }
        .onAppear { evaluate(reason: "onAppear") }
        .onDisappear {
            // [T-faceid-lock-on-exit 2026-05-21] "Lock on exit" mode
            // (idleTimeoutSeconds < 0): clear this session's unlock as
            // soon as the chat view leaves the screen (user popped back
            // to the sidebar / pushed a settings page / navigated to
            // another session). Without this, the unlock stamp survives
            // until the app backgrounds, which doesn't match the user's
            // intent of "locking the moment I leave this chat".
            //
            // Positive idle windows are NOT cleared here — they keep
            // the stamp so navigating away and back within the window
            // doesn't re-prompt for Face ID.
            if let sid = sessionId, store.isLocked(sid), store.idleTimeoutSeconds < 0 {
                store.clearUnlock(sid)
                attemptFailed = false
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScene(newPhase)
        }
        .onChange(of: sessionId) { _ in
            attemptFailed = false
            promptInFlight = false
            evaluate(reason: "sessionIdChanged")
        }
    }

    private var shouldShow: Bool {
        guard let sid = sessionId, !sid.isEmpty else { return false }
        return store.isVisuallyLocked(sid)
    }

    private var gateView: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .overlay {
                    Color(UIColor.systemBackground).opacity(0.4)
                        .ignoresSafeArea()
                }

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)

                Text("This session is locked")
                    .font(.system(size: 18, weight: .semibold))

                Text(attemptFailed
                     ? "Authentication failed. Tap to try again."
                     : "Tap to unlock with \(BiometricAuth.biometryDisplayName)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    promptForBiometricUnlock()
                } label: {
                    Label(attemptFailed
                          ? AppLocalized("Try again")
                          : AppLocalized("Unlock"),
                          systemImage: "faceid")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 32)
        }
        .contentShape(Rectangle())
        .onTapGesture { promptForBiometricUnlock() }
        .transition(.opacity)
    }

    private func evaluate(reason: String) {
        guard let sid = sessionId, !sid.isEmpty else { return }
        guard store.globalEnabled, BiometricAuth.isAvailable else { return }
        guard store.isLocked(sid) else { return }
        store.relockIfIdleExpired(sid)
        guard !store.isCurrentlyUnlocked(sid) else { return }
        guard !promptInFlight, !attemptFailed else { return }
        promptForBiometricUnlock()
    }

    private func promptForBiometricUnlock() {
        guard let sid = sessionId, !sid.isEmpty else { return }
        guard !promptInFlight else { return }
        promptInFlight = true
        Task { @MainActor in
            let reason = AppLocalized("Unlock this chat session")
            let ok = await BiometricAuth.authenticate(reason: reason)
            promptInFlight = false
            if ok {
                store.noteUnlock(sid)
                attemptFailed = false
            } else {
                attemptFailed = true
            }
        }
    }

    private func handleScene(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            // [T-faceid-lock-background-timeout 2026-05-21] Previously
            // cleared the per-session unlock stamp unconditionally on
            // background/inactive, which made the idle timeout setting
            // (e.g. "10 minutes") behave as if it were "Lock on exit":
            // any backgrounding instantly re-locked the chat. Honor the
            // user's chosen idle window now — only clear the unlock if
            // they explicitly chose "Lock on exit" (idle < 0). For
            // positive idle values the stamp is kept and re-evaluated
            // on .active via evictIdleExpired() + evaluate().
            if let sid = sessionId, store.isLocked(sid) {
                if store.idleTimeoutSeconds < 0 {
                    store.clearUnlock(sid)
                }
                attemptFailed = false
            }
        case .active:
            store.evictIdleExpired()
            evaluate(reason: "scenePhase.active")
        @unknown default:
            break
        }
    }
}
