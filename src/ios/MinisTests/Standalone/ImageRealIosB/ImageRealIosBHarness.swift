// [T-image-seams iOS-B] Scenario runner for ImageRealIosBTests.swift. Calls the
// tool-image functions production calls (compiled from their declarations) and
// prints one `R key=<json>` line per measurement.
import Foundation
import UIKit
import UniformTypeIdentifiers
import CryptoKit

@main
struct ImageRealIosBHarness {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        if CommandLine.arguments.count > 1 { IosBEnv.root = URL(fileURLWithPath: CommandLine.arguments[1]) }
        try? FileManager.default.removeItem(at: IosBEnv.root)
        try? FileManager.default.createDirectory(at: IosBEnv.root, withIntermediateDirectories: true)
        await Runner().run()
    }
}

@MainActor
final class Runner {
    let sid = IosBEnv.sessionId
    let vision = LLMModel(id: "gpt-repro", displayName: "repro", provider: "openai", modalityOverride: .vision)
    let gemini = LLMModel(id: "gemini-2.5-pro", displayName: "repro", provider: "gemini", modalityOverride: .vision)

    func R(_ key: String, _ value: Any) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        print("R \(key)=\(String(data: data, encoding: .utf8)!)")
    }
    func record(_ key: String, _ data: Data, mime: String? = nil) {
        let p = iosbProbe(data)
        R(key + ".w", p.w); R(key + ".h", p.h); R(key + ".bytes", data.count); R(key + ".fmt", p.fmt)
        R(key + ".sha", SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined())
        if let mime { R(key + ".mime", mime) }
    }
    func fileData(_ ref: MediaRef) async -> Data {
        try! Data(contentsOf: await ChatStore.shared.mediaFileURLResolver()(ref))
    }
    func subdir(_ ref: MediaRef) -> String { ref.relativePath.split(separator: "/").dropFirst().first.map(String.init) ?? "?" }

    /// Persist → reload with the real `RawMessage.toAgentMessage`.
    func reload(id: String, name: String, ref: MediaRef) async -> [AgentMessage] {
        let rows: [(MessageRole, [ContentPart])] = [
            (.user, [.text("look at it")]),
            (.assistant, [.toolUse(ToolUse(toolUseId: id, name: name, input: "{}", description: nil, thoughtSignature: nil))]),
            (.user, [.toolResult(ToolResult(toolUseId: id, output: "Screenshot captured", success: true, mediaRef: ref,
                                            snapshot: nil, pageURL: nil, status: "success"))]),
            (.user, [.text("next question")]),
        ]
        let resolver = await ChatStore.shared.mediaFileURLResolver()
        return rows.enumerated().map { i, row in
            let parts = try! JSONDecoder().decode([ContentPart].self, from: try! JSONEncoder().encode(row.1))
            return RawMessage(id: "m\(i)", sessionId: sid, role: row.0, parts: parts, createdAt: Date()).toAgentMessage(mediaResolver: resolver)
        }
    }
    func live(id: String, name: String, image: Data, mime: String) -> [AgentMessage] {
        [AgentMessage(role: .user, parts: [.text("look at it")]),
         AgentMessage(role: .assistant, parts: [.toolUse(id: id, name: name, input: [:])]),
         AgentMessage(role: .user, parts: [.toolResult(id: id, name: name, content: "Screenshot captured", isError: false,
                                                        imageData: image, imageMimeType: mime)]),
         AgentMessage(role: .user, parts: [.text("next question")])]
    }
    func toolImage(_ h: [AgentMessage]) -> (Data, String?)? {
        for m in h { for p in m.parts { if case .toolResult(_, _, _, _, let d?, let mime, _, _, _) = p { return (d, mime) } } }
        return nil
    }
    func wire(_ h: [AgentMessage], _ key: String) {
        let openai = OpenAIAgentProvider(model: vision)
        let bodies: [(String, Any)] = [("responses", openai.convertMessagesResponsesAPI(h)),
                                      ("chat", openai.flattenChatCompletionsMessages(h)),
                                      ("gemini", GeminiAgentProvider(model: gemini).convertMessages(h)),
                                      ("antigravity", AntigravityAgentProvider(model: gemini).convertMessages(h))]
        for (name, body) in bodies {
            if let img = iosbFirstImage(body) { record("\(key).\(name)", img.data, mime: img.mime) } else { R("\(key).\(name).w", 0) }
        }
    }

    /// browser_use: screenshot → live bytes → B2 → snapshot media → reload → wire.
    func browser(_ key: String, pointW: Int, pointH: Int) async {
        let shot = iosbScreenshot(pointW: pointW, pointH: pointH)
        record("\(key).src", shot.data, mime: "image/jpeg")
        R("\(key).metaLine", BrowserUseManager.screenshotImageLine(imageSize: shot.size, fileSize: shot.data.count))
        let inference = AIChatViewModel.browserUseInferenceImage(shot.data)
        record("\(key).live", inference.data, mime: inference.mimeType)
        let linuxPath = AIChatViewModel.writeBrowserScreenshotCopy(shot.data, sessionId: sid)
        R("\(key).b2.linuxPath", linuxPath.replacingOccurrences(of: #"\d{9,}"#, with: "<s>", options: .regularExpression))
        let b2 = try? Data(contentsOf: AIChatViewModel.minisBrowserPersistentDir(for: sid).appendingPathComponent((linuxPath as NSString).lastPathComponent))
        R("\(key).b2.isOriginal", b2 == shot.data)
        // [T-image-gate #412] Production stores the model image (`toolImageData`).
        let ref = await AIChatViewModel.saveBrowserSnapshotMedia(imageData: inference.data, sessionId: sid, linuxPath: linuxPath,
                                                                 mimeType: inference.mimeType)
        record("\(key).persisted", await fileData(ref), mime: ref.mimeType)
        R("\(key).persisted.subdir", subdir(ref)); R("\(key).persisted.name", ref.originalFileName ?? "nil")
        let id = "call_\(key)|fc_\(key)"
        let rebuilt = await reload(id: id, name: "browser_use", ref: ref)
        if let r = toolImage(rebuilt) { record("\(key).rebuilt", r.0, mime: r.1); R("\(key).liveEqualsRebuilt", r.0 == inference.data) }
        else { R("\(key).rebuilt.w", 0) }
        wire(live(id: id, name: "browser_use", image: inference.data, mime: inference.mimeType), "\(key).wire.live")
        wire(rebuilt, "\(key).wire.rebuilt")
    }

    /// read_image: file → live bytes → R1 → reload → wire.
    func readImage(_ key: String, data: Data, fileName: String) async {
        let url = IosBEnv.root.appendingPathComponent(fileName)
        try! data.write(to: url)
        record("\(key).src", data)
        let inf = AIChatViewModel.readImageInference(fileData: data, image: UIImage(data: data)!)
        record("\(key).live", inf.data, mime: inf.mimeType)
        R("\(key).sizes", "\(inf.originalW)x\(inf.originalH)->\(inf.resizedW)x\(inf.resizedH)")
        let ref = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: url.path, imageData: inf.data, sessionId: sid,
                                                                   linuxPath: "/var/minis/attachments/uploads/\(fileName)")
        record("\(key).persisted", await fileData(ref), mime: ref.mimeType)
        R("\(key).persisted.subdir", subdir(ref)); R("\(key).persisted.ext", (ref.relativePath as NSString).pathExtension)
        let id = "call_\(key)|fc_\(key)"
        let rebuilt = await reload(id: id, name: "read_image", ref: ref)
        if let r = toolImage(rebuilt) { record("\(key).rebuilt", r.0, mime: r.1); R("\(key).liveEqualsRebuilt", r.0 == inf.data) }
        wire(rebuilt, "\(key).wire.rebuilt")
    }

    func run() async {
        await browser("s1", pointW: 920, pointH: 7297)
        await browser("s2a", pointW: 390, pointH: 844)
        await browser("s2b", pointW: 3000, pointH: 2000)

        await readImage("s5.big", data: iosbScreenshot(pointW: 920, pointH: 7297).data, fileName: "page.jpg")
        let heic = iosbEncode(iosbCGImage(w: 4032, h: 3024, pattern: .photo), type: .heic, quality: 0.8)
        await readImage("s5.heic", data: heic, fileName: "IMG_0002.heic")

        // Same file read twice: two R1 copies; same live bytes.
        let small = iosbEncode(iosbCGImage(w: 1600, h: 1200, pattern: .photo), type: .jpeg, quality: 0.9)
        let url = IosBEnv.root.appendingPathComponent("small.jpg")
        try! small.write(to: url)
        let imagesDir = IosBEnv.root.appendingPathComponent("MinisChat/minis/\(sid)/images")
        try? FileManager.default.removeItem(at: imagesDir)
        let a = AIChatViewModel.readImageInference(fileData: small, image: UIImage(data: small)!)
        let b = AIChatViewModel.readImageInference(fileData: small, image: UIImage(data: small)!)
        _ = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: url.path, imageData: a.data, sessionId: sid, linuxPath: nil)
        _ = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: url.path, imageData: b.data, sessionId: sid, linuxPath: nil)
        R("s5.twice.r1Copies", (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path).count) ?? 0)
        R("s5.twice.liveSame", a.data == b.data)
        R("s5.twice.reencodes", a.data != small)
    }
}
