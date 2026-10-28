//
//  ChatSearchDebugRPC.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] DEBUG builds only: `debug.chatSearch` drives the search
//  of the chat on screen (open / query / next / previous / done / state) for
//  on-device tests, and `action=spike` checks the one assumption the feature
//  rests on - that the text worked out from a reply's markdown
//  (ChatSearchMarkdownText) is the text its cell renders (ChatSearchComposite
//  over MarkdownNSRenderer's output) - over every text block of the chat.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

#if DEBUG
import Foundation
import UIKit

@MainActor
enum ChatSearchDebugRPC {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handle(_ params: [String: Any]) async throws -> [String: Any] {
        guard let sid = (params["sessionId"] as? String) ?? AIChatViewModel.activeSessionId,
              let vm = ViewModelCache.shared.get(for: sid) else {
            throw Failure(message: "No chat on screen (pass sessionId)")
        }
        let search = vm.chatSearch
        let action = params["action"] as? String ?? "state"
        switch action {
        case "open":
            search.activate(prefill: params["query"] as? String)
        case "query":
            guard search.isActive else { throw Failure(message: "Search is not open (action=open first)") }
            search.query = params["query"] as? String ?? ""
        case "next":
            search.next()
        case "previous":
            search.previous()
        case "done":
            search.deactivate()
        case "spike":
            return spike(vm, query: params["query"] as? String)
        case "state":
            break
        default:
            throw Failure(message: "Unknown action \(action); use open, query, next, previous, done, state or spike")
        }
        let waitMs = params["waitMs"] as? Int ?? (action == "query" || action == "open" ? 600 : 150)
        if waitMs > 0 { try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000) }
        return state(search, sessionId: sid)
    }

    static func state(_ s: ChatSearchController, sessionId: String) -> [String: Any] {
        var out: [String: Any] = [
            "sessionId": sessionId,
            "active": s.isActive,
            "query": s.query,
            "count": s.matchCount,
            "truncated": s.isTruncated,
            "searching": s.isSearching,
            "counter": ChatSearchNavigation.counterText(index: s.currentIndex, count: s.matchCount, truncated: s.isTruncated),
        ]
        if let i = s.currentIndex { out["currentIndex"] = i }
        if let m = s.currentMatch {
            out["current"] = [
                "messageId": m.key.messageId.uuidString,
                "blockId": m.key.blockId?.uuidString ?? "",
                "field": "\(m.key.field)",
                "ordinal": m.ordinal,
            ] as [String: Any]
        }
        if let n = s.notice { out["notice"] = "\(n)" }
        return out
    }

    /// Renders every assistant text block of the chat the way its cell does
    /// and compares the visible text the cell's highlighter would read with
    /// the text the search worked out from the markdown.
    static func spike(_ vm: AIChatViewModel, query: String?) -> [String: Any] {
        var blocks = 0, identical = 0
        var differing: [[String: Any]] = []
        var features: [String: Int] = [:]
        var countMismatches = 0
        let started = CFAbsoluteTimeGetCurrent()
        for message in vm.messages where message.role == .assistant {
            for block in message.blocks {
                guard case .text = block.kind, !block.content.isEmpty else { continue }
                blocks += 1
                let parsed = block.cachedMarkdown ?? MarkdownContent(prepareMarkdownForRender(block.content))
                for (name, hit) in featureFlags(parsed.blocks) where hit { features[name, default: 0] += 1 }
                let extracted = ChatSearchUnitBuilder.resolveMarkdown(raw: block.content, blocks: parsed.blocks,
                                                                      finalised: true)
                let rendered = ChatSearchComposite.build(renderMarkdownBlocks(parsed.blocks)).text
                if let query, !query.isEmpty {
                    let a = ChatSearchMatcher.count(of: query, in: extracted, limit: 10_000)
                    let b = ChatSearchMatcher.count(of: query, in: rendered, limit: 10_000)
                    if a != b { countMismatches += 1 }
                }
                if extracted == rendered {
                    identical += 1
                    continue
                }
                let e = Array(extracted.utf16), r = Array(rendered.utf16)
                var i = 0
                while i < min(e.count, r.count), e[i] == r[i] { i += 1 }
                func context(_ s: [UInt16]) -> String {
                    let lo = max(0, i - 20), hi = min(s.count, i + 20)
                    return String(utf16CodeUnits: Array(s[lo..<hi]), count: hi - lo)
                }
                if differing.count < 12 {
                    differing.append([
                        "messageId": message.id.uuidString,
                        "blockId": block.id.uuidString,
                        "extractedLength": e.count,
                        "renderedLength": r.count,
                        "firstDifferenceAt": i,
                        "extracted": context(e),
                        "rendered": context(r),
                    ])
                }
            }
        }
        return [
            "textBlocks": blocks,
            "identical": identical,
            "different": blocks - identical,
            "queryCountMismatches": countMismatches,
            "blocksWith": features,
            "examples": differing,
            "ms": Int((CFAbsoluteTimeGetCurrent() - started) * 1000),
        ]
    }

    /// Which constructs a reply uses, so the spike result says what it covered.
    private static func featureFlags(_ blocks: [BlockNode]) -> [String: Bool] {
        var flags: [String: Bool] = [:]
        func inline(_ nodes: [InlineNode]) {
            for n in nodes {
                switch n {
                case .link(_, let ch): flags["link"] = true; inline(ch)
                case .code: flags["inlineCode"] = true
                case .emphasis(let ch), .strong(let ch), .strikethrough(let ch): flags["emphasis"] = true; inline(ch)
                case .image: flags["image"] = true
                case .inlineMath: flags["math"] = true
                default: break
                }
            }
        }
        func walk(_ bs: [BlockNode]) {
            for b in bs {
                switch b {
                case .paragraph(let c), .heading(_, let c): inline(c)
                case .codeBlock: flags["codeBlock"] = true
                case .table: flags["table"] = true
                case .bulletedList, .numberedList, .taskList: flags["list"] = true; walk(b.children)
                case .blockquote: flags["quote"] = true; walk(b.children)
                case .mathBlock: flags["math"] = true
                default: break
                }
            }
        }
        walk(blocks)
        return flags
    }
}
#endif
