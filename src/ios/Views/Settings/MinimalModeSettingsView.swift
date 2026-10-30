//
//  MinimalModeSettingsView.swift
//  Minis
//
//  [T-minimal-mode] Settings → Agent Runtime → Minimal Mode.
//
//  Reads top to bottom as the feature itself works: what minimal mode is, then
//  the two things a user can actually decide (whether it is offered at all, and
//  which of THEIR extensions it may run). Everything minimal mode forbids is
//  shown read-only rather than as a switch, because those are not preferences —
//  they are what "minimal" means, and a switch that the policy would ignore is
//  worse than no switch.
//

import SwiftUI

struct MinimalModeSettingsView: View {
    /// Master switch: whether the mode is offered in the slash menu.
    @AppStorage(MinimalModePolicy.Key.enabled) private var minimalModeEnabled = true

    /// User-installed extensions, refreshed when the store changes so the list is
    /// right after an install or an uninstall without leaving the page.
    @State private var installed: [ExtensionStore.Record] = []
    @State private var loadToken = UUID()

    var body: some View {
        List {
            introduction

            Section {
                Toggle(isOn: $minimalModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalized("Offer Minimal Mode in the / menu"))
                        Text(AppLocalized("When off, new sessions no longer offer the choice. Existing minimal sessions are unaffected."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(AppLocalized("Basics"))
            }

            pinnedOffSection
            keptSection
            installedExtensionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalized("Minimal Mode"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    // MARK: - Introduction

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: AgentMode.minimal.symbol)
                        .font(.title3)
                        .foregroundStyle(.green)
                    Text(AppLocalized("A token-lean session"))
                        .font(.headline)
                }
                Text(AppLocalized("Minimal mode runs the same agent with a much smaller prompt and a much smaller tool list. It is meant for quick, focused work — every turn costs less because there is less to send."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(AppLocalized("You choose it once, from the / menu, on a new session. It cannot be changed afterwards: the tool list and prompt a conversation was reasoned under must not change mid-thread."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - What minimal mode always switches off

    private var pinnedOffSection: some View {
        Section {
            ForEach(MinimalModePolicy.disabledBuiltins.sorted { $0.key < $1.key }, id: \.key) { id, reason in
                row(
                    title: BuiltinExtension.displayName(id: id),
                    subtitle: reason,
                    symbol: "minus.circle",
                    tint: .secondary
                )
            }
        } header: {
            Text(AppLocalized("Always off in minimal mode"))
        } footer: {
            Text(AppLocalized("These are switched off because each one adds tokens to every turn. They are not affected in normal sessions."))
        }
    }

    private var keptSection: some View {
        Section {
            ForEach(MinimalModePolicy.keptBuiltins.sorted { $0.key < $1.key }, id: \.key) { id, reason in
                row(
                    title: BuiltinExtension.displayName(id: id),
                    subtitle: reason,
                    symbol: "checkmark.circle",
                    tint: .green
                )
            }
        } header: {
            Text(AppLocalized("Kept"))
        } footer: {
            Text(AppLocalized("Basic capabilities that cost nothing per turn, or that the agent cannot work without."))
        }
    }

    // MARK: - The user's own extensions

    private var installedExtensionsSection: some View {
        Section {
            if installed.isEmpty {
                Text(AppLocalized("You have not installed any extensions yet."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(installed, id: \.id) { record in
                    Toggle(isOn: allowBinding(for: record.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                            Text(record.id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(AppLocalized("Your extensions"))
        } footer: {
            Text(AppLocalized("All off by default. Switch on only the ones a minimal session needs — each one adds its tools to every turn. Built-in plugins are not listed here; they are governed above."))
        }
    }

    // MARK: - Pieces

    private func row(title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One boolean per extension id, defaulting to the policy's default (off).
    private func allowBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                UserDefaults.standard.object(forKey: MinimalModePolicy.Key.allow(id)) == nil
                    ? MinimalModePolicy.userExtensionDefaultEnabled
                    : UserDefaults.standard.bool(forKey: MinimalModePolicy.Key.allow(id))
            },
            set: { UserDefaults.standard.set($0, forKey: MinimalModePolicy.Key.allow(id)) }
        )
    }

    /// User-installed extensions only — built-ins are shown above, and mixing the
    /// two in one list is how a user ends up hunting for a switch that cannot
    /// exist.
    private func reload() async {
        let token = UUID()
        loadToken = token
        let records = await ExtensionStore.shared.list()
            .filter { !BuiltinExtension.isBuiltin($0.id) }
        guard loadToken == token else { return }
        installed = records
    }
}
