#!/usr/bin/env swift
// [T-log-redaction] Tests for Shared/LogRedaction.swift and its call sites.
//
// Compiles the SHIPPING LogRedaction.swift with swiftc and checks:
//   [1] secrets are reduced to their length; credential headers are recognised
//   [2] a body becomes "N bytes, head: …" - at most bodyHeadChars characters,
//       one line, sk-/Bearer tokens scrubbed, multi-byte text not split
//   [3] source guards: no request-body pretty dump and no token prefix left in
//       the provider log lines that used to print them
//
// Run: swift LogRedactionTests.swift
import Foundation

let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logredact-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let main = tmp.appendingPathComponent("main.swift")
try! #"""
import Foundation
func out(_ k: String, _ v: String) { print("\(k)\t\(v.replacingOccurrences(of: "\n", with: "\\n"))") }
let token = "sk-ant-oat01-ABCDEFGHIJKLMNOPQRSTUV0123456789"
out("SECRET", LogRedaction.secret(token))
out("H_AUTH", LogRedaction.headerLine("Authorization", "Bearer " + token))
out("H_GOOG", LogRedaction.headerLine("x-goog-api-key", "AIzaSyDUMMYKEY0123456789"))
out("H_XAPI", LogRedaction.headerLine("X-Api-Key", "abc123"))
out("H_COOKIE", LogRedaction.headerLine("Cookie", "sid=1"))
out("H_CT", LogRedaction.headerLine("Content-Type", "application/json"))
out("H_UA", LogRedaction.headerLine("User-Agent", "claude-cli/2.1.280"))
let big = "{\"max_tokens\":128000,\"messages\":[{\"role\":\"user\",\"content\":\"" + String(repeating: "x", count: 5000) + "\"}]}"
out("BODY_BIG", LogRedaction.bodySummary(Data(big.utf8)))
out("BODY_SMALL", LogRedaction.bodySummary(Data("{\"a\":1}".utf8)))
out("BODY_NIL", LogRedaction.bodySummary(nil))
let withToken = "{\"auth\":\"Bearer " + token + "\",\n\"k\":\"" + token + "\"}"
out("BODY_TOKEN", LogRedaction.bodySummary(Data(withToken.utf8)))
let cjk = String(repeating: "你好世界", count: 100)
out("BODY_CJK", LogRedaction.bodySummary(Data(cjk.utf8)))
out("SCRUB", LogRedaction.scrubTokens("key sk-proj-abc123XYZ and Bearer eyJhbGciOi.payload.sig end"))
"""#.write(to: main, atomically: true, encoding: .utf8)

let bin = tmp.appendingPathComponent("redact").path
let (cs, co) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, ios.appendingPathComponent("Shared/LogRedaction.swift").path, main.path])
guard cs == 0 else { print("❌ compile failed:\n\(co)"); exit(1) }
let (_, out) = run(bin, [])
var r: [String: String] = [:]
for line in out.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1)
    if parts.count == 2 { r[String(parts[0])] = String(parts[1]) }
}
let token = "ABCDEFGHIJKLMNOPQRSTUV0123456789"

print("▶️  1. secrets and headers")
check("a secret is its length only", r["SECRET"] == "<redacted len=45>")
check("Authorization carries no token", r["H_AUTH"] == "Authorization: <redacted len=52>")
check("x-goog-api-key / X-Api-Key / Cookie are credentials",
      r["H_GOOG"]?.contains("<redacted len=") == true && r["H_XAPI"] == "X-Api-Key: <redacted len=6>" && r["H_COOKIE"] == "Cookie: <redacted len=5>")
check("ordinary headers pass through", r["H_CT"] == "Content-Type: application/json" && r["H_UA"] == "User-Agent: claude-cli/2.1.280")
print("▶️  2. bodies")
let bigHead = r["BODY_BIG"] ?? ""
check("a large body is its size and a capped head", bigHead.hasPrefix("5063 bytes, head: {\"max_tokens\":128000") && bigHead.hasSuffix("…"))
check("…no more than 160 characters of it", (bigHead.components(separatedBy: "head: ").last ?? "").count <= 161)
check("a small body is shown whole, no ellipsis", r["BODY_SMALL"] == "7 bytes, head: {\"a\":1}")
check("no body", r["BODY_NIL"] == "0 bytes")
let tok = r["BODY_TOKEN"] ?? ""
check("tokens inside the head are scrubbed, on one line", !tok.contains(token) && tok.contains("Bearer ***\"") && !tok.contains("Bearer ******") && tok.contains("sk-***") && !tok.contains("\\n"))
let cjk = r["BODY_CJK"] ?? ""
check("multi-byte text is cut by characters, not mid-byte", cjk.hasPrefix("1200 bytes, head: 你好世界") && !cjk.contains("\u{FFFD}"))
check("scrubTokens covers sk- keys and bearer tokens", r["SCRUB"] == "key sk-*** and Bearer *** end")

print("▶️  3. source guards")
let oauth = source("Providers/Anthropic/OAuthHTTPClient.swift")
check("URLProtocol: no token prefix in 'Set Bearer token'", !oauth.contains("Set Bearer token (prefix:") && oauth.contains("Set Bearer token (len="))
check("URLProtocol: headers go through LogRedaction.headerLine", oauth.contains("LogRedaction.headerLine(key, headers[key] ?? \"\")")
      && !oauth.contains("value.dropFirst(min(7, value.count)).prefix(16)"))
check("URLProtocol: body log is a summary", oauth.contains("[URLProtocol] Body: \\(LogRedaction.bodySummary(capturedBody))")
      && !oauth.contains("formatted.prefix(2000)"))
let anth = source("Providers/Anthropic/AnthropicProvider.swift")
check("Anthropic request log: no 'Full Body' dump", !anth.contains("parts.append(\"  Full Body:\")") && anth.contains("LogRedaction.bodySummary(encodedParameter)"))
let gem = source("Providers/Gemini/GeminiProvider.swift")
check("Gemini request log: headers redacted, body summarised", gem.contains("LogRedaction.headerLine(key, value)") && gem.contains("LogRedaction.bodySummary(body)"))
for (file, needle) in [("Providers/Gemini/GeminiModelsAPI.swift", "oauthToken.prefix(20)"),
                       ("Providers/OpenRouter/OAuth/OpenRouterOAuthManager.swift", "apiKey.prefix(16)"),
                       ("Providers/Anthropic/OAuth/ClaudeOAuthManager.swift", "accessToken.prefix(16)"),
                       ("Providers/OpenAI/OpenAIProvider.swift", "token.prefix(12)")] {
    check("\(file.split(separator: "/").last!): no token prefix logged", !source(file).contains(needle))
}

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)\n\(out)")
exit(failures == 0 ? 0 : 1)
