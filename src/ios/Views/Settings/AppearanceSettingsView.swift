//
//  AppearanceSettingsView.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Settings > Appearance: theme, app icon, language (supportedLanguages - also
//  edited by scripts/register_locale.py), font scale and related toggles.
//  Opened from SettingsSheet.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Appearance Settings

private struct AppIconOption: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let iconName: String?  // nil = automatic (default asset catalog icon)
    let imageName: String  // bundle image file name for preview
}

private struct LanguageOption: Identifiable {
    let id: String   // language code, "" = system
    let name: String  // native name
    let flag: String
}

// Native names are deliberately NOT localized: a language picker shows each
// option in its own language so a user who cannot read the current UI language
// can still find theirs.
//
// [T-ios-inapp-language-string-localized] zh-Hant was missing even though the
// catalog carries a full Traditional Chinese translation, so those users could
// not select it in-app; es is new. Every id here must have a matching .lproj in
// the bundle — `Bundle.setLanguage(_:)` looks the directory up by this string
// and silently falls back to the system language if it is absent.
private let supportedLanguages: [LanguageOption] = [
    LanguageOption(id: "",       name: "System", flag: ""),
    LanguageOption(id: "en",     name: "English", flag: "🇺🇸"),
    LanguageOption(id: "zh-Hans", name: "简体中文", flag: "🇨🇳"),
    LanguageOption(id: "zh-Hant", name: "繁體中文", flag: "🇭🇰"),
    LanguageOption(id: "ja",     name: "日本語", flag: "🇯🇵"),
    LanguageOption(id: "ko",     name: "한국어", flag: "🇰🇷"),
    LanguageOption(id: "es",     name: "Español", flag: "🇪🇸"),
    LanguageOption(id: "fr",     name: "Français", flag: "🇫🇷"),
    LanguageOption(id: "de",     name: "Deutsch", flag: "🇩🇪"),
    LanguageOption(id: "ru",     name: "Русский", flag: "🇷🇺"),
    LanguageOption(id: "id",     name: "Bahasa Indonesia", flag: "🇮🇩"),
    LanguageOption(id: "ms",    name: "Bahasa Melayu", flag: "🇲🇾"),
    LanguageOption(id: "fil",   name: "Filipino", flag: "🇵🇭"),
    LanguageOption(id: "th",    name: "ไทย", flag: "🇹🇭"),
    LanguageOption(id: "tr",    name: "Türkçe", flag: "🇹🇷"),
    LanguageOption(id: "pl",    name: "Polski", flag: "🇵🇱"),
    LanguageOption(id: "ro",    name: "Română", flag: "🇷🇴"),
    LanguageOption(id: "pt-BR", name: "Português (Brasil)", flag: "🇧🇷"),
    LanguageOption(id: "hr",    name: "Hrvatski", flag: "🇭🇷"),
]

private struct FontScaleRow: View {
    let label: String
    @Binding var level: FontScaleLevel

    private static let cases = FontScaleLevel.allCases
    private let stepCount = FontScaleRow.cases.count  // 5

    private var currentIndex: Int {
        Self.cases.firstIndex(of: level) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `label` is a fixed English identifier ("Chat Input" etc.);
            // wrap in LocalizedStringKey so SwiftUI looks it up in the
            // String Catalog instead of rendering the verbatim English.
            Text(LocalizedStringKey(label))
            HStack(spacing: 12) {
                Button {
                    let idx = currentIndex - 1
                    if idx >= 0 {
                        level = Self.cases[idx]
                    }
                } label: {
                    Text("A")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                SteppedSlider(value: currentIndex, steps: stepCount) { newIndex in
                    if newIndex >= 0, newIndex < Self.cases.count {
                        let newLevel = Self.cases[newIndex]
                        if newLevel != level { level = newLevel }
                    }
                }

                Button {
                    let idx = currentIndex + 1
                    if idx < Self.cases.count {
                        level = Self.cases[idx]
                    }
                } label: {
                    Text("A")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A custom stepped slider that supports both drag and tap-to-snap.
/// Uses local gesture state to avoid layout feedback loops from SwiftUI's Slider.
private struct SteppedSlider: View {
    let value: Int
    let steps: Int
    let onChanged: (Int) -> Void

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 22
    private let tickSize: CGFloat = 6

    @State private var dragValue: Int?

    private var displayValue: Int { dragValue ?? value }

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let midY = geo.size.height / 2
            let maxStep = CGFloat(steps - 1)

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(height: trackHeight)
                    .position(x: totalW / 2, y: midY)

                // Filled portion
                let fillW = maxStep > 0 ? totalW * CGFloat(displayValue) / maxStep : 0
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fillW, height: trackHeight)
                    .position(x: fillW / 2, y: midY)

                // Tick marks
                ForEach(0..<steps, id: \.self) { i in
                    let x = maxStep > 0 ? totalW * CGFloat(i) / maxStep : 0
                    Circle()
                        .fill(i <= displayValue ? Color.accentColor : Color(.systemFill))
                        .frame(width: tickSize, height: tickSize)
                        .position(x: x, y: midY)
                }

                // Thumb
                let thumbX = maxStep > 0 ? totalW * CGFloat(displayValue) / maxStep : 0
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: thumbX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let step = stepFromX(drag.location.x, width: totalW)
                        if step != dragValue { dragValue = step }
                    }
                    .onEnded { drag in
                        let step = stepFromX(drag.location.x, width: totalW)
                        dragValue = nil
                        onChanged(step)
                    }
            )
        }
        .frame(height: thumbSize + 8)
    }

    private func stepFromX(_ x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, steps > 1 else { return 0 }
        let fraction = x / width
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * CGFloat(steps - 1)).rounded())
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("appIconMode") private var appIconMode: Int = 0
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("launchScreen") private var launchScreen: Int = 0  // 0=Auto, 1=Last Session, 2=New Chat, 3=Home
    @AppStorage("toolPreviewEnabled") private var toolPreviewEnabled: Bool = true
    /// 0 = Return inserts a newline (default), 1 = Return sends the message.
    @AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0
    /// When true, holds `UIApplication.isIdleTimerDisabled` while any session
    /// is running a task. See `KeepScreenAwakeController`.
    @AppStorage("keepScreenAwakeDuringTasks") private var keepScreenAwakeDuringTasks: Bool = false
    /// [T-always-on-idle-setting] Screen Saver: seconds without a touch before
    /// the black screen, 0 = Off (default). See `AlwaysOnController.idleDelay`.
    @AppStorage(AlwaysOnController.idleSecondsKey) private var alwaysOnIdleSeconds: Int = 0
    /// [T-keyboard-auto-pop default flip] When true, the input field becomes
    /// the first responder ~1.5 s after the model finishes a reply (the
    /// historical behavior). ON by default — most users want the composer
    /// ready for a follow-up immediately. Existing users who explicitly
    /// toggled OFF keep their stored false; users who never opened the
    /// toggle get the new ON default via @AppStorage's fallback.
    @AppStorage("chat.autoFocusAfterReply") private var autoFocusAfterReply: Bool = true
    /// [T-stop-confirm] Ask before the composer's stop button stops a running
    /// task. Read by ChatSendButton through `StopConfirmPolicy.settingsKey`;
    /// [T-stop-mode-longpress] OFF by default, also set from the stop button's long-press.
    @AppStorage(StopConfirmPolicy.settingsKey) private var confirmBeforeStopping: Bool = StopConfirmPolicy.defaultValue
    /// [T-thinking-auto-expand-toggle] When true (default, historical
    /// behavior) a NEW streaming thinking block auto-expands while reasoning
    /// streams. When false it stays collapsed until tapped. Read at
    /// block-mount time in ThinkingBlockView.
    @AppStorage("chat.autoExpandThinking") private var autoExpandThinking: Bool = true
    /// [T-fold-consecutive-tools] Mirrors `ToolFoldPlanner.settingsKey`.
    @AppStorage("chat.foldConsecutiveTools") private var foldConsecutiveTools: Bool = false
    @ObservedObject private var fontSettings = FontSettings.shared

    private let iconOptions: [AppIconOption] = [
        AppIconOption(id: 0, title: "Automatic", subtitle: "Follows system", iconName: nil, imageName: "AlternateIcons/AppIcon-Light"),
        AppIconOption(id: 1, title: "Light", subtitle: "Always light", iconName: "AppIcon-Light", imageName: "AlternateIcons/AppIcon-Light"),
        AppIconOption(id: 2, title: "Dark", subtitle: "Always dark", iconName: "AppIcon-Dark", imageName: "AlternateIcons/AppIcon-Dark"),
        AppIconOption(id: 3, title: "Light (Legacy)", subtitle: "Classic light icon", iconName: "AppIcon-LegacyLight", imageName: "AlternateIcons/AppIcon-LegacyLight"),
        AppIconOption(id: 4, title: "Dark (Legacy)", subtitle: "Classic dark icon", iconName: "AppIcon-LegacyDark", imageName: "AlternateIcons/AppIcon-LegacyDark"),
    ]

    /// Settings' choices, plus a value set from `minis-config` that is not one
    /// of them, so the picker never shows an empty selection.
    private var screenSaverChoices: [Int] {
        let base = AlwaysOnController.idleChoices
        return base.contains(alwaysOnIdleSeconds) ? base : (base + [alwaysOnIdleSeconds]).sorted()
    }

    private static func screenSaverLabel(_ seconds: Int) -> String {
        switch seconds {
        case ..<1: return AppLocalized("Off")
        case 30: return AppLocalized("After 30 Seconds")
        case 60: return AppLocalized("After 1 Minute")
        case 120: return AppLocalized("After 2 Minutes")
        case 300: return AppLocalized("After 5 Minutes")
        default: return String(format: AppLocalized("After %d Seconds"), seconds)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Theme", selection: $appearanceMode) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            } footer: {
                Text("Override the system appearance for this app.")
            }
            .onChange(of: appearanceMode) { _ in
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                windowScene.windows.forEach { window in
                    window.overrideUserInterfaceStyle = appearanceMode == 1 ? .light : appearanceMode == 2 ? .dark : .unspecified
                }
            }

            Section {
                Picker("Launch Session", selection: $launchScreen) {
                    Text("Auto").tag(0)
                    Text("Last Session").tag(1)
                    Text("New Chat").tag(2)
                    Text("Home").tag(3)
                }
            } header: {
                Text("Launch Session")
            } footer: {
                Text("Choose what to show when the app starts. \"Auto\" opens a new chat if the last session is older than 15 minutes.")
            }

            // Auto-grouping default is OFF on principle: it costs nothing
            // extra (it rides the title-generation call), but it moves user
            // data without being asked — a behavior the user must opt into.
            // No pendingSettingsReopen dance here: that exists only because
            // appLanguage rebuilds the root via .id(); a plain toggle has no
            // such side effect.
            Section {
                Toggle("Auto-Grouping", isOn: autoGroupingBinding)
            } header: {
                Text("Grouping")
            } footer: {
                Text("When a chat's title is first generated, also file it into a matching existing group. Runs once per chat, only uses groups you already created, and leaves the chat ungrouped when nothing matches.")
            }

            Section {
                Picker(AppLocalized("Return Key"), selection: $returnKeyBehavior) {
                    Text(AppLocalized("Newline")).tag(0)
                    Text(AppLocalized("Send")).tag(1)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Return Key")
            } footer: {
                Text("Choose whether the Return key in the chat input inserts a newline or sends the message. Hardware Shift+Return always inserts a newline.")
            }

            Section {
                Toggle(AppLocalized("Keep Screen Awake"), isOn: $keepScreenAwakeDuringTasks)
                // [T-always-on-idle-setting] One picker instead of a toggle plus a
                // duration: "Off" is the toggle. Shown only with the switch on —
                // it has no effect otherwise (a chat's … menu override still
                // uses it, which the footer says).
                if keepScreenAwakeDuringTasks {
                    Picker(AppLocalized("Screen Saver"), selection: $alwaysOnIdleSeconds) {
                        ForEach(screenSaverChoices, id: \.self) { seconds in
                            Text(Self.screenSaverLabel(seconds)).tag(seconds)
                        }
                    }
                }
            } header: {
                Text("Keep Screen Awake")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prevent the screen from sleeping while any session is running a task. May increase battery drain.")
                    // [T-always-on] Kept as a second line so the sentence above
                    // keeps its existing translations.
                    Text("Screen Saver: after the chosen time without a touch, the chat on screen turns black and shows only the current step; tap anywhere to return. Staying in the foreground helps tasks run faster. Use “Keep Screen On” in a chat's … menu to turn it on or off for that chat only.")
                }
            }

            Section {
                Toggle(AppLocalized("Auto-Focus Input After Reply"), isOn: $autoFocusAfterReply)
            } header: {
                Text("Auto-Focus Input After Reply")
            } footer: {
                Text("When on, the keyboard pops up automatically after the model finishes replying so the input is ready for a follow-up. On by default; turn off if you prefer to read the response without an unexpected keyboard.")
            }

            Section {
                Toggle(AppLocalized("Confirm Before Stopping"), isOn: $confirmBeforeStopping)
            } header: {
                Text("Confirm Before Stopping")
            } footer: {
                Text("Ask for confirmation when you tap the stop button while a task is running, so an accidental tap does not end a long run. Off by default. You can also long-press the stop button to switch.")
            }

            Section {
                Toggle(AppLocalized("Tool Preview Window"), isOn: $toolPreviewEnabled)
            } header: {
                Text("Tool Status Bar")
            } footer: {
                Text("Show a live preview thumbnail alongside the tool status bar during agent execution.")
            }

            // [T-thinking-auto-expand-toggle] Whether a NEW streaming thinking
            // block opens expanded (historical behavior, default) or stays
            // collapsed. Only affects the streaming auto-expand; manual taps
            // always work either way.
            Section {
                Toggle(AppLocalized("Expand Thinking While Streaming"), isOn: $autoExpandThinking)
            } header: {
                Text("Deep Thinking")
            } footer: {
                Text("When on, a new thinking block expands automatically while the model is reasoning and collapses when it finishes. When off, thinking blocks stay collapsed — tap one to read it.")
            }

            // [T-fold-consecutive-tools] Fold a run of 3+ tool calls that a
            // reply follows into one "Ran N tools" line.
            Section {
                Toggle(AppLocalized("Fold Consecutive Tool Calls"), isOn: $foldConsecutiveTools)
                    .onChange(of: foldConsecutiveTools) { _ in
                        // Re-lay out an open chat (iPad split view) right away.
                        NotificationCenter.default.post(name: .messageListNeedsResnapshot, object: nil)
                    }
            } header: {
                Text("Tool Calls")
            } footer: {
                Text("Consecutive tool calls are shown as one line. Tap it to see each call.")
            }

            Section {
                FontScaleRow(
                    label: "Chat Input",
                    level: $fontSettings.chatInputScale
                )
                FontScaleRow(
                    label: "Message Text",
                    level: $fontSettings.messageBaseScale
                )
                FontScaleRow(
                    label: "App Base",
                    level: $fontSettings.appBaseScale
                )
                if fontSettings.isModified {
                    Button("Reset to Defaults") {
                        fontSettings.resetToDefaults()
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Text("Font Size")
            } footer: {
                Text("Scale fonts for chat input, message content, and general app text. Changes apply immediately.")
            }

            if UIApplication.shared.supportsAlternateIcons {
                Section {
                    ForEach(iconOptions) { option in
                        Button {
                            guard appIconMode != option.id else { return }
                            appIconMode = option.id
                            UIApplication.shared.setAlternateIconName(option.iconName) { error in
                                if let error = error {
                                    print("[AppIcon] Failed to set icon: \(error.localizedDescription)")
                                }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                if let img = UIImage(named: option.imageName) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                                        )
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    // `option.title` / `option.subtitle` are fixed English
                                    // keys ("Automatic", "Light", "Always light", etc.).
                                    // Wrap in LocalizedStringKey so the catalog lookup kicks
                                    // in — Text(String) would render them verbatim.
                                    Text(LocalizedStringKey(option.title))
                                        .foregroundStyle(.primary)
                                    Text(LocalizedStringKey(option.subtitle))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if appIconMode == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                        .font(.title3)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("App Icon")
                } footer: {
                    Text("\"Automatic\" uses the system icon which adapts to Dark Mode on iOS 18+.")
                }
            }

            Section {
                ForEach(supportedLanguages) { lang in
                    Button {
                        // Persist a reopen-hint BEFORE flipping appLanguage —
                        // the @AppStorage write triggers the root
                        // `.id(appLanguage)` rebuild in MinisApp.swift, which
                        // drops the entire view tree including the Settings
                        // sheet. ContentView/SettingsSheet read this flag on
                        // re-mount and reopen the sheet + push back to the
                        // Appearance page so the user lands where they were
                        // with all strings rendered in the new language.
                        UserDefaults.standard.set("appearance", forKey: "pendingSettingsReopen")
                        // [T-ios-stacknav-transition-attributegraph-race] The
                        // `.id(appLanguage)` re-key below is the app's only
                        // unconditional WHOLE-TREE teardown, and a chat can be
                        // streaming underneath this sheet while it happens —
                        // the same hosting-subgraph race the push/pop observers
                        // guard, with every mounted vm outgoing at once. Pin
                        // them all across the re-mount. No-ops when nothing is
                        // processing, which is the overwhelmingly common case.
                        ViewModelCache.shared.suspendAllForTreeRemount()
                        appLanguage = lang.id
                        Bundle.setLanguage(lang.id.isEmpty ? nil : lang.id)
                    } label: {
                        HStack(spacing: 12) {
                            if !lang.flag.isEmpty {
                                Text(lang.flag).font(.title2)
                            } else {
                                Image(systemName: "globe")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                            }
                            Text(lang.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if appLanguage == lang.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Override the display language for this app. \"System\" follows your device language.")
            }

        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .background(InteractivePopGestureDisabler())
    }

    /// UserDefaults-backed binding (not @AppStorage: the key is read at
    /// title-generation time in AIChatViewModel, so a plain defaults write is
    /// the single source of truth).
    private var autoGroupingBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoGroupingEnabled") },
            set: { UserDefaults.standard.set($0, forKey: "autoGroupingEnabled") }
        )
    }
}

/// Disables the navigation controller's interactive pop gesture on the hosting page
/// to prevent conflict with horizontal Slider drag.
private struct InteractivePopGestureDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = GestureDisablerView()
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private class GestureDisablerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            setPopGesture(enabled: false)
        }
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil { setPopGesture(enabled: true) }
        }
        private func setPopGesture(enabled: Bool) {
            // Walk the responder chain to find the UINavigationController
            var responder: UIResponder? = self
            while let r = responder {
                if let nav = r as? UINavigationController {
                    nav.interactivePopGestureRecognizer?.isEnabled = enabled
                    return
                }
                responder = r.next
            }
        }
    }
}
