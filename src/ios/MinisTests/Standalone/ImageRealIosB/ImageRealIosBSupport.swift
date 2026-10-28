// [T-image-seams iOS-B] Support code for the ImageRealIosB harness: stand-ins
// for app symbols that have nothing to do with images, generated fixtures, and
// byte probes. Compiled only into that harness.
import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum IosBEnv {
    static var root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imgreal-iosb-work")
    static let sessionId = "S-IOSB"
}

// MARK: - Stand-ins (names the compiled production code refers to)

struct AppLogger {
    init(category: String) {}
    func info(_ m: @autoclosure () -> String) {}
    func warning(_ m: @autoclosure () -> String) {}
    func error(_ m: @autoclosure () -> String) {}
    func debug(_ m: @autoclosure () -> String) {}
    func verbose(_ m: @autoclosure () -> String) {}
}
let logger = AppLogger(category: "harness")
func AppLocalized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String { String(localized: key) }
enum ModelsDevAPI { static func enrichModel(_ m: LLMModel) -> LLMModel { m } }
enum XAIModelsAPI { static var allModels: [LLMModel] { [] } }
enum KimiModelsAPI { static var allModels: [LLMModel] { [] } }

// MARK: - Fixtures (same generators as the previous round, so bytes compare)

enum IosBPattern { case page, photo }

func iosbCGImage(w: Int, h: Int, pattern: IosBPattern) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    switch pattern {
    case .page:
        ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(UIColor(white: 0.25, alpha: 1).cgColor)
        var y = 40
        var line = 0
        while y < h - 20 {
            let len = (w - 80) * (60 + (line * 37) % 40) / 100
            ctx.fill(CGRect(x: 40, y: y, width: len, height: max(2, w / 160)))
            y += max(10, w / 60); line += 1
            if line % 12 == 0 { y += max(30, w / 20) }
        }
    case .photo:
        let colors = [UIColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1).cgColor, UIColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1).cgColor] as CFArray
        let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        var x: UInt64 = 88172645463325252
        func next() -> UInt64 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x }
        for _ in 0..<2000 {
            ctx.setFillColor(UIColor(white: CGFloat(next() % 1000) / 1000, alpha: 0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: Int(next() % UInt64(w)), y: Int(next() % UInt64(h)), width: w / 40, height: w / 40))
        }
    }
    return ctx.makeImage()!
}

func iosbEncode(_ img: CGImage, type: UTType, quality: Double = 0.85) -> Data {
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    return out as Data
}

/// The screenshot action's output for a page of `pointW` x `pointH` points at
/// screen scale 3: the snapshot UIImage encoded by the REAL
/// `BrowserUseManager.screenshotJPEGData`, plus the `UIImage.size` the
/// metadata line is fed.
func iosbScreenshot(pointW: Int, pointH: Int) -> (data: Data, size: CGSize) {
    let image = UIImage(cgImage: iosbCGImage(w: pointW * 3, h: pointH * 3, pattern: .page), scale: 3, orientation: .up)
    return (BrowserUseManager.screenshotJPEGData(image)!, image.size)
}

struct IosBProbe { var w = 0, h = 0, fmt = "?" }
func iosbProbe(_ data: Data) -> IosBProbe {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return IosBProbe() }
    let t = (CGImageSourceGetType(src) as String?) ?? "?"
    let fmt = t == UTType.jpeg.identifier ? "jpeg" : t == UTType.heic.identifier ? "heic" : t == UTType.png.identifier ? "png" : t
    return IosBProbe(w: p[kCGImagePropertyPixelWidth] as? Int ?? 0, h: p[kCGImagePropertyPixelHeight] as? Int ?? 0, fmt: fmt)
}

/// First image a serialized request carries (Responses `input_image`, Chat
/// `image_url`, Gemini / Antigravity `inlineData`), with its declared MIME.
func iosbFirstImage(_ v: Any) -> (data: Data, mime: String)? {
    func fromURL(_ s: String) -> (Data, String)? {
        guard s.hasPrefix("data:"), let semi = s.range(of: ";base64,") else { return nil }
        let mime = String(s[s.index(s.startIndex, offsetBy: 5)..<semi.lowerBound])
        return Data(base64Encoded: String(s[semi.upperBound...])).map { ($0, mime) }
    }
    if let d = v as? [String: Any] {
        if let inline = d["inlineData"] as? [String: Any], let b = inline["data"] as? String, let data = Data(base64Encoded: b) {
            return (data, inline["mimeType"] as? String ?? "?")
        }
        if d["type"] as? String == "input_image", let u = d["image_url"] as? String, let r = fromURL(u) { return r }
        if d["type"] as? String == "image_url", let u = (d["image_url"] as? [String: Any])?["url"] as? String, let r = fromURL(u) { return r }
        for k in d.keys.sorted() { if let r = iosbFirstImage(d[k]!) { return r } }
    } else if let a = v as? [Any] {
        for x in a { if let r = iosbFirstImage(x) { return r } }
    }
    return nil
}
