// [T-anthropic-inner-session-timeout] Guards the idle timeout of the real
// network request made by the Anthropic URLProtocols.
//
// Report: a custom anthropic-type provider (Volcengine Ark, reasoning model
// `ark-code-latest`) failed with "request timed out" on hard prompts while the
// server answered 200 after 120-220 s with no bytes before that.
//
// Root cause: the outer HTTPClient sessions set timeoutIntervalForRequest =
// 600, but OAuthURLProtocol / EagerStreamingURLProtocol / DualAuthURLProtocol
// re-issue every request on their own inner session, which was built from a
// `.default` configuration (60 s). SwiftAnthropic never sets
// URLRequest.timeoutInterval, so nothing else raised it.
//
//   A. Mechanism (Foundation behaviour this fix depends on): with an outer
//      session carrying a long timeout and a URLProtocol that re-sends on an
//      inner session, the INNER session's timeoutIntervalForRequest decides
//      when the request fails. Scaled down: outer 30 s, server delay 3 s,
//      inner 1 s -> times out; inner 30 s -> 200.
//   B. Source invariant: every inner protocol session in OAuthHTTPClient.swift
//      goes through makeInnerProtocolSession, which applies the long timeout.
//
// Standalone: `swift AnthropicInnerSessionTimeoutTests.swift` (needs python3
// for the local delay server).

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

// MARK: - A. Mechanism

final class InnerProtocol: URLProtocol, URLSessionDataDelegate {
    nonisolated(unsafe) static var innerTimeout: TimeInterval = 60
    lazy var inner: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = InnerProtocol.innerTimeout
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    override class func canInit(with request: URLRequest) -> Bool {
        URLProtocol.property(forKey: "InnerHandled", in: request) == nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "InnerHandled", in: mutable)
        inner.dataTask(with: mutable as URLRequest).resume()
    }
    override func stopLoading() {}
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
}

let port = 18000 + Int.random(in: 0..<1000)
let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
server.arguments = ["python3", "-c", """
import http.server, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0)))
        time.sleep(3)
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', \(port)), H).serve_forever()
"""]
// Detach the child's stdio: an inherited pipe keeps a `| tail` caller waiting.
server.standardOutput = FileHandle.nullDevice
server.standardError = FileHandle.nullDevice
try server.run()
Thread.sleep(forTimeInterval: 1.0)

/// Outer session mirrors EagerStreamingHTTPClient: long timeout + protocol.
/// The request mirrors SwiftAnthropic: timeoutInterval left at its default.
func run(innerTimeout: TimeInterval) -> Result<Int, NSError> {
    InnerProtocol.innerTimeout = innerTimeout
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.protocolClasses = [InnerProtocol.self]
    let session = URLSession(configuration: config)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    var result: Result<Int, NSError> = .failure(NSError(domain: "unset", code: 0))
    let done = DispatchSemaphore(value: 0)
    session.dataTask(with: request) { _, response, error in
        if let error { result = .failure(error as NSError) }
        else { result = .success((response as? HTTPURLResponse)?.statusCode ?? -1) }
        done.signal()
    }.resume()
    done.wait()
    session.invalidateAndCancel()
    return result
}

print("A. Inner protocol session decides the timeout")
if case .failure(let e) = run(innerTimeout: 1) {
    check("inner 1s < server 3s -> NSURLErrorTimedOut despite outer 30s (got \(e.code))",
          e.domain == NSURLErrorDomain && e.code == NSURLErrorTimedOut)
} else {
    check("inner 1s < server 3s -> NSURLErrorTimedOut despite outer 30s (got success)", false)
}
if case .success(let status) = run(innerTimeout: 30) {
    check("inner 30s > server 3s -> 200 (got \(status))", status == 200)
} else {
    check("inner 30s > server 3s -> 200 (got failure)", false)
}

// MARK: - B. Source invariant

let root = FileManager.default.currentDirectoryPath
func source(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: root)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent("src/ios/" + rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("source not found: \(rel)")
}

print("B. OAuthHTTPClient.swift inner sessions")
let client = source("Providers/Anthropic/OAuthHTTPClient.swift")
check("no inner session built on a bare .default configuration",
      !client.contains("URLSession(configuration: .default, delegate:"))
check("all three URLProtocols use makeInnerProtocolSession",
      client.components(separatedBy: "innerSession: URLSession = makeInnerProtocolSession(delegate: self)").count - 1 == 3)
check("makeInnerProtocolSession applies anthropicRequestIdleTimeout",
      client.contains("config.timeoutIntervalForRequest = anthropicRequestIdleTimeout\n    return URLSession(configuration: config, delegate: delegate"))
if let range = client.range(of: #"let anthropicRequestIdleTimeout: TimeInterval = (\d+)"#, options: .regularExpression),
   let value = Int(client[range].split(separator: "=").last!.trimmingCharacters(in: .whitespaces)) {
    check("idle timeout covers a 220s reasoning TTFB with margin (\(value)s >= 300s)", value >= 300)
} else {
    check("anthropicRequestIdleTimeout declared", false)
}

// Explicit, not `defer`: top-level defer does not run on exit().
server.terminate()
server.waitUntilExit()
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
