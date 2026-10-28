//
//  ContentView+EmptyState.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, empty state: the first-run checklist (add a provider, select
//  models, or restore a backup). Its sheet flags and the provider store are
//  stored in ContentView.swift.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    // MARK: - Empty State

    /// [T-onboarding-hide-fab] Whether the floating New Chat / Search buttons
    /// stay hidden because the first-run checklist owns the screen. The two are
    /// mounted independently (checklist = list overlay, buttons = bottom safe
    /// area inset), so without this the New Chat button floated over steps 1-2
    /// before any provider or model existed - offering a chat that cannot run.
    /// Hidden only until models are selected: from then on step 3's subtitle
    /// ("Tap the button below to begin") points at that very button, and a
    /// returning user with no chats lands on this same screen.
    /// `showSearchBar` keeps an open search field from vanishing under it.
    /// Not gated on `didInitialLoad`: the provider config is read synchronously
    /// in ProviderConfigStore.init, so a set-up user never matches, and a first
    /// launch no longer flashes the buttons while the (empty) list loads.
    func hidesFABForOnboarding(listIsEmpty: Bool) -> Bool {
        listIsEmpty && !showSearchBar && providerStore.modelGroups.isEmpty
    }

    var emptyState: some View {
        let hasProviders = !providerStore.instances.isEmpty
        let hasGroups = !providerStore.modelGroups.isEmpty

        return VStack(spacing: 32) {
            Spacer()
            // App icon / hero
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)

            VStack(spacing: 8) {
                Text("Welcome to Minis")
                    .font(.title2.bold())
                Text("Your first On-Device Agent is almost ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Setup steps
            VStack(spacing: 16) {
                // Step 1 – Add Provider
                setupStep(
                    number: 1,
                    title: "Add a Provider",
                    subtitle: hasProviders ? "Done" : "Configure an API key or sign in with OAuth",
                    isDone: hasProviders
                ) {
                    if !hasProviders {
                        showAddProvider = true
                    }
                }

                // Step 2 – Select Models
                setupStep(
                    number: 2,
                    title: "Select Models",
                    subtitle: hasGroups ? "Done" : (hasProviders ? "Choose the models you want to use" : "Complete step 1 first"),
                    isDone: hasGroups
                ) {
                    if hasProviders && !hasGroups {
                        showSelectModels = true
                    }
                }

                // Step 3 – Start chatting
                setupStep(
                    number: 3,
                    title: "Start a Conversation",
                    subtitle: hasGroups ? "Tap the button below to begin" : "Complete step 2 first",
                    isDone: false
                ) {
                    if hasGroups {
                        // [T-nav-ghost-row-link] From the home list: replace, never append.
                        switchToSession(Self.makeNewSessionId())
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 400)

            Spacer()

            // [T-onboarding-restore-link] A side route for someone moving from
            // another device: kept to a footnote link (not a fourth card) so it
            // does not compete with the three steps. Shown only until models
            // are selected — after that this empty state also greets returning
            // users with no chats, for whom Settings → Backup & Restore is the
            // path. Restore merges, so it is safe after step 1 as well.
            //
            // [T-onboarding-restore-link-bottom] Pinned to the bottom, below
            // the second Spacer, rather than tucked under step 3: a footnote
            // reads as a footer, and the steps keep the centre to themselves.
            // The overlay inherits the list's safe area, so this sits above the
            // Home Indicator; the extra bottom padding keeps it clear of the
            // indicator's swipe zone as well.
            if !hasGroups {
                Button {
                    showRestoreBackup = true
                } label: {
                    Label("Have a backup? Restore from it", systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
                .accessibilityIdentifier("onboarding.restoreBackup")
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 32)
        .sheet(isPresented: $showAddProvider) {
            NavigationStack {
                AddProviderView()
            }
        }
        .sheet(isPresented: $showSelectModels) {
            NavigationStack {
                OnboardingModelSelectionView()
            }
        }
        .sheet(isPresented: $showRestoreBackup) {
            // Same presentation as opening a .minisbak from Files: straight to
            // the Restore tab. Not auto-dismissed on success — the result
            // report is worth reading; the steps above refresh on their own
            // (restore reloads ProviderConfigStore and the session list).
            NavigationStack {
                BackupAndRestoreView(initialTab: .restore)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showRestoreBackup = false }
                        }
                    }
            }
        }
    }

    // title/subtitle must stay LocalizedStringKey, not String. A string literal at
    // the call site localizes fine on its own, but routing it through a String
    // parameter erases that: `Text(String)` stores the value verbatim and never
    // consults the string table, so these steps rendered English even though
    // Localizable.xcstrings has all 8 locales for these keys. Typing the parameter
    // as LocalizedStringKey keeps the literals (both branches of the `isDone`
    // ternaries included) resolving as keys.
    private func setupStep(
        number: Int,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isDone: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Step indicator
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green : Color.accentColor)
                        .frame(width: 32, height: 32)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isDone ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !isDone {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDone)
    }
}
