// [T-image-real-seams] iOS-D: request-body image parser for every provider's
// wire format. Pure Foundation, no app types, so any harness can include it:
// compile it with -D IMAGE_REAL_WIRE (or -D IMAGE_REAL_IOS_D) and call
// `wireImages(_:)` on a parsed JSON body (Data, [String: Any] or [[String: Any]]).
//
// Recognised image carriers:
//   * OpenAI Responses `input_image.image_url` and Chat Completions
//     `image_url.url`: a `data:<mime>;base64,<payload>` string
//   * Gemini / Antigravity `inlineData` / `inline_data` {mimeType, data}
//   * Anthropic `{"type":"image","source":{"type":"base64","media_type","data"}}`
// Each hit is reported with the JSON path it was found at, in document order
// (object keys sorted, so the order is stable across serializers).
//
// Guarded so the MinisTests target (which picks up every .swift under
// MinisTests/) compiles this to nothing.
#if IMAGE_REAL_WIRE || IMAGE_REAL_IOS_D
import Foundation

struct WireImage {
    /// "data-url", "inline-data" or "anthropic-source".
    let carrier: String
    let mimeType: String
    let data: Data
    /// JSON path, e.g. `messages[3].content[0].source`.
    let path: String
    /// Length of the base64 text as sent.
    let base64Length: Int
}

func wireImages(_ body: Any) -> [WireImage] {
    var root: Any = body
    if let data = body as? Data, let json = try? JSONSerialization.jsonObject(with: data) { root = json }
    var found: [WireImage] = []

    func dataURL(_ s: String, _ path: String) {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return }
        let header = s[s.index(s.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return }
        let payload = String(s[s.index(after: comma)...])
        guard let d = Data(base64Encoded: payload) else { return }
        found.append(WireImage(carrier: "data-url", mimeType: String(header.dropLast(7)), data: d,
                               path: path, base64Length: payload.utf8.count))
    }

    func walk(_ v: Any, _ path: String) {
        if let s = v as? String { dataURL(s, path); return }
        if let a = v as? [Any] {
            for (i, x) in a.enumerated() { walk(x, "\(path)[\(i)]") }
            return
        }
        guard let d = v as? [String: Any] else { return }
        for key in ["inlineData", "inline_data"] {
            if let inline = d[key] as? [String: Any], let b64 = inline["data"] as? String,
               let bytes = Data(base64Encoded: b64) {
                let mime = (inline["mimeType"] as? String) ?? (inline["mime_type"] as? String) ?? "?"
                found.append(WireImage(carrier: "inline-data", mimeType: mime, data: bytes,
                                       path: "\(path).\(key)", base64Length: b64.utf8.count))
            }
        }
        if d["type"] as? String == "image", let source = d["source"] as? [String: Any],
           source["type"] as? String == "base64", let b64 = source["data"] as? String,
           let bytes = Data(base64Encoded: b64) {
            found.append(WireImage(carrier: "anthropic-source", mimeType: source["media_type"] as? String ?? "?",
                                   data: bytes, path: "\(path).source", base64Length: b64.utf8.count))
        }
        for key in d.keys.sorted() where !(key == "inlineData" || key == "inline_data" || (key == "source" && d["type"] as? String == "image")) {
            walk(d[key]!, path.isEmpty ? key : "\(path).\(key)")
        }
    }
    walk(root, "")
    return found
}
#endif
