// Tests for [T-oauth-callback-double-resume] — OAuthCallbackServer must resume
// its waiter exactly once.
//
// Crash (1.15 build 3, 2 TestFlight events, one iPhone 15, 01:51 and 02:37):
// SIGTRAP in CheckedContinuation.resume(throwing:) from the timeout closure of
// waitForCallback, while the main thread sat in stop() (MCP sign-in defer).
// Sequence reproduced here:
//   1. the accept loop runs ON `queue` and blocks in accept(), so the 300 s
//      timeout (queue.asyncAfter) cannot run while the server listens;
//   2. an error callback (?error=access_denied) resumed the waiter but left
//      `stopped` false;
//   3. the flow threw, its defer called stop(): closing the socket freed the
//      queue, the overdue timeout ran first, saw stopped == false, and resumed
//      the SAME continuation a second time.
//
// Compiles the real OAuthCallbackServer out of ClaudeOAuthManager.swift with
// small stubs, drives it over a real loopback socket, and runs each scenario
// in a child process so a crash shows up as a failed check, not a dead runner.
//
// Standalone: `swift OAuthCallbackServerTests.swift` from this directory.
import Foundation

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}

// OAUTH_SRC overrides the source (e.g. an older revision, to see a check fail).
let srcURL = ProcessInfo.processInfo.environment["OAUTH_SRC"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("../../Providers/Anthropic/OAuth/ClaudeOAuthManager.swift").standardized
guard let full = try? String(contentsOf: srcURL, encoding: .utf8) else { print("❌ cannot read \(srcURL.path)"); exit(1) }
let lines = full.components(separatedBy: "\n")
guard let start = lines.firstIndex(where: { $0.hasPrefix("struct OAuthCallbackResult") }),
      let cls = lines.firstIndex(where: { $0.hasPrefix("final class OAuthCallbackServer") }),
      let end = lines[cls...].firstIndex(where: { $0 == "}" }) else { print("❌ class not found"); exit(1) }
let classSource = lines[start...end].joined(separator: "\n")

let harness = #"""
import Foundation
enum LLMError: Error { case providerError(message: String) }
struct AppLogger { func info(_ s: String) {}; func error(_ s: String) {}; func warning(_ s: String) {} }
let logger = AppLogger()
"""# + "\n" + classSource + "\n" + #"""

func get(_ port: UInt16, _ path: String) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    let req = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
    _ = req.withCString { write(fd, $0, strlen($0)) }
    var buf = [UInt8](repeating: 0, count: 4096); _ = read(fd, &buf, buf.count); close(fd)
}

let scenario = CommandLine.arguments[1]
let port = UInt16(CommandLine.arguments[2])!
let server = OAuthCallbackServer(port: port)
try! server.start()
let done = DispatchSemaphore(value: 0)
var outcome = "none"
func startWaiting() {
    Task.detached {
        do { let r = try await server.waitForCallback(timeout: 1); outcome = "ok:\(r.code)" }
        catch { outcome = "err:\(error)" }
        done.signal()
    }
}
if scenario == "callbackBeforeWait" {
    // The redirect lands before the flow reaches waitForCallback.
    usleep(100_000)
    get(port, "/callback?code=early&state=s1")
    usleep(200_000)
}
startWaiting()
usleep(200_000)
switch scenario {
case "errorThenLateStop":
    // The crash: error callback, the 1 s timeout falls due while the accept
    // loop holds the queue, then stop() (the flow's defer).
    get(port, "/callback?error=access_denied")
    _ = done.wait(timeout: .now() + 3)
    usleep(1_500_000)
    server.stop()
    usleep(300_000)
case "successThenStop":
    get(port, "/callback?code=abc&state=s1")
    _ = done.wait(timeout: .now() + 3)
    usleep(1_500_000)
    server.stop()
    usleep(300_000)
case "stopWhileWaiting":
    server.stop()
    _ = done.wait(timeout: .now() + 3)
case "callbackBeforeWait":
    _ = done.wait(timeout: .now() + 3)
    server.stop()
default: break
}
print("OUTCOME \(outcome)")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oauthsrv-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try! harness.write(to: mainFile, atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t").path

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

print("▶️  compile the real OAuthCallbackServer")
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-o", bin, mainFile.path])
check("compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }

print("▶️  scenarios (each in its own process)")
var port: UInt16 = 48_700 + UInt16.random(in: 0..<500)
func scenario(_ name: String) -> (Int32, String) {
    port += 1
    return run(bin, [name, String(port)])
}
let (s1, o1) = scenario("errorThenLateStop")
check("error callback, overdue timeout, then stop(): no crash (was SIGTRAP double resume)", s1 == 0)
if s1 != 0 { print("     exit \(s1): \(o1.split(separator: "\n").filter { $0.contains("Fatal") || $0.contains("OUTCOME") || $0.contains("resume") }.prefix(3).joined(separator: " | "))") }
check("…and the waiter got the callback's error, once", o1.contains("OUTCOME err:") && o1.contains("access_denied"))
let (s2, o2) = scenario("successThenStop")
check("success callback, then stop(): no crash, code delivered", s2 == 0 && o2.contains("OUTCOME ok:abc"))
let (s3, o3) = scenario("stopWhileWaiting")
check("stop() while waiting: no crash, waiter cancelled", s3 == 0 && o3.contains("OUTCOME err:") && o3.contains("cancelled"))

let (s4, o4) = scenario("callbackBeforeWait")
check("callback before the flow waits: delivered, not lost (was: hang until stop)", s4 == 0 && o4.contains("OUTCOME ok:early"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
