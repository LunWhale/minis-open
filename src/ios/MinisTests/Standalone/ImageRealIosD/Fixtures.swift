// [T-image-real-seams] iOS-D fixtures: images drawn in code at run time
// (nothing checked in) and a byte prober. Same generators and seeds as the
// previous round's ImagePipelineRepro harness, so S3/S4/S6 inputs are the
// same pixels; kept in this directory so the two harnesses can change
// independently.
//
// Guarded so the MinisTests target (which picks up every .swift under
// MinisTests/) compiles this to nothing; the driver passes -D IMAGE_REAL_IOS_D.
#if IMAGE_REAL_IOS_D
import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum Pattern { case page, photo, noise, flat }

/// RGBA bitmap with deterministic content: `page` a web page (white with
/// text-like grey bars), `photo` a gradient with mild texture, `noise`
/// incompressible pixels, `flat` a solid colour.
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

struct Probe {
    var w = 0, h = 0
    var fmt = "?"
    var alpha = false
}

func probe(_ data: Data) -> Probe {
    var p = Probe()
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return p }
    p.w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    p.h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    p.alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
    switch (CGImageSourceGetType(src) as String?) ?? "?" {
    case UTType.jpeg.identifier: p.fmt = "jpeg"
    case UTType.png.identifier: p.fmt = "png"
    case UTType.heic.identifier, "public.heif": p.fmt = "heic"
    case UTType.gif.identifier: p.fmt = "gif"
    case let other: p.fmt = other
    }
    return p
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
#endif
