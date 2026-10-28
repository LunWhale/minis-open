//
//  SidebarDebugProbes.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  DEBUG-only row-height and scroll-phase probes for the session list.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

#if DEBUG
// TEMPORARY: SessionRow height probe to confirm List cell-height estimation
// jitter. Logs each distinct measured row height once (deduped) so we know
// the true height distribution before pinning a fixed .frame. Remove after.
struct RowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private let rowHeightLog = AppLogger(category: "RowHeight")
#endif

#if DEBUG
// Availability-gated scroll-phase probe (onScrollPhaseChange is iOS 18+).
// Its only call site is DEBUG-gated too (see `.modifier(ScrollPhaseProbe())`).
struct ScrollPhaseProbe: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { old, new in
                rowHeightLog.info("[SCROLL] \(old) -> \(new)")
            }
        } else {
            content
        }
    }
}

private let rowHeightSeenLock = NSLock()
nonisolated(unsafe) private var rowHeightSeen = Set<Int>()
func probeRowHeight(_ h: CGFloat, _ tag: String) {
    // Ignore the pre-layout zero/garbage pass — only real measured heights.
    guard h > 1, h.isFinite else { return }
    let key = Int((h * 2).rounded())  // 0.5pt buckets
    rowHeightSeenLock.lock()
    let isNew = rowHeightSeen.insert(key).inserted
    rowHeightSeenLock.unlock()
    if isNew {
        rowHeightLog.info("[ROWH] \(tag) height=\(String(format: "%.1f", h))pt")
    }
}
#endif
