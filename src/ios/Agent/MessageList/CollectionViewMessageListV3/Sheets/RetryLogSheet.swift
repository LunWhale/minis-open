//
//  RetryLogSheet.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Retry marker in front of "<name> is thinking…" and the retry log sheet it
//  opens [T-retry-log-sheet].
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - Retry marker + details [T-retry-log-sheet]

/// The yellow marker in front of "<name> is thinking…" while a retry is under
/// way. Sized to the indicator's line so it never changes the footer height.
struct RetryMarkerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.yellow)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Retry details"))
    }
}

/// The current run's retry log. Live while the run goes on; if the run ends
/// with the sheet open (the store drops the log), the last record seen stays
/// on screen with a note, instead of the list emptying under the user.
struct RetryLogSheet: View {
    let key: String
    @ObservedObject private var store = RetryLogStore.shared
    @State private var lastSeen: [RetryLogEvent] = []
    @Environment(\.dismiss) private var dismiss

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var live: [RetryLogEvent] { store.events(for: key) }
    private var shown: [RetryLogEvent] { live.isEmpty ? lastSeen : live }
    private var runEnded: Bool { live.isEmpty && !lastSeen.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if shown.isEmpty {
                    Text("No retries so far in this run.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(shown) { event in
                            row(event)
                        }
                    } header: {
                        Text(String(format: AppLocalized("%lld retry event(s) in this run"), shown.count))
                    } footer: {
                        if runEnded {
                            Text("This generation has ended. This is its last retry record.")
                        }
                    }
                }
            }
            .navigationTitle(Text("Retry details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { if !live.isEmpty { lastSeen = live } }
        .onChange(of: live) { new in if !new.isEmpty { lastSeen = new } }
    }

    @ViewBuilder
    private func row(_ e: RetryLogEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon(e.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(title(e.kind)).font(.subheadline.weight(.semibold))
                Spacer()
                outcomeChip(e.outcome)
                Text(Self.timeFormatter.string(from: e.time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let n = e.attempt, let total = e.maxAttempts {
                let attempt = String(format: AppLocalized("Attempt %lld of %lld"), n, total)
                let wait = e.delaySeconds.map { " · " + String(format: AppLocalized("Waited %lld s"), $0) } ?? ""
                Text(attempt + wait).font(.caption).foregroundStyle(.secondary)
            }
            Text(String(format: AppLocalized("Model: %@"), e.model))
                .font(.caption).foregroundStyle(.secondary)
            if let to = e.switchedTo {
                Text(String(format: AppLocalized("Switched to: %@"), to))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !e.reason.isEmpty {
                Text(e.reason)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(_ k: RetryLogEvent.Kind) -> String {
        switch k {
        case .autoRetry: return "clock.arrow.circlepath"
        case .streamInterrupted: return "bolt.horizontal.circle"
        case .modelSwitch: return "arrow.triangle.swap"
        case .emptyResponse: return "text.bubble"
        }
    }

    private func title(_ k: RetryLogEvent.Kind) -> String {
        switch k {
        case .autoRetry: return AppLocalized("Automatic retry")
        case .streamInterrupted: return AppLocalized("Reply interrupted")
        case .modelSwitch: return AppLocalized("Switched model")
        case .emptyResponse: return AppLocalized("Empty reply, asked again")
        }
    }

    @ViewBuilder
    private func outcomeChip(_ o: RetryLogEvent.Outcome) -> some View {
        let (text, color): (String, Color) = {
            switch o {
            case .pending: return (AppLocalized("Retrying"), .orange)
            case .succeeded: return (AppLocalized("Recovered"), .green)
            // Not the shared "Failed" key: its zh-Hans reads 加载失败 (load failed).
            case .failed: return (AppLocalized("Not recovered"), .red)
            case .unfinished: return (AppLocalized("Unfinished"), .gray)
            }
        }()
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
