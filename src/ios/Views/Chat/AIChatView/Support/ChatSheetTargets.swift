//
//  ChatSheetTargets.swift
//  Minis - chat page (AIChatView)
//
//  Sheet items for the downloads panel: MinisFolderBrowseTarget (open the file
//  browser at a folder) and DownloadLocateTarget (highlight a downloaded file).
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

/// [T-browser-download-ux-v2] Sheet item for "Show in Files" from the
/// downloads panel: opens the file browser rooted at the session workspace
/// and highlights this filename.
struct MinisFolderBrowseTarget: Identifiable {
    let root: URL
    let folder: URL
    let label: String
    var id: String { folder.path }
}

struct DownloadLocateTarget: Identifiable {
    let filename: String
    var id: String { filename }
}
