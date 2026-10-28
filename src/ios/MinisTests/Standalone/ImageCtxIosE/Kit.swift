// [T-ctx-builder] iOS-E Fixture Kit (catalog A1-A5): every input a scenario
// feeds the chain is generated here at run time - nothing binary is checked in.
// Pixels come from the iOS-D generators (ImageRealIosD/Fixtures.swift:
// makeCGImage / encode / probe / sha256), compiled into the same program, so
// a CAMERA_4032x3024 here is the same image the earlier rounds measured.
//
// Formats ImageIO cannot write on this host are produced as their smallest
// valid header and flagged `headerOnly` - the report names each one.
//
// Guarded so the MinisTests target (which picks up every .swift under
// MinisTests/) compiles this to nothing; the driver passes -D IMAGE_CTX_IOS_E.
#if IMAGE_CTX_IOS_E
import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - A1 images

/// Size presets, named identically on both platforms.
enum Preset: String, CaseIterable {
    case CAMERA_4032x3024, ALBUM_4000x6000, TINY_10x10, WIDE_9000x300, TALL_1x9000
    case FULLPAGE_IOS_2760x21891, FULLPAGE_AND_1080x32768, VIEWPORT_IOS_1170x2532, VIEWPORT_BIG_9000x6000

    var size: (w: Int, h: Int) {
        let dims = rawValue.split(separator: "_").last!.split(separator: "x").map { Int($0)! }
        return (dims[0], dims[1])
    }
}

enum ImageFormat: String { case jpeg, png, pngAlpha, gif, bmp, heic, webp, tiff }

struct Fixture {
    let data: Data
    let fileName: String
    /// True when the platform cannot encode the format and `data` is only the
    /// smallest valid header (catalog: "仅头部").
    var headerOnly = false
    var note = ""
}

enum Kit {
    static var headerOnlyFormats: Set<String> = []

    static func canWrite(_ type: UTType) -> Bool {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return ids.contains(type.identifier)
    }

    /// A1: an image of `w` x `h` in `format`, optionally with an EXIF
    /// orientation tag (1-8, mirrored ones included).
    static func image(_ w: Int, _ h: Int, _ format: ImageFormat, pattern: Pattern = .photo,
                      orientation: Int? = nil, name: String? = nil, quality: Double = 0.85) -> Fixture {
        let ext: String
        let data: Data
        var headerOnly = false
        switch format {
        case .jpeg:
            ext = "jpg"; data = encode(makeCGImage(w: w, h: h, pattern: pattern), type: .jpeg, quality: quality, orientation: orientation)
        case .png:
            ext = "png"; data = encode(makeCGImage(w: w, h: h, pattern: pattern), type: .png, orientation: orientation)
        case .pngAlpha:
            ext = "png"; data = encode(makeCGImage(w: w, h: h, pattern: pattern, alpha: true), type: .png, orientation: orientation)
        case .gif:
            ext = "gif"; data = gif(w, h, frames: 3)
        case .bmp:
            ext = "bmp"; data = encode(makeCGImage(w: w, h: h, pattern: pattern), type: .bmp)
        case .heic:
            ext = "heic"
            if canWrite(.heic) { data = encode(makeCGImage(w: w, h: h, pattern: pattern), type: .heic, quality: 0.8, orientation: orientation) }
            else { data = heicHeader(); headerOnly = true }
        case .webp:
            ext = "webp"
            if canWrite(.webP) { data = encode(makeCGImage(w: w, h: h, pattern: pattern), type: .webP, quality: quality) }
            else { data = webpHeader(); headerOnly = true }
        case .tiff:
            ext = "tiff"; data = encode(makeCGImage(w: w, h: h, pattern: pattern), type: .tiff)
        }
        if headerOnly { headerOnlyFormats.insert(format.rawValue) }
        return Fixture(data: data, fileName: name ?? "IMG_\(w)x\(h).\(ext)", headerOnly: headerOnly)
    }

    static func image(_ preset: Preset, _ format: ImageFormat = .jpeg, pattern: Pattern = .photo, name: String? = nil) -> Fixture {
        image(preset.size.w, preset.size.h, format, pattern: pattern, name: name)
    }

    /// Multi-frame GIF (each frame a different solid tint).
    static func gif(_ w: Int, _ h: Int, frames: Int) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames, nil)!
        for i in 0..<frames {
            let frame = makeCGImage(w: w, h: h, pattern: i % 2 == 0 ? .photo : .flat)
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func heicHeader() -> Data { Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8)) }
    static func webpHeader() -> Data { Data(Array("RIFF".utf8) + [0x1A, 0, 0, 0] + Array("WEBPVP8 ".utf8) + [0x0E, 0, 0, 0] + [UInt8](repeating: 0, count: 14)) }

    // A1 variants
    static func zeroBytes(_ name: String = "empty.jpg") -> Fixture { Fixture(data: Data(), fileName: name) }
    static func truncated(_ f: Fixture, keep: Int = 1024) -> Fixture { Fixture(data: f.data.prefix(keep), fileName: "truncated_" + f.fileName) }
    static func notAnImage(_ name: String = "fake.jpg") -> Fixture {
        Fixture(data: Data(String(repeating: "this is plain text pretending to be an image\n", count: 64).utf8), fileName: name)
    }
    /// Same bytes, different extension (e.g. JPEG bytes named `.webp`).
    static func renamed(_ f: Fixture, ext: String) -> Fixture {
        Fixture(data: f.data, fileName: ((f.fileName as NSString).deletingPathExtension) + "." + ext, headerOnly: f.headerOnly)
    }

    // MARK: - A2 text

    static func text(chars n: Int) -> String {
        let words = ["context", "budget", "image", "request", "provider", "summary", "anchor", "token", "stream", "tool"]
        var s = ""
        s.reserveCapacity(n + 16)
        var i = 0
        while s.utf8.count < n { s += words[i % words.count]; s += (i % 13 == 12) ? ".\n" : " "; i += 1 }
        return String(s.prefix(n))
    }
    static func chinese(chars n: Int) -> String {
        let pool = Array("构建模型请求上下文的整条链路需要可以被单元测试覆盖并且不依赖真实数据")
        return String((0..<n).map { pool[$0 % pool.count] })
    }
    static let emojiZWJ = "family 👨‍👩‍👧‍👦 flag 🏳️‍🌈 skin 👍🏽 keycap 1️⃣"
    static let codeAndTable = "```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |"
    static let contextSummaryLike = "Please keep this literally: <context-summary>not a real summary</context-summary>"

    // MARK: - A3 other attachments

    /// ISO BMFF `ftyp` box only (catalog: header-only mp4; AVFoundation is not
    /// used because no iOS code path decodes a video attachment).
    static func mp4Header(_ name: String = "clip.mp4") -> Fixture {
        Fixture(data: Data([0, 0, 0, 0x20] + Array("ftypisom".utf8) + [0, 0, 2, 0] + Array("isomiso2avc1mp41".utf8)),
                fileName: name, headerOnly: true)
    }
    static func pdf(_ name: String = "doc.pdf") -> Fixture {
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        let d = r.pdfData { ctx in ctx.beginPage(); ("fixture" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil) }
        return Fixture(data: d, fileName: name)
    }
    /// A real 0.1 s 8 kHz mono PCM WAV.
    static func wav(_ name: String = "voice.wav") -> Fixture {
        let samples = 800
        var d = Data("RIFF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(UInt32(36 + samples * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        for i in 0..<samples { u16(UInt16(bitPattern: Int16(sin(Double(i) / 4) * 8000))) }
        return Fixture(data: d, fileName: name)
    }
    /// An empty but valid zip (end-of-central-directory record only).
    static func zip(_ name: String = "bundle.zip") -> Fixture {
        Fixture(data: Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)), fileName: name)
    }
    static func plainText(_ name: String = "notes.txt") -> Fixture { Fixture(data: Data("hello from a text attachment\n".utf8), fileName: name) }

    /// A3 "huge file": sparse, so it occupies no disk blocks.
    static func sparseFile(at url: URL, bytes: UInt64) -> URL {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try! FileHandle(forWritingTo: url)
        try! h.truncate(atOffset: bytes)
        try! h.close()
        return url
    }

    // MARK: - A4 browser artifacts (real encoder setting)

    /// What the screenshot action returns for a page of `pointW` x `pointH`
    /// points at screen scale 3: `BrowserUseManager.screenshotJPEGData`
    /// (JPEG 0.8) of the snapshot UIImage.
    static func screenshot(pointW: Int, pointH: Int) -> (data: Data, size: CGSize) {
        let image = UIImage(cgImage: makeCGImage(w: pointW * 3, h: pointH * 3, pattern: .page), scale: 3, orientation: .up)
        return (BrowserUseManager.screenshotJPEGData(image)!, image.size)
    }
    static func screenshot(_ preset: Preset) -> (data: Data, size: CGSize) {
        screenshot(pointW: preset.size.w / 3, pointH: preset.size.h / 3)
    }

    // MARK: - A5 tool outputs

    static func shellOutput(lines: Int) -> String { (0..<lines).map { "line \($0): " + text(chars: 60) }.joined(separator: "\n") }
    static func mcpJSONWithBase64(_ image: Data) -> String {
        "{\"content\":[{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"\(image.base64EncodedString())\"}]}"
    }
}
#endif
