// [T-image-real-seams] iOS-C scenarios: persistence, reload, request budget,
// takeover. Every result comes from the shipping code compiled verbatim by
// the driver - AIChatViewModel.toolResultMediaRef / persistedUserImageRef
// (+Persistence), RawMessage.rebuiltImagePart / rebuiltToolResultImage
// (RawMessage+Conversion), AIChatViewModel.budgetedRequestImages
// (+RequestBudget), AIChatViewModel.takeoverScreenshotMessage
// (+BackgroundTask) - with ChatStore.saveMedia / mediaFileURLResolver lifted
// from ChatStore+Media and pointed at a temp directory. Results go to the JSON
// file named by argv[1].
//
// Guarded like Fixtures.swift; the driver's main.swift calls runScenarios().
#if IMAGE_REAL_IOS_C
import Foundation
import UIKit

var results: [String: Any] = [:]
func R(_ key: String, _ value: Any) { results[key] = value }

func image(_ key: String, _ data: Data?, mime: String? = nil) {
    guard let data else { R("\(key).present", false); return }
    let p = probe(data)
    R("\(key).present", true)
    R("\(key).w", p.w); R("\(key).h", p.h); R("\(key).bytes", data.count); R("\(key).fmt", p.fmt)
    R("\(key).sha256", sha256(data))
    if let mime { R("\(key).mime", mime) }
}

/// Parts as the DB stores them: parts_json encode / decode.
func viaJSON(_ parts: [ContentPart]) -> [ContentPart] {
    try! JSONDecoder().decode([ContentPart].self, from: JSONEncoder().encode(parts))
}

/// What a request carries after the budget: the image bytes and every text.
/// The first image a request carries (a user image or a tool result's).
func requestImage(_ key: String, _ messages: [AgentMessage]) {
    for m in messages {
        for p in m.parts {
            if case .imageData(let d, let mime, _) = p { image(key, d, mime: mime); return }
            if case .toolResult(_, _, _, _, let d?, let mime, _, _, _) = p { image(key, d, mime: mime); return }
        }
    }
    image(key, nil)
}

func describe(_ key: String, _ messages: [AgentMessage]) {
    var images: [String] = [], texts: [String] = []
    for m in messages {
        for p in m.parts {
            switch p {
            case .imageData(let d, let mime, let lp): images.append("img \(sha256(d).prefix(16)) \(mime) \(lp ?? "-")")
            case .toolResult(_, _, let content, _, let d, let mime, _, let lp, _):
                if let d { images.append("tool \(sha256(d).prefix(16)) \(mime ?? "nil") \(lp ?? "-")") }
                texts.append(content)
            case .text(let t): texts.append(t)
            default: break
            }
        }
    }
    R("\(key).images", images)
    R("\(key).texts", texts)
}

func runScenarios() async {
    let sid = HarnessEnv.sessionId
    let resolver = await ChatStore.shared.mediaFileURLResolver()

    // P-i2: a browser_use tool result stored BEFORE #412 was fixed: the live
    // turn carried a small image, but the snapshot's ref points at the
    // full-page original. [T-image-gate] The live turn's image is the gate's
    // output (browserUseInferenceImage), which is what the snapshot stores now.
    let original = encode(makeCGImage(w: 2760, h: 21891, pattern: .page), type: .jpeg, quality: 0.8)
    let live = ModelImageGate.prepare(original, maxBytes: AIChatViewModel.rawBytesForBase64Budget(AIChatViewModel.kPerImageMaxBytes)).data!
    image("p2.original", original)
    let snapRef = await ChatStore.shared.saveMedia(data: original, mimeType: "image/jpeg", sessionId: sid,
                                                   subdir: "browser", linuxPath: "/var/minis/browser/screenshot_1.jpg")
    let snap = ToolSnapshot(type: .image, text: nil, mediaRef: snapRef, duration: 1.5)
    let chosen = AIChatViewModel.toolResultMediaRef(imageData: live, snapshot: snap)
    R("p2.storedRefIsSnapshotRef", chosen == snapRef)
    R("p2.noImageMeansNoRef", AIChatViewModel.toolResultMediaRef(imageData: nil, snapshot: snap) == nil)
    let stored = viaJSON([.toolResult(ToolResult(toolUseId: "t1", output: "Screenshot taken", success: true,
                                                 mediaRef: chosen, snapshot: snap, pageURL: nil, status: "success"))])
    guard case .toolResult(let tr) = stored[0] else { fatalError("tool result lost in JSON") }
    let (rebuiltData, rebuiltMime) = RawMessage.rebuiltToolResultImage(tr.mediaRef, mediaResolver: resolver)
    image("p2.rebuilt", rebuiltData, mime: rebuiltMime)
    R("p2.rebuiltEqualsOriginal", rebuiltData == original)
    R("p2.rebuiltEqualsLive", rebuiltData == live)
    let p2History = [AgentMessage(role: .user, parts: [.text("open the page")]),
                     AgentMessage(role: .user, parts: [.toolResult(id: "t1", name: "", content: tr.output, isError: false,
                                                                   imageData: rebuiltData, imageMimeType: rebuiltMime,
                                                                   imageLinuxPath: tr.mediaRef?.linuxPath)])]
    let p2Budget = AIChatViewModel.budgetedRequestImages(p2History, sessionId: sid)
    R("p2.budgetUnchanged", p2Budget == nil)
    // [T-image-gate] What the request stage sends for that reloaded original:
    // the gate heals it to the live turn's bytes.
    requestImage("p2.request", p2Budget?.messages ?? p2History)
    if case .toolResult(_, _, _, _, let sent?, _, _, _, _)? = (p2Budget?.messages ?? p2History).last?.parts.first {
        R("p2.requestEqualsLive", sent == live)
    }

    // P-i4: browser takeover screenshot, 9000x6000.
    let takeover = encode(makeCGImage(w: 9000, h: 6000, pattern: .page), type: .jpeg, quality: 0.8)
    image("p4.src", takeover)
    let attachmentsDir = HarnessEnv.root.appendingPathComponent("MinisChat/minis/\(sid)/attachments")
    let before = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path))?.count ?? 0
    let msg = AIChatViewModel.takeoverScreenshotMessage(takeover, sessionId: sid, timestamp: 1_791_000_000)
    R("p4.role", msg.role == .user ? "user" : "assistant")
    R("p4.partCount", msg.parts.count)
    if case .text(let t) = msg.parts[0] { R("p4.note", t) }
    if case .imageData(let d, let mime, let lp) = msg.parts[1] {
        image("p4.live", d, mime: mime)
        R("p4.liveIsSource", d == takeover)
        R("p4.liveIsGated", d == ModelImageGate.prepare(takeover, maxBytes: AIChatViewModel.rawBytesForBase64Budget(AIChatViewModel.kPerImageMaxBytes)).data)
        R("p4.linuxPath", lp ?? "nil")
    }
    let written = HarnessEnv.root.appendingPathComponent("MinisChat/minis/\(sid)/browser/takeover_1791000000.jpg")
    R("p4.fileWritten", (try? Data(contentsOf: written)) == takeover)
    R("p4.noMediaStoreWrite", ((try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path))?.count ?? 0) == before)
    let p4Budget = AIChatViewModel.budgetedRequestImages([msg], sessionId: sid)
    R("p4.budgetUnchanged", p4Budget == nil)
    requestImage("p4.request", p4Budget?.messages ?? [msg])

    // P-i8: the request budget counts bytes only - a 9000x300 image passes.
    let wide = encode(makeCGImage(w: 9000, h: 300, pattern: .page), type: .jpeg, quality: 0.8)
    image("p8.src", wide)
    let wideHistory = [AgentMessage(role: .user, parts: [.imageData(data: wide, mimeType: "image/jpeg", linuxPath: nil)])]
    let p8Budget = AIChatViewModel.budgetedRequestImages(wideHistory, sessionId: sid)
    R("p8.budgetUnchanged", p8Budget == nil)
    requestImage("p8.request", p8Budget?.messages ?? wideHistory)

    // P-i8 continued: over the 25 MB request budget the oldest images become
    // placeholders (spilled when they have no linuxPath); nothing is resized.
    // [T-image-gate] Real JPEGs that already follow the gate's rule (<= 2000 px,
    // each just under the 3.75 MB raw per-image cap), so the gate passes their
    // bytes through and only the budget acts on them. Six exceed the 25 MB
    // (base64) budget by one image. Widths differ so every image is distinct.
    // (This used to be 4 MB of random bytes labelled image/jpeg; the request
    // gate now rightly turns such non-images into placeholders.)
    let perImageCap = (5 * 1024 * 1024 / 4) * 3
    var noisy: [Data] = []
    for i in 0..<6 {
        let img = makeCGImage(w: 2000 - i, h: 1900, pattern: .noise)
        var q = 0.95
        var d = encode(img, type: .jpeg, quality: q)
        while d.count > perImageCap - 64 * 1024 && q > 0.3 { q -= 0.03; d = encode(img, type: .jpeg, quality: q) }
        noisy.append(d)
    }
    R("budget.src.bytes", noisy.map(\.count))
    var over: [AgentMessage] = []
    over.append(AgentMessage(role: .user, parts: [.imageData(data: noisy[0], mimeType: "image/jpeg", linuxPath: nil)]))
    over.append(AgentMessage(role: .user, parts: [.imageData(data: noisy[1], mimeType: "image/png", linuxPath: "/var/minis/attachments/uploads/b.png")]))
    over.append(AgentMessage(role: .user, parts: [.toolResult(id: "t9", name: "", content: "shot", isError: false,
                                                              imageData: noisy[2], imageMimeType: nil, imageLinuxPath: nil)]))
    for d in noisy[3...] { over.append(AgentMessage(role: .user, parts: [.imageData(data: d, mimeType: "image/jpeg", linuxPath: nil)])) }
    if let budgeted = AIChatViewModel.budgetedRequestImages(over, sessionId: sid) {
        let out = budgeted.messages, plan = budgeted.plan
        R("budget.dropped", plan.droppedCount); R("budget.total", plan.totalCount)
        R("budget.keptBytes", plan.keptBytes); R("budget.elidedBytes", plan.elidedBytes)
        describe("budget.out", out)
        var keptUnchanged = true
        for (i, m) in out.enumerated() {
            for p in m.parts { if case .imageData(let d, _, _) = p, d != noisy[i] { keptUnchanged = false } }
        }
        R("budget.keptBytesUnchanged", keptUnchanged)
    } else { R("budget.dropped", 0) }

    // Missing media: the ref outlives its file.
    let gone = MediaRef(id: "gone", relativePath: "\(sid)/attachments/gone.jpg", mimeType: "image/jpeg",
                        originalFileName: nil, linuxPath: "/var/minis/attachments/uploads/gone.jpg")
    R("missing.userPartIsNil", RawMessage.rebuiltImagePart(gone, mediaResolver: resolver) == nil)
    let goneTool = RawMessage.rebuiltToolResultImage(gone, mediaResolver: resolver)
    R("missing.toolImageIsNil", goneTool.data == nil && goneTool.mimeType == nil)

    // Persist -> reload round trip of user images.
    let jpeg = encode(makeCGImage(w: 2000, h: 1500, pattern: .photo), type: .jpeg, quality: 0.85)
    let heicSmall = encode(makeCGImage(w: 1200, h: 900, pattern: .photo), type: .heic, quality: 0.8)
    let png = encode(makeCGImage(w: 512, h: 512, pattern: .flat, alpha: true), type: .png)
    for (name, data, mime) in [("jpeg", jpeg, "image/jpeg"), ("heicAsJpeg", heicSmall, "image/jpeg"), ("png", png, "image/png"),
                               ("gifLabelOnJpeg", jpeg, "image/gif")] {
        let ref = await AIChatViewModel.persistedUserImageRef(data: data, mimeType: mime, sessionId: sid,
                                                              linuxPath: "/var/minis/attachments/uploads/\(name)")
        R("rt.\(name).relativePath.ext", (ref.relativePath as NSString).pathExtension)
        R("rt.\(name).subdir", ref.relativePath.split(separator: "/").dropFirst().first.map(String.init) ?? "?")
        guard case .mediaRef(let back) = viaJSON([.mediaRef(ref)])[0],
              let part = RawMessage.rebuiltImagePart(back, mediaResolver: resolver),
              case .imageData(let d, let m, let lp) = part else { R("rt.\(name).rebuilt", false); continue }
        image("rt.\(name).rebuilt", d, mime: m)
        R("rt.\(name).bytesEqual", d == data)
        R("rt.\(name).mimeEqual", m == mime)
        R("rt.\(name).linuxPath", lp ?? "nil")
    }

    // Tool image MIME on reload: sniffed from the bytes, stored MIME as fallback.
    for (name, data, mime) in [("jpegStoredAsPng", jpeg, "image/png"), ("heicStoredAsJpeg", heicSmall, "image/jpeg"),
                               ("pngStoredAsJpeg", png, "image/jpeg")] {
        let ref = await ChatStore.shared.saveMedia(data: data, mimeType: mime, sessionId: sid, subdir: "images")
        let (d, m) = RawMessage.rebuiltToolResultImage(ref, mediaResolver: resolver)
        R("sniff.\(name).mime", m ?? "nil")
        R("sniff.\(name).bytesEqual", d == data)
        image("sniff.\(name)", d)
    }

    let json = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
    try! json.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
#endif
