// [T-image-real-seams] iOS-A scenarios. Every output below comes from the
// shipping `AIChatViewModel.inlineAttachmentImage(_:ext:route:)` (compiled
// verbatim from AIChatViewModel+Send.swift by the driver) and the real
// `downsampledCameraJPEG` for the camera capture; nothing here re-implements
// the pipeline. Results go to the JSON file named by argv[1].
//
// Guarded like Fixtures.swift; the driver's main.swift calls runScenarios().
#if IMAGE_REAL_IOS_A
import Foundation
import UIKit

var results: [String: Any] = [:]
func R(_ key: String, _ value: Any) { results[key] = value }

/// One attached image through one route; records what the model would get.
@discardableResult
func route(_ key: String, _ data: Data, ext: String, _ r: AttachmentInlineRoute) -> AttachmentInlineImage {
    let out = AIChatViewModel.inlineAttachmentImage(data, ext: ext, route: r)
    let p = probe(out.final)
    R("\(key).bytes", out.final.count)
    R("\(key).w", p.w)
    R("\(key).h", p.h)
    R("\(key).fmt", p.fmt)
    R("\(key).alpha", p.alpha)
    R("\(key).mime", out.mimeType)
    R("\(key).sha256", sha256(out.final))
    R("\(key).resizedBytes", out.resized.count)
    R("\(key).finalIsSource", out.final == data)
    return out
}

func source(_ key: String, _ data: Data) {
    let p = probe(data)
    R("\(key).src.bytes", data.count)
    R("\(key).src.w", p.w)
    R("\(key).src.h", p.h)
    R("\(key).src.fmt", p.fmt)
    R("\(key).src.sha256", sha256(data))
}

func runScenarios() {
    // S3: camera — the real downsampledCameraJPEG on a full-size capture, then
    // the attached file through both routes.
    let capture = UIImage(cgImage: makeCGImage(w: 4032, h: 3024, pattern: .photo))
    let camera = AIChatViewModel.downsampledCameraJPEG(capture)!
    source("s3", camera)
    route("s3.send", camera, ext: "jpg", .send)
    route("s3.queue", camera, ext: "jpg", .queue)

    // S4: photo-library picks (send route; queue route recorded too).
    let jpeg = encode(makeCGImage(w: 4032, h: 3024, pattern: .photo), type: .jpeg, quality: 0.9)
    let heic = encode(makeCGImage(w: 4032, h: 3024, pattern: .photo), type: .heic, quality: 0.8)
    let heicSmall = encode(makeCGImage(w: 1200, h: 900, pattern: .photo), type: .heic, quality: 0.8)
    let exif6 = encode(makeCGImage(w: 4032, h: 3024, pattern: .photo), type: .jpeg, quality: 0.9, orientation: 6)
    let png = encode(makeCGImage(w: 512, h: 512, pattern: .flat, alpha: true), type: .png)
    let pngBig = encode(makeCGImage(w: 3000, h: 3000, pattern: .flat, alpha: true), type: .png)
    for (name, data, ext) in [("jpeg", jpeg, "jpg"), ("heic", heic, "heic"), ("heicSmall", heicSmall, "heic"),
                              ("exif6", exif6, "jpg"), ("png", png, "png"), ("pngBig", pngBig, "png")] {
        source("s4.\(name)", data)
        route("s4.\(name).send", data, ext: ext, .send)
        route("s4.\(name).queue", data, ext: ext, .queue)
    }

    // S6: queue vs send on the same files.
    source("s6.jpeg", jpeg)
    let s6send = route("s6.jpeg.send", jpeg, ext: "jpg", .send)
    let s6queue = route("s6.jpeg.queue", jpeg, ext: "jpg", .queue)
    R("s6.jpeg.identical", s6send.final == s6queue.final)
    let gif = encode(makeCGImage(w: 2400, h: 1800, pattern: .photo), type: .gif)
    source("s6.gif", gif)
    route("s6.gif.send", gif, ext: "gif", .send)
    route("s6.gif.queue", gif, ext: "gif", .queue)
    let noisy = encode(makeCGImage(w: 2000, h: 2000, pattern: .noise), type: .jpeg, quality: 1.0)
    source("s6.noisy", noisy)
    route("s6.noisy.send", noisy, ext: "jpg", .send)
    route("s6.noisy.queue", noisy, ext: "jpg", .queue)
    R("ladderTargetRaw", AIChatViewModel.rawBytesForBase64Budget(AIChatViewModel.kPerImageMaxBytes))

    // Per-message budget (send route only): the real decision at its edges.
    let cap = AIChatViewModel.kMessageImageMaxBytes
    R("budget.cap", cap)
    R("budget.atCap", AIChatViewModel.attachmentImageOverflowsMessage(cumulativeImageBytes: cap - 100, compressedB64: 100))
    R("budget.overCap", AIChatViewModel.attachmentImageOverflowsMessage(cumulativeImageBytes: cap - 100, compressedB64: 101))

    let json = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
    try! json.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
#endif
