import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Minis

/// [T-image-seams iOS-B] Tool images (browser_use, read_image) through the REAL
/// production functions, linked from the app: ingest → live-turn bytes → disk
/// copies → persisted tool result → `RawMessage.toAgentMessage` (reload) →
/// provider serializers. Propositions P-i1, P-i3, P-i9; scenarios S1, S2, S5, S7.
///
/// Characterization tests pin TODAY's behaviour (several of them describe the
/// #412 family of bugs and must keep passing until the fix lands). Desired
/// behaviour is wrapped in `XCTExpectFailure` (KNOWN GAP): it does not fail the
/// run today, and turns into a failure the day a fix makes it pass — remove the
/// wrapper then.
///
/// Writes only under a throw-away session id in the app's own container and
/// deletes it in tearDown. No network: providers are constructed, never called.
///
/// Run: xcodebuild test -project src/ios/Minis.xcodeproj -scheme Minis \
///        -destination id=<My Mac (Designed for iPad) id> \
///        -only-testing:MinisTests/ImageRealIosBTests
@MainActor
final class ImageRealIosBTests: XCTestCase {

    private let sid = "IMGREAL-IOSB-\(UUID().uuidString.prefix(8))"
    private let visionModel = LLMModel(id: "gpt-repro", displayName: "repro", provider: "openai", modalityOverride: .vision)
    private let geminiModel = LLMModel(id: "gemini-2.5-pro", displayName: "repro", provider: "gemini", modalityOverride: .vision)

    /// [T-ios-unit-test-infra] Every test gets its own media store under a temp dir.
    /// `ChatStore.testOverride` points the app helpers that use `store`
    /// internally (snapshot / browser media) at the same store.
    private var storeRoot: URL!
    private var store: ChatStore!

    override func setUp() async throws {
        try await super.setUp()
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisTests-\(UUID().uuidString)", isDirectory: true)
        store = ChatStore(baseURL: storeRoot.appendingPathComponent("MinisChat", isDirectory: true))
        ChatStore.testOverride = store
    }

    override func tearDown() async throws {
        ChatStore.testOverride = nil
        store = nil
        try? FileManager.default.removeItem(at: storeRoot)
        try? FileManager.default.removeItem(at: AIChatViewModel.minisBrowserPersistentDir(for: sid))
        try? FileManager.default.removeItem(at: scratch)
    }
    private lazy var scratch: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("imgreal-iosb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    // MARK: - Fixtures (generated, nothing checked in)

    /// A web-page-like snapshot at screen scale, encoded with the real
    /// `BrowserUseManager.screenshotJPEGData`, as the screenshot action does.
    private func screenshot(pointW: Int, pointH: Int, scale: CGFloat = 3) -> (data: Data, image: UIImage) {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: pointW, height: pointH), format: fmt).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: pointW, height: pointH))
            UIColor(white: 0.25, alpha: 1).setFill()
            var y = 14, line = 0
            while y < pointH - 8 {
                ctx.fill(CGRect(x: 14, y: y, width: (pointW - 28) * (60 + (line * 37) % 40) / 100, height: 2))
                y += 6; line += 1
                if line % 12 == 0 { y += 12 }
            }
        }
        return (BrowserUseManager.screenshotJPEGData(image)!, image)
    }

    private func photo(w: Int, h: Int, type: UTType, orientation: Int? = nil) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [UIColor.orange.cgColor, UIColor.blue.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private struct Probe: Equatable { var w = 0, h = 0, fmt = "?" }
    private func probe(_ d: Data) -> Probe {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return Probe() }
        let t = (CGImageSourceGetType(src) as String?) ?? "?"
        let fmt = t == UTType.jpeg.identifier ? "jpeg" : t == UTType.heic.identifier ? "heic" : t == UTType.png.identifier ? "png" : t
        return Probe(w: p[kCGImagePropertyPixelWidth] as? Int ?? 0, h: p[kCGImagePropertyPixelHeight] as? Int ?? 0, fmt: fmt)
    }
    private func longEdge(_ d: Data) -> Int { let p = probe(d); return max(p.w, p.h) }

    // MARK: - Reload + serialize (real RawMessage / ChatStore / providers)

    /// Persist the tool result the way the DB row looks (parts_json), then
    /// rebuild it with the real `toAgentMessage` and the real media resolver.
    private func reloadToolResult(id: String, name: String, ref: MediaRef) async -> [AgentMessage] {
        let rows: [(MessageRole, [ContentPart])] = [
            (.user, [.text("look at it")]),
            (.assistant, [.toolUse(ToolUse(toolUseId: id, name: name, input: "{}", description: nil, thoughtSignature: nil))]),
            (.user, [.toolResult(ToolResult(toolUseId: id, output: "Screenshot captured", success: true,
                                            mediaRef: ref, snapshot: nil, pageURL: nil, status: "success"))]),
            (.user, [.text("next question")]),
        ]
        // The resolver closure is not Sendable (Swift 6 test target), so resolve
        // through the same actor method it wraps: minisBaseURL + relativePath.
        let url = await store.mediaFileURL(for: ref)
        return rows.enumerated().map { i, row in
            let parts = try! JSONDecoder().decode([ContentPart].self, from: try! JSONEncoder().encode(row.1))
            return RawMessage(id: "m\(i)", sessionId: sid, role: row.0, parts: parts, createdAt: Date())
                .toAgentMessage(mediaResolver: { _ in url })
        }
    }
    private func liveToolHistory(id: String, name: String, image: Data, mime: String) -> [AgentMessage] {
        [AgentMessage(role: .user, parts: [.text("look at it")]),
         AgentMessage(role: .assistant, parts: [.toolUse(id: id, name: name, input: [:])]),
         AgentMessage(role: .user, parts: [.toolResult(id: id, name: name, content: "Screenshot captured", isError: false,
                                                        imageData: image, imageMimeType: mime)]),
         AgentMessage(role: .user, parts: [.text("next question")])]
    }
    private func toolImage(_ h: [AgentMessage]) -> (data: Data, mime: String?)? {
        for m in h { for p in m.parts { if case .toolResult(_, _, _, _, let d?, let mime, _, _, _) = p { return (d, mime) } } }
        return nil
    }

    /// First image each serializer puts on the wire (Responses, Chat
    /// Completions, Gemini, Antigravity). Anthropic is not here: its
    /// `convertMessages` is private and outside this task's files.
    private func wire(_ history: [AgentMessage]) -> [String: (data: Data, mime: String)] {
        let openai = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "test", model: visionModel))
        let bodies: [(String, Any)] = [
            ("responses", openai.convertMessagesResponsesAPI(history)),
            ("chat", openai.flattenChatCompletionsMessages(history)),
            ("gemini", GeminiAgentProvider(provider: GeminiProvider(apiKey: "test", model: geminiModel)).convertMessages(history)),
            ("antigravity", AntigravityAgentProvider(provider: AntigravityProvider(oauthTokenProvider: { "test" }, model: geminiModel)).convertMessages(history)),
        ]
        var out: [String: (Data, String)] = [:]
        for (name, body) in bodies { if let img = firstImage(body) { out[name] = img } }
        return out
    }
    private func firstImage(_ v: Any) -> (Data, String)? {
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
            for k in d.keys.sorted() { if let r = firstImage(d[k]!) { return r } }
        } else if let a = v as? [Any] {
            for x in a { if let r = firstImage(x) { return r } }
        }
        return nil
    }

    // MARK: - S1 / P-i1 / P-i9: full-page browser screenshot

    func testS1FullPageScreenshot() async throws {
        let shot = screenshot(pointW: 920, pointH: 7297)
        XCTAssertEqual(probe(shot.data), Probe(w: 2760, h: 21891, fmt: "jpeg"))

        // P-i9: the metadata line reports UIImage.size — points, not pixels.
        let line = BrowserUseManager.screenshotImageLine(imageSize: shot.image.size, fileSize: shot.data.count)
        XCTAssertTrue(line.hasPrefix("  Image: 920x7297 ("), line)

        // P-i1 live: <= 2000 JPEG.
        let live = AIChatViewModel.browserUseInferenceImage(shot.data)
        XCTAssertEqual(probe(live.data), Probe(w: 253, h: 2000, fmt: "jpeg"))
        XCTAssertEqual(live.mimeType, "image/jpeg")

        // B2 (`minis_url`) and the snapshot media file are both the ORIGINAL.
        let linuxPath = AIChatViewModel.writeBrowserScreenshotCopy(shot.data, sessionId: sid)
        XCTAssertTrue(linuxPath.hasPrefix("/var/minis/browser/screenshot_") && linuxPath.hasSuffix(".jpg"), linuxPath)
        let b2 = AIChatViewModel.minisBrowserPersistentDir(for: sid).appendingPathComponent((linuxPath as NSString).lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: b2), shot.data)
        let ref = await AIChatViewModel.saveBrowserSnapshotMedia(imageData: shot.data, sessionId: sid, linuxPath: linuxPath)
        XCTAssertEqual(ref.relativePath.split(separator: "/").dropFirst().first, "browser")
        XCTAssertEqual(ref.mimeType, "image/jpeg")
        XCTAssertEqual(ref.originalFileName, "browser_snapshot.jpg")
        let persistedURL = await store.mediaFileURL(for: ref)
        let persisted = try Data(contentsOf: persistedURL)
        XCTAssertEqual(persisted, shot.data, "P-i1: the persisted snapshot is the original, not the live bytes")

        // S7 / reload: the tool image survives — as the original.
        let rebuilt = await reloadToolResult(id: "call_s1|fc_s1", name: "browser_use", ref: ref)
        let rebuiltImage = try XCTUnwrap(toolImage(rebuilt))
        XCTAssertEqual(rebuiltImage.data, shot.data)
        XCTAssertNotEqual(rebuiltImage.data, live.data)

        // Wire: live is <= 2000 everywhere; after reload every serializer here
        // carries the 21891-px original.
        let liveWire = wire(liveToolHistory(id: "call_s1|fc_s1", name: "browser_use", image: live.data, mime: live.mimeType))
        let rebuiltWire = wire(rebuilt)
        XCTAssertEqual(Set(liveWire.keys), ["responses", "chat", "gemini", "antigravity"])
        for (name, img) in liveWire { XCTAssertEqual(longEdge(img.data), 2000, "\(name) live") }
        for (name, img) in rebuiltWire { XCTAssertEqual(longEdge(img.data), 21891, "\(name) after reload carries the original") }

        XCTExpectFailure("KNOWN GAP #412: after a reload the request carries the original full-page screenshot") {
            for (name, img) in rebuiltWire { XCTAssertLessThanOrEqual(longEdge(img.data), 2000, "\(name)") }
        }
    }

    // MARK: - S2: viewport screenshots

    func testS2ViewportScreenshots() async throws {
        // Default viewport (390x844 pt @3): within 8192 even after reload.
        let small = screenshot(pointW: 390, pointH: 844)
        XCTAssertEqual(probe(small.data), Probe(w: 1170, h: 2532, fmt: "jpeg"))
        XCTAssertEqual(longEdge(AIChatViewModel.browserUseInferenceImage(small.data).data), 2000)
        let smallRef = await AIChatViewModel.saveBrowserSnapshotMedia(imageData: small.data, sessionId: sid, linuxPath: nil)
        let smallRebuilt = await reloadToolResult(id: "call_s2a|fc", name: "browser_use", ref: smallRef)
        XCTAssertEqual(try XCTUnwrap(toolImage(smallRebuilt)).data, small.data)

        // Big custom viewport (3000x2000 pt @3 = 9000x6000 px): > 8192 after reload.
        let big = screenshot(pointW: 3000, pointH: 2000)
        XCTAssertEqual(probe(big.data), Probe(w: 9000, h: 6000, fmt: "jpeg"))
        XCTAssertEqual(probe(AIChatViewModel.browserUseInferenceImage(big.data).data).w, 2000)
        let bigRef = await AIChatViewModel.saveBrowserSnapshotMedia(imageData: big.data, sessionId: sid, linuxPath: nil)
        let bigRebuilt = await reloadToolResult(id: "call_s2b|fc", name: "browser_use", ref: bigRef)
        let bigWire = wire(bigRebuilt)
        for (name, img) in bigWire { XCTAssertEqual(longEdge(img.data), 9000, "\(name) after reload") }
        XCTExpectFailure("KNOWN GAP: a big custom viewport screenshot exceeds 8192 px after a reload") {
            for (name, img) in bigWire { XCTAssertLessThanOrEqual(longEdge(img.data), 8192, "\(name)") }
        }
    }

    // MARK: - S5 / P-i3: read_image

    func testS5ReadImageBigFile() async throws {
        let page = screenshot(pointW: 920, pointH: 7297).data
        let file = scratch.appendingPathComponent("page.jpg")
        try page.write(to: file)
        let inference = AIChatViewModel.readImageInference(fileData: page, image: try XCTUnwrap(UIImage(data: page)))
        XCTAssertEqual(probe(inference.data), Probe(w: 253, h: 2000, fmt: "jpeg"))
        XCTAssertEqual(inference.mimeType, "image/jpeg")
        XCTAssertEqual([inference.originalW, inference.originalH, inference.resizedW, inference.resizedH], [2760, 21891, 253, 2000])

        // R1: a copy of the ORIGINAL file under images/.
        let ref = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: file.path, imageData: page, sessionId: sid,
                                                                   linuxPath: "/var/minis/attachments/uploads/page.jpg")
        XCTAssertEqual(ref.relativePath.split(separator: "/").dropFirst().first, "images")
        let r1URL = await store.mediaFileURL(for: ref)
        XCTAssertEqual(try Data(contentsOf: r1URL), page)

        let rebuilt = await reloadToolResult(id: "call_s5|fc_s5", name: "read_image", ref: ref)
        let img = try XCTUnwrap(toolImage(rebuilt))
        XCTAssertEqual(img.data, page, "P-i3: after a reload read_image resends the original file")
        for (name, w) in wire(rebuilt) { XCTAssertEqual(longEdge(w.data), 21891, "\(name)") }
        XCTExpectFailure("KNOWN GAP: read_image rebuilt bytes differ from the live bytes") {
            XCTAssertEqual(img.data, inference.data)
        }
    }

    func testS5ReadImageHEICIsLabelledJPEG() async throws {
        let heic = photo(w: 4032, h: 3024, type: .heic)
        let file = scratch.appendingPathComponent("IMG_0002.heic")
        try heic.write(to: file)
        XCTAssertEqual(probe(heic).fmt, "heic")

        let inference = AIChatViewModel.readImageInference(fileData: heic, image: try XCTUnwrap(UIImage(data: heic)))
        XCTAssertEqual(probe(inference.data), Probe(w: 2000, h: 1500, fmt: "jpeg"))

        let ref = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: file.path, imageData: heic, sessionId: sid, linuxPath: nil)
        XCTAssertEqual(ref.mimeType, "image/jpeg", "P-i3: detectImageMime does not know HEIC")
        XCTAssertEqual((ref.relativePath as NSString).pathExtension, "jpg")
        let rebuiltHistory = await reloadToolResult(id: "call_heic|fc", name: "read_image", ref: ref)
        let rebuilt = try XCTUnwrap(toolImage(rebuiltHistory))
        XCTAssertEqual(probe(rebuilt.data).fmt, "heic")
        XCTAssertEqual(rebuilt.mime, "image/jpeg")
        XCTExpectFailure("KNOWN GAP: HEIC bytes are labelled image/jpeg after a reload") {
            XCTAssertNotEqual(probe(rebuilt.data).fmt, "heic")
        }
    }

    func testS5ReadImageTwiceWritesTwoCopies() async throws {
        let small = photo(w: 1600, h: 1200, type: .jpeg)
        let file = scratch.appendingPathComponent("small.jpg")
        try small.write(to: file)
        let a = AIChatViewModel.readImageInference(fileData: small, image: try XCTUnwrap(UIImage(data: small)))
        let b = AIChatViewModel.readImageInference(fileData: small, image: try XCTUnwrap(UIImage(data: small)))
        XCTAssertEqual(a.data, b.data, "same input, same process: same bytes")
        XCTAssertNotEqual(a.data, small, "a <= 2000 JPEG is still re-encoded (jpegData 0.85)")
        let r1 = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: file.path, imageData: small, sessionId: sid, linuxPath: nil)
        let r2 = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: file.path, imageData: small, sessionId: sid, linuxPath: nil)
        XCTAssertNotEqual(r1.relativePath, r2.relativePath, "each read writes a new R1 copy")
    }
}
