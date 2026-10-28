//
//  SpeedTier+Display.swift
//  Minis - chat page (AIChatView)
//
//  SpeedTier display strings and SF Symbols for the speed menu and the
//  navigation-bar badge.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

extension SpeedTier {
    /// [T-codex-speed-tier] Tier name, text only. [T-codex-speed-icons] The
    /// emoji prefixes are gone: the icon is the row's SF Symbol, and the
    /// submenu row's subtitle repeats this text without an icon.
    var title: String {
        switch self {
        case .standard: return AppLocalized("Standard")
        case .fast: return AppLocalized("Fast")
        case .ultrafast: return AppLocalized("Ultrafast")
        }
    }

    /// [T-codex-speed-icons] Monochrome SF Symbol for the tier's menu row:
    /// speedometer / outline bolt / filled bolt, so Fast and Ultrafast differ
    /// by fill rather than by a count of emoji. Selection stays the system
    /// checkmark (single-selection menu).
    var symbol: String {
        switch self {
        case .standard: return "speedometer"
        case .fast: return "bolt"
        case .ultrafast: return "bolt.fill"
        }
    }

    /// The "Speed" submenu entry's icon.
    static let entrySymbol = "speedometer"

    /// Navigation-bar badge glyph; nil for Standard (no badge).
    var badgeSymbol: String? {
        self == .standard ? nil : symbol
    }
}
