//
//  SyncStatusIndicators.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Sync feedback on the home screen: the rotating "syncing" title indicator
//  and the Force Sync confirmation banner.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

/// Rotate-and-pause animation for the "syncing" title indicator. Period
/// scales with the active throttle so the user can tell at a glance how
/// fast sync is going: full speed = quick pulses, background = slow.
///
/// Loop is driven by a `.task` whose Task is cancelled automatically when
/// the view disappears. Earlier versions used `onAppear { tick() }` with
/// a self-rescheduling `DispatchQueue.main.asyncAfter` chain, which never
/// stopped the old chain — so each tab-switch back to home spawned a new
/// chain on top of the previous one, doubling/quadrupling perceived
/// rotation speed until the view tree rebuilt.
struct PulseRotateIcon: View {
    @State private var rotation: Double = 0
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .rotationEffect(.degrees(rotation))
            .task { await pulseLoop() }
    }
    /// Reads SyncCore's currentSendDelay (5s sync sheet → 60s background)
    /// and converts to an animation cadence: animation phase ≈ delay/4,
    /// hold phase ≈ delay/4. Clamped so it never feels frozen or frantic.
    private func currentPeriod() -> (anim: TimeInterval, hold: TimeInterval) {
        let delay: TimeInterval
        if #available(iOS 17.0, *) {
            delay = SyncCore.shared.currentSendDelay
        } else {
            delay = 10
        }
        // 5s → 1.0s anim + 1.0s hold → ~2s period (active)
        // 15s → 1.5s anim + 1.5s hold
        // 30s → 2.0s anim + 2.0s hold
        // 60s → 2.5s anim + 2.5s hold (slow)
        let anim = max(0.8, min(2.5, delay / 12 + 0.5))
        let hold = anim
        return (anim, hold)
    }
    @MainActor
    private func pulseLoop() async {
        while !Task.isCancelled {
            let (anim, hold) = currentPeriod()
            withAnimation(.easeInOut(duration: anim)) {
                rotation += 180
            }
            let total = UInt64((anim + hold) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: total)
        }
    }
}

/// Transient confirmation banner shown after a Force Sync runs against
/// a multi-session selection. Floats at the top of the home view, fades
/// in and out over ~4s. Mirrors the iOS system "Now playing" pill.
struct ForceSyncToastBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.92))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.horizontal, 16)
        .frame(maxWidth: 480)
    }
}
