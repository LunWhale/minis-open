//
//  UserAskSettings.swift
//  Minis
//
//  [T-user-ask] Settings for the user_ask tool (Settings › Agent Tools, and
//  `minis-config agentTools.userAsk.*`). Foundation only, so
//  MinisTests/Standalone/UserAskSettingsTests.swift compiles the block below.
//

import Foundation

// BEGIN UserAskSettings
struct UserAskSettings: Equatable {
    // UserDefaults keys. `enabledKey` is AgentToolSwitch.userAsk's key.
    static let enabledKey = "agent.tools.userAsk.enabled"
    static let timeoutMinutesKey = "agent.tools.userAsk.timeoutMinutes"
    static let notifyInBackgroundKey = "agent.tools.userAsk.notifyInBackground"
    /// [T-user-ask-fallback] The one-shot "your reply ends with a question —
    /// ask it with user_ask" nudge. No settings row; off unless set to true
    /// (its detector is a first cut, to be judged on real turn-end logs).
    static let textAskNudgeKey = "agent.tools.userAsk.textAskNudge"

    // minis-config paths (topic `agentTools`).
    static let configPathPrefix = "agentTools.userAsk."
    static let enabledPath = configPathPrefix + "enabled"
    static let timeoutMinutesPath = configPathPrefix + "timeoutMinutes"
    static let notifyInBackgroundPath = configPathPrefix + "notifyInBackground"

    static let defaultEnabled = true
    static let defaultTimeoutMinutes = 5
    static let maxTimeoutMinutes = 1440
    static let defaultNotifyInBackground = true
    static let defaultTextAskNudge = false
    /// Settings picker choices; 0 = wait indefinitely.
    static let timeoutChoices = [1, 2, 5, 10, 30, 60, 0]

    var enabled = defaultEnabled
    var timeoutMinutes = defaultTimeoutMinutes
    var notifyInBackground = defaultNotifyInBackground
    var textAskNudge = defaultTextAskNudge

    static func load(_ d: UserDefaults = .standard) -> UserAskSettings {
        var s = UserAskSettings()
        s.enabled = (d.object(forKey: enabledKey) as? Bool) ?? defaultEnabled
        s.timeoutMinutes = clampTimeout((d.object(forKey: timeoutMinutesKey) as? Int) ?? defaultTimeoutMinutes)
        s.notifyInBackground = (d.object(forKey: notifyInBackgroundKey) as? Bool) ?? defaultNotifyInBackground
        s.textAskNudge = (d.object(forKey: textAskNudgeKey) as? Bool) ?? defaultTextAskNudge
        return s
    }

    static func clampTimeout(_ m: Int) -> Int { min(max(m, 0), maxTimeoutMinutes) }

    /// [T-user-ask-no-policy] Keys of the removed "Always allow" rules and
    /// "apply the model's default on timeout" mode. Deleted at launch so an
    /// old rule or mode can never come back into effect.
    static let legacyKeys = [
        "agent.tools.userAsk.alwaysAllowRules",
        "agent.tools.userAsk.autoDefaultMode",
    ]

    /// Returns the legacy keys that were present (and are now removed).
    @discardableResult
    static func purgeLegacyKeys(_ d: UserDefaults = .standard) -> [String] {
        let present = legacyKeys.filter { d.object(forKey: $0) != nil }
        for k in present { d.removeObject(forKey: k) }
        return present
    }
}
// END UserAskSettings
