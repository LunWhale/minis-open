// [T-ctx-builder] iOS-E behaviour-unchanged evidence. The driver compiles this
// file twice: once against the code BEFORE the extraction (the three files at
// the pinned base commit) and once against the current code, each at -Onone
// and -O. Both builds run the same fixed inputs through the production entry
// points and print one sha256 per final message; the driver diffs them.
//
//   request  = vm.applyRequestImageBudget(vm.effectiveAgentHistory())
//              (what AgentLoop sends; in the new code this is the builder)
//   builder  = RequestContextBuilder.build(input) with explicit inputs (new only)
//   stored   = vm.buildRawMessage(msg).parts, canonicalized (random media ids
//              and dates removed)
//
// Guarded so MinisTests compiles it to nothing; the driver passes
// -D IMAGE_CTX_IOS_E_EQUIV (and -D NEW_BUILDER for the current code).
#if IMAGE_CTX_IOS_E_EQUIV
import Foundation
import CryptoKit

func canon(_ m: AgentMessage) -> String {
    var s = "role=\(m.role.rawValue) db=\(m.dbMessageId ?? "-") int=\(m.isInterrupted) rc=\(m.reasoningContent ?? "-")"
    for p in m.parts {
        switch p {
        case .text(let t): s += "|T:\(t)"
        case .toolUse(let id, let name, let input, _):
            let j = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            s += "|U:\(id):\(name):\(j)"
        case .toolResult(let id, let name, let content, let isError, let img, let mime, let url, let lp, let rb):
            s += "|R:\(id):\(name):\(content):\(isError):\(img.map { sha256(Data($0)) } ?? "-"):\(mime ?? "-"):\(url ?? "-"):\(lp ?? "-"):\(rb)"
        case .imageData(let d, let mime, let lp): s += "|I:\(sha256(d)):\(mime):\(lp ?? "-")"
        }
    }
    return s
}

func stripNoise(_ v: Any) -> Any {
    if let d = v as? [String: Any] {
        var o: [String: Any] = [:]
        for (k, x) in d where !["id", "relativePath", "createdAt"].contains(k) { o[k] = stripNoise(x) }
        return o
    }
    if let a = v as? [Any] { return a.map(stripNoise) }
    return v
}

func canonParts(_ parts: [ContentPart]) -> String {
    let j = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(parts))
    return String(decoding: try! JSONSerialization.data(withJSONObject: stripNoise(j), options: [.sortedKeys]), as: UTF8.self)
}

func emit(_ fixture: String, _ kind: String, _ msgs: [AgentMessage]) {
    for (i, m) in msgs.enumerated() { print("E \(fixture) \(kind) \(i) \(sha256(Data(canon(m).utf8)).prefix(16))") }
    print("E \(fixture) \(kind) count \(msgs.count)")
}

func jpeg(_ w: Int, _ h: Int, _ pattern: Pattern, q: Double = 0.85) -> Data { encode(makeCGImage(w: w, h: h, pattern: pattern), type: .jpeg, quality: q) }

func marker(_ sid: String, anchor: String, firstKept: String?) -> CompactMarker {
    var m = CompactMarker(id: "mk-\(sid)", sessionId: sid, summary: "S: earlier work", firstKeptSortOrder: 0, compactedCount: 0,
                          createdAt: Date(timeIntervalSince1970: 1_800_000_000), uiBoundarySortOrder: nil,
                          boundaryMessageId: anchor, firstKeptMessageId: firstKept, lastCompactedMessageId: anchor)
    m.version = 2
    return m
}

func withIds(_ msgs: [AgentMessage]) -> [AgentMessage] {
    msgs.enumerated().map { i, m in var x = m; x.dbMessageId = String(format: "db%03d", i); return x }
}

func u(_ t: String) -> AgentMessage { AgentMessage(role: .user, parts: [.text(t)]) }
func a(_ t: String) -> AgentMessage { AgentMessage(role: .assistant, parts: [.text(t)]) }

@MainActor
func runEquiv(root: URL) async {
    HarnessEnv.root = root
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sid = "00000000-0000-4000-8000-00000000E001"
    ChatStore.shared = ChatStore(baseURL: root.appendingPathComponent("MinisChat", isDirectory: true))
    let photo = jpeg(2000, 1500, .photo)
    let shot = jpeg(924, 2000, .page, q: 0.8)
    let noise = (0..<6).map { i in jpeg(1400 + i, 1400, .noise, q: 0.95) }
    let fixtures: [(String, [AgentMessage], CompactMarker?)] = [
        ("pureText", withIds([u("hi"), a("hello"), u("again")]), nil),
        ("compactPlainUser", withIds([u("q1"), a("a1"), u("q2"), a("a2"), u("q3"), a("a3"), u("q4")]),
         marker(sid, anchor: "db005", firstKept: "db006")),
        ("compactToolCarrier404", withIds([u("q1"), a("a1"), u("list"),
                                           AgentMessage(role: .assistant, parts: [.toolUse(id: "call_1|fc_1", name: "shell", input: ["command": "ls"])]),
                                           AgentMessage(role: .user, parts: [.toolResult(id: "call_1|fc_1", name: "shell", content: "a b", isError: false)]),
                                           a("done")]),
         marker(sid, anchor: "db003", firstKept: "db004")),
        ("userAndToolImage", withIds([AgentMessage(role: .user, parts: [.text("[attached image: /var/minis/attachments/uploads/p.jpg]"),
                                                                        .imageData(data: photo, mimeType: "image/jpeg", linuxPath: "/var/minis/attachments/uploads/p.jpg")]),
                                      AgentMessage(role: .assistant, parts: [.toolUse(id: "call_2|fc_2", name: "browser_use", input: ["action": "screenshot"])]),
                                      AgentMessage(role: .user, parts: [.toolResult(id: "call_2|fc_2", name: "browser_use", content: "Screenshot", isError: false,
                                                                                    imageData: shot, imageMimeType: "image/jpeg", imageLinuxPath: "/var/minis/browser/s.jpg")]),
                                      u("what now")]), nil),
        ("budget6x4MB", withIds(noise.enumerated().flatMap { i, d in
            [AgentMessage(role: .user, parts: [.text("img \(i)"), .imageData(data: d, mimeType: "image/jpeg", linuxPath: i % 2 == 0 ? "/var/minis/attachments/uploads/n\(i).jpg" : nil)]), a("ok \(i)")]
        }), nil),
    ]
    let vm = AIChatViewModel()
    vm.sessionId = sid
    for (name, history, mk) in fixtures {
        print("E \(name) inputBytes \(noise.map(\.count).reduce(0, +))")
        vm.agentHistory = history
        vm.cachedLatestMarker = mk
        vm.warmUpDropByMarker = [:]
        emit(name, "request", vm.applyRequestImageBudget(vm.effectiveAgentHistory()))
        #if NEW_BUILDER
        emit(name, "requestViaBuildRequestContext", vm.buildRequestContext().messages)
        let input = RequestContextBuilder.Input(history: history, compaction: mk, warmUpDrop: [:], helpers: vm.effectiveHistoryHelpers(),
                                                sessionId: sid, spilloverBase: AIChatViewModel.minisPersistentBase,
                                                requestImageMaxBytes: AIChatViewModel.kRequestImageMaxBytes)
        emit(name, "builder", RequestContextBuilder.build(input).messages)
        #endif
        for (i, m) in history.enumerated() {
            let raw = await vm.buildRawMessage(m)!
            print("E \(name) stored \(i) \(sha256(Data(canonParts(raw.parts).utf8)).prefix(16))")
        }
    }
    // Missing media: persist a user image, delete its file, reload, request.
    let msg = AgentMessage(role: .user, parts: [.text("look"), .imageData(data: photo, mimeType: "image/jpeg", linuxPath: "/var/minis/attachments/uploads/p.jpg")])
    let raw = await vm.buildRawMessage(msg)!
    for case .mediaRef(let ref) in raw.parts { try? FileManager.default.removeItem(at: await ChatStore.shared.mediaFileURL(for: ref)) }
    let resolver = await ChatStore.shared.mediaFileURLResolver()
    var reloaded = raw.toAgentMessage(mediaResolver: resolver)
    reloaded.dbMessageId = "db000"
    vm.agentHistory = [reloaded, a("ok"), u("still?")]
    vm.cachedLatestMarker = nil
    emit("missingMedia", "request", vm.applyRequestImageBudget(vm.effectiveAgentHistory()))
    #if NEW_BUILDER
    emit("missingMedia", "requestViaBuildRequestContext", vm.buildRequestContext().messages)
    #endif
}
#endif
