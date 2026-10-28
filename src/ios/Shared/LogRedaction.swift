import Foundation

/// [T-log-redaction] What may reach a log line from a request: a body is reduced
/// to its size and a short head, a secret to its length.
///
/// The Debug log used to carry pretty-printed request bodies (up to 2,000-3,000
/// characters of chat history, tool output and system prompt per request) and
/// the first 16-20 characters of OAuth access tokens / API keys - one day of
/// logs was 73 MB with token prefixes in it, and those logs get exported and
/// shared. Pretty-printing multi-MB bodies for the log also cost memory on the
/// send path.
enum LogRedaction {
    /// How much of a request body's head a log line keeps.
    static let bodyHeadChars = 160

    /// A secret reduced to its length.
    static func secret(_ value: String) -> String {
        "<redacted len=\(value.count)>"
    }

    /// Header names whose values are credentials.
    static func isSecretHeader(_ name: String) -> Bool {
        let n = name.lowercased()
        if n == "authorization" || n == "proxy-authorization" || n == "cookie" || n == "set-cookie" {
            return true
        }
        return n.contains("api-key") || n.contains("apikey") || n.contains("token")
            || n.contains("secret") || n.contains("session-key")
    }

    /// `name: value`, with a credential's value replaced by its length.
    static func headerLine(_ name: String, _ value: String) -> String {
        "\(name): \(isSecretHeader(name) ? secret(value) : value)"
    }

    /// `N bytes, head: …` - the body's size and its first `bodyHeadChars`
    /// characters on one line, with token-looking strings scrubbed.
    static func bodySummary(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "0 bytes" }
        let headBytes = data.prefix(bodyHeadChars * 4)
        var head = String(decoding: headBytes, as: UTF8.self)
        if head.count > bodyHeadChars { head = String(head.prefix(bodyHeadChars)) }
        head = scrubTokens(head)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let more = data.count > headBytes.count || head.count >= bodyHeadChars ? "…" : ""
        return "\(data.count) bytes, head: \(head)\(more)"
    }

    private static let tokenPatterns: [(NSRegularExpression, String)] = {
        // Bearer first: its token may itself be an sk- key, and scrubbing that
        // first would leave "Bearer sk-***" for the second rule to half-eat.
        let specs: [(String, String)] = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer ***"),
            (#"sk-[A-Za-z0-9_\-]{4,}"#, "sk-***"),
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }()

    /// Replaces API-key / bearer-token looking strings.
    static func scrubTokens(_ text: String) -> String {
        var out = text
        for (regex, template) in tokenPatterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }

    // MARK: - Export sanitising [T-crash-diag-export]

    private static let exportPatterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // A whole Authorization header value, in a log line or JSON.
            (#"(?i)("?(?:proxy-)?authorization"?\s*[:=]\s*"?)[^"\n]*"#, "$1<redacted>"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer ***"),
            (#"sk-[A-Za-z0-9_\-]{4,}"#, "sk-***"),
            // URL query strings: keep scheme/host/path, drop the parameters.
            (#"(?i)(https?://[^\s?#"'<>]+)\?[^\s"'<>]*"#, "$1?<redacted>"),
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }()

    /// Text leaving the device (crash-diagnostics export, debug.crashDiag.read):
    /// sk- keys, Bearer tokens and Authorization values, URL query parameters
    /// and e-mail addresses are replaced.
    static func sanitizeForExport(_ text: String) -> String {
        var out = text
        for (regex, template) in exportPatterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }

    private static let logEntryStart = try? NSRegularExpression(
        pattern: #"^\[\d\d:\d\d:\d\d\] \d{4}-\d\d-\d\d \d\d:\d\d:\d\d"#)

    /// A log file prepared for export: every entry that printed a request body
    /// keeps its first line (with the byte count) and loses the body lines
    /// that follow, then sanitizeForExport. Logs written before
    /// [T-log-redaction] carried multi-line pretty-printed bodies (chat history,
    /// tool output, system prompt); this strips them without touching other
    /// multi-line entries.
    static func sanitizeLogForExport(_ log: String) -> String {
        var out: [Substring] = []
        var dropping = false
        var dropped = 0
        func flush() {
            if dropped > 0 { out.append("  <request body omitted: \(dropped) lines>") }
            dropped = 0
        }
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let str = String(line)
            let isEntry = logEntryStart?.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil
            if isEntry {
                flush()
                dropping = str.contains("Body (") || str.contains("Full Body") || str.contains("📤 Anthropic Request")
                    || str.contains("Request Body")
                out.append(line)
            } else if dropping {
                dropped += 1
            } else {
                out.append(line)
            }
        }
        flush()
        return sanitizeForExport(out.joined(separator: "\n"))
    }
}
