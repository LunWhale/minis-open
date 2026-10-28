//
//  AlwaysOnOverlay.swift
//  MinisApp
//
//  [T-always-on] The black screen of Always On mode. AlwaysOnController
//  decides when; this draws it: a pure-black window above the whole app
//  (sheets and full-screen covers included) with the Soul icon, the current
//  step's tool_title and the run time, drifting every 15 s so nothing stays on
//  the same pixels of an OLED panel. Any touch closes it.
//
//  Its own UIWindow at .alert + 1, because a layer in the app's root ZStack
//  sits under presented sheets. The window never becomes key, so the first
//  responder and the keyboard state underneath are left alone; the host
//  controller hides the status bar and the home indicator, whose fixed white
//  shapes would otherwise be the brightest static pixels on screen.
//

import SwiftUI
import UIKit
import Combine

/// The overlay's window; UserActivityMonitor skips it.
final class AlwaysOnWindow: UIWindow, AlwaysOnExcludedWindow {}

final class AlwaysOnHostingController: UIHostingController<AlwaysOnOverlayView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

@MainActor
final class AlwaysOnWindowPresenter {
    static let shared = AlwaysOnWindowPresenter()

    private var window: AlwaysOnWindow?
    private var cancellable: AnyCancellable?

    private init() {}

    func start() {
        guard cancellable == nil else { return }
        cancellable = AlwaysOnController.shared.$isShowing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { AlwaysOnWindowPresenter.shared.update(showing: $0) }
    }

    private func update(showing: Bool) {
        showing ? show() : hide()
    }

    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else { return }
        // Q3: the keyboard lives above every app window and cannot be covered;
        // put it away first. The text stays, only the cursor position is lost.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let w = AlwaysOnWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .black
        w.overrideUserInterfaceStyle = .dark
        let host = AlwaysOnHostingController(rootView: AlwaysOnOverlayView {
            AlwaysOnController.shared.userActivity()   // hides the overlay, restarts the idle timer
        })
        host.view.backgroundColor = .black
        w.rootViewController = host
        w.alpha = 0
        w.isHidden = false          // visible, but never makeKey
        host.setNeedsStatusBarAppearanceUpdate()
        host.setNeedsUpdateOfHomeIndicatorAutoHidden()
        window = w
        UIView.animate(withDuration: 0.4) { w.alpha = 1 }
    }

    private func hide() {
        // Immediate: a tap should reveal the app at once.
        window?.isHidden = true
        window = nil
    }
}

/// Where the content sits, as an offset from the centre.
enum AlwaysOnDrift {
    /// Share of the shorter screen side the content may wander from the centre.
    static let radiusFraction: CGFloat = 0.15
    /// Each move covers at least this share of the radius.
    static let minStepFraction: CGFloat = 0.4
    static let interval = 15   // ticks (seconds)

    /// A new offset inside a circle of radius R around the centre (uniform over
    /// the disc: r = R·√u), at least 0.4·R from `current`, and clamped so the
    /// content stays inside `bounds`.
    static func next(from current: CGSize, bounds: CGSize, content: CGSize,
                     random: () -> CGFloat = { CGFloat.random(in: 0...1) }) -> CGSize {
        let R = min(bounds.width, bounds.height) * radiusFraction
        guard R > 0 else { return .zero }
        let maxX = max(0, (bounds.width - content.width) / 2)
        let maxY = max(0, (bounds.height - content.height) / 2)
        func clamp(_ p: CGSize) -> CGSize {
            CGSize(width: min(max(p.width, -maxX), maxX), height: min(max(p.height, -maxY), maxY))
        }
        func farEnough(_ p: CGSize) -> Bool {
            hypot(p.width - current.width, p.height - current.height) >= minStepFraction * R
        }
        // Judge the distance after clamping: near a narrow edge the clamp can
        // pull a candidate back next to where the content already is.
        for _ in 0..<8 {
            let theta = random() * 2 * .pi
            let r = R * random().squareRoot()
            let candidate = clamp(CGSize(width: r * cos(theta), height: r * sin(theta)))
            if farEnough(candidate) { return candidate }
        }
        // No luck: the point R away on the opposite side of the centre.
        let len = hypot(current.width, current.height)
        let dir = len > 0.001 ? CGSize(width: -current.width / len, height: -current.height / len) : CGSize(width: 1, height: 0)
        return clamp(CGSize(width: dir.width * R, height: dir.height * R))
    }
}

struct AlwaysOnOverlayView: View {
    let onTouch: () -> Void

    @ObservedObject private var controller = AlwaysOnController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var soul: SoulMetadata = SoulStore.cachedMetadata
    @State private var offset: CGSize = .zero
    @State private var contentSize: CGSize = .zero

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
    }

    /// No pulse when motion is reduced or in Low Power Mode.
    private var calm: Bool { reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                content
                    .background(GeometryReader { g in
                        Color.clear.onAppear { contentSize = g.size }
                            .onChange(of: g.size) { contentSize = $0 }
                    })
                    .offset(offset)
                    .animation(.easeInOut(duration: 1.5), value: offset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: controller.tick) { tick in
                guard tick > 0, tick % AlwaysOnDrift.interval == 0 else { return }
                offset = AlwaysOnDrift.next(from: offset, bounds: geo.size, content: contentSize)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Any touch, tap or drag, closes it at touch-down.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in onTouch() })
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soul = SoulStore.cachedMetadata
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var content: some View {
        let dim = Color.white
        return VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(dim.opacity(calm ? 0.2 : (controller.tick.isMultiple(of: 2) ? 0.12 : 0.35)), lineWidth: 2)
                    .frame(width: 84, height: 84)
                    .animation(calm ? nil : .easeInOut(duration: 1), value: controller.tick)
                SoulIconView(
                    icon: soul.icon,
                    size: 56,
                    sparkleGradient: LinearGradient(
                        colors: [Color(red: 0.72, green: 0.69, blue: 0.59),
                                 Color(red: 0.6, green: 0.6, blue: 0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .opacity(0.8)
            }
            // [T-always-on-step-icon] What kind of step this is, in front of its
            // title — like the Live Activity / Dynamic Island status row, and
            // with the same tool → SF Symbol table (sfSymbol(forTool:)), so the
            // two never disagree. Dimmer than the title; redrawn with the 1 Hz
            // snapshot, no animation of its own. First-baseline aligned so a
            // two-line title keeps the icon on its first line.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: stepIcon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(dim.opacity(0.4))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(dim.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let since = controller.snapshot.runningSince {
                Text("Running \(Self.elapsed(since))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(dim.opacity(0.35))
            }
        }
        .frame(maxWidth: 300)
        .padding(24)
    }

    /// The step being run: the model's tool_title; while the model is writing
    /// text the tracker reports tool "text" with a machine status, so say so.
    private var title: String {
        let s = controller.snapshot
        if s.toolName == "text" { return AppLocalized("Replying…") }
        // [T-bka-continued-card-status] The tracker now reports thinking too.
        if s.toolName == "thinking" { return AppLocalized("Thinking deeply…") }
        let t = s.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? AppLocalized("Working…") : t
    }

    /// SF Symbol for the running step — the Live Activity's table. Before the
    /// first tool (toolName "") that table's generic fallback.
    private var stepIcon: String {
        AgentLiveActivityManager.sfSymbol(forTool: controller.snapshot.toolName)
    }

    /// mm:ss, or h:mm:ss past an hour. Re-evaluated on every tick.
    static func elapsed(_ since: Date, now: Date = Date()) -> String {
        let total = max(0, Int(now.timeIntervalSince(since)))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
