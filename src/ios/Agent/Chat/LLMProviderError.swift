//
//  LLMProviderError.swift
//  Minis - chat view model (Agent/Chat)
//
//  LLMProviderError - the provider credential error. It sat at the end of
//  AIChatViewModel.swift before that file was split.
//
//  Map of the AIChatViewModel files: AIChatViewModel.swift.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

enum LLMProviderError: LocalizedError {
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No API credentials available"
        }
    }
}
