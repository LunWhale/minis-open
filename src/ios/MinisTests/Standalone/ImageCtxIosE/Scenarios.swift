// [T-ctx-builder] iOS-E scenario table (catalog B): C01-C32, numbered as on
// Android. Each row builds its conversation with the Session DSL, then the
// runner captures the request on the live turn and again after restart() and
// serializes it for all five providers.
//
// `current` checks characterize what the code does TODAY (measured by running
// the real functions; they must pass). `desired` checks state the behaviour
// we want; a failing one prints KNOWN GAP and does not fail the run. Flipping
// a gap after a fix is the point of the table.
//
// Guarded like Kit.swift.
#if IMAGE_CTX_IOS_E
import Foundation
import UIKit
import ImageIO

struct Check { let label: String; let desired: Bool; let ok: Bool }

final class Ctx {
    let id: String
    var checks: [Check] = []
    var notes: [String] = []
    var metrics: [String: Any] = [:]
    var captures: [String: Capture] = [:]
    /// Images the conversation produced (user + tool), counted on the live
    /// history; a request that carries fewer and shows no placeholder for the
    /// rest dropped them silently.
    var producedImages = 0
    var session: Session!

    init(_ id: String) { self.id = id }

    func current(_ label: String, _ ok: Bool) { checks.append(Check(label: label, desired: false, ok: ok)) }
    func desired(_ label: String, _ ok: Bool) { checks.append(Check(label: label, desired: true, ok: ok)) }
    func note(_ s: String) { notes.append(s) }
    func metric(_ k: String, _ v: Any) { metrics[k] = v }

    var sessionsMade = 0
    /// Session ids are UUIDs (SessionStorageCleanup only removes UUID-named
    /// directories), derived from the scenario number so runs are stable.
    func newSession(_ suffix: String = "") -> Session {
        sessionsMade += 1
        let n = Int(id.dropFirst())! * 16 + sessionsMade
        let s = Session(String(format: "00000000-0000-4000-8000-%012X", n))
        if session == nil { session = s }
        return s
    }

    /// Captures `live`, then restarts and captures `restart`.
    func liveAndRestart(_ s: Session) async {
        producedImages = historyImages(s.history).count
        captures["live"] = s.capture("live")
        await s.restart()
        captures["restart"] = s.capture("restart")
    }

    func view(_ phase: String, _ p: Provider) -> [RVMessage] { captures[phase]?.views[p] ?? [] }
    func images(_ phase: String, _ p: Provider) -> [RVImage] { view(phase, p).flatMap { $0.parts.compactMap { $0.image } } }
    func inv(_ phase: String, _ p: Provider) -> Invariants { invariants(view(phase, p), provider: p) }
    func dims(_ phase: String, _ p: Provider) -> [String] { images(phase, p).map { "\($0.w)x\($0.h)" } }
    func texts(_ phase: String, _ p: Provider) -> String { view(phase, p).flatMap { $0.parts.compactMap { $0.text } }.joined(separator: "\n") }
    var all: [Provider] { Provider.allCases }
    var nonAnthropic: [Provider] { [.responses, .chat, .gemini, .antigravity] }
}

struct Scenario {
    let id: String
    let title: String
    let input: String
    /// The catalog's "current" column, kept verbatim for the report's diff.
    let catalogCurrent: String
    let desired: String
    let run: (Ctx) async -> Void
}

// MARK: - byte helpers

func exifOrientation(_ d: Data) -> Int {
    guard let src = CGImageSourceCreateWithData(d as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
    return p[kCGImagePropertyOrientation] as? Int ?? 1
}

/// RGBA of the pixel at (x, y) after decoding (top-left origin).
func pixel(_ d: Data, _ x: Int, _ y: Int) -> [Int] {
    guard let src = CGImageSourceCreateWithData(d as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return px.map(Int.init)
}

func firstImageData(_ h: [AgentMessage]) -> Data? { historyImages(h).first }
let summaryTag = "<context-summary>"

// MARK: - the table

let scenarios: [Scenario] = [
    Scenario(id: "C01", title: "plain text Q&A", input: "user / assistant / user, text only",
             catalogCurrent: "request is text only, same on both platforms (to measure)", desired: "same") { c in
        let s = c.newSession()
        await s.user("What is the capital of France?")
        await s.assistant("Paris.")
        await s.user("And of Italy?")
        await c.liveAndRestart(s)
        for p in c.all { c.current("\(p): no image, live and restart", c.inv("live", p).imageCount == 0 && c.inv("restart", p).imageCount == 0) }
        c.current("live and restart requests are identical for every provider",
                  c.all.allSatisfy { NSDictionary(dictionary: ["v": viewJSON(c.view("live", $0))]).isEqual(to: ["v": viewJSON(c.view("restart", $0))]) })
    },

    Scenario(id: "C02", title: "200k-character text input", input: "one user message of 200,000 chars (also: 200k CJK, 2M ASCII for the estimator)",
             catalogCurrent: "to measure: truncation, offload, token estimate", desired: "never silently truncated") { c in
        let s = c.newSession()
        let long = Kit.text(chars: 200_000)
        await s.user(long)
        await c.liveAndRestart(s)
        for p in c.all {
            for phase in ["live", "restart"] {
                c.current("\(p) \(phase): the whole 200,000 chars reach the request", c.texts(phase, p).contains(long))
            }
        }
        c.metric("estimateTokens.ascii200k", ContextSizeMeter.estimateTokens(long))
        c.metric("estimateTokens.cjk200k", ContextSizeMeter.estimateTokens(Kit.chinese(chars: 200_000)))
        c.metric("estimateTokens.ascii2M", ContextSizeMeter.estimateTokens(Kit.text(chars: 2_000_000)))
        c.metric("estimateTokens.emojiZWJ", ContextSizeMeter.estimateTokens(Kit.emojiZWJ))
        c.note("Offloading (+Offloading.swift) only rewrites tool results; a user text is never offloaded or truncated by the request chain.")
        c.desired("not silently truncated (all providers, both phases)", c.all.allSatisfy { c.texts("live", $0).contains(long) && c.texts("restart", $0).contains(long) })
    },

    Scenario(id: "C03", title: "pasted long text (PastePlaceholder)", input: "user text + one 50,000-char paste; then the paste file is deleted",
             catalogCurrent: "to measure; a missing paste file shows a visible placeholder (known)", desired: "same") { c in
        let s = c.newSession()
        let paste = Kit.text(chars: 50_000)
        await s.user("summarize this:", pastes: [paste])
        await c.liveAndRestart(s)
        for p in c.all {
            c.current("\(p): paste expanded inline on the live turn", c.texts("live", p).contains(paste))
            c.current("\(p): paste read back from its stored file after restart", c.texts("restart", p).contains(paste))
        }
        let pastedFiles = (try? FileManager.default.subpathsOfDirectory(atPath: s.sessionDir.path))?.filter { $0.hasSuffix(".txt") } ?? []
        c.metric("pasteFiles", pastedFiles)
        c.metric("liveUserParts", c.view("live", .anthropic).first?.parts.count ?? -1)
        c.metric("restartUserParts", c.view("restart", .anthropic).first?.parts.count ?? -1)
        for f in pastedFiles { try? FileManager.default.removeItem(at: s.sessionDir.appendingPathComponent(f)) }
        await s.restart()
        let gone = s.capture("restart-missing")
        let t = gone.views[.anthropic]!.flatMap { $0.parts.compactMap { $0.text } }.joined()
        c.current("missing paste file: visible marker, no text", t.contains(PastePlaceholder.unavailableMarker) && !t.contains(paste))
        c.desired("missing paste file shows a visible placeholder", t.contains(PastePlaceholder.unavailableMarker))
    },

    Scenario(id: "C04", title: "camera photo 4032x3024", input: "JPEG CAMERA_4032x3024 attached (send route)",
             catalogCurrent: "2000x1500 on send and after restart, same bytes (verified)", desired: "same") { c in
        let s = c.newSession()
        await s.user("what is in the photo?", [Kit.image(.CAMERA_4032x3024)])
        await c.liveAndRestart(s)
        for p in c.all {
            c.current("\(p): one 2000x1500 image/jpeg, live and restart", c.dims("live", p) == ["2000x1500"] && c.dims("restart", p) == ["2000x1500"]
                      && c.images("live", p).first?.mime == "image/jpeg")
            c.current("\(p): restart sends the live bytes", c.inv("live", p).shas == c.inv("restart", p).shas)
        }
    },

    Scenario(id: "C05", title: "album JPEG 4000x6000", input: "JPEG ALBUM_4000x6000 attached (send route)",
             catalogCurrent: "1333x2000, same bytes (verified)", desired: "same") { c in
        let s = c.newSession()
        await s.user("describe", [Kit.image(.ALBUM_4000x6000)])
        await c.liveAndRestart(s)
        for p in c.all {
            c.current("\(p): one 1334x2000 image/jpeg (catalog says 1333), live == restart bytes",
                      c.dims("live", p) == ["1334x2000"] && c.inv("live", p).shas == c.inv("restart", p).shas && c.images("live", p).first?.mime == "image/jpeg")
        }
    },

    Scenario(id: "C06", title: "HEIC 4032x3024", input: "HEIC 4032x3024 attached (send route)",
             catalogCurrent: "re-encoded to JPEG 2000x1500 (iOS verified)", desired: "same") { c in
        let s = c.newSession()
        let heic = Kit.image(4032, 3024, .heic)
        c.metric("headerOnly", heic.headerOnly)
        await s.user("describe", [heic])
        await c.liveAndRestart(s)
        for p in c.all {
            c.current("\(p): JPEG 2000x1500 labelled image/jpeg, live == restart",
                      c.dims("live", p) == ["2000x1500"] && c.images("live", p).first?.fmt == "jpeg" && c.images("live", p).first?.mime == "image/jpeg"
                      && c.inv("live", p).shas == c.inv("restart", p).shas)
        }
    },

    Scenario(id: "C07", title: "small HEIC 1200x900", input: "HEIC 1200x900 attached (send route)",
             catalogCurrent: "iOS: HEIC bytes sent as is, labelled image/jpeg (verified)", desired: "transcoded to a compliant JPEG, MIME matches bytes") { c in
        let s = c.newSession()
        await s.user("describe", [Kit.image(1200, 900, .heic)])
        await c.liveAndRestart(s)
        // [T-image-gate] Was: HEIC bytes sent as is, labelled image/jpeg (KNOWN GAP
        // "MIME matches the bytes"). The request gate transcodes them.
        for p in c.all {
            c.current("\(p): the request gate transcodes the HEIC to a JPEG labelled image/jpeg, live and restart",
                      c.images("live", p).first?.fmt == "jpeg" && c.images("live", p).first?.mime == "image/jpeg"
                      && c.images("restart", p).first?.fmt == "jpeg" && c.images("restart", p).first?.mime == "image/jpeg")
            c.current("\(p): MIME matches the bytes", !c.inv("live", p).flags.contains("MIME") && !c.inv("restart", p).flags.contains("MIME"))
        }
    },

    Scenario(id: "C08", title: "EXIF orientation 6 photo", input: "JPEG with EXIF Orientation=6: small 1200x900 and camera 4032x3024 (send route)",
             catalogCurrent: "iOS attachment path outputs upright", desired: "both platforms output correctly oriented pixels") { c in
        let s = c.newSession()
        let small = Kit.image(1200, 900, .jpeg, orientation: 6, name: "exif6_small.jpg")
        let big = Kit.image(4032, 3024, .jpeg, orientation: 6, name: "exif6_big.jpg")
        await s.user("two photos", [small, big])
        await c.liveAndRestart(s)
        let live = historyImages(s.history)
        c.metric("small.out", "\(probe(live[0]).w)x\(probe(live[0]).h) orientation=\(exifOrientation(live[0]))")
        c.metric("big.out", "\(probe(live[1]).w)x\(probe(live[1]).h) orientation=\(exifOrientation(live[1]))")
        c.current("small (<=2000): original bytes pass through, EXIF tag 6 kept, pixels still 1200x900",
                  live[0] == small.data && exifOrientation(live[0]) == 6)
        c.current("big: re-rendered upright 1500x2000, tag dropped", probe(live[1]).w == 1500 && probe(live[1]).h == 2000 && exifOrientation(live[1]) == 1)
        c.desired("small: pixels upright without relying on the EXIF tag", exifOrientation(live[0]) == 1)
        // [T-image-gate] The stored intake bytes above keep the tag (intake is not
        // the gate's file); what the model gets is upright on every provider.
        for p in c.all {
            c.current("\(p): the request carries the small photo upright (900x1200, no EXIF tag), live and restart",
                      ["live", "restart"].allSatisfy { ph in c.images(ph, p).first.map { $0.w == 900 && $0.h == 1200 } == true })
        }
    },

    Scenario(id: "C09", title: "transparent PNG 512 / 3000", input: "PNG with transparent top/bottom bands, 512x512 and 3000x3000 (send route)",
             catalogCurrent: "iOS: 512 stays PNG, 3000 becomes JPEG on white", desired: "one rule on both platforms (white or keep PNG)") { c in
        let s = c.newSession()
        await s.user("two", [Kit.image(512, 512, .pngAlpha, name: "a512.png"), Kit.image(3000, 3000, .pngAlpha, name: "a3000.png")])
        await c.liveAndRestart(s)
        let live = historyImages(s.history)
        let p512 = probe(live[0]), p3000 = probe(live[1])
        c.metric("512.out", "\(p512.fmt) \(p512.w)x\(p512.h) alpha=\(p512.alpha) px(0,0)=\(pixel(live[0], 0, 0))")
        c.metric("3000.out", "\(p3000.fmt) \(p3000.w)x\(p3000.h) alpha=\(p3000.alpha) px(0,0)=\(pixel(live[1], 0, 0))")
        c.current("512 stays PNG with alpha", p512.fmt == "png" && p512.alpha)
        c.current("3000 becomes 2000x2000 JPEG", p3000.fmt == "jpeg" && p3000.w == 2000)
        let bg = pixel(live[1], 0, 0)
        c.metric("3000.transparentBecomes", bg.count == 4 && bg[0] > 200 ? "white" : (bg.count == 4 && bg[0] < 50 ? "black" : "\(bg)"))
        for p in c.all { c.current("\(p): both reach the request", c.inv("live", p).imageCount == 2 && c.inv("restart", p).imageCount == 2) }
    },

    Scenario(id: "C10", title: "GIF 2400x1800", input: "3-frame GIF 2400x1800, queue route and send route",
             catalogCurrent: "iOS queue path labels gif but sends JPEG (verified)", desired: "MIME decided by the output bytes") { c in
        let s = c.newSession()
        let g = Kit.image(2400, 1800, .gif)
        await s.user("queued", [g], route: .queue)
        await s.user("sent", [Kit.renamed(g, ext: "gif")], route: .send)
        await c.liveAndRestart(s)
        let imgs = c.images("live", .chat)
        c.metric("queue", "\(imgs.first.map { "\($0.mime) \($0.fmt) \($0.w)x\($0.h)" } ?? "-")")
        c.metric("send", "\(imgs.dropFirst().first.map { "\($0.mime) \($0.fmt) \($0.w)x\($0.h)" } ?? "-")")
        // [T-image-gate] Was: the queue route's image/gif label went out on JPEG
        // bytes (KNOWN GAP "MIME matches bytes"). The gate labels by the bytes.
        c.current("queue: the request labels the JPEG bytes image/jpeg (was image/gif)", imgs.first?.mime == "image/jpeg" && imgs.first?.fmt == "jpeg")
        c.current("send: image/jpeg on JPEG bytes", imgs.dropFirst().first?.mime == "image/jpeg" && imgs.dropFirst().first?.fmt == "jpeg")
        for p in c.all { c.current("\(p): MIME matches bytes", !c.inv("live", p).flags.contains("MIME")) }
    },

    Scenario(id: "C11", title: "extension does not match bytes", input: "JPEG bytes named .webp, 800x600 (send route)",
             catalogCurrent: "iOS send path labels image/webp (verified)", desired: "decided by magic bytes") { c in
        let s = c.newSession()
        await s.user("look", [Kit.renamed(Kit.image(800, 600, .jpeg), ext: "webp")])
        await c.liveAndRestart(s)
        // [T-image-gate] Was: live labelled image/webp on JPEG bytes (KNOWN GAP
        // "MIME from magic bytes"). The gate keeps the bytes and fixes the label.
        for p in c.all {
            c.current("\(p): live labels the JPEG bytes image/jpeg (original bytes kept)", c.images("live", p).first?.mime == "image/jpeg" && c.images("live", p).first?.fmt == "jpeg")
            c.metric("\(p).restartMime", c.images("restart", p).first?.mime ?? "-")
            c.current("\(p): MIME from magic bytes, live and restart", !c.inv("live", p).flags.contains("MIME") && !c.inv("restart", p).flags.contains("MIME"))
        }
    },

    Scenario(id: "C12", title: "0-byte / truncated / not-an-image", input: "empty.jpg (0 B), first 1 KB of a 1600x1200 JPEG, text bytes named fake.jpg (send route)",
             catalogCurrent: "iOS: non-image bytes sent as image/jpeg (verified); others to measure", desired: "visible placeholder, nothing non-compliant sent") { c in
        let s = c.newSession()
        await s.user("three broken", [Kit.zeroBytes(), Kit.truncated(Kit.image(1600, 1200, .jpeg, name: "photo.jpg")), Kit.notAnImage()])
        await c.liveAndRestart(s)
        let live = historyImages(s.history)
        c.metric("historyImages", live.map { "\($0.count)B fmt=\(probe($0).fmt)" })
        for p in c.all {
            let imgs = c.images("live", p)
            c.metric("\(p).live", imgs.map { "\($0.bytes)B \($0.mime) fmt=\($0.fmt)" })
            c.metric("\(p).restart", c.images("restart", p).map { "\($0.bytes)B \($0.mime) fmt=\($0.fmt)" })
            // [T-image-gate] Was KNOWN GAP: the 0-byte and non-image parts went
            // out as image/jpeg. Now they become visible placeholders and the
            // truncated JPEG is re-encoded to a decodable one.
            c.current("\(p): no undecodable bytes in the request", imgs.allSatisfy { $0.fmt != "?" })
            c.current("\(p): 0-byte and non-image parts become visible placeholders, the truncated JPEG goes out decodable, live and restart",
                      ["live", "restart"].allSatisfy { ph in
                          c.images(ph, p).count == 1 && c.images(ph, p)[0].fmt == "jpeg"
                              && c.inv(ph, p).placeholders.filter { $0.hasPrefix("[image not sent") }.count == 2 })
        }
        c.current("all three are kept as image parts in history (intake rejects none)", live.count == 3)
    },

    Scenario(id: "C13", title: "video attachment (mp4)", input: "clip.mp4 (ftyp header only, 32 B)",
             catalogCurrent: "TO MEASURE - not verified", desired: "to confirm with the user") { c in
        let s = c.newSession()
        let v = Kit.mp4Header()
        await s.user("watch this", [v])
        c.metric("kind", String(describing: s.vm.attachments.first?.kind))
        await c.liveAndRestart(s)
        let t = c.texts("live", .anthropic)
        c.current("classified .video by extension", String(describing: s.vm.attachments.first?.kind) == "Optional(Minis.InputAttachment.Kind.video)"
                  || String(describing: s.vm.attachments.first?.kind).hasSuffix("video)"))
        c.current("no image, no video bytes in any request; only the <user-attached-files> path line",
                  c.all.allSatisfy { c.inv("live", $0).imageCount == 0 } && t.contains("/var/minis/attachments/uploads/clip.mp4") && t.contains("size=\"32\""))
        c.current("the file is copied into the session's uploads", s.fileCount("attachments/uploads") == 1)
        c.current("restart sends the same text", c.texts("restart", .anthropic) == t)
        c.note("No video code path: not decoded, not resized, no frame sampling, no size cap; the model only sees the path and byte size.")
    },

    Scenario(id: "C14", title: "PDF / audio / plain text / zip", input: "doc.pdf, voice.wav, notes.txt, bundle.zip",
             catalogCurrent: "to measure (expected: only path and metadata reach the context)", desired: "same") { c in
        let s = c.newSession()
        await s.user("files", [Kit.pdf(), Kit.wav(), Kit.plainText(), Kit.zip()])
        await c.liveAndRestart(s)
        let t = c.texts("live", .anthropic)
        c.metric("kinds", s.vm.attachments.map { "\($0.fileName.split(separator: "_", maxSplits: 1).last!)=\($0.kind)" })
        c.current("all four classified .document", s.vm.attachments.allSatisfy { "\($0.kind)" == "document" })
        c.current("only the four <file> lines reach the request, no content",
                  c.all.allSatisfy { c.inv("live", $0).imageCount == 0 } && t.components(separatedBy: "<file path=").count - 1 == 4
                  && !t.contains("hello from a text attachment"))
        c.desired("only path and metadata in context (live == restart)", c.texts("restart", .anthropic) == t)
    },

    Scenario(id: "C15", title: "huge file, same name twice, CJK/space name, no extension", input: "2.5 GiB sparse file; notes.txt twice; 我的 文件.txt; README (no ext)",
             catalogCurrent: "to measure", desired: "nothing lost, nothing overwritten") { c in
        let s = c.newSession()
        let big = Kit.sparseFile(at: HarnessEnv.root.appendingPathComponent("huge.bin"), bytes: 2_684_354_560)
        s.vm.attachments = []
        s.vm.addFileAttachment(from: big)
        s.vm.addDataAttachment(data: Data("first".utf8), fileName: "notes.txt")
        s.vm.addDataAttachment(data: Data("second".utf8), fileName: "notes.txt")
        s.vm.addDataAttachment(data: Data("cjk".utf8), fileName: "我的 文件.txt")
        s.vm.addDataAttachment(data: Data("readme".utf8), fileName: "README")
        await s.userWithStagedAttachments("files", route: .send)
        await c.liveAndRestart(s)
        let t = c.texts("live", .anthropic)
        let uploads = s.sessionDir.appendingPathComponent("attachments/uploads")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: uploads.path)) ?? []).sorted()
        c.metric("uploads", names)
        c.metric("fileLines", t.components(separatedBy: "\n").filter { $0.contains("<file ") })
        let du = (try? uploads.appendingPathComponent("huge.bin").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? -1
        c.metric("huge.allocatedBytes", du)
        c.current("huge file: copied, size reported in full, no content read", t.contains("size=\"2684354560\""))
        c.current("same name twice: notes.txt and notes_1.txt, both kept", names.contains("notes.txt") && names.contains("notes_1.txt")
                  && (try? String(contentsOf: uploads.appendingPathComponent("notes_1.txt"), encoding: .utf8)) == "second")
        c.current("CJK + space name kept verbatim in the path", t.contains("/var/minis/attachments/uploads/我的 文件.txt"))
        c.current("no-extension text file classified .document", t.contains("/var/minis/attachments/uploads/README\""))
        c.desired("nothing lost or overwritten (5 files, 5 lines)", names.count == 5 && t.components(separatedBy: "<file path=").count - 1 == 5)
    },

    Scenario(id: "C16", title: "browser screenshot, default viewport", input: "browser_use screenshot of a 390x844 pt page at 3x (1170x2532 px, JPEG 0.8)",
             catalogCurrent: "iOS live 925x2000, after restart the original 1170x2532 (verified)", desired: "live == restart") { c in
        let s = c.newSession()
        await s.user("open the page")
        _ = await s.browserScreenshot("call_v1|fc_v1", pointW: 390, pointH: 844)
        await s.user("what does it say?")
        await c.liveAndRestart(s)
        c.metric("live", Dictionary(uniqueKeysWithValues: c.all.map { ($0.rawValue, c.dims("live", $0)) }))
        c.metric("restart", Dictionary(uniqueKeysWithValues: c.all.map { ($0.rawValue, c.dims("restart", $0)) }))
        // [T-image-gate #412] The live turn sends the gate's output (was 925x2000
        // from resizedImageData) and the snapshot stores it, so restart == live.
        for p in c.all { c.current("\(p): live 924x2000 (the gate's output)", c.dims("live", p) == ["924x2000"]) }
        // [T-image-gate] Was: restart sent the stored 1170x2532 original. The
        // request gate converts it (every provider, Anthropic included).
        for p in c.all { c.current("\(p): restart: the request gate converts the stored original to <= 2000 (924x2000)", c.dims("restart", p) == ["924x2000"]) }
        for p in c.all { c.current("\(p): restart == live", c.inv("restart", p).shas == c.inv("live", p).shas) }
    },

    Scenario(id: "C17", title: "browser screenshot, big viewport 9000x6000", input: "3000x2000 pt viewport at 3x (9000x6000 px)",
             catalogCurrent: "iOS: 9000x6000 reaches the request after restart (verified)", desired: "<= 2000 and consistent") { c in
        let s = c.newSession()
        await s.user("open")
        _ = await s.browserScreenshot("call_v2|fc_v2", pointW: 3000, pointH: 2000)
        await s.user("and?")
        await c.liveAndRestart(s)
        // [T-image-gate #412] Was: live 2000x1334 (resizedImageData), restart 9000x6000.
        for p in c.all { c.current("\(p): live 2000x1333 (the gate's output)", c.dims("live", p) == ["2000x1333"]) }
        // [T-image-gate] Was: restart 9000x6000.
        for p in c.all { c.current("\(p): restart: the request gate converts the stored original to 2000x1333", c.dims("restart", p) == ["2000x1333"]) }
        c.metric("anthropic.restart", c.dims("restart", .anthropic))
        for p in c.all { c.current("\(p): restart <= 2000 and == live", c.inv("restart", p).maxEdge <= 2000 && c.inv("restart", p).shas == c.inv("live", p).shas) }
    },

    Scenario(id: "C18", title: "full-page screenshot (#412)", input: "920x7297 pt page at 3x (2760x21891 px)",
             catalogCurrent: "iOS live 253x2000, after restart 2760x21891 (verified)", desired: "both phases agree and within limits") { c in
        let s = c.newSession()
        await s.user("capture the whole page")
        _ = await s.browserScreenshot("call_fp|fc_fp", pointW: 920, pointH: 7297)
        await s.user("summarize")
        await c.liveAndRestart(s)
        // [T-image-gate #412] Was: live 253x2000 (resizedImageData).
        for p in c.all { c.current("\(p): live 252x2000 (the gate's output)", c.dims("live", p) == ["252x2000"]) }
        // [T-image-gate] Was: restart sent the 2760x21891 original (#412).
        for p in c.all { c.current("\(p): restart: the request gate converts the stored original to 252x2000, compliant",
                                   c.dims("restart", p) == ["252x2000"] && c.inv("restart", p).compliant) }
        for p in c.all { c.current("\(p): restart == live and compliant", c.inv("restart", p).shas == c.inv("live", p).shas && c.inv("restart", p).compliant) }

        // [T-image-gate #412] A session stored BEFORE this fix: its snapshot holds
        // the 2760x21891 original (the old tool path re-read the file). After a
        // restart the request gate heals it on the next send - every provider
        // gets the gate's 252x2000 image, never the original.
        let old = c.newSession("legacy")
        await old.user("capture the whole page")
        let shot = Kit.screenshot(pointW: 920, pointH: 7297)
        await old.assistant(nil, toolUses: [("call_lg|fc_lg", "browser_use", ["action": "screenshot"])])
        let lp = AIChatViewModel.writeBrowserScreenshotCopy(shot.data, sessionId: old.sid)
        let oldRef = await AIChatViewModel.saveBrowserSnapshotMedia(imageData: shot.data, sessionId: old.sid, linuxPath: lp)
        await old.toolResult("call_lg|fc_lg", "browser_use", "Screenshot captured", image: AIChatViewModel.resizedImageData(shot.data) ?? shot.data,
                             mime: "image/jpeg", linuxPath: lp, snapshot: ToolSnapshot(type: .image, text: nil, mediaRef: oldRef, duration: nil))
        await old.user("summarize")
        await old.restart()
        let healed = old.capture("restart")
        let gated = ModelImageGate.prepare(shot.data, maxBytes: AIChatViewModel.rawBytesForBase64Budget(AIChatViewModel.kPerImageMaxBytes)).data
        for p in c.all {
            let imgs = (healed.views[p] ?? []).flatMap { $0.parts.compactMap { $0.image } }
            c.metric("legacy.\(p)", imgs.map { "\($0.w)x\($0.h)" })
            c.current("\(p): a session stored before the fix heals on the next send (252x2000, the gate's bytes, compliant)",
                      imgs.count == 1 && imgs[0].w == 252 && imgs[0].h == 2000 && invariants(healed.views[p] ?? [], provider: p).compliant
                      && imgs[0].sha256 == gated.map { sha256($0) })
        }
    },

    Scenario(id: "C19", title: "two screenshots in the same second", input: "writeBrowserScreenshotCopy twice within one wall-clock second",
             catalogCurrent: "Android overwrites (N3, to confirm); iOS to measure", desired: "unique file names") { c in
        let s = c.newSession()
        let a = Kit.screenshot(pointW: 390, pointH: 844).data
        let b = Kit.screenshot(pointW: 400, pointH: 900).data
        var pa = "", pb = ""
        for _ in 0..<5 {
            pa = AIChatViewModel.writeBrowserScreenshotCopy(a, sessionId: s.sid)
            pb = AIChatViewModel.writeBrowserScreenshotCopy(b, sessionId: s.sid)
            if pa == pb { break }
        }
        let onDisk = try? Data(contentsOf: s.hostPath(linux: pb))
        c.metric("paths", [normalized(pa), normalized(pb)])
        c.current("both calls return the same path (second-resolution name)", pa == pb)
        c.current("the second screenshot overwrote the first", onDisk == b && s.fileCount("browser") == 1)
        c.desired("each screenshot keeps its own file", pa != pb)
        await s.user("x")
        await c.liveAndRestart(s)
    },

    Scenario(id: "C20", title: "takeover screenshot (iOS only)", input: "takeover message with a 9000x6000 px screenshot",
             catalogCurrent: "9000x6000 sent as is, not stored as mediaRef (verified)", desired: "resized and persisted") { c in
        let s = c.newSession()
        await s.user("I will drive the browser")
        await s.takeover(Kit.screenshot(.VIEWPORT_BIG_9000x6000).data)
        await c.liveAndRestart(s)
        // [T-image-gate] Was: live 9000x6000 on the four non-Anthropic providers.
        for p in c.all { c.current("\(p): live: the request gate converts it to 2000x1333", c.dims("live", p) == ["2000x1333"]) }
        c.metric("anthropic.live", c.dims("live", .anthropic))
        // [T-image-gate #412] Was: gone after restart (never persisted), no
        // placeholder. The takeover message is stored, with the gate's image.
        for p in c.all { c.current("\(p): after restart the stored screenshot, the same bytes as live", c.inv("restart", p).imageCount == 1
                                   && c.inv("restart", p).shas == c.inv("live", p).shas) }
        for p in c.all { c.current("\(p): <= 2000 live and still there after restart", c.inv("live", p).maxEdge <= 2000 && c.inv("restart", p).imageCount == 1) }
    },

    Scenario(id: "C21", title: "read_image on a big image", input: "read_image of a 2760x21891 page JPEG",
             catalogCurrent: "iOS live 253x2000, after restart the original (verified)", desired: "consistent") { c in
        let s = c.newSession()
        await s.user("read page.jpg")
        _ = await s.readImage("call_r1|fc_r1", Fixture(data: Kit.screenshot(pointW: 920, pointH: 7297).data, fileName: "page.jpg"))
        await c.liveAndRestart(s)
        // [T-image-gate #412] Was: live 253x2000 (resizedImageData).
        for p in c.all { c.current("\(p): live 252x2000 (the gate's output)", c.dims("live", p) == ["252x2000"]) }
        // [T-image-gate] Was: restart sent the 2760x21891 original (#412).
        for p in c.all { c.current("\(p): restart: the request gate converts the stored original to 252x2000, compliant",
                                   c.dims("restart", p) == ["252x2000"] && c.inv("restart", p).compliant) }
        for p in c.all { c.current("\(p): restart == live", c.inv("restart", p).shas == c.inv("live", p).shas) }
    },

    Scenario(id: "C22", title: "read_image of the same image twice", input: "read_image small.jpg (1600x1200) in two consecutive rounds",
             catalogCurrent: "iOS stores 2 R1 copies (verified)", desired: "deduplicated by content") { c in
        let s = c.newSession()
        await s.user("read it twice")
        let f = Kit.image(1600, 1200, .jpeg, name: "small.jpg")
        _ = await s.readImage("call_a|fc_a", f)
        _ = await s.readImage("call_b|fc_b", f)
        await c.liveAndRestart(s)
        c.metric("imagesDirFiles", s.fileCount("images"))
        c.current("two snapshot copies on disk", s.fileCount("images") == 2)
        for p in c.all { c.current("\(p): the request carries it twice", c.inv("live", p).imageCount == 2 && c.inv("live", p).duplicateImages == 1) }
        for p in c.all { c.desired("\(p): sent once", c.inv("live", p).duplicateImages == 0 && c.inv("restart", p).duplicateImages == 0) }
    },

    Scenario(id: "C23", title: "read_image on HEIC / EXIF photo", input: "read_image IMG.heic 4032x3024 and exif6.jpg 4032x3024 Orientation=6",
             catalogCurrent: "iOS: after restart HEIC labelled jpeg, EXIF photo squashed on Anthropic (verified)", desired: "correct transcoding and orientation") { c in
        let s = c.newSession()
        await s.user("read both")
        _ = await s.readImage("call_h|fc_h", Kit.image(4032, 3024, .heic, name: "IMG.heic"))
        _ = await s.readImage("call_e|fc_e", Kit.image(4032, 3024, .jpeg, orientation: 6, name: "exif6.jpg"))
        await c.liveAndRestart(s)
        for p in c.all {
            c.metric("\(p).live", c.images("live", p).map { "\($0.w)x\($0.h) \($0.mime)/\($0.fmt)" })
            c.metric("\(p).restart", c.images("restart", p).map { "\($0.w)x\($0.h) \($0.mime)/\($0.fmt)" })
        }
        // [T-image-gate] Was: restart sent the HEIC original labelled image/jpeg,
        // and Anthropic squashed the EXIF photo to 2000x1500 (KNOWN GAP below).
        let rh = c.images("restart", .chat).first
        c.current("restart (chat): the HEIC goes out as a JPEG 2000x1500", rh?.fmt == "jpeg" && rh?.mime == "image/jpeg" && rh?.w == 2000)
        let ra = c.images("restart", .anthropic).dropFirst().first
        c.current("restart (anthropic): the EXIF photo goes out upright 1500x2000", ra.map { $0.w == 1500 && $0.h == 2000 } ?? false)
        for p in c.all { c.current("\(p): MIME matches and orientation upright after restart",
                                   !c.inv("restart", p).flags.contains("MIME") && c.images("restart", p).dropFirst().first.map { $0.h > $0.w } == true) }
    },

    Scenario(id: "C24", title: "images over 25 MB (6 x ~4 MB)", input: "six user turns, each one distinct noise JPEG (2048+i)x2048 (send route compresses each to <= 5 MB base64)",
             catalogCurrent: "iOS-C: plan drops 1, rewrite drops all, placeholders all point to one file (verified)", desired: "drop only the planned ones; each placeholder points to its own file") { c in
        let s = c.newSession()
        for i in 0..<6 {
            await s.user("image \(i)", [Kit.image(2048 + i, 2048, .jpeg, pattern: .noise, name: "noise\(i).jpg", quality: 0.95)])
            await s.assistant("ok \(i)")
        }
        await c.liveAndRestart(s)
        let plan = c.captures["live"]!.output.budgetPlan
        c.metric("plan", plan.map { "dropped=\($0.droppedCount)/\($0.totalCount) kept=\($0.keptBytes) elided=\($0.elidedBytes)" } ?? "nil")
        c.metric("historyImageB64", historyImages(s.history).map { AIChatViewModel.estimatedBase64Length($0.count) })
        for phase in ["live", "restart"] {
            let inv = c.inv(phase, .chat)
            c.metric("\(phase).requestImages", inv.imageCount)
            c.metric("\(phase).placeholders", inv.placeholders.map(normalized))
        }
        let inv = c.inv("live", .chat)
        // [T-budget-position-ids] Was: the plan dropped 1, the rewrite dropped all
        // six and every placeholder named noise5.jpg (KNOWN GAP below) - ids were
        // ObjectIdentifier(data as AnyObject), a reused temporary address. Ids
        // are now positions in the request's image list.
        c.current("planner reports one drop", plan?.droppedCount == 1)
        c.current("the rewrite drops only the oldest image (noise0.jpg); its placeholder names its own file",
                  inv.placeholders.count == 1 && inv.placeholders[0].contains("Original at /var/minis/attachments/uploads/noise0.jpg "))
        for phase in ["live", "restart"] {
            c.current("\(phase): only planned images dropped, each placeholder names its own file",
                      c.inv(phase, .chat).imageCount == 5 && c.inv(phase, .chat).placeholders.count == 1)
        }
    },

    Scenario(id: "C25", title: "compaction, first post-anchor message is a plain user", input: "u1 a1 u2 a2 [anchor=a2] u3; summary S",
             catalogCurrent: "summary inserted at the front of that user message (verified)", desired: "same") { c in
        let s = c.newSession()
        await s.user("first question"); await s.assistant("first answer")
        await s.user("second question"); await s.assistant("second answer")
        s.compaction(anchorAt: 3, summary: "S: the user asked two questions")
        await s.user("third question")
        await c.liveAndRestart(s)
        for p in c.all {
            let v = c.view("live", p)
            let i = v.firstIndex { $0.parts.contains { $0.text?.contains(summaryTag) == true } } ?? -1
            // Responses emits each text part as its own message item; the others keep one user message.
            let txt = i < 0 ? "" : (p == .responses ? v[i...min(i + 1, v.count - 1)] : v[i...i])
                .flatMap { $0.parts.compactMap { $0.text } }.joined(separator: "|")
            c.current("\(p): summary first, then \"third question\"\(p == .responses ? " (two adjacent user items)" : " in one user message")",
                      txt.hasPrefix(summaryTag) && txt.contains("third question"))
            c.current("\(p): adjacency holds", c.inv("live", p).adjacencyOK)
        }
        // [T-404-summary-after-tool-results] The fix must not move the summary
        // here: sha256 of every provider's serialized request, compared by the
        // iOS-H report against the build before the fix (prompt cache).
        for phase in ["live", "restart"] {
            for (name, sha) in ctxRequestBodySha256(c.captures[phase]!.output.messages) { c.metric("bodySha.\(phase).\(name)", sha) }
        }
    },

    Scenario(id: "C26", title: "compaction, first post-anchor message is a tool-result carrier (#404)", input: "u1 a1 u2 a2(tool_use t1) [anchor=a2] tool_result(t1) a3; summary S",
             catalogCurrent: "iOS Responses: function_call -> message(summary) -> function_call_output (verified)", desired: "summary after the tool result; tool_result right after tool_use") { c in
        let s = c.newSession()
        await s.user("first"); await s.assistant("ok")
        await s.user("list files")
        await s.assistant(nil, toolUses: [("call_t1|fc_t1", "shell", ["command": "ls"])])
        s.compaction(anchorAt: 3, summary: "S: listing files")
        await s.toolResult("call_t1|fc_t1", "shell", "a.txt b.txt")
        await s.assistant("two files")
        await c.liveAndRestart(s)
        func order(_ phase: String, _ p: Provider) -> [String] {
            c.view(phase, p).map { m in "\(m.role):" + m.parts.map { $0.kind == "text" && $0.text?.contains(summaryTag) == true ? "SUMMARY" : $0.kind }.joined(separator: "+") }
        }
        for p in c.all {
            let inv = c.inv("live", p)
            c.metric("\(p).adjacency", inv.adjacencyOK ? "ok" : inv.adjacencyNote)
            c.metric("\(p).order", order("live", p))
        }
        // [T-404-summary-after-tool-results] Was KNOWN GAP (summary between
        // function_call and function_call_output; dropped on Chat Completions).
        for p in c.all {
            for phase in ["live", "restart"] {
                c.current("\(p) \(phase): tool_result right after tool_use", c.inv(phase, p).adjacencyOK)
                c.current("\(p) \(phase): the summary reaches the request", c.texts(phase, p).contains(summaryTag))
            }
        }
        let r = c.view("live", .responses)
        let fc = r.firstIndex { $0.parts.contains { $0.kind == "toolUse" } } ?? -1
        c.current("responses: function_call, then function_call_output, then the summary message",
                  fc >= 0 && fc + 2 < r.count && r[fc + 1].parts.first?.kind == "toolResult" && r[fc + 2].parts.contains { $0.text?.contains(summaryTag) == true })
        c.current("chat: tool reply, then the summary as a user message", order("live", .chat).contains("tool:toolResult")
                  && order("live", .chat).firstIndex(of: "tool:toolResult")! + 1 < order("live", .chat).count
                  && order("live", .chat)[order("live", .chat).firstIndex(of: "tool:toolResult")! + 1] == "user:SUMMARY")
        for p in [Provider.gemini, .antigravity, .anthropic] {
            c.current("\(p): tool result first, summary after it in the same user turn", order("live", p).contains { $0.hasSuffix("toolResult+SUMMARY") })
        }
        for phase in ["live", "restart"] {
            for (name, sha) in ctxRequestBodySha256(c.captures[phase]!.output.messages) { c.metric("bodySha.\(phase).\(name)", sha) }
        }
    },

    Scenario(id: "C27", title: "same history, switch provider", input: "camera photo + browser screenshot, serialized by all five providers",
             catalogCurrent: "to measure: are the bytes the same everywhere", desired: "same image bytes") { c in
        let s = c.newSession()
        await s.user("photo", [Kit.image(.CAMERA_4032x3024)])
        _ = await s.browserScreenshot("call_s|fc_s", pointW: 390, pointH: 844)
        await s.user("compare")
        await c.liveAndRestart(s)
        for phase in ["live", "restart"] {
            let sets = c.all.map { c.inv(phase, $0).shas }
            c.metric("\(phase).distinctByteSets", Set(sets.map { $0.joined(separator: ",") }).count)
        }
        c.current("live: all five send identical bytes", Set(c.all.map { c.inv("live", $0).shas }).count == 1)
        // [T-image-gate] Was: after restart Anthropic sent its own downscale and
        // the other four the original (KNOWN GAP "all five identical"). Now all
        // five get the request gate's output.
        c.current("restart: all five identical", Set(c.all.map { c.inv("restart", $0).shas }).count == 1)
    },

    Scenario(id: "C28", title: "edit an old message and resend / retry", input: "user+photo, assistant; edit(0, new text); separately retry(0)",
             catalogCurrent: "to measure; Android edit-resend copies media and uploads (static)", desired: "nothing stored twice") { c in
        let s = c.newSession()
        await s.user("old text", [Kit.image(.CAMERA_4032x3024, name: "IMG_1.jpg")])
        await s.assistant("answer")
        c.metric("before", "uploads=\(s.fileCount("attachments/uploads")) mediaJPEG=\(((try? FileManager.default.contentsOfDirectory(atPath: s.sessionDir.appendingPathComponent("attachments").path)) ?? []).filter { $0.hasSuffix(".jpg") }.count)")
        await s.edit(0, "new text")
        let uploads = ((try? FileManager.default.contentsOfDirectory(atPath: s.sessionDir.appendingPathComponent("attachments/uploads").path)) ?? []).sorted()
        let media = ((try? FileManager.default.contentsOfDirectory(atPath: s.sessionDir.appendingPathComponent("attachments").path)) ?? []).filter { $0.hasSuffix(".jpg") }
        c.metric("afterEdit.uploads", uploads)
        c.metric("afterEdit.mediaFiles", media.count)
        await c.liveAndRestart(s)
        c.current("edit re-uploads the photo as IMG_1_1.jpg (two copies in uploads)", uploads == ["IMG_1.jpg", "IMG_1_1.jpg"])
        c.current("edit stores a second media copy; the old one is orphaned", media.count == 2)
        for p in c.all { c.current("\(p): request has the one image", c.inv("live", p).imageCount == 1 && c.inv("restart", p).imageCount == 1) }
        c.desired("edit stores nothing twice", uploads.count == 1 && media.count == 1)
        // retry(fromIndex): retryFromMessage keeps the bubble and its history
        // entry (cutAtUserBubble keepBubble: true) - nothing is re-stored.
        let r = c.newSession("-retry")
        await r.user("q", [Kit.image(.CAMERA_4032x3024)])
        await r.assistant("a")
        r.history = Array(r.history.prefix(1)); r.rows = Array(r.rows.prefix(1))
        c.current("retry keeps one upload and one media file", r.fileCount("attachments/uploads") == 1
                  && ((try? FileManager.default.contentsOfDirectory(atPath: r.sessionDir.appendingPathComponent("attachments").path)) ?? []).filter { $0.hasSuffix(".jpg") }.count == 1)
    },

    Scenario(id: "C29", title: "queued send vs normal send", input: "JPEG 4032x3024, GIF 2400x1800, PNG 3000x3000 through both routes",
             catalogCurrent: "iOS: identical for plain JPEG; GIF label and compression ladder differ (verified)", desired: "identical") { c in
        let s = c.newSession()
        let files = [Kit.image(.CAMERA_4032x3024), Kit.image(2400, 1800, .gif), Kit.image(3000, 3000, .png, name: "p.png")]
        await s.user("send", files, route: .send)
        await s.user("queue", files, route: .queue)
        await c.liveAndRestart(s)
        let imgs = c.images("live", .chat)
        let send = Array(imgs.prefix(3)), queue = Array(imgs.dropFirst(3))
        c.metric("send", send.map { "\($0.w)x\($0.h) \($0.mime)/\($0.fmt) \($0.bytes)B" })
        c.metric("queue", queue.map { "\($0.w)x\($0.h) \($0.mime)/\($0.fmt) \($0.bytes)B" })
        c.current("JPEG: same bytes on both routes", send.count == 3 && queue.count == 3 && send[0].sha256 == queue[0].sha256)
        // [T-image-gate] Was: the queue route's image/gif label reached the
        // request (KNOWN GAP "identical parts"); the gate labels by the bytes.
        c.current("GIF: both routes label the JPEG bytes image/jpeg", send[1].mime == "image/jpeg" && queue[1].mime == "image/jpeg")
        c.current("both routes produce identical parts", zip(send, queue).allSatisfy { $0.sha256 == $1.sha256 && $0.mime == $1.mime })
    },

    Scenario(id: "C30", title: "missing media file", input: "user photo; its media file deleted; restart",
             catalogCurrent: "silently dropped, no placeholder (verified)", desired: "visible placeholder") { c in
        let s = c.newSession()
        await s.user("photo", [Kit.image(.CAMERA_4032x3024)])
        await s.user("still there?")
        let attachments = s.sessionDir.appendingPathComponent("attachments")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: attachments.path)) ?? [] where f.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: attachments.appendingPathComponent(f))
        }
        await c.liveAndRestart(s)
        for p in c.all {
            c.current("\(p): after restart no image and no placeholder", c.inv("restart", p).imageCount == 0 && c.inv("restart", p).placeholders.isEmpty)
            c.desired("\(p): a visible placeholder replaces the lost image", !c.inv("restart", p).placeholders.isEmpty)
        }
    },

    Scenario(id: "C31", title: "tool-result image in history", input: "browser screenshot then two more turns; restart",
             catalogCurrent: "iOS: still there after restart, but the original (verified)", desired: "consistent on both platforms") { c in
        let s = c.newSession()
        await s.user("open")
        _ = await s.browserScreenshot("call_h1|fc_h1", pointW: 390, pointH: 844)
        await s.assistant("I see the page")
        await s.user("next")
        await c.liveAndRestart(s)
        for p in c.all { c.current("\(p): one image live and after restart", c.inv("live", p).imageCount == 1 && c.inv("restart", p).imageCount == 1) }
        // [T-image-gate #412] Was: after restart the 1170x2532 original, live
        // 925x2000. Live is the gate's output and the snapshot stores it.
        c.current("live and after restart (chat) both 924x2000", c.dims("restart", .chat) == ["924x2000"] && c.dims("live", .chat) == ["924x2000"])
        for p in c.all { c.current("\(p): restart == live", c.inv("restart", p).shas == c.inv("live", p).shas) }
    },

    Scenario(id: "C32", title: "rename / fork / backup restore", input: "(a) rename the uploaded file; (b) fork by verbatim row copy, then delete the source session",
             catalogCurrent: "to measure", desired: "no image lost") { c in
        let s = c.newSession()
        await s.user("photo", [Kit.image(.CAMERA_4032x3024, name: "IMG_9.jpg")])
        let up = s.sessionDir.appendingPathComponent("attachments/uploads")
        try? FileManager.default.moveItem(at: up.appendingPathComponent("IMG_9.jpg"), to: up.appendingPathComponent("renamed.jpg"))
        await c.liveAndRestart(s)
        for p in c.all { c.current("(a) \(p): image survives the rename (it is served from the media copy)", c.inv("restart", p).imageCount == 1) }
        c.current("(a) the [attached image: ...] text still names the old path",
                  c.texts("restart", .chat).contains("[attached image: /var/minis/attachments/uploads/IMG_9.jpg]"))
        // (b) SessionForkManager.duplicateSession copies parts verbatim: the
        // mediaRef keeps the SOURCE session's relativePath.
        let fork = c.newSession("-fork")
        fork.rows = s.rows.map { RawMessage(id: $0.id, sessionId: fork.sid, role: $0.role, parts: $0.parts, createdAt: $0.createdAt) }
        await fork.restart()
        let before = historyImages(fork.history).count
        _ = SessionStorageCleanup.removeSessionDirectory(s.sid, minisBase: AIChatViewModel.minisPersistentBase)
        await fork.restart()
        let after = historyImages(fork.history).count
        c.metric("fork.imagesBeforeSourceDelete", before)
        c.metric("fork.imagesAfterSourceDelete", after)
        c.current("(b) the fork resolves its image through the source session's directory", before == 1)
        c.current("(b) deleting the source session silently drops the fork's image", after == 0)
        c.desired("(b) a fork keeps its images after the source is deleted", after == 1)
        c.note("(c) backup/restore: not runnable here - BackupManager needs the real ChatStore database; not covered.")
    },
]
/// [T-404-summary-after-tool-results] sha256 of each provider's serialized
/// request for `messages` (JSON with sorted keys; Anthropic's final body).
func ctxRequestBodySha256(_ messages: [AgentMessage]) -> [String: String] {
    func json(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data() }
    let openai = OpenAIAgentProvider(model: openAIModel)
    let anthropic = AnthropicAgentProvider(provider: AnthropicProvider(model: claudeModel, isClaudeCode: true))
    let bodies: [String: Data] = [
        "responses": json(openai.convertMessagesResponsesAPI(messages)),
        "chat": json(openai.flattenChatCompletionsMessages(messages)),
        "gemini": json(GeminiAgentProvider(model: geminiModel).convertMessages(messages)),
        "antigravity": json(AntigravityAgentProvider(model: geminiModel).convertMessages(messages)),
        "anthropic": ((try? anthropic.requestBody(messages: messages, systemPrompt: "harness", tools: [], maxTokens: 1024, route: .oauth)) ?? nil) ?? Data(),
    ]
    return bodies.mapValues { sha256($0) }
}
#endif
