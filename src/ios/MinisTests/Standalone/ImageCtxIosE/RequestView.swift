// [T-ctx-builder] iOS-E assertion tools (catalog A8): RequestView - one shape
// for every provider's request body - plus the invariant checkers and the
// stable JSON the golden snapshots are made of.
//
// RequestView = [{role, parts: [{kind: text|image|toolUse|toolResult|reasoning,
// text, image: {w, h, mime, fmt, bytes, sha256, base64Len}, id, name}]}].
// Images found inside a tool result (Responses / Anthropic arrays) are listed
// right after it with `inToolResult = true`.
//
// Guarded like Kit.swift.
#if IMAGE_CTX_IOS_E
import Foundation

struct RVImage {
    let w: Int, h: Int
    let mime: String, fmt: String
    let bytes: Int, base64Len: Int
    let sha256: String
}

struct RVPart {
    var kind: String
    var text: String? = nil
    var image: RVImage? = nil
    var id: String? = nil
    var name: String? = nil
    var inToolResult = false
}

struct RVMessage {
    var role: String
    var parts: [RVPart]
}

enum Provider: String, CaseIterable {
    case responses, chat, gemini, antigravity, anthropic
}

func rvImage(dataURL s: String) -> RVImage? {
    guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
    let header = s[s.index(s.startIndex, offsetBy: 5)..<comma]
    let payload = String(s[s.index(after: comma)...])
    guard header.hasSuffix(";base64"), let d = Data(base64Encoded: payload) else { return nil }
    return rvImage(d, mime: String(header.dropLast(7)), b64: payload.utf8.count)
}

func rvImage(_ d: Data, mime: String, b64: Int) -> RVImage {
    let p = probe(d)
    return RVImage(w: p.w, h: p.h, mime: mime, fmt: p.fmt, bytes: d.count, base64Len: b64, sha256: sha256(d))
}

func rvImage(base64 b: String, mime: String) -> RVImage? {
    Data(base64Encoded: b).map { rvImage($0, mime: mime, b64: b.utf8.count) }
}

private func textOf(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    if let d = v as? [String: Any] { return (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } }
    return nil
}

enum RequestView {
    static func parse(_ provider: Provider, _ body: Any) -> [RVMessage] {
        switch provider {
        case .responses: return responses(body as? [[String: Any]] ?? [])
        case .chat: return chat(body as? [[String: Any]] ?? [])
        case .gemini, .antigravity: return gemini(body as? [[String: Any]] ?? [])
        case .anthropic:
            let json = (body as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return anthropic(json?["messages"] as? [[String: Any]] ?? [])
        }
    }

    static func responses(_ items: [[String: Any]]) -> [RVMessage] {
        items.map { item in
            switch item["type"] as? String {
            case "function_call":
                return RVMessage(role: "assistant", parts: [RVPart(kind: "toolUse", id: item["call_id"] as? String, name: item["name"] as? String)])
            case "function_call_output":
                var parts = [RVPart(kind: "toolResult", text: textOf(item["output"]), id: item["call_id"] as? String)]
                for c in (item["output"] as? [[String: Any]]) ?? [] {
                    if let u = c["image_url"] as? String, let img = rvImage(dataURL: u) { parts.append(RVPart(kind: "image", image: img, inToolResult: true)) }
                }
                return RVMessage(role: "tool", parts: parts)
            case "reasoning":
                return RVMessage(role: "assistant", parts: [RVPart(kind: "reasoning")])
            default:
                var parts: [RVPart] = []
                if let s = item["content"] as? String { parts.append(RVPart(kind: "text", text: s)) }
                for c in (item["content"] as? [[String: Any]]) ?? [] {
                    switch c["type"] as? String {
                    case "input_image":
                        if let u = c["image_url"] as? String, let img = rvImage(dataURL: u) { parts.append(RVPart(kind: "image", image: img)) }
                    default:
                        parts.append(RVPart(kind: "text", text: c["text"] as? String ?? ""))
                    }
                }
                return RVMessage(role: item["role"] as? String ?? "?", parts: parts)
            }
        }
    }

    static func chat(_ messages: [[String: Any]]) -> [RVMessage] {
        messages.map { m in
            let role = m["role"] as? String ?? "?"
            var parts: [RVPart] = []
            if role == "tool" {
                parts.append(RVPart(kind: "toolResult", text: textOf(m["content"]), id: m["tool_call_id"] as? String))
                return RVMessage(role: role, parts: parts)
            }
            if let s = m["content"] as? String, !s.isEmpty { parts.append(RVPart(kind: "text", text: s)) }
            for c in (m["content"] as? [[String: Any]]) ?? [] {
                if c["type"] as? String == "image_url", let u = (c["image_url"] as? [String: Any])?["url"] as? String, let img = rvImage(dataURL: u) {
                    parts.append(RVPart(kind: "image", image: img))
                } else {
                    parts.append(RVPart(kind: "text", text: c["text"] as? String ?? ""))
                }
            }
            for tc in (m["tool_calls"] as? [[String: Any]]) ?? [] {
                parts.append(RVPart(kind: "toolUse", id: tc["id"] as? String, name: (tc["function"] as? [String: Any])?["name"] as? String))
            }
            return RVMessage(role: role, parts: parts)
        }
    }

    /// Gemini and Antigravity. functionCall / functionResponse carry no id, so
    /// the tool name stands in for it.
    static func gemini(_ contents: [[String: Any]]) -> [RVMessage] {
        contents.map { c in
            var parts: [RVPart] = []
            for p in (c["parts"] as? [[String: Any]]) ?? [] {
                if let t = p["text"] as? String { parts.append(RVPart(kind: p["thought"] as? Bool == true ? "reasoning" : "text", text: t)) }
                if let inline = (p["inlineData"] ?? p["inline_data"]) as? [String: Any], let b = inline["data"] as? String,
                   let img = rvImage(base64: b, mime: (inline["mimeType"] ?? inline["mime_type"]) as? String ?? "?") {
                    parts.append(RVPart(kind: "image", image: img))
                }
                if let fc = p["functionCall"] as? [String: Any] {
                    let name = fc["name"] as? String
                    parts.append(RVPart(kind: "toolUse", id: (fc["id"] as? String) ?? name, name: name))
                }
                if let fr = p["functionResponse"] as? [String: Any] {
                    let name = fr["name"] as? String
                    parts.append(RVPart(kind: "toolResult", text: textOf(fr["response"]), id: (fr["id"] as? String) ?? name, name: name))
                }
            }
            return RVMessage(role: c["role"] as? String ?? "?", parts: parts)
        }
    }

    static func anthropic(_ messages: [[String: Any]]) -> [RVMessage] {
        messages.map { m in
            var parts: [RVPart] = []
            if let s = m["content"] as? String { parts.append(RVPart(kind: "text", text: s)) }
            for c in (m["content"] as? [[String: Any]]) ?? [] {
                switch c["type"] as? String {
                case "image":
                    if let src = c["source"] as? [String: Any], let b = src["data"] as? String,
                       let img = rvImage(base64: b, mime: src["media_type"] as? String ?? "?") { parts.append(RVPart(kind: "image", image: img)) }
                case "tool_use":
                    parts.append(RVPart(kind: "toolUse", id: c["id"] as? String, name: c["name"] as? String))
                case "tool_result":
                    var nested: [RVPart] = []
                    var texts: [String] = []
                    if let s = c["content"] as? String { texts.append(s) }
                    for x in (c["content"] as? [[String: Any]]) ?? [] {
                        if x["type"] as? String == "image", let src = x["source"] as? [String: Any], let b = src["data"] as? String,
                           let img = rvImage(base64: b, mime: src["media_type"] as? String ?? "?") {
                            nested.append(RVPart(kind: "image", image: img, inToolResult: true))
                        } else if let t = x["text"] as? String { texts.append(t) }
                    }
                    parts.append(RVPart(kind: "toolResult", text: texts.joined(separator: "\n"), id: c["tool_use_id"] as? String))
                    parts.append(contentsOf: nested)
                case "thinking", "redacted_thinking":
                    parts.append(RVPart(kind: "reasoning"))
                default:
                    parts.append(RVPart(kind: "text", text: c["text"] as? String ?? ""))
                }
            }
            return RVMessage(role: m["role"] as? String ?? "?", parts: parts)
        }
    }
}

// MARK: - Invariants

struct Invariants {
    var imageCount = 0
    var maxEdge = 0
    var mimes: [String] = []
    var totalBytes = 0
    var totalBase64 = 0
    var flags: Set<String> = []
    var adjacencyOK = true
    var adjacencyNote = ""
    var shas: [String] = []
    var placeholders: [String] = []
    var duplicateImages = 0

    /// Compliant = every image's MIME matches its bytes, no edge over 8192,
    /// none over 3.5 MB of base64, the request under 25 MB of base64.
    var compliant: Bool { flags.isDisjoint(with: ["MIME", "E8192", "B3.5MB", "T25MB"]) }
}

// [T-image-gate] "[image not sent": an image the request gate could not make valid.
let placeholderMarkers = ["[image elided", "[image omitted", "[image not sent", "[pasted content unavailable"]

func invariants(_ view: [RVMessage], provider: Provider) -> Invariants {
    var inv = Invariants()
    var seen: [String: Int] = [:]
    for m in view {
        for p in m.parts {
            if let img = p.image {
                inv.imageCount += 1
                inv.maxEdge = max(inv.maxEdge, img.w, img.h)
                inv.mimes.append(img.mime)
                inv.totalBytes += img.bytes
                inv.totalBase64 += img.base64Len
                inv.shas.append(img.sha256)
                seen[img.sha256, default: 0] += 1
                let expected = ["image/jpeg": "jpeg", "image/png": "png", "image/gif": "gif", "image/webp": "org.webmproject.webp", "image/heic": "heic"][img.mime]
                if expected != img.fmt { inv.flags.insert("MIME") }
                if max(img.w, img.h) > 2000 { inv.flags.insert("E2000") }
                if max(img.w, img.h) > 8192 { inv.flags.insert("E8192") }
                if img.base64Len > 3_500_000 { inv.flags.insert("B3.5MB") }
            }
            if let t = p.text {
                for marker in placeholderMarkers {
                    var rest = Substring(t)
                    while let r = rest.range(of: marker) {
                        let tail = rest[r.lowerBound...]
                        let end = tail.firstIndex(of: "]") ?? tail.endIndex
                        inv.placeholders.append(String(tail[..<end]) + "]")
                        rest = tail[end...]
                    }
                }
            }
        }
    }
    if inv.totalBase64 > 25 * 1024 * 1024 { inv.flags.insert("T25MB") }
    inv.duplicateImages = seen.values.reduce(0) { $0 + max(0, $1 - 1) }
    (inv.adjacencyOK, inv.adjacencyNote) = adjacency(view, provider: provider)
    return inv
}

/// Every tool call is answered right away: after a run of messages that only
/// call tools, the following messages must carry the results for all of them
/// before anything else is said. For Anthropic the tool_result blocks must
/// also come first inside the user message.
func adjacency(_ view: [RVMessage], provider: Provider) -> (Bool, String) {
    var i = 0
    while i < view.count {
        guard view[i].parts.contains(where: { $0.kind == "toolUse" }) else { i += 1; continue }
        var pending: [String] = view[i].parts.filter { $0.kind == "toolUse" }.compactMap { $0.id }
        var j = i + 1
        while j < view.count, !view[j].parts.isEmpty, view[j].parts.allSatisfy({ $0.kind == "toolUse" || $0.kind == "reasoning" }) {
            pending += view[j].parts.filter { $0.kind == "toolUse" }.compactMap { $0.id }
            j += 1
        }
        while !pending.isEmpty {
            guard j < view.count else { return (false, "msg[\(i)]: no result for \(pending)") }
            let m = view[j]
            guard m.parts.contains(where: { $0.kind == "toolResult" }) else {
                let what = m.parts.first.map { $0.kind == "image" ? "image" : ($0.text.map { String($0.prefix(30)) } ?? $0.kind) } ?? "empty"
                return (false, "msg[\(j)] (\(m.role)) sits between call and result: \(what)")
            }
            var sawOther = false
            for p in m.parts {
                switch p.kind {
                case "toolResult":
                    if provider == .anthropic && sawOther { return (false, "msg[\(j)]: text before tool_result") }
                    if let idx = pending.firstIndex(of: p.id ?? "") { pending.remove(at: idx) }
                case "image" where p.inToolResult:
                    break
                default:
                    sawOther = true
                }
            }
            j += 1
        }
        i = j
    }
    return (true, "")
}

// MARK: - Stable JSON for golden snapshots

/// Strips per-run noise: UUIDs, unix timestamps (9+ digits), temp roots.
func normalized(_ s: String) -> String {
    var t = s
    t = t.replacingOccurrences(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, with: "<uuid>", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\d{9,}"#, with: "<ts>", options: .regularExpression)
    t = t.replacingOccurrences(of: HarnessEnv.root.path, with: "<root>")
    return t
}

func excerpt(_ s: String) -> [String: Any] {
    let n = normalized(s)
    return ["chars": s.count, "head": String(n.prefix(160)), "tail": n.count > 160 ? String(n.suffix(60)) : "",
            "sha8": String(sha256(Data(n.utf8)).prefix(8))]
}

func viewJSON(_ view: [RVMessage]) -> [[String: Any]] {
    view.map { m in
        ["role": m.role, "parts": m.parts.map { p -> [String: Any] in
            var d: [String: Any] = ["kind": p.kind]
            if let t = p.text { d["text"] = excerpt(t) }
            if let id = p.id { d["id"] = normalized(id) }
            if let n = p.name { d["name"] = n }
            if p.inToolResult { d["inToolResult"] = true }
            if let i = p.image {
                d["image"] = ["w": i.w, "h": i.h, "mime": i.mime, "fmt": i.fmt, "bytes": i.bytes, "base64Len": i.base64Len,
                              "sha256": String(i.sha256.prefix(16))]
            }
            return d
        }]
    }
}
#endif
