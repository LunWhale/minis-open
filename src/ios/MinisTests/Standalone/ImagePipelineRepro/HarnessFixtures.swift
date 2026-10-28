// [T-image-repro] Generated test images and request-body image extraction.
// Every fixture is drawn in code at run time; nothing is checked in.
import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Image generation

enum Pattern { case page, photo, noise, flat, halves }

/// RGBA bitmap with deterministic content. `page` imitates a web page (white
/// with text-like grey bars), `photo` a smooth gradient with mild texture,
/// `noise` incompressible pixels, `flat` a solid colour.
func makeCGImage(w: Int, h: Int, pattern: Pattern, alpha: Bool = false) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
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
    case .noise:
        let data = ctx.data!.bindMemory(to: UInt32.self, capacity: ctx.bytesPerRow / 4 * h)
        var x: UInt32 = 2463534242
        for i in 0..<(ctx.bytesPerRow / 4 * h) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; data[i] = x | 0xFF00_0000 }
    case .flat:
        ctx.setFillColor(UIColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    case .halves:
        // stored left half red, right half blue — tells upright / rotated / squashed apart
        ctx.setFillColor(UIColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(UIColor.blue.cgColor); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
    }
    if alpha {
        // Transparent bands at the top and bottom edges.
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 8))
        ctx.fill(CGRect(x: 0, y: h - h / 8, width: w, height: h / 8))
        ctx.setBlendMode(.normal)
    }
    return ctx.makeImage()!
}

func encode(_ img: CGImage, type: UTType, quality: Double = 0.85, orientation: Int? = nil) -> Data {
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "encode \(type.identifier) failed")
    return out as Data
}

/// What BrowserUseManager.screenshot does with the WKWebView snapshot: a UIImage
/// at screen scale, `jpegData(compressionQuality: 0.8)`, and `image.size` for
/// the metadata line. Here the snapshot is drawn at the same point size / scale.
func screenshotLike(pointW: Int, pointH: Int, scale: CGFloat = 3) -> (data: Data, size: CGSize) {
    let cg = makeCGImage(w: Int(CGFloat(pointW) * scale), h: Int(CGFloat(pointH) * scale), pattern: .page)
    let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
    return (image.jpegData(compressionQuality: 0.8)!, image.size)
}

// MARK: - Probing bytes

struct Probe {
    var w = 0, h = 0
    var fmt = "?"
    var alpha = false
    var orientation = 1
    var corner = ""
}

func probe(_ data: Data) -> Probe {
    var p = Probe()
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return p }
    p.w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    p.h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    p.alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
    p.orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    let t = (CGImageSourceGetType(src) as String?) ?? "?"
    switch t {
    case UTType.jpeg.identifier: p.fmt = "jpeg"
    case UTType.png.identifier: p.fmt = "png"
    case UTType.heic.identifier, "public.heif": p.fmt = "heic"
    case UTType.gif.identifier: p.fmt = "gif"
    default: p.fmt = t
    }
    // top-left pixel, decoded small (the corner of a 3000px image is inside the
    // transparent band of the fixture)
    if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(thumb, in: CGRect(x: 0, y: -(thumb.height - 1), width: thumb.width, height: thumb.height))
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
        p.corner = "rgba(\(px[0]),\(px[1]),\(px[2]),\(px[3]))"
    }
    return p
}

/// How an EXIF-6 `.halves` fixture came out, judged on the STORED pixels plus
/// the orientation tag (what a provider that ignores EXIF would show):
///   upright  — portrait, red on top, blue at the bottom (correctly rotated)
///   tagged   — still landscape with orientation 6 kept (viewer must rotate)
///   squashed — landscape, no tag, red on top / blue at the bottom: portrait
///              content drawn into a landscape canvas (distorted)
///   sideways — landscape, no tag, red left / blue right: rotation dropped
func orientationVerdict(_ data: Data) -> String {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "undecodable" }
    let p = probe(data)
    let n = 16
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
    func colour(_ x: Int, _ yTop: Int) -> String {   // bitmap memory row 0 is the top row
        let o = (yTop * n + x) * 4
        return px[o] > px[o + 2] ? "red" : "blue"
    }
    let top = colour(n / 2, 1), bottom = colour(n / 2, n - 2), left = colour(1, n / 4), right = colour(n - 2, n / 4)
    let portrait = img.height > img.width
    if p.orientation != 1 { return "tagged(\(p.orientation)) \(img.width)x\(img.height)" }
    if portrait && top == "red" && bottom == "blue" { return "upright \(img.width)x\(img.height)" }
    if !portrait && top == "red" && bottom == "blue" { return "squashed \(img.width)x\(img.height)" }
    if !portrait && left == "red" && right == "blue" { return "sideways \(img.width)x\(img.height)" }
    return "other(t=\(top),b=\(bottom),l=\(left),r=\(right)) \(img.width)x\(img.height)"
}

// MARK: - Request-body image extraction

struct WireImage {
    let mime: String
    let data: Data
    let b64Length: Int
}

/// Every image a serialized request carries, in document order. Understands
/// OpenAI Responses (`input_image`), Chat Completions (`image_url`), Gemini /
/// Antigravity (`inlineData`) and Anthropic (`image` + `source`).
func wireImages(_ json: Any) -> [WireImage] {
    var found: [WireImage] = []
    func dataURL(_ s: String) -> WireImage? {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ","),
              let semi = s.range(of: ";base64") else { return nil }
        let mime = String(s[s.index(s.startIndex, offsetBy: 5)..<semi.lowerBound])
        let b64 = String(s[s.index(after: comma)...])
        return Data(base64Encoded: b64).map { WireImage(mime: mime, data: $0, b64Length: b64.count) }
    }
    func walk(_ v: Any) {
        if let d = v as? [String: Any] {
            if let inline = d["inlineData"] as? [String: Any], let b64 = inline["data"] as? String,
               let data = Data(base64Encoded: b64) {
                found.append(WireImage(mime: inline["mimeType"] as? String ?? "?", data: data, b64Length: b64.count))
            }
            if d["type"] as? String == "image", let src = d["source"] as? [String: Any], let b64 = src["data"] as? String,
               let data = Data(base64Encoded: b64) {
                found.append(WireImage(mime: src["media_type"] as? String ?? "?", data: data, b64Length: b64.count))
            }
            if d["type"] as? String == "input_image", let url = d["image_url"] as? String, let img = dataURL(url) { found.append(img) }
            if d["type"] as? String == "image_url", let u = d["image_url"] as? [String: Any], let url = u["url"] as? String,
               let img = dataURL(url) { found.append(img) }
            for key in d.keys.sorted() where key != "inlineData" && key != "source" { walk(d[key]!) }
        } else if let a = v as? [Any] {
            a.forEach(walk)
        }
    }
    walk(json)
    return found
}

/// Compact structural signature of a request's item list.
func orderSignature(_ items: [[String: Any]]) -> String {
    items.map { item -> String in
        if let t = item["type"] as? String { return t }
        let role = item["role"] as? String ?? "?"
        if let parts = item["content"] as? [[String: Any]] {
            let kinds = parts.compactMap { $0["type"] as? String }.filter { $0.contains("image") }
            return kinds.isEmpty ? role : "\(role):\(kinds.joined(separator: "+"))"
        }
        return role
    }.joined(separator: ">")
}
