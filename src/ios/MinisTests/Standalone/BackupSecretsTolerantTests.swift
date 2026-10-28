// Tests for [T-backup-secrets-tolerant] — a backup's secrets.json from an
// Android phone omits empty sections (kotlinx does not encode default values),
// e.g. no `mcpOAuth` key when the phone has no MCP OAuth tokens. iOS must read
// it anyway; before, the whole file failed to decode and no credential or
// environment-variable value was restored. Compiles the REAL BackupSecrets out
// of Agent/Backup/BackupSecrets.swift.
//
// Standalone: `swift BackupSecretsTolerantTests.swift` from this directory.
import Foundation

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
let src = (try? String(contentsOfFile: root + "Agent/Backup/BackupSecrets.swift", encoding: .utf8)) ?? ""
guard let s = src.range(of: "struct BackupSecrets: Codable {"),
      let e = src.range(of: "// END BackupSecretsShape", range: s.upperBound..<src.endIndex) else {
    print("❌ BackupSecrets not found"); exit(1)
}
let harness = "import Foundation\n" + String(src[s.lowerBound..<e.lowerBound]) + #"""
func dec(_ j: String) -> BackupSecrets? { try? JSONDecoder().decode(BackupSecrets.self, from: Data(j.utf8)) }
// Android package as written by the real exporter for a phone with env vars only
let android = dec(#"{"v":1,"providers":[],"envVars":[{"name":"ZZ_ON","value":"YQ=="}]}"#)
print("androidNoMcp=\(android != nil && android!.envVars.count == 1 && android!.mcpOAuth.isEmpty)")
let sparse = dec(#"{"envVars":[{"name":"A","value":"YQ=="}]}"#)
print("onlyEnvVars=\(sparse != nil && sparse!.v == 1 && sparse!.providers.isEmpty && sparse!.envVars.count == 1)")
let empty = dec("{}")
print("emptyObject=\(empty != nil && empty!.envVars.isEmpty)")
var full = BackupSecrets(); full.envVars = [.init(name: "B", value: "Yg==")]
let back = dec(String(data: try! JSONEncoder().encode(full), encoding: .utf8)!)
print("iosRoundTrip=\(back != nil && back!.envVars.first?.name == "B")")
print("badStillFails=\(dec(#"{"envVars":"nope"}"#) == nil)")
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bst-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("BackupSecrets compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])
func ok(_ k: String) -> Bool { o.contains("\(k)=true") }
check("Android package without mcpOAuth decodes (env var values kept)", ok("androidNoMcp"))
check("only envVars present: v defaults to 1, other sections empty", ok("onlyEnvVars"))
check("an empty object decodes to empty sections", ok("emptyObject"))
check("iOS-written secrets still round-trip", ok("iosRoundTrip"))
check("a malformed section still fails (tolerance is for MISSING keys only)", ok("badStillFails"))
print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
