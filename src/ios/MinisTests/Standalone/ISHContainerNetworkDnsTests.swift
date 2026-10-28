#!/usr/bin/env swift
// [T-container-network-dns GH#396] Shell Container DNS: Auto (system, default)
// or Custom (user's servers, kept across network changes).
//
// Compiles, from the shipping sources:
//   - the `ContainerDnsSettings` block of Shared/NetworkMonitor.swift
//     (parsing, IPv4/IPv6 validation, resolv.conf, auto/custom decision),
//   - Shared/Config/ConfigField.swift, ConfigError.swift, Fields/ClosureField.swift,
//   - the `registerNetwork` block of Shared/Config/ConfigRegistry+Builtins.swift,
// with stubs for ConfigRegistry (collects fields) and ISHKernel (counts
// refreshDns), then drives the fields exactly as `minis-config get/set` does:
// ConfigValue.decode(cliValue:for:) → normalizeForWrite → validateForWrite →
// write → read.
//
// Run: swift ISHContainerNetworkDnsTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.lowerBound..<r2.upperBound])
}

let monitor = source("Shared/NetworkMonitor.swift")
let builtins = source("Shared/Config/ConfigRegistry+Builtins.swift")
guard let dnsBlock = between(monitor, "// BEGIN ContainerDnsSettings", "// END ContainerDnsSettings"),
      let netBlock = between(builtins, "// BEGIN registerNetwork", "// END registerNetwork") else {
    print("❌ marked blocks not found"); exit(1)
}

let stubs = """
import Foundation
@MainActor final class ConfigRegistry {
    var fields: [String: ConfigField] = [:]
    func register(_ field: ConfigField) { fields[field.path] = field }
}
final class ISHKernel {
    static let shared = ISHKernel()
    var refreshCount = 0
    func refreshDns() { refreshCount += 1 }
}
extension ConfigRegistry {
\(netBlock)
    @MainActor static func testRegisterNetwork(into r: ConfigRegistry) { registerNetwork(into: r) }
}
"""

let harness = #"""
import Foundation
func out(_ k: String, _ v: Any) { print("\(k)=\(v)") }
func j(_ v: ConfigValue) -> String { v.jsonString() }

let D = ContainerDnsSettings.self
// ---- parsing / validation
let p1 = D.parse("8.8.8.8\n 1.1.1.1 , 2001:4860:4860:0:0:0:0:8888;fe80::1%en0\ndns.google 8.8.8.8 256.1.1.1 [::1] 1.1.1.1:53 10.0.0")
out("P1_SERVERS", p1.servers.joined(separator: " "))
out("P1_INVALID", p1.invalid.joined(separator: " "))
out("CANON_V4", D.canonicalAddress("10.0.0.1") ?? "nil")
out("CANON_V6", D.canonicalAddress("2001:0DB8:0000:0000:0000:0000:0000:0001") ?? "nil")
out("CANON_MAPPED", D.canonicalAddress("::ffff:1.2.3.4") ?? "nil")
out("EMPTY", D.parse("  \n,, ;").servers.count + D.parse("  \n,, ;").invalid.count)
// ---- resolv.conf
let conf = D.resolvConf(servers: ["1.1.1.1", "2606:4700:4700::1111"])
out("CONF_NS", conf.split(separator: "\n").filter { $0.hasPrefix("nameserver ") }.joined(separator: "|"))
out("CONF_SEARCH", conf.contains("search") ? 1 : 0)
out("CONF_COMMENTS_OK", conf.split(separator: "\n").allSatisfy { $0.hasPrefix("#") || $0.hasPrefix("nameserver ") } ? 1 : 0)

// ---- auto/custom decision, on an isolated defaults suite
let suite = "dns-test-\(UUID().uuidString)"
let ud = UserDefaults(suiteName: suite)!
out("DEFAULT_MODE", D.mode(ud).rawValue)
out("AUTO_CONF", D.customResolvConf(ud) ?? "nil")
ud.set("custom", forKey: D.modeKey)
out("CUSTOM_EMPTY_CONF", D.customResolvConf(ud) ?? "nil")
ud.set("9.9.9.9\nnot-an-ip\n149.112.112.112", forKey: D.serversKey)
out("CUSTOM_CONF_NS", (D.customResolvConf(ud) ?? "nil").split(separator: "\n").filter { $0.hasPrefix("nameserver") }.joined(separator: "|"))
ud.set("garbage", forKey: D.modeKey)
out("UNKNOWN_MODE", D.mode(ud).rawValue)
UserDefaults().removePersistentDomain(forName: suite)

// ---- minis-config binding (the bridge's sequence)
@MainActor func run() {
    let reg = ConfigRegistry()
    ConfigRegistry.testRegisterNetwork(into: reg)
    out("PATHS", reg.fields.keys.sorted().joined(separator: ","))
    guard let mode = reg.fields["network.dnsMode"], let servers = reg.fields["network.dnsCustomServers"] else { return }
    out("MODE_SCHEMA", mode.valueSchema.helpDescription)
    out("SERVERS_SCHEMA", servers.valueSchema.helpDescription)
    out("RW", "\(mode.access == .readwrite)\(servers.access == .readwrite)")

    UserDefaults.standard.removeObject(forKey: D.modeKey)
    UserDefaults.standard.removeObject(forKey: D.serversKey)

    func cliSet(_ field: ConfigField, _ raw: String) -> String {
        guard let v = ConfigValue.decode(cliValue: raw, for: field.valueSchema) else { return "unparseable" }
        do {
            let n = try field.normalizeForWrite(v)
            try field.validateForWrite(n)
            try field.write(n)
            return "ok " + j(try field.read())
        } catch { return "err \(error)" }
    }
    func cliAppend(_ field: ConfigField, _ raw: String) -> String {
        guard case .array(let elem) = field.valueSchema,
              let v = ConfigValue.decode(cliValue: raw, for: elem) else { return "unparseable" }
        do {
            try elem.validate(v)
            guard case .array(let cur) = try field.read() else { return "not array" }
            let next = ConfigValue.array(cur + [v])
            try field.validateForWrite(next)
            try field.write(next)
            return "ok " + j(try field.read())
        } catch { return "err \(error)" }
    }

    out("GET_MODE_DEFAULT", j(try! mode.read()))
    out("SET_MODE_BARE", cliSet(mode, "custom"))
    out("SET_MODE_JSON", cliSet(mode, "\"auto\""))
    out("SET_MODE_BAD", cliSet(mode, "manual"))
    out("SET_SERVERS_BARE", cliSet(servers, "1.1.1.1,2606:4700:4700:0::1111, 1.1.1.1"))
    out("SET_SERVERS_JSON", cliSet(servers, "[\"8.8.8.8\",\"8.8.4.4\"]"))
    out("SET_SERVERS_QUOTED", cliSet(servers, "\"9.9.9.9\\n149.112.112.112\""))
    out("SET_SERVERS_BAD", cliSet(servers, "8.8.8.8,dns.google"))
    out("SET_SERVERS_BAD_JSON_ELEM", cliSet(servers, "[\"8.8.8.8\", 53]"))
    out("AFTER_BAD_UNCHANGED", j(try! servers.read()))
    out("APPEND_OK", cliAppend(servers, "1.0.0.1"))
    out("APPEND_BAD", cliAppend(servers, "localhost"))
    out("SET_SERVERS_EMPTY", cliSet(servers, "[]"))
    out("REFRESH_COUNT", ISHKernel.shared.refreshCount)
    _ = cliSet(mode, "custom"); _ = cliSet(servers, "10.0.0.53")
    out("END_TO_END_CONF", (D.customResolvConf() ?? "nil").split(separator: "\n").filter { $0.hasPrefix("nameserver") }.joined(separator: "|"))
    UserDefaults.standard.removeObject(forKey: D.modeKey)
    UserDefaults.standard.removeObject(forKey: D.serversKey)
}
MainActor.assumeIsolated { run() }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dns-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files: [(String, String)] = [
    ("dns.swift", "import Foundation\n" + dnsBlock),
    ("ConfigField.swift", source("Shared/Config/ConfigField.swift")),
    ("ConfigError.swift", source("Shared/Config/ConfigError.swift")),
    ("ClosureField.swift", source("Shared/Config/Fields/ClosureField.swift")),
    // [T-config-readable] ConfigField now requires a ConfigReadable.
    ("ConfigReadable.swift", source("Shared/Config/Readable/ConfigReadable.swift")),
    ("stubs.swift", stubs),
    ("main.swift", harness),
]
for (name, text) in files { try text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
check("shipping DNS + config sources compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("harness ran", rc == 0)
if rc != 0 { print(out) }
var r: [String: String] = [:]
for line in out.split(separator: "\n") {
    let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("\n1. Parsing and validation")
check("valid IPv4/IPv6 kept in order, canonical, de-duplicated: \(r["P1_SERVERS"] ?? "")",
      r["P1_SERVERS"] == "8.8.8.8 1.1.1.1 2001:4860:4860::8888")
check("rejects zone ids, hostnames, out-of-range, brackets, ports, short IPv4: \(r["P1_INVALID"] ?? "")",
      r["P1_INVALID"] == "fe80::1%en0 dns.google 256.1.1.1 [::1] 1.1.1.1:53 10.0.0")
check("IPv4 canonical", r["CANON_V4"] == "10.0.0.1")
check("IPv6 canonical (lower-case, compressed)", r["CANON_V6"] == "2001:db8::1")
check("IPv4-mapped IPv6 accepted", r["CANON_MAPPED"] == "::ffff:1.2.3.4")
check("separators only → nothing", r["EMPTY"] == "0")

print("\n2. resolv.conf")
check("one nameserver line per address, in order", r["CONF_NS"] == "nameserver 1.1.1.1|nameserver 2606:4700:4700::1111")
check("no search line in custom mode", r["CONF_SEARCH"] == "0")
check("only comments and nameserver lines", r["CONF_COMMENTS_OK"] == "1")

print("\n3. Auto / custom decision")
check("default mode is auto", r["DEFAULT_MODE"] == "auto")
check("auto → nil (kernel keeps the system-DNS path)", r["AUTO_CONF"] == "nil")
check("custom without servers falls back to auto (never an empty resolv.conf)", r["CUSTOM_EMPTY_CONF"] == "nil")
check("custom uses only valid saved servers (bad stored line dropped)",
      r["CUSTOM_CONF_NS"] == "nameserver 9.9.9.9|nameserver 149.112.112.112")
check("unknown stored mode reads as auto", r["UNKNOWN_MODE"] == "auto")

print("\n4. minis-config binding")
check("both paths registered: \(r["PATHS"] ?? "")", r["PATHS"] == "network.dnsCustomServers,network.dnsMode")
check("mode schema is the enum auto|custom (\(r["MODE_SCHEMA"] ?? ""))", (r["MODE_SCHEMA"] ?? "").contains("auto") && (r["MODE_SCHEMA"] ?? "").contains("custom"))
check("servers schema is an array of strings (\(r["SERVERS_SCHEMA"] ?? ""))", r["SERVERS_SCHEMA"] == "[string max 64 chars]")
check("both read-write", r["RW"] == "truetrue")
check("get network.dnsMode defaults to \"auto\"", r["GET_MODE_DEFAULT"] == "\"auto\"")
check("set network.dnsMode custom (bare word)", r["SET_MODE_BARE"] == "ok \"custom\"")
check("set network.dnsMode '\"auto\"' (JSON)", r["SET_MODE_JSON"] == "ok \"auto\"")
check("set network.dnsMode manual → rejected: \(r["SET_MODE_BAD"] ?? "")", (r["SET_MODE_BAD"] ?? "").hasPrefix("err"))
check("set servers as a bare comma list → canonical array, duplicate dropped: \(r["SET_SERVERS_BARE"] ?? "")",
      r["SET_SERVERS_BARE"] == "ok [\"1.1.1.1\",\"2606:4700:4700::1111\"]")
check("set servers as a JSON array", r["SET_SERVERS_JSON"] == "ok [\"8.8.8.8\",\"8.8.4.4\"]")
check("set servers as a quoted newline list", r["SET_SERVERS_QUOTED"] == "ok [\"9.9.9.9\",\"149.112.112.112\"]")
check("a hostname is rejected BEFORE writing, naming it: \(r["SET_SERVERS_BAD"] ?? "")",
      (r["SET_SERVERS_BAD"] ?? "").hasPrefix("err") && (r["SET_SERVERS_BAD"] ?? "").contains("dns.google"))
check("a non-string array element is rejected", (r["SET_SERVERS_BAD_JSON_ELEM"] ?? "").hasPrefix("err"))
check("a rejected set leaves the saved list unchanged", r["AFTER_BAD_UNCHANGED"] == "[\"9.9.9.9\",\"149.112.112.112\"]")
check("set …dnsCustomServers.append 1.0.0.1 (bare)", r["APPEND_OK"] == "ok [\"9.9.9.9\",\"149.112.112.112\",\"1.0.0.1\"]")
check("append of a non-address is rejected", (r["APPEND_BAD"] ?? "").hasPrefix("err"))
check("set [] clears the list", r["SET_SERVERS_EMPTY"] == "ok []")
check("every successful write re-applies DNS (refreshDns called \(r["REFRESH_COUNT"] ?? "?")×)", r["REFRESH_COUNT"] == "7")
check("end to end: mode custom + servers → resolv.conf the kernel writes",
      r["END_TO_END_CONF"] == "nameserver 10.0.0.53")

print("\n5. Wiring in the shipping code")
let kernel = source("iSH/ISHKernel.m")
let bridge = source("NativeOffloads/ConfigOffloadBridge.swift")
let view = source("Views/Rootfs/RootfsManagementView.swift")
check("configureDns asks for the custom config first and returns without reading system DNS",
      kernel.contains("NSString *custom = [MinisContainerDns customResolvConfForKernel];\n    if (custom) {")
      && kernel.contains("[self writeResolvConf:custom];\n        return;"))
check("the bind-mount fallback seeds the custom servers too",
      kernel.contains("NSString *customSeed = [MinisContainerDns customResolvConfForKernel];"))
check("auto path unchanged (system resolver + public fallback)",
      kernel.contains("BOOL initOk = (res_ninit(&res) == 0);") && kernel.contains("[resolvConf appendString:@\"nameserver 8.8.8.8\\n\"];"))
check("network monitor still refreshes on every path update", monitor.contains("ISHKernel.shared.refreshDns()"))
check("registered at launch", builtins.contains("registerNetwork(into: r)"))
check("bridge: bare CLI values + normalize/validate before the confirmation sheet",
      bridge.contains("ConfigValue.decode(cliValue: valueJSON, for: cliSchema)")
      && bridge.contains("newValue = try field.normalizeForWrite(parsedValue)\n                    try field.validateForWrite(newValue)"))
check("Rootfs page has the Container Network section", view.contains("ContainerNetworkSection()") && view.contains("Text(\"Container Network\")"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
