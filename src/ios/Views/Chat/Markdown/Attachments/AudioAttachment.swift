//
//  AudioAttachment.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments.
//
//  Markdown audio link: an inline player row driven by the shared
//  GlobalAudioPlayer (InlineAudioController). Taps on the row are handled by
//  AudioTapGesture in Media/MediaPreviewPresentation.swift.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Audio Attachment

final class AudioAttachment: NSTextAttachment {
    let source: String
    let theme: SelectableMarkdownTheme
    private var resolvedURL: URL?
    private var isResolved = false

    static let attachmentHeight: CGFloat = 70

    init(source: String, theme: SelectableMarkdownTheme) {
        self.source = source
        self.theme = theme
        super.init(data: nil, ofType: nil)
        self.image = Self.transparentImage
        resolveURL()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    private func resolveURL() {
        // Strip query parameters for file URL resolution (they are metadata, not part of the path)
        let cleanSource: String
        if let url = URL(string: source), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = nil
            cleanSource = components.url?.absoluteString ?? source
        } else {
            cleanSource = source
        }
        if let url = URL(string: cleanSource), url.scheme == "minis" {
            resolvedURL = resolveMinisFileURLForNativeText(url: url)
        } else if let url = URL(string: cleanSource) {
            resolvedURL = url
        }
        isResolved = true
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = lineFrag.width
        return CGRect(x: 0, y: 0, width: width, height: Self.attachmentHeight)
    }

    func makeView(width: CGFloat) -> UIView {
        let maxW = width
        let h = Self.attachmentHeight

        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: h))
        container.backgroundColor = .clear

        let bg = UIView(frame: CGRect(x: 0, y: 0, width: maxW, height: h))
        bg.backgroundColor = .secondarySystemBackground
        bg.layer.cornerRadius = 10
        bg.clipsToBounds = true
        container.addSubview(bg)

        let rawFilename = source.components(separatedBy: "/").last ?? source
        let filename = rawFilename.components(separatedBy: "?").first ?? rawFilename

        // Waveform icon + filename
        let waveIcon = UIImageView(image: UIImage(systemName: "waveform"))
        waveIcon.tintColor = .secondaryLabel
        waveIcon.frame = CGRect(x: 10, y: 8, width: 14, height: 14)
        bg.addSubview(waveIcon)

        let nameLabel = UILabel()
        nameLabel.text = filename
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .secondaryLabel
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = CGRect(x: 28, y: 8, width: maxW - 62, height: 16)
        bg.addSubview(nameLabel)

        // Play button
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        let playBtn = UIButton(type: .system)
        playBtn.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig), for: .normal)
        playBtn.tintColor = .systemOrange
        playBtn.frame = CGRect(x: 10, y: 30, width: 30, height: 30)
        bg.addSubview(playBtn)

        // Slider
        let slider = UISlider()
        slider.minimumTrackTintColor = .systemOrange
        slider.frame = CGRect(x: 46, y: 34, width: maxW - 100, height: 22)
        slider.value = 0
        bg.addSubview(slider)

        // Duration label
        let durLabel = UILabel()
        durLabel.text = "--:--"
        durLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durLabel.textColor = .secondaryLabel
        durLabel.textAlignment = .right
        durLabel.frame = CGRect(x: maxW - 50, y: 36, width: 40, height: 16)
        bg.addSubview(durLabel)

        // Expand button (top-right)
        let expandBtn = UIButton(type: .system)
        let expandConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        expandBtn.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: expandConfig), for: .normal)
        expandBtn.tintColor = .secondaryLabel
        expandBtn.frame = CGRect(x: maxW - 28, y: 6, width: 22, height: 22)
        bg.addSubview(expandBtn)

        // Wire up audio playback controller
        let controller = InlineAudioController(fileURL: resolvedURL, playButton: playBtn, slider: slider, durationLabel: durLabel)
        // Keep controller alive by attaching to the view
        objc_setAssociatedObject(bg, &InlineAudioController.associatedKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Expand button action
        let expandTap = AudioTapGesture(target: nil, action: nil)
        expandTap.fileURL = resolvedURL
        expandTap.addTarget(expandTap, action: #selector(AudioTapGesture.handleTap))
        expandBtn.addTarget(expandTap, action: #selector(AudioTapGesture.handleTap), for: .touchUpInside)
        // Keep expandTap alive
        objc_setAssociatedObject(expandBtn, &AudioTapGesture.expandTapKey, expandTap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Tap on filename area opens fullscreen audio preview
        let tapTarget = UIView(frame: CGRect(x: 0, y: 0, width: maxW, height: 26))
        tapTarget.backgroundColor = .clear
        tapTarget.isUserInteractionEnabled = true
        bg.addSubview(tapTarget)
        let audioTap = AudioTapGesture(target: nil, action: nil)
        audioTap.fileURL = resolvedURL
        audioTap.addTarget(audioTap, action: #selector(AudioTapGesture.handleTap))
        tapTarget.addGestureRecognizer(audioTap)

        return container
    }
}

/// Manages inline audio UI by delegating to GlobalAudioPlayer singleton.
private final class InlineAudioController: NSObject {
    static var associatedKey: UInt8 = 0

    private let fileURL: URL?
    private weak var playButton: UIButton?
    private weak var slider: UISlider?
    private weak var durationLabel: UILabel?
    private var cancellables = Set<AnyCancellable>()

    init(fileURL: URL?, playButton: UIButton, slider: UISlider, durationLabel: UILabel) {
        self.fileURL = fileURL
        self.playButton = playButton
        self.slider = slider
        self.durationLabel = durationLabel
        super.init()

        playButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        // Pre-load duration for display
        // Note: auto_play is NOT triggered here because InlineAudioController is
        // re-created every time the view renders (including when re-entering a
        // conversation). Auto-play on LLM response is handled by
        // AIChatViewModel.triggerAutoPlayAudio() which only fires once at the end
        // of streaming.
        if let fileURL {
            Task.detached(priority: .userInitiated) {
                guard let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
                p.prepareToPlay()
                let dur = p.duration
                await MainActor.run {
                    slider.maximumValue = Float(dur)
                    durationLabel.text = Self.formatTime(dur)
                }
            }
        }

        // Subscribe to global player state on the main actor
        Task { @MainActor [weak self] in
            guard let self else { return }
            let gp = GlobalAudioPlayer.shared
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)

            gp.$isPlaying.combineLatest(gp.$activeFileURL)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] playing, activeURL in
                    guard let self, let url = self.fileURL else { return }
                    let isActive = activeURL == url
                    let icon = isActive && playing ? "pause.circle.fill" : "play.circle.fill"
                    self.playButton?.setImage(UIImage(systemName: icon, withConfiguration: iconConfig), for: .normal)
                }
                .store(in: &self.cancellables)

            gp.$currentTime.combineLatest(gp.$activeFileURL)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] time, activeURL in
                    guard let self, let url = self.fileURL else { return }
                    if activeURL == url {
                        self.slider?.value = Float(time)
                    }
                }
                .store(in: &self.cancellables)

            gp.$duration.combineLatest(gp.$activeFileURL)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] dur, activeURL in
                    guard let self, let url = self.fileURL else { return }
                    if activeURL == url {
                        self.slider?.maximumValue = Float(dur)
                        self.durationLabel?.text = Self.formatTime(dur)
                    }
                }
                .store(in: &self.cancellables)
        }
    }

    @MainActor @objc private func togglePlayPause() {
        guard let url = fileURL else { return }
        let gp = GlobalAudioPlayer.shared
        if gp.isActive(url: url) {
            gp.togglePlayPause()
        } else {
            gp.play(url: url)
        }
    }

    @MainActor @objc private func sliderChanged() {
        guard let url = fileURL, let slider else { return }
        let gp = GlobalAudioPlayer.shared
        if gp.isActive(url: url) {
            gp.seek(to: TimeInterval(slider.value))
        }
    }

    static func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
