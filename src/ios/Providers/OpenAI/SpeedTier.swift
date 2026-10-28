import Foundation

// [T-codex-speed-tier] Request speed tier ("…" menu → Speed).
//
// The "Enable Fast Mode" switch ([T-codex-fast-mode], [T-xai-priority-
// processing]) becomes three mutually exclusive tiers:
//
//   standard   no `service_tier` field (the request is unchanged)
//   fast       `service_tier: "priority"` — Fast's wire value; sending the
//              string "fast" is a 400
//   ultrafast  `service_tier: "ultrafast"` — Responses API only, and only for
//              the models in `ultrafastModelPrefixes` (GPT-6 Astra) or those the
//              account's Codex catalogue declares it for
//
// [T-codex-ultrafast-echo] The response's `service_tier` is NOT evidence of
// what tier ran. Under ChatGPT auth the tier is decided by server-side routing,
// and the echoed value is "not an end-to-end field you can reliably verify"
// (openai/codex issue #14204); CLIProxyAPI measured Fast working while the echo
// still said "default" (PR #6090). A toast here used to read an echoed
// "default" as "this account doesn't support Ultrafast" — a Pro user was shown
// exactly that. It is gone; the echo is only logged, without a verdict.
//
// Storage keeps the old Bool key: `codexFastModeEnabled == true` still means
// Fast, so a user upgrading from the switch keeps exactly what they had, and a
// downgrade to a build that only knows the Bool reads Fast for both Fast and
// Ultrafast (never an unknown value). The tier itself lives under a new String
// key, written together with the Bool.
//
// Foundation-only on purpose: MinisTests/Standalone/SpeedTierTests.swift
// compiles this file as shipped.

enum SpeedTier: String, CaseIterable, Equatable {
    case standard
    case fast
    case ultrafast

    /// `service_tier` for a Responses-API request; nil = omit the field.
    var wireValue: String? {
        switch self {
        case .standard: return nil
        case .fast: return "priority"
        case .ultrafast: return "ultrafast"
        }
    }
}

enum SpeedTierSettings {
    /// New String key holding the tier (`SpeedTier.rawValue`).
    static let tierDefaultsKey = "codexSpeedTier"
    /// The pre-tier Bool ("Enable Fast Mode"). Same string as
    /// `OpenAIProvider.fastModeDefaultsKey`; kept in step with the tier.
    static let legacyFastModeKey = "codexFastModeEnabled"

    // BEGIN storedTier
    /// The user's chosen tier, independent of any model. A valid tier key
    /// wins; without one, the legacy Bool decides (true → Fast), so a value
    /// written by the old switch keeps its meaning with no migration step.
    static func storedTier(in defaults: UserDefaults = .standard) -> SpeedTier {
        if let raw = defaults.string(forKey: tierDefaultsKey), let tier = SpeedTier(rawValue: raw) {
            return tier
        }
        return defaults.bool(forKey: legacyFastModeKey) ? .fast : .standard
    }

    /// Writes the tier AND the legacy Bool (on for Fast and Ultrafast), so any
    /// reader of the old key — including an older build after a downgrade —
    /// still sees "fast mode on" whenever a faster tier is chosen.
    static func setTier(_ tier: SpeedTier, in defaults: UserDefaults = .standard) {
        defaults.set(tier.rawValue, forKey: tierDefaultsKey)
        defaults.set(tier != .standard, forKey: legacyFastModeKey)
    }
    // END storedTier

    // BEGIN supportsUltrafast
    /// Models offered Ultrafast by the fallback WHITELIST, matched as a
    /// lowercased id prefix. The official client only sends a tier the model's
    /// catalog entry declares (`ModelInfo::service_tier_for_request`), and the
    /// bundled catalog (checked: CLIProxyAPI's codex_client_models.json at
    /// c8a2bfe8f) declares only "priority" for every model; the whitelist is
    /// kept because the user decided to offer Ultrafast without waiting for a
    /// catalog declaration. See `catalogUltrafastKey` for how the catalog takes
    /// precedence once it declares the tier.
    ///
    /// [T-ultrafast-astra-only] GPT-6 Astra only. OpenAI's Codex speed docs list
    /// Ultrafast as "GPT-6 Astra only" (Pro $500 and eligible Enterprise/Edu
    /// plans); gpt-6.1-sol was on this list from DevDay coverage alone and is
    /// not offered. An account without the entitlement still gets a 200 and is
    /// served at Standard - the echoed service_tier cannot tell the two apart.
    static let ultrafastModelPrefixes = ["gpt-6-astra"]

    /// [T-codex-ultrafast-echo] Lowercased ids whose Codex catalogue entry
    /// declares an "ultrafast" tier, written by every successful discovery
    /// (replacing the previous list, so a withdrawn declaration disappears).
    static let catalogUltrafastKey = "codexCatalogUltrafastModels"

    static func supportsUltrafast(modelId: String, in defaults: UserDefaults = .standard) -> Bool {
        let lid = modelId.lowercased()
        if (defaults.stringArray(forKey: catalogUltrafastKey) ?? []).contains(lid) { return true }
        return ultrafastModelPrefixes.contains { lid.hasPrefix($0) }
    }

    /// Does one catalogue entry declare Ultrafast? `service_tiers[].id` is what
    /// the official client checks; `additional_speed_tiers` (today ["fast"]) is
    /// read too in case the tier is announced there first.
    static func catalogDeclaresUltrafast(_ item: [String: Any]) -> Bool {
        let tierIds = ((item["service_tiers"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        let speedTiers = (item["additional_speed_tiers"] as? [String]) ?? []
        return (tierIds + speedTiers).contains { $0.lowercased() == "ultrafast" }
    }

    static func recordCatalogUltrafast(modelIds: [String], in defaults: UserDefaults = .standard) {
        defaults.set(modelIds.map { $0.lowercased() }, forKey: catalogUltrafastKey)
    }
    // END supportsUltrafast

    // BEGIN requestTiers
    /// The tier a Responses-API request for `modelId` actually uses:
    /// Ultrafast falls back to Fast for a model outside the whitelist, so a
    /// user who chose Ultrafast and then switched model never sends
    /// "ultrafast" where it is not offered.
    static func effectiveTier(_ stored: SpeedTier, modelId: String,
                              in defaults: UserDefaults = .standard) -> SpeedTier {
        if stored == .ultrafast, !supportsUltrafast(modelId: modelId, in: defaults) { return .fast }
        return stored
    }

    /// `service_tier` for the Responses path (Codex OAuth and Responses
    /// relays), gated on a gpt-family id exactly as Fast Mode was.
    static func responsesServiceTier(stored: SpeedTier, modelId: String,
                                     in defaults: UserDefaults = .standard) -> String? {
        guard modelId.lowercased().contains("gpt") else { return nil }
        return effectiveTier(stored, modelId: modelId, in: defaults).wireValue
    }

    /// [T-ultrafast-unsupported-log] A log line for a request where Ultrafast was
    /// chosen but is not what the model / account supports, or nil when there is
    /// nothing to report (another tier chosen, or Ultrafast declared by the
    /// account's catalogue). Two cases:
    ///   - the model is not offered Ultrafast: the request goes out as Fast
    ///     ("priority");
    ///   - the model is offered only by the fallback whitelist and the account's
    ///     catalogue does not declare it: "ultrafast" is sent, but an account
    ///     without the entitlement gets a 200 served at Standard, and the echoed
    ///     service_tier cannot tell.
    static func ultrafastUnsupportedNote(stored: SpeedTier, modelId: String,
                                         in defaults: UserDefaults = .standard) -> String? {
        let lid = modelId.lowercased()
        // Non-gpt ids take no Responses tier at all (xAI has its own
        // "priority" path), so there is nothing to report for them.
        guard stored == .ultrafast, lid.contains("gpt") else { return nil }
        let declared = defaults.stringArray(forKey: catalogUltrafastKey) ?? []
        let sent = responsesServiceTier(stored: stored, modelId: modelId, in: defaults) ?? "none"
        if !supportsUltrafast(modelId: modelId, in: defaults) {
            return "Ultrafast not supported for model=\(modelId) (whitelist=\(ultrafastModelPrefixes), catalogue declares=\(declared)); sending service_tier=\(sent)"
        }
        if !declared.contains(lid) {
            return "Ultrafast for model=\(modelId) comes from the fallback whitelist only; the account catalogue declares it for \(declared) - an account without the entitlement is likely served at Standard (service_tier=\(sent))"
        }
        return nil
    }

    /// xAI Priority Processing only has "priority": Fast and Ultrafast both
    /// map to it, never to "ultrafast".
    static func xaiServiceTier(stored: SpeedTier) -> String? {
        stored == .standard ? nil : "priority"
    }
    // END requestTiers

    // BEGIN routingHint
    /// [T-codex-routing-hint] Value of `x-codex-routing-hint`, which the official
    /// Codex client sends on every ChatGPT-backend Responses request
    /// (codex-rs/core/src/client.rs `build_routing_hint_header`):
    /// `model=<request model>;tier=<request service_tier>`, or just
    /// `model=<request model>` when the request carries no tier. Built from the
    /// FINAL request body so header and body cannot disagree. nil without a
    /// model. Aligning with the official client does NOT prove the header is
    /// needed for Fast / Ultrafast to take effect.
    static func codexRoutingHint(model: String?, serviceTier: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        if let serviceTier, !serviceTier.isEmpty { return "model=\(model);tier=\(serviceTier)" }
        return "model=\(model)"
    }

    static let routingHintHeaderField = "x-codex-routing-hint"
    // END routingHint
}
