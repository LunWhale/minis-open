//
//  ContentPart+ProviderConversion.swift
//  Minis - chat persistence (Agent/Chat)
//
//  [ContentPart] -> provider wire formats: Anthropic content blocks (with the
//  JSON / media-type helpers, private to this file) and Gemini parts.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

// MARK: - Anthropic Conversion

extension Array where Element == ContentPart {
    /// Convert to Anthropic MessageParameter.Message.Content,
    /// loading media files as base64 via the store.
    func toAnthropicContent(store: ChatStore) async -> MessageParameter.Message.Content {
        var objects: [MessageParameter.Message.Content.ContentObject] = []

        for part in self {
            switch part {
            case .text(let s):
                objects.append(.text(s))

            case .mediaRef(let ref):
                // [T-paste-mediaref] Same gate as toAgentMessage: pasted text
                // is content, not an image, and must never be base64'd as one.
                if PastePlaceholder.isPastedTextRef(ref) {
                    if let data = await store.loadMediaData(ref),
                       let s = String(data: data, encoding: .utf8) {
                        objects.append(.text(s))
                    } else {
                        objects.append(.text(PastePlaceholder.unavailableMarker))
                    }
                } else if let data = await store.loadMediaData(ref) {
                    let base64 = data.base64EncodedString()
                    let mediaType = anthropicMediaType(for: ref.mimeType)
                    objects.append(.image(.init(type: .base64, mediaType: mediaType, data: base64)))
                }

            case .toolUse(let tu):
                let input = parseJSONToDynamicContent(tu.input)
                objects.append(.toolUse(tu.toolUseId, tu.name, input))

            case .toolResult(let tr):
                objects.append(.toolResult(tr.toolUseId, tr.output, isError: !tr.success))
            }
        }

        if objects.count == 1, case .text(let s) = objects[0] {
            return .text(s)
        }
        return .list(objects)
    }
}

private func anthropicMediaType(for mimeType: String) -> MessageParameter.Message.Content.ImageSource.MediaType {
    switch mimeType.lowercased() {
    case "image/png": return .png
    case "image/gif": return .gif
    case "image/webp": return .webp
    default: return .jpeg
    }
}

/// Convert JSON string to Anthropic's DynamicContent input format.
private func parseJSONToDynamicContent(_ json: String) -> MessageResponse.Content.Input {
    guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ["input": .string(json)]
    }
    var result: MessageResponse.Content.Input = [:]
    for (key, value) in dict {
        if let s = value as? String {
            result[key] = .string(s)
        } else if let n = value as? NSNumber {
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                result[key] = .bool(n.boolValue)
            } else {
                result[key] = .integer(n.intValue)
            }
        }
    }
    return result
}

func parseJSONToDict(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return dict
}

// MARK: - Gemini Conversion

extension Array where Element == ContentPart {
    /// Convert to Gemini parts array [[String: Any]],
    /// loading media files as base64 via the store.
    func toGeminiParts(store: ChatStore) async -> [[String: Any]] {
        var parts: [[String: Any]] = []

        for part in self {
            switch part {
            case .text(let s):
                parts.append(["text": s])

            case .mediaRef(let ref):
                // [T-paste-mediaref] Pasted text inlines as a text part.
                if PastePlaceholder.isPastedTextRef(ref) {
                    if let data = await store.loadMediaData(ref),
                       let s = String(data: data, encoding: .utf8) {
                        parts.append(["text": s])
                    } else {
                        parts.append(["text": PastePlaceholder.unavailableMarker])
                    }
                } else if let data = await store.loadMediaData(ref) {
                    let base64 = data.base64EncodedString()
                    parts.append([
                        "inlineData": [
                            "mimeType": ref.mimeType,
                            "data": base64,
                        ]
                    ])
                }

            case .toolUse(let tu):
                let args = parseJSONToDict(tu.input)
                parts.append(GeminiConversation.functionCallPart(
                    name: tu.name, args: args
                ))

            case .toolResult(let tr):
                var response: [String: Any] = [
                    "output": tr.output,
                    "success": tr.success,
                ]
                if let ref = tr.mediaRef, let data = await store.loadMediaData(ref) {
                    response["image_base64"] = data.base64EncodedString()
                    response["image_mime_type"] = ref.mimeType
                }
                parts.append(GeminiConversation.functionResponsePart(
                    name: "", response: response
                ))
            }
        }

        return parts
    }
}
