import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Minis

/// [T-image-real-seams] iOS-A, slow layer: user-attachment images through the
/// app's own code end to end — `AIChatViewModel.inlineAttachmentImage` (the
/// function send() and processAttachments share), then the real persistence
/// (`ChatStore.saveMedia`, the same call persistAgentMessage makes for an
/// `.imageData` part), the real rebuild (`RawMessage.toAgentMessage` with the
/// store's media resolver, after a JSON round trip of the parts as the DB
/// stores them) and the real request path (`applyRequestImageBudget`, then the
/// OpenAI Responses serializer). No network: the provider is only constructed.
///
/// The fast layer is MinisTests/Standalone/ImageRealIosATests.swift; this one
/// pins the "persist → rebuild → serialize" half that needs the app module.
/// Writes media under a throw-away session id and deletes it in tearDown.
@MainActor
final class ImageRealIosAXCTests: XCTestCase {

    private let sessionId = "image-real-iosA-\(UUID().uuidString)"

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
        try await super.tearDown()
    }

    // MARK: - Fixtures (drawn in code; same generators as the Standalone layer)

    private func photo(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [UIColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1).cgColor, UIColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1).cgColor] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!, start: .zero, end: CGPoint(x: w, y: h), options: [])
        var x: UInt64 = 88172645463325252
        func next() -> UInt64 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x }
        for _ in 0..<2000 {
            ctx.setFillColor(UIColor(white: CGFloat(next() % 1000) / 1000, alpha: 0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: Int(next() % UInt64(w)), y: Int(next() % UInt64(h)), width: w / 40, height: w / 40))
        }
        return ctx.makeImage()!
    }

    private func encode(_ img: CGImage, _ type: UTType, quality: Double = 0.85) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    // MARK: - Round trip

    private struct Wire { let mime: String; let data: Data }

    /// Inline → persist → JSON round trip → rebuild → request budget →
    /// Responses serializer. Returns the live bytes, the rebuilt part and what
    /// the request body carries.
    private func roundTrip(_ data: Data, ext: String, route: AttachmentInlineRoute)
        async throws -> (live: AttachmentInlineImage, rebuilt: (Data, String), wire: Wire) {
        let live = AIChatViewModel.inlineAttachmentImage(data, ext: ext, route: route)
        let linuxPath = "/var/minis/attachments/uploads/fixture.\(ext)"
        let ref = await store.saveMedia(data: live.final, mimeType: live.mimeType,
                                                   sessionId: sessionId, linuxPath: linuxPath)
        let stored: [ContentPart] = [.text("see attached"), .mediaRef(ref)]
        let parts = try JSONDecoder().decode([ContentPart].self, from: JSONEncoder().encode(stored))
        let raw = RawMessage(id: "m1", sessionId: sessionId, role: .user, parts: parts, createdAt: Date())
        let resolver = await store.mediaFileURLResolver()
        let rebuiltMessage = raw.toAgentMessage(mediaResolver: resolver)
        var rebuilt: (Data, String)?
        for part in rebuiltMessage.parts { if case .imageData(let d, let m, _) = part { rebuilt = (d, m) } }
        let image = try XCTUnwrap(rebuilt, "rebuilt message lost its image")

        let vm = AIChatViewModel()
        let history = vm.applyRequestImageBudget([rebuiltMessage, AgentMessage(role: .user, parts: [.text("next")])])
        let model = LLMModel(id: "gpt-image-real", displayName: "image-real", provider: "openai", modalityOverride: .vision)
        let provider = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "no-network", model: model))
        let body = provider.convertMessagesResponsesAPI(history)
        let wire = try XCTUnwrap(Self.firstDataURL(in: body), "request body carries no image")
        return (live, image, wire)
    }

    private static func firstDataURL(in value: Any) -> Wire? {
        if let s = value as? String, s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            let header = s[s.index(s.startIndex, offsetBy: 5)..<comma]
            let mime = header.replacingOccurrences(of: ";base64", with: "")
            guard let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else { return nil }
            return Wire(mime: mime, data: data)
        }
        if let d = value as? [String: Any] { for v in d.values { if let w = firstDataURL(in: v) { return w } } }
        if let a = value as? [Any] { for v in a { if let w = firstDataURL(in: v) { return w } } }
        return nil
    }

    // MARK: - P-i7: live bytes == rebuilt bytes == request bytes

    func testCameraAttachmentSurvivesPersistRebuildSerialize() async throws {
        let camera = try XCTUnwrap(AIChatViewModel.downsampledCameraJPEG(UIImage(cgImage: photo(4032, 3024))))
        for route in [AttachmentInlineRoute.send, .queue] {
            let r = try await roundTrip(camera, ext: "jpg", route: route)
            XCTAssertEqual(pixelSize(r.live.final).0, 2000)
            XCTAssertEqual(r.live.mimeType, "image/jpeg")
            XCTAssertEqual(r.rebuilt.0, r.live.final, "rebuilt bytes differ from the live turn (\(route))")
            XCTAssertEqual(r.rebuilt.1, r.live.mimeType)
            XCTAssertEqual(r.wire.data, r.live.final, "request bytes differ from the live turn (\(route))")
            XCTAssertEqual(r.wire.mime, "image/jpeg")
        }
    }

    func testLibraryJPEGAndHEICSurviveRoundTrip() async throws {
        for (data, ext) in [(encode(photo(4032, 3024), .jpeg, quality: 0.9), "jpg"),
                            (encode(photo(4032, 3024), .heic, quality: 0.8), "heic")] {
            let r = try await roundTrip(data, ext: ext, route: .send)
            XCTAssertEqual(pixelSize(r.live.final).0, 2000)
            XCTAssertEqual(r.rebuilt.0, r.live.final)
            XCTAssertEqual(r.wire.data, r.live.final)
            XCTAssertEqual(r.wire.mime, "image/jpeg")
        }
    }

    /// S4: a small HEIC is not resized at intake, so its HEIC bytes are stored
    /// labelled image/jpeg. [T-image-gate] The request gate transcodes them:
    /// the model gets a 1200x900 JPEG (was: the HEIC bytes as image/jpeg).
    func testSmallHEICIsTranscodedToJPEGAtTheRequest() async throws {
        let heic = encode(photo(1200, 900), .heic, quality: 0.8)
        let r = try await roundTrip(heic, ext: "heic", route: .send)
        XCTAssertEqual(r.live.final, heic, "intake keeps the HEIC bytes")
        XCTAssertEqual(r.live.mimeType, "image/jpeg")
        XCTAssertEqual(r.rebuilt.1, "image/jpeg")
        XCTAssertEqual(r.wire.mime, "image/jpeg")
        XCTAssertNotEqual(r.wire.data, heic)
        XCTAssertEqual([UInt8](r.wire.data.prefix(3)), [0xFF, 0xD8, 0xFF], "the request carries JPEG bytes")
        XCTAssertEqual(pixelSize(r.wire.data).0, 1200)
        XCTAssertEqual(pixelSize(r.wire.data).1, 900)
    }

    // MARK: - P-i5: the queue route's differences, end to end

    /// S6: the queue route labels resized GIF output image/gif although the
    /// bytes are JPEG, and the label is persisted. [T-image-gate] The request
    /// gate keeps the bytes and sends them labelled image/jpeg (was image/gif).
    func testQueueRouteGIFLabelIsCorrectedAtTheRequest() async throws {
        let gif = encode(photo(2400, 1800), .gif)
        let queue = try await roundTrip(gif, ext: "gif", route: .queue)
        let send = try await roundTrip(gif, ext: "gif", route: .send)
        XCTAssertEqual(queue.live.final, send.live.final, "both routes produce the same JPEG bytes")
        XCTAssertEqual(queue.live.mimeType, "image/gif", "intake still labels it image/gif")
        XCTAssertEqual(send.live.mimeType, "image/jpeg")
        XCTAssertEqual(queue.wire.mime, "image/jpeg")
        XCTAssertEqual(queue.wire.data, queue.live.final, "original bytes kept")
    }

    func testQueueRouteHasNoCompressorLadder_today() {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 2000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let px = ctx.data!.bindMemory(to: UInt32.self, capacity: ctx.bytesPerRow / 4 * 2000)
        var x: UInt32 = 2463534242
        for i in 0..<(ctx.bytesPerRow / 4 * 2000) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; px[i] = x | 0xFF00_0000 }
        let noisy = encode(ctx.makeImage()!, .jpeg, quality: 1.0)
        let target = AIChatViewModel.rawBytesForBase64Budget(AIChatViewModel.kPerImageMaxBytes)
        XCTAssertGreaterThan(noisy.count, target)
        XCTAssertLessThanOrEqual(AIChatViewModel.inlineAttachmentImage(noisy, ext: "jpg", route: .send).final.count, target)
        XCTAssertEqual(AIChatViewModel.inlineAttachmentImage(noisy, ext: "jpg", route: .queue).final, noisy)
    }

    func testMessageBudgetEdges() {
        let cap = AIChatViewModel.kMessageImageMaxBytes
        XCTAssertFalse(AIChatViewModel.attachmentImageOverflowsMessage(cumulativeImageBytes: cap - 100, compressedB64: 100))
        XCTAssertTrue(AIChatViewModel.attachmentImageOverflowsMessage(cumulativeImageBytes: cap - 100, compressedB64: 101))
    }
}
