//
//  DraggableFAB.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  A floating action button that can be dragged horizontally and snaps to an
//  edge. Taps go through FABActionChannel, never a stored closure.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Draggable FAB

/// A floating action button that can be dragged horizontally and snaps to the left or right edge.
/// Uses UIKit's UIPanGestureRecognizer via UIViewRepresentable for reliable, low-latency drag tracking
/// that doesn't conflict with SwiftUI's Button/tap gestures.
struct DraggableFAB<Label: View>: View {
    @Binding var fabOnLeft: Bool
    @Binding var dragOffset: CGFloat
    @Binding var didDrag: Bool
    /// When true, this FAB sits on the opposite side of `fabOnLeft` and inverts the snap logic.
    var inverted: Bool = false
    var onTap: () -> Void
    @ViewBuilder var label: () -> Label

    private let fabSize: CGFloat = 56
    private let edgePadding: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width
            let leftX = edgePadding + fabSize / 2
            let rightX = screenWidth - edgePadding - fabSize / 2
            let onLeft = inverted ? !fabOnLeft : fabOnLeft
            let restingX = onLeft ? leftX : rightX

            label()
                .frame(width: fabSize, height: fabSize)
                .position(x: restingX + dragOffset, y: fabSize / 2)
                .onTapGesture {
                    onTap()
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            didDrag = true
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            let currentCenter = restingX + value.translation.width
                            let droppedOnLeft = currentCenter < screenWidth / 2
                            // For inverted FAB: dropping on left means the *other* FAB goes right
                            let newFabOnLeft = inverted ? !droppedOnLeft : droppedOnLeft
                            let changed = fabOnLeft != newFabOnLeft
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                fabOnLeft = newFabOnLeft
                                dragOffset = 0
                            }
                            if changed {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                didDrag = false
                            }
                        }
                )
        }
        .frame(height: fabSize)
    }
}
