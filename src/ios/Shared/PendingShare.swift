import Foundation

/// Describes content shared into the app via the Share Extension.
/// Encoded to JSON and stored in the App Group UserDefaults.
struct PendingShare: Codable, Equatable {
    let items: [Item]
    let timestamp: Date

    struct Item: Codable, Equatable {
        let kind: Kind
        /// For `.inlineText`: the text/URL content. For `.attachment`: the filename in the shared container.
        let value: String

        enum Kind: String, Codable {
            case inlineText
            case attachment
        }
    }
}

// BEGIN ShareItemRules
/// [T-share-one-link] What one share turns into, decided in one place for the
/// extension and the app.
///
/// Sharing a web page from Safari hands the extension more than one item
/// provider for the same page: the page URL, and (seen in the field, iOS 27) a
/// plain-text provider whose whole content is another address of that page.
/// Each provider used to become its own line, so the composer got two links:
///     https://buzzkit.dev/buzz.html
///     https://buzzkit.dev/buzz?t=6
/// Pure: no providers, no files - the callers pass in what they loaded.
enum ShareItemRules {
    /// One value loaded from one item provider.
    struct Candidate: Equatable {
        enum Source: Equatable {
            /// A `public.url` provider that returned a web (non-file) URL.
            case webURL
            /// A plain-text provider.
            case text
            /// Anything saved as a file (image, video, document, long text).
            case attachment
        }
        let source: Source
        /// The URL string, the text, or the attachment's file name.
        let value: String
        /// Which NSExtensionItem it came from. Providers of one item describe
        /// the same shared thing; different items are different things.
        let group: Int
    }

    /// The http(s) URL `text` consists of, when it is nothing but one URL.
    /// A sentence that contains a link, a title, or two links is not one.
    static func soleWebURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func host(_ url: URL) -> String {
        var h = (url.host ?? "").lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// What to keep of one share's candidates, in order:
    /// - a text that is only a web address on the same host as a web URL of
    ///   the SAME extension item is another form of that page and is dropped;
    ///   the URL the host app declared as the page's URL stays;
    /// - anything identical (same kind, same value) to an earlier item is
    ///   dropped;
    /// - real text (a title, a selection, a sentence with a link), a link to
    ///   another host, and every attachment are kept.
    static func reduce(_ candidates: [Candidate]) -> [Candidate] {
        var pageHostsByGroup: [Int: Set<String>] = [:]
        for c in candidates where c.source == .webURL {
            if let url = URL(string: c.value) { pageHostsByGroup[c.group, default: []].insert(host(url)) }
        }
        var kept: [Candidate] = []
        for c in candidates {
            if c.source == .text, let url = soleWebURL(in: c.value),
               pageHostsByGroup[c.group]?.contains(host(url)) == true {
                continue
            }
            let isAttachment = c.source == .attachment
            let duplicate = kept.contains {
                ($0.source == .attachment) == isAttachment
                    && $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        == c.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if duplicate { continue }
            kept.append(c)
        }
        return kept
    }

    /// `existing` followed by the items of `new` it does not already hold.
    static func merge(existing: [PendingShare.Item], new: [PendingShare.Item]) -> [PendingShare.Item] {
        var merged = existing
        for item in new where !merged.contains(where: { $0.kind == item.kind && $0.value == item.value }) {
            merged.append(item)
        }
        return merged
    }

    /// Whether a shared text should be added to a composer that holds
    /// `composerText`: not when that exact text is already one of its lines.
    static func shouldInject(_ text: String, into composerText: String) -> Bool {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return !composerText.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == wanted }
    }

    /// How the extension ends its request.
    enum Finish: Equatable {
        /// Nothing usable was shared: cancel, do not open the app.
        case cancel
        /// Content was saved: open the app, then complete.
        case openAppThenComplete
    }

    static func finish(savedItemCount: Int) -> Finish {
        savedItemCount > 0 ? .openAppThenComplete : .cancel
    }
}
// END ShareItemRules
