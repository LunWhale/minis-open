//
//  MarkdownLoggers.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Loggers shared across the module (renderer, media attachments, text view,
//  bridge, minis:// resolution). They were file-private globals while the
//  module was one file; they are internal now that their users live in
//  separate files. Categories are unchanged, so existing log greps still
//  match: MinisImage, AttachDebug, MarkdownResponder.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

let imgLogger = AppLogger(category: "MinisImage")
let attachLogger = AppLogger(category: "AttachDebug")
/// [T-ios-resign-first-responder-graph-reentry] Deferred responder-chain walks.
let responderLogger = AppLogger(category: "MarkdownResponder")
