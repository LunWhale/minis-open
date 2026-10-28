import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Minis

/// [T-image-real-seams] iOS-C, slow layer: persist -> reload -> request budget
/// through the app's own code. A RawMessage carrying mediaRefs is built the
/// way buildRawMessage builds it (`toolResultMediaRef`,
/// `persistedUserImageRef` -> the real `ChatStore.saveMedia`), round-tripped
/// through JSON as the DB stores parts, rebuilt by the full
/// `RawMessage.toAgentMessage` with the store's media resolver, and then sent
/// through the real `applyRequestImageBudget`. Also the takeover message.
///
/// The fast layer is MinisTests/Standalone/ImageRealIosCTests.swift. Desired
/// behaviour that is still missing is wrapped in XCTExpectFailure (the
/// Standalone layer's KNOWN GAP). Writes under a throw-away session id and
/// removes it in tearDown. No network.
@MainActor
final class ImageRealIosCXCTests: XCTestCase {

    private let sessionId = "image-real-iosC-\(UUID().uuidString)"

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
        try? FileManager.default.removeItem(at: AIChatViewModel.minisBrowserPersistentDir(for: sessionId))
        try? FileManager.default.removeItem(at: AIChatViewModel.minisPersistentBase
            .appendingPathComponent(sessionId).appendingPathComponent("attachments/spillover"))
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func page(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(UIColor(white: 0.25, alpha: 1).cgColor)
        var y = 40, line = 0
        while y < h - 20 {
            ctx.fill(CGRect(x: 40, y: y, width: (w - 80) * (60 + (line * 37) % 40) / 100, height: max(2, w / 160)))
            y += max(10, w / 60); line += 1
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private func viaJSON(_ parts: [ContentPart]) throws -> [ContentPart] {
        try JSONDecoder().decode([ContentPart].self, from: JSONEncoder().encode(parts))
    }

    // MARK: - P-i2: the reloaded tool image is the original

    /// A tool result stored before #412 was fixed (its snapshot holds the
    /// original): it reloads as the original, and [T-image-gate] the request
    /// gate heals it to exactly the bytes the live turn sends.
    func testReloadedOriginalGoesOutAsTheLiveImage() async throws {
        let original = page(2760, 21891)
        // What the live turn hands the model for this screenshot.
        let live = AIChatViewModel.browserUseInferenceImage(original).data
        let snapRef = await store.saveMedia(data: original, mimeType: "image/jpeg", sessionId: sessionId,
                                                       subdir: "browser", linuxPath: "/var/minis/browser/screenshot_1.jpg")
        let snap = ToolSnapshot(type: .image, text: nil, mediaRef: snapRef, duration: 1)
        XCTAssertNil(AIChatViewModel.toolResultMediaRef(imageData: nil, snapshot: snap), "no image to the model -> no ref")
        let ref = try XCTUnwrap(AIChatViewModel.toolResultMediaRef(imageData: live, snapshot: snap))
        XCTAssertEqual(ref, snapRef)

        let parts = try viaJSON([.toolResult(ToolResult(toolUseId: "t1", output: "Screenshot taken", success: true,
                                                        mediaRef: ref, snapshot: snap, pageURL: nil, status: "success"))])
        let raw = RawMessage(id: "m1", sessionId: sessionId, role: .user, parts: parts, createdAt: Date())
        let rebuilt = raw.toAgentMessage(mediaResolver: await store.mediaFileURLResolver())
        guard case .toolResult(_, _, _, _, let data?, let mime, _, let lp, _) = rebuilt.parts.first else {
            return XCTFail("tool image lost on reload")
        }
        XCTAssertEqual(data, original)
        XCTAssertEqual(pixelSize(data).1, 21891)
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertEqual(lp, "/var/minis/browser/screenshot_1.jpg")

        let vm = AIChatViewModel()
        let request = vm.applyRequestImageBudget([rebuilt])
        guard case .toolResult(_, _, _, _, let sent?, let sentMime, _, _, _) = request.first?.parts.first else { return XCTFail() }
        // [T-image-gate] Was: the budget passed the 2760x21891 original through.
        XCTAssertEqual(pixelSize(sent).0, 252, "the request gate converts the reloaded original")
        XCTAssertEqual(pixelSize(sent).1, 2000)
        XCTAssertEqual(sentMime, "image/jpeg")
        XCTAssertEqual(sent, live, "P-i2: after reload the model gets the same <=2000 image as the live turn")
    }

    // MARK: - Missing media: silent drop

    func testMissingMediaFileIsDroppedWithoutPlaceholder_today() async throws {
        let present = page(400, 300)
        let kept = await AIChatViewModel.persistedUserImageRef(data: present, mimeType: "image/jpeg", sessionId: sessionId,
                                                               linuxPath: "/var/minis/attachments/uploads/kept.jpg")
        let gone = MediaRef(id: "gone", relativePath: "\(sessionId)/attachments/gone.jpg", mimeType: "image/jpeg",
                            originalFileName: nil, linuxPath: "/var/minis/attachments/uploads/gone.jpg")
        let toolGone = ToolResult(toolUseId: "t2", output: "shot", success: true, mediaRef: gone, snapshot: nil, pageURL: nil, status: "success")
        let parts = try viaJSON([.text("two pictures"), .mediaRef(kept), .mediaRef(gone), .toolResult(toolGone)])
        let raw = RawMessage(id: "m2", sessionId: sessionId, role: .user, parts: parts, createdAt: Date())
        let rebuilt = raw.toAgentMessage(mediaResolver: await store.mediaFileURLResolver())

        XCTAssertEqual(rebuilt.parts.count, 3, "text + the image that exists + the tool result; the missing image leaves nothing")
        guard case .imageData(let d, let m, let lp) = rebuilt.parts[1] else { return XCTFail() }
        XCTAssertEqual(d, present); XCTAssertEqual(m, "image/jpeg"); XCTAssertEqual(lp, "/var/minis/attachments/uploads/kept.jpg")
        guard case .toolResult(_, _, let content, _, let toolData, let toolMime, _, let toolLp, _) = rebuilt.parts[2] else { return XCTFail() }
        XCTAssertEqual(content, "shot")
        XCTAssertNil(toolData); XCTAssertNil(toolMime)
        XCTAssertEqual(toolLp, "/var/minis/attachments/uploads/gone.jpg")

        XCTExpectFailure("a missing image should leave a visible placeholder")
        XCTAssertTrue(rebuilt.parts.contains { if case .text(let t) = $0 { return t.contains("gone.jpg") }; return false })
    }

    // MARK: - Persist -> reload: user image round trip

    func testUserImageRoundTripKeepsBytesMimeAndPath() async throws {
        let jpeg = page(2000, 1500)
        let ref = await AIChatViewModel.persistedUserImageRef(data: jpeg, mimeType: "image/jpeg", sessionId: sessionId,
                                                              linuxPath: "/var/minis/attachments/uploads/photo.jpg")
        XCTAssertTrue(ref.relativePath.hasPrefix("\(sessionId)/attachments/"))
        XCTAssertTrue(ref.relativePath.hasSuffix(".jpg"))
        let raw = RawMessage(id: "m3", sessionId: sessionId, role: .user,
                             parts: try viaJSON([.text("look"), .mediaRef(ref)]), createdAt: Date())
        let rebuilt = raw.toAgentMessage(mediaResolver: await store.mediaFileURLResolver())
        guard case .imageData(let d, let m, let lp) = rebuilt.parts.last else { return XCTFail("image lost") }
        XCTAssertEqual(d, jpeg)
        XCTAssertEqual(m, "image/jpeg")
        XCTAssertEqual(lp, "/var/minis/attachments/uploads/photo.jpg")
    }

    // MARK: - P-i8: the request budget counts bytes; the gate before it resizes

    /// [T-image-gate] Was testRequestBudgetPassesAWideImageUntouched: a
    /// 9000x300 image went out at 9000x300. The request gate resizes it.
    func testRequestGateResizesAWideImage() throws {
        let wide = page(9000, 300)
        let vm = AIChatViewModel()
        let history = [AgentMessage(role: .user, parts: [.imageData(data: wide, mimeType: "image/jpeg", linuxPath: nil)])]
        let staged = try XCTUnwrap(AIChatViewModel.budgetedRequestImages(history, sessionId: sessionId))
        XCTAssertEqual(staged.plan.droppedCount, 0, "nothing elided")
        XCTAssertEqual(staged.plan.gate.converted, 1)
        guard case .imageData(let sent, let mime, _) = vm.applyRequestImageBudget(history).first?.parts.first else { return XCTFail() }
        XCTAssertEqual(pixelSize(sent).0, 2000)
        XCTAssertEqual(mime, "image/jpeg")
    }

    /// Noise JPEGs that already follow the gate's rule (<= 2000 px, each just
    /// under the per-image cap), so only the budget acts on them.
    private func compliantNoiseJPEG(width: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: 1900, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt32.self)
        var x: UInt32 = 2463534242 &+ UInt32(width)
        for i in 0..<(ctx.bytesPerRow / 4 * 1900) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = x | 0xFF00_0000 }
        let cap = AIChatViewModel.rawBytesForBase64Budget(AIChatViewModel.kPerImageMaxBytes) - 64 * 1024
        var q: CGFloat = 0.95
        while true {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            CGImageDestinationFinalize(dest)
            if out.length <= cap || q < 0.3 { return out as Data }
            q -= 0.03
        }
    }

    func testRequestBudgetOverflowElidesWithPlaceholders() throws {
        // [T-image-gate] Real images: random bytes labelled image/jpeg are now
        // (rightly) turned into placeholders by the gate before the budget.
        let images = (0..<6).map { compliantNoiseJPEG(width: 2000 - $0) }
        let history = images.enumerated().map { i, d in
            AgentMessage(role: .user, parts: [.imageData(data: d, mimeType: "image/jpeg", linuxPath: i == 1 ? "/var/minis/attachments/uploads/b.jpg" : nil)])
        }
        let budgeted = try XCTUnwrap(AIChatViewModel.budgetedRequestImages(history, sessionId: sessionId))
        XCTAssertEqual(budgeted.plan.droppedCount, 1, "the plan drops the oldest image")
        XCTAssertEqual(budgeted.plan.totalCount, 6)
        let placeholders = budgeted.messages.flatMap(\.parts).compactMap { p -> String? in
            if case .text(let t) = p, t.hasPrefix("[image elided to fit 25MB request budget.") { return t }; return nil
        }
        XCTAssertFalse(placeholders.isEmpty)
        XCTAssertTrue(placeholders[0].contains("/var/minis/attachments/spillover/"), "the oldest has no linuxPath -> spilled")
        // [T-budget-position-ids] Was XCTExpectFailure: the rewrite matched parts
        // by a temporary box's ObjectIdentifier and elided them all.
        XCTAssertEqual(placeholders.count, 1, "only the planned image is elided")
        XCTAssertEqual(budgeted.messages.flatMap(\.parts).filter { if case .imageData = $0 { return true }; return false }.count, 5)
    }

    // MARK: - P-i4: takeover screenshot

    /// [T-image-gate #412] Was ..._IsSentFullSizeAndNotStored_today: the 9000x6000
    /// screenshot went out as is. Now the message carries the gate's output,
    /// the original stays in browser/, and the note is a <system-reminder>
    /// (the agent loop stores the message; the row renders nothing on reload).
    func testTakeoverScreenshotIsGatedAndItsNoteHidden() throws {
        let shot = page(9000, 6000)
        let msg = AIChatViewModel.takeoverScreenshotMessage(shot, sessionId: sessionId, timestamp: 1_791_000_000)
        XCTAssertEqual(msg.role, .user)
        guard case .text(let note) = msg.parts.first, case .imageData(let d, let m, let lp) = msg.parts.last else { return XCTFail() }
        XCTAssertTrue(note.hasPrefix("<system-reminder>[Browser takeover]"))
        XCTAssertTrue(note.hasSuffix("</system-reminder>"))
        XCTAssertFalse(AIChatViewModel.isUserBubbleEntry(msg), "not a user bubble")
        XCTAssertEqual(pixelSize(d).0, 2000, "P-i4: sent within 2000 px like other screenshots")
        XCTAssertEqual(m, "image/jpeg")
        XCTAssertEqual(lp, "/var/minis/browser/takeover_1791000000.jpg")
        let file = AIChatViewModel.minisBrowserPersistentDir(for: sessionId).appendingPathComponent("takeover_1791000000.jpg")
        XCTAssertEqual(try Data(contentsOf: file), shot, "the original is kept for viewing / read_image")
    }
}
