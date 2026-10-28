// [T-ios-aojit] AOJIT: AOT images of the ARM64 JIT linked into the app,
// switched from Rootfs Management (off by default).
//
//   [1] build-id probe: reads NT_GNU_BUILD_ID from a guest file's PT_NOTE
//       (the port below is checked verbatim against AOJITSettingsView.swift).
//   [2] runtime report parsing (jit_describe / /proc/ish/jit format).
//   [3] the in-app catalog matches deps/aot/README.md: one image per module
//       with its family pattern ([T-aojit-family]); the probe takes the
//       recorded build-id first, then the family.
//   [3b] a Fix (apk add) only runs after the confirmation dialog.
//   [3c] plan B: a core package with no matching image can be restored to
//        the bundled build, behind a warning, with the bundled r8 packages.
//   [3e] the screen explains full / partial (family) / no image.
//   [4] wiring: default off, applied before the first guest process, AOT-only
//       libish, the archive force-loaded in both configurations.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift AOJITTests.swift`

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repo = ios.deletingLastPathComponent().deletingLastPathComponent()
func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
let view = read(ios.appendingPathComponent("Views/Rootfs/AOJITSettingsView.swift"))
let kernel = read(ios.appendingPathComponent("iSH/ISHKernel.m"))
let pbx = read(ios.appendingPathComponent("Minis.xcodeproj/project.pbxproj"))
let buildIsh = read(repo.appendingPathComponent("deps/build_ish.sh"))
let buildAot = read(repo.appendingPathComponent("deps/build_aot.sh"))
let readme = read(repo.appendingPathComponent("deps/aot/README.md"))
let gitignore = read(repo.appendingPathComponent(".gitignore"))
check("sources found", !view.isEmpty && !kernel.isEmpty && !pbx.isEmpty && !buildIsh.isEmpty && !buildAot.isEmpty && !readme.isEmpty)

// MARK: - [1] build-id probe

print("\n▶️  1. ELF build-id probe")
/// Verbatim port of AOJITModuleProbe.buildId(inELF:).
func buildId(inELF d: Data) -> String? {
        let b = [UInt8](d)
        guard b.count >= 64, b[0] == 0x7f, b[1] == 0x45, b[2] == 0x4c, b[3] == 0x46, b[4] == 2 else { return nil }
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? (0..<4).reduce(0) { $0 | Int(b[o + $1]) << (8 * $1) } : 0 }
        func u64(_ o: Int) -> Int { o + 8 <= b.count ? (0..<8).reduce(0) { $0 | Int(b[o + $1]) << (8 * $1) } : 0 }
        let phoff = u64(0x20), phentsize = u16(0x36), phnum = u16(0x38)
        for i in 0..<phnum {
            let ph = phoff + i * phentsize
            guard u32(ph) == 4 else { continue }  // PT_NOTE
            var off = u64(ph + 8)
            let end = off + u64(ph + 32)
            while off + 12 <= min(end, b.count) {
                let namesz = u32(off), descsz = u32(off + 4), type = u32(off + 8)
                let desc = off + 12 + ((namesz + 3) & ~3)
                if type == 3, namesz == 4, desc + descsz <= b.count,
                   b[off + 12] == 0x47, b[off + 13] == 0x4e, b[off + 14] == 0x55 {  // "GNU"
                    return b[desc..<(desc + descsz)].map { String(format: "%02x", $0) }.joined()
                }
                off = desc + ((descsz + 3) & ~3)
            }
        }
        return nil
}
func functionBody(_ src: String, _ header: String) -> String {
    guard let r = src.range(of: header),
          let end = src.range(of: "\n    }\n", range: r.upperBound..<src.endIndex) else { return "" }
    return String(src[r.lowerBound..<end.upperBound]).filter { !$0.isWhitespace }
}
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
let prodBody = functionBody(view, "static func buildId(inELF d: Data) -> String? {")
let portBody: String = {
    guard let r = me.range(of: "func buildId(inELF d: Data) -> String? {"),
          let e = me.range(of: "\n}\n", range: r.upperBound..<me.endIndex) else { return "" }
    return String(me[r.lowerBound..<e.lowerBound]).filter { !$0.isWhitespace }
}()
check("port is verbatim", !prodBody.isEmpty && prodBody.hasPrefix(String(portBody.dropFirst(0).prefix(40)).replacingOccurrences(of: "func", with: "staticfunc"))
      && prodBody.contains(String(portBody.dropFirst("funcbuildId(inELFd:Data)->String?{".count).prefix(300))))

/// A minimal ELF64 with one PT_NOTE holding an optional extra note, then GNU build-id.
func makeELF(id: [UInt8], leadingNote: Bool = false, gnu: Bool = true) -> Data {
    var notes = [UInt8]()
    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
    if leadingNote {  // an unrelated note (type 1, name "Go\0\0") before the build-id
        notes += le32(4) + le32(4) + le32(1) + Array("Go\0\0".utf8) + [1, 2, 3, 4]
    }
    notes += le32(4) + le32(id.count) + le32(3) + Array((gnu ? "GNU\0" : "XYZ\0").utf8) + id
    var b = [UInt8](repeating: 0, count: 64 + 56)
    b[0] = 0x7f; b[1] = 0x45; b[2] = 0x4c; b[3] = 0x46; b[4] = 2; b[5] = 1
    func put64(_ o: Int, _ v: Int) { for i in 0..<8 { b[o + i] = UInt8((v >> (8 * i)) & 0xff) } }
    func put16(_ o: Int, _ v: Int) { b[o] = UInt8(v & 0xff); b[o + 1] = UInt8(v >> 8) }
    put64(0x20, 64); put16(0x36, 56); put16(0x38, 1)
    let ph = 64
    b[ph] = 4  // PT_NOTE
    put64(ph + 8, 120); put64(ph + 32, notes.count)
    return Data(b + notes)
}
let id = (0..<20).map { UInt8($0 * 7 & 0xff) }
let idHex = id.map { String(format: "%02x", $0) }.joined()
check("reads the GNU build-id", buildId(inELF: makeELF(id: id)) == idHex)
check("skips an unrelated note before it", buildId(inELF: makeELF(id: id, leadingNote: true)) == idHex)
check("a non-GNU note is not a build-id", buildId(inELF: makeELF(id: id, gnu: false)) == nil)
check("not an ELF → nil", buildId(inELF: Data("#!/bin/sh\necho hi\n".utf8)) == nil)
check("truncated file → nil, no crash", buildId(inELF: makeELF(id: id).prefix(80)) == nil)
// Real files from the bundled rootfs when present (gitignored build input).
let rootfs = repo.appendingPathComponent("deps/resources/alpine-rootfs/data")
for (path, want) in [("lib/ld-musl-aarch64.so.1", "384940f9110e809da953d6fbabcb31d297c217b5"),
                     ("bin/busybox", "2f8b429ec88eacccb94c8bb23ec060ab4a028ee8")] {
    if let d = try? Data(contentsOf: rootfs.appendingPathComponent(path)) {
        check("bundled \(path) has the recorded build-id", buildId(inELF: d.prefix(64 * 1024)) == want)
    } else {
        print("  ⚠️  \(path) not present (deps/resources not built) — skipped")
    }
}

// MARK: - [2] runtime report

print("\n▶️  2. runtime report parsing (family format)")
let report = """
mode: AOT images only (no executable memory)
AOT: on (echo on|off > /proc/ish/jit; affects blocks compiled afterwards, i.e. new processes)
blocks translated or looked up: 2555, AOT installs: 900 (moved: 300, with pc-relative immediates fixed: 12, slot taken elsewhere: 0), reused: 0
other versions: images serve their family (ISH_AOT_FAMILY=0 turns off)
images: 3 in use, 1 rejected (abi daf8fcc7)
  ok        /bin/busybox (6224 translations, family busybox)
  ok        /lib/ld-musl-aarch64.so.1 (3858 translations, family ld-musl-aarch64.so.1*)
  ok        /usr/lib/libz.so.1.3.1 (954 translations, family libz.so.1*)
  rejected  /usr/lib/libpython3.12.so.1.0 (made by an ish with other conventions or layouts)
modules with an image (blocks / AOT hits / of which moved):
  /lib/ld-musl-aarch64.so.1                   29335 / 12902    / 0
  /usr/lib/libz.so.1.3.2                        925 / 800      / 300
  /bin/busybox                                11705 / 0        / 0        <- no match: module file differs from the recorded one
  /usr/bin/node                            not loaded by any process yet
"""
/// Port of AOJITRuntimeStatus.init(report:) and coverage(for:).
struct Cov: Equatable { var blocks = 0, hits = 0, moved = 0 }
struct Status {
    var rejected: Set<String> = [], accepted: Set<String> = [], hits: [String: Cov] = [:], abi: String?
    init(report: String) {
        for raw in report.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "(abi ") { abi = String(line[r.upperBound...].prefix { $0 != ")" }) }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2, parts[0] == "ok" { accepted.insert(parts[1]) }
            if parts.count >= 2, parts[0].hasPrefix("rejected") { rejected.insert(parts[1]) }
            if parts.count >= 4, parts[0].hasPrefix("/"), parts[2] == "/",
               let blocks = Int(parts[1]), let hit = Int(parts[3]) {
                let moved = parts.count >= 6 && parts[4] == "/" ? Int(parts[5]) ?? 0 : 0
                hits[parts[0]] = Cov(blocks: blocks, hits: hit, moved: moved)
            }
        }
    }
    func coverage(recorded: String, family: String) -> Cov? {
        let rows = hits.filter { $0.key == recorded || fnmatch(family, ($0.key as NSString).lastPathComponent, 0) == 0 }
        guard !rows.isEmpty else { return nil }
        return rows.values.reduce(into: Cov()) { $0.blocks += $1.blocks; $0.hits += $1.hits; $0.moved += $1.moved }
    }
}
let st = Status(report: report)
check("abi read", st.abi == "daf8fcc7")
check("accepted images (family suffix does not break the path)", st.accepted == ["/bin/busybox", "/lib/ld-musl-aarch64.so.1", "/usr/lib/libz.so.1.3.1"])
check("rejected image", st.rejected == ["/usr/lib/libpython3.12.so.1.0"])
check("hits and moved per module", st.hits["/usr/lib/libz.so.1.3.2"] == Cov(blocks: 925, hits: 800, moved: 300))
check("trailing annotation does not break the line", st.hits["/bin/busybox"] == Cov(blocks: 11705, hits: 0, moved: 0))
check("'not loaded' module has no entry", st.hits["/usr/bin/node"] == nil)
check("an older 2-column line still parses (moved 0)", Status(report: "  /bin/x   10 / 5").hits["/bin/x"] == Cov(blocks: 10, hits: 5, moved: 0))
check("family coverage counts the other version's real path (zlib 1.3.1 image on 1.3.2)",
      st.coverage(recorded: "/usr/lib/libz.so.1.3.1", family: "libz.so.1*") == Cov(blocks: 925, hits: 800, moved: 300))
check("a module outside the family is not counted", st.coverage(recorded: "/usr/lib/libssl.so.3", family: "libssl.so.3*") == nil)
check("source: parser and coverage match the port",
      view.contains("let moved = parts.count >= 6 && parts[4] == \"/\" ? Int(parts[5]) ?? 0 : 0")
      && view.contains("let rows = hits.filter { $0.key == image.recordedPath || image.servesFamily(($0.key as NSString).lastPathComponent) }")
      && view.contains("if parts.count >= 2, parts[0].hasPrefix(\"rejected\") { rejected.insert(parts[1]) }"))
/// Port of AOJITSettingsSection.percent.
func percent(_ part: Int, of whole: Int) -> String {
    guard whole > 0 else { return "0%" }
    var p = Int((Double(part) / Double(whole) * 100).rounded())
    if part < whole { p = min(p, 99) }
    if part > 0 { p = max(p, 1) }
    return "\(p)%"
}
check("coverage %: 800/925 → 86%, 999/1000 → 99% (never a false 100%), 1/1000 → 1%, 0 → 0%",
      percent(800, of: 925) == "86%" && percent(999, of: 1000) == "99%" && percent(1, of: 1000) == "1%" && percent(0, of: 10) == "0%" && percent(5, of: 0) == "0%")
check("source: percent matches the port", view.contains("if part < whole { p = min(p, 99) }") && view.contains("if part > 0 { p = max(p, 1) }"))

// MARK: - [3] catalog vs README

print("\n▶️  3. in-app catalog matches deps/aot/README.md (one image per module)")
// [T-aojit-family] One image per module. `module` is the real file recorded
// (README, image header, runtime report); `row` is the catalog row's module
// when it is a soname link to that file; `family` is the image's pattern.
let images: [(file: String, module: String, bid: String, pkg: String, row: String?, family: String)] = [
    ("aot_musl_1.2.5-r8.S", "/lib/ld-musl-aarch64.so.1", "384940f9110e809da953d6fbabcb31d297c217b5", "musl-1.2.5-r8", nil, "ld-musl-aarch64.so.1*"),
    ("aot_busybox_1.37.0-r8.S", "/bin/busybox", "2f8b429ec88eacccb94c8bb23ec060ab4a028ee8", "busybox-1.37.0-r8", nil, "busybox"),
    ("aot_zlib_1.3.1-r2.S", "/usr/lib/libz.so.1.3.1", "0b23d104a896ab2e7e3a8144b70175fb3ce8cbd9", "zlib-1.3.1-r2", "/usr/lib/libz.so.1", "libz.so.1*"),
    ("aot_libcrypto_3.3.2-r4.S", "/usr/lib/libcrypto.so.3", "1dcac613c1f6b724c56844356ad82a8c97ff401a", "libcrypto3-3.3.2-r4", nil, "libcrypto.so.3*"),
    ("aot_libssl_3.3.2-r4.S", "/usr/lib/libssl.so.3", "d0b98a4924a7a7dcc3f3f31dc5645db6ffd4fd9c", "libssl3-3.3.2-r4", nil, "libssl.so.3*"),
    ("aot_python3_3.12.15-r0.S", "/usr/lib/libpython3.12.so.1.0", "d644d658076939b92edde6d007ef8bf491fec5a3", "python3-3.12.15-r0", nil, "libpython3.12.so.1*"),
    ("aot_nodejs_22.23.2-r0.S", "/usr/bin/node", "c324f04a6d01b07f6858cc8ef1da4d6d3656daa3", "nodejs-22.23.2-r0", nil, "node"),
    ("aot_sqlite_3.48.0-r4.S", "/usr/lib/libsqlite3.so.0.8.6", "0cd2f33152f67d2b77c8468184bbe0cef1d7e7f2", "sqlite-libs-3.48.0-r4", "/usr/lib/libsqlite3.so.0", "libsqlite3.so.0*"),
    ("aot_pillow_11.0.0-r0.S", "/usr/lib/python3.12/site-packages/PIL/_imaging.cpython-312-aarch64-linux-musl.so", "4c527f1dd53c539fadb6e761f32fe1c97453f94e", "py3-pillow-11.0.0-r0", nil, "_imaging.cpython-312-aarch64-linux-musl.so"),
    ("aot_libwebp_1.4.0-r0.S", "/usr/lib/libwebp.so.7.1.9", "8ef75205b20db80a13c5a7cc73c4010bf5ee4d6f", "libwebp-1.4.0-r0", "/usr/lib/libwebp.so.7", "libwebp.so.7*"),
    ("aot_libjpeg_3.0.4-r0.S", "/usr/lib/libjpeg.so.8.3.2", "18c1b17b04d907c6774bf76263b9fa42e9408db8", "libjpeg-turbo-3.0.4-r0", "/usr/lib/libjpeg.so.8", "libjpeg.so.8*"),
    ("aot_numpy_2.1.3-r0.S", "/usr/lib/python3.12/site-packages/numpy/_core/_multiarray_umath.cpython-312-aarch64-linux-musl.so", "04b4971c8e52a43f5c0608f64d7b13207b8c1c3e", "py3-numpy-2.1.3-r0", nil, "_multiarray_umath.cpython-312-aarch64-linux-musl.so"),
    ("aot_pcre2_10.43-r0.S", "/usr/lib/libpcre2-8.so.0.12.0", "2a7cfd13f571d133069bf15c8e869ba13d2a4c5f", "pcre2-10.43-r0", "/usr/lib/libpcre2-8.so.0", "libpcre2-8.so.0*"),
    // [T-aojit-batch2]
    ("aot_ssh_9.9_p2-r0.S", "/usr/bin/ssh", "df1649582b7a74dc596ffcb440391796995dd202", "openssh-client-default-9.9_p2-r0", nil, "ssh"),
    ("aot_scp_9.9_p2-r0.S", "/usr/bin/scp", "cbc5234e3d96db92e8acd726e6743ec76b66e03d", "openssh-client-common-9.9_p2-r0", nil, "scp"),
    ("aot_py_json_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/_json.cpython-312-aarch64-linux-musl.so", "a1d82af66c4470aa6cac49ca772927a2995ed297", "python3-3.12.15-r0", nil, "_json.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_hashlib_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/_hashlib.cpython-312-aarch64-linux-musl.so", "97a005a1b066e6bd4158eb271132e1b38c1be8cb", "python3-3.12.15-r0", nil, "_hashlib.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_blake2_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/_blake2.cpython-312-aarch64-linux-musl.so", "f4f542cf566ffe62953373b6e54602f614df6951", "python3-3.12.15-r0", nil, "_blake2.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_struct_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/_struct.cpython-312-aarch64-linux-musl.so", "6cfef1a2458b6dcc2f396ec8f2b9d9ebb771bba1", "python3-3.12.15-r0", nil, "_struct.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_datetime_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/_datetime.cpython-312-aarch64-linux-musl.so", "e361da74dd7d72b332863d47c2dfe3f52026d916", "python3-3.12.15-r0", nil, "_datetime.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_binascii_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/binascii.cpython-312-aarch64-linux-musl.so", "dd90d3e7366c8149d54e58c13669f05e76e48e60", "python3-3.12.15-r0", nil, "binascii.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_math_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/math.cpython-312-aarch64-linux-musl.so", "67f6d6a06bb8f7453d482c52f6ef4bc6fb720937", "python3-3.12.15-r0", nil, "math.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_zlib_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/zlib.cpython-312-aarch64-linux-musl.so", "fad09a48ab85c708fbd9bc458f4b1ac1ed129055", "python3-3.12.15-r0", nil, "zlib.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_socket_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/_socket.cpython-312-aarch64-linux-musl.so", "d3f34d4d8f288f9f9324bf303dc3b25c8969b533", "python3-3.12.15-r0", nil, "_socket.cpython-312-aarch64-linux-musl.so"),
    ("aot_py_select_3.12.15-r0.S", "/usr/lib/python3.12/lib-dynload/select.cpython-312-aarch64-linux-musl.so", "109bd4dae0f995d654c1e0b4346eba111c6aa8c1", "python3-3.12.15-r0", nil, "select.cpython-312-aarch64-linux-musl.so"),
]
for i in images {
    // "musl-1.2.5-r8" in the README, "musl 1.2.5-r8" in the app.
    let shown = i.pkg.replacingOccurrences(of: "-", with: " ", range: i.pkg.range(of: #"-(?=\d)"#, options: .regularExpression))
    let tail = i.row == nil ? ")" : ", path: \"\(i.module)\")"
    let buildLine = "build: AOJITBuild(file: \"\(i.file)\", buildId: \"\(i.bid)\", package: \"\(shown)\"" + tail
    check("\(i.file): catalog row = module + build + family",
          view.contains(buildLine) && view.contains(buildLine + ",\n            family: \"\(i.family)\",")
          && view.range(of: "module: \"\(i.row ?? i.module)\"").map { m in
              view.range(of: buildLine).map { $0.lowerBound > m.lowerBound } ?? false } ?? false)
    check("\(i.file): README row agrees", readme.contains("`\(i.file)` | `\(i.module)` | `\(i.pkg)`") && readme.contains(i.bid))
    check("\(i.file): its own file name is in its family", fnmatch(i.family, (i.module as NSString).lastPathComponent, 0) == 0)
}
check("one image per module: 25 rows, 25 builds, no `builds:` arrays",
      view.components(separatedBy: "        AOJITImage(\n").count - 1 == 25
      && view.components(separatedBy: "build: AOJITBuild(").count - 1 == 25 && !view.contains("builds: ["))
check("ripgrep and _ssl are not carried (dropped after the iPhone 11 measurement)",
      !view.contains("aot_ripgrep") && !view.contains("aot_py_ssl") && !readme.contains("| `aot_ripgrep") && !readme.contains("| `aot_py_ssl"))
check("Fix pins the recorded package where apk can install it",
      ["python3=3.12.15-r0", "nodejs=22.23.2-r0", "py3-pillow=11.0.0-r0", "libwebp=1.4.0-r0", "libjpeg-turbo=3.0.4-r0",
       "py3-numpy=2.1.3-r0", "sqlite-libs=3.48.0-r4", "pcre2=10.43-r0",
       "openssh-client-default=9.9_p2-r0", "openssh-client-common=9.9_p2-r0"].allSatisfy { view.contains("apkSpec: \"\($0)\"") })
check("core packages bundled with the rootfs offer no apk Fix (musl, busybox, zlib, libcrypto, libssl)",
      view.components(separatedBy: "apkSpec: nil").count - 1 == 5)
check("PCRE2 says who does NOT benefit (ripgrep default, jq) and never claims jq uses it",
      view.contains("ripgrep's default search does not use PCRE2 and does not benefit, and neither does jq")
      && !view.contains("jq may") && !view.contains("jq and git"))
check("AES-GCM's and OpenBLAS's limits are stated",
      view.contains("Bulk AES-GCM encryption gains little.") && view.contains("Linear algebra runs in OpenBLAS, which has no image."))
check("README: one image per module, family matching, the ish commit and abi",
      readme.contains("**One image per module, family matching for other versions.**")
      && readme.contains("ish: `deps/ish` at `75da01ca` (ish-arm64 feat/aot-family-match `df9484e6` merged with\nthe local fakefs commit `7cbfc56c`; JIT_CODE_VERSION 8), abi `1f3bb5a0`.")
      && readme.contains("Not carried any more (family matching serves them)"))
check("README: maintenance now = full speed back, not silent breakage",
      readme.contains("Package upgrades no longer switch an image off"))
// The bundled rootfs really ships the core builds chosen.
let bundledZ = repo.appendingPathComponent("deps/resources/alpine-rootfs/data/usr/lib/libz.so.1.3.1")
if let d = try? Data(contentsOf: bundledZ) {
    check("bundled rootfs zlib has the zlib image's build-id", buildId(inELF: d.prefix(64 * 1024)) == "0b23d104a896ab2e7e3a8144b70175fb3ce8cbd9")
} else {
    print("  ⚠️  bundled libz.so.1.3.1 not present (deps/resources not built) — skipped")
}
// Images present locally (gitignored build input): the header gen.py wrote
// must name the module, build-id, family and a symbol unique to the file.
let aotDir = repo.appendingPathComponent("deps/aot")
var symbols = Set<String>()
for i in images {
    guard let h = try? FileHandle(forReadingFrom: aotDir.appendingPathComponent(i.file)) else {
        print("  ⚠️  deps/aot/\(i.file) not present — skipped"); continue
    }
    // The module header is at the end of the file.
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 8192 ? size - 8192 : 0)
    let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    try? h.close()
    let bidBytes = stride(from: 0, to: 40, by: 2).map { i.bid.dropFirst($0).prefix(2) }.map { String(Int($0, radix: 16)!) }
    let sym = tail.range(of: #"_ish_aot_module_\w+"#, options: .regularExpression).map { String(tail[$0]) }
    // [T-aojit-compact] Compact-table layout. abi 1f3bb5a0 = 524006816
    // (JIT_CODE_VERSION 8, deps/ish 75da01ca); was 97963b7f = 2543205247.
    check("\(i.file): header names \(i.module), its build-id, family \(i.family) and abi 1f3bb5a0",
          tail.contains(".asciz \"\(i.module)\"") && tail.contains(".byte " + bidBytes.joined(separator: ", "))
          && tail.contains("Lfamily:\n    .asciz \"\(i.family)\"") && tail.contains(", 524006816\n"))
    check("\(i.file): symbol unique across images", sym != nil && symbols.insert(sym!).inserted)
}
let stale = ((try? FileManager.default.contentsOfDirectory(atPath: aotDir.path)) ?? []).filter { $0.hasSuffix(".S") && !images.map(\.file).contains($0) }
check("no stale images left in deps/aot (found: \(stale))", stale.isEmpty)

// Port of AOJITModuleProbe.match: build-id first, then the family pattern.
enum St: Equatable { case matched, family(String), mismatch }
func match(_ found: String?, file: String, bid: String, family: String) -> St {
    if let found, found == bid { return .matched }
    if fnmatch(family, file, 0) == 0 { return .family(file) }
    return .mismatch
}
let zb = "0b23d104a896ab2e7e3a8144b70175fb3ce8cbd9"
check("the recorded build → full speed", match(zb, file: "libz.so.1.3.1", bid: zb, family: "libz.so.1*") == .matched)
check("another version in the family → partial (zlib 1.3.2)", match("cde0", file: "libz.so.1.3.2", bid: zb, family: "libz.so.1*") == .family("libz.so.1.3.2"))
check("a soname bump leaves the family → no image", match("ffff", file: "libz.so.2.0.0", bid: zb, family: "libz.so.1*") == .mismatch)
check("an exact-name family (programs): busybox r14 → partial, other names → no image",
      match("2aa6", file: "busybox", bid: "2f8b", family: "busybox") == .family("busybox")
      && match("2aa6", file: "busybox.static", bid: "2f8b", family: "busybox") == .mismatch)
check("source: probe applies build-id, then family, on the resolved file name",
      view.contains("if let found, found == image.build.buildId { return .matched(image.build) }")
      && view.contains("if image.servesFamily(file) { return .family(file: file) }")
      && view.contains("return match(buildId(inELF: head), file: (path as NSString).lastPathComponent, in: image)")
      && view.contains("fnmatch(family, fileName, 0) == 0"))

// MARK: - [3b] Fix asks first

print("\n▶️  3b. Fix is confirmed before apk runs")
let sectionSrc = view.components(separatedBy: "struct AOJITSettingsSection: View {").last ?? ""
check("the Fix button only stages the request", sectionSrc.contains("Button {\n                    pendingFix = image\n                }"))
check("apk runs only from the dialog's confirm button",
      sectionSrc.components(separatedBy: "model.fix(").count - 1 == 1
      && sectionSrc.contains("Button(\"Install \\(image.build.package)\") { model.fix(image) }"))
check("the dialog names the exact apk spec",
      sectionSrc.contains(".confirmationDialog(") && sectionSrc.contains("Text(\"Runs “apk add \\(image.apkSpec ?? \"\")” in the Shell Container."))
check("the dialog can be cancelled", sectionSrc.contains("Button(\"Cancel\", role: .cancel) {}"))

// MARK: - [3c] plan B: restore a core package to the bundled build

print("\n▶️  3c. restore to the bundled build (plan B)")
let restoreSh = read(ios.appendingPathComponent("AOJITRestore/restore.sh"))
let rootfsMgr = read(ios.appendingPathComponent("iSH/RootfsManager.swift"))
check("offered only when the installed file is not in the family at all",
      sectionSrc.contains("if !image.restorePackages.isEmpty, case .mismatch = state {"))
check("only musl and busybox can be restored",
      view.contains("restorePackages: [\"musl\", \"musl-utils\"],") && view.contains("restorePackages: [\"busybox\", \"busybox-binsh\", \"ssl_client\"],")
      && view.components(separatedBy: "restorePackages: [\"").count - 1 == 2)
check("the Restore button only stages the request", sectionSrc.contains("Button(role: .destructive) {\n                    pendingRestore = image\n                }"))
check("restore runs only from the warning's destructive button",
      sectionSrc.components(separatedBy: "model.restore(").count - 1 == 1
      && sectionSrc.contains("Button(\"Restore\", role: .destructive) { model.restore(image) }")
      && sectionSrc.contains(".alert(") && sectionSrc.contains("This is a core system package: if it breaks, no program in the Shell Container can start."))
check("the warning says what the package does and to back up first",
      view.contains("coreRole: \"musl is the C library that almost every installed program is linked against.\"")
      && sectionSrc.contains("Back up files you cannot lose before continuing."))
// The bundled packages must be exactly the builds the r8 images were recorded from.
let restoreDir = ios.appendingPathComponent("AOJITRestore")
for (apk, inside, bid) in [("musl-1.2.5-r8.apk", "lib/ld-musl-aarch64.so.1", "384940f9110e809da953d6fbabcb31d297c217b5"),
                           ("busybox-1.37.0-r8.apk", "bin/busybox", "2f8b429ec88eacccb94c8bb23ec060ab4a028ee8")] {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aojit-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", restoreDir.appendingPathComponent(apk).path, "-C", tmp.path, inside]
    tar.standardError = FileHandle.nullDevice
    try? tar.run(); tar.waitUntilExit()
    let d = (try? Data(contentsOf: tmp.appendingPathComponent(inside))) ?? Data()
    check("bundled \(apk) holds the recorded r8 build (\(bid.prefix(8)))", buildId(inELF: d.prefix(64 * 1024)) == bid)
    try? FileManager.default.removeItem(at: tmp)
}
for apk in ["musl-utils-1.2.5-r8.apk", "busybox-binsh-1.37.0-r8.apk", "ssl_client-1.37.0-r8.apk"] {
    check("bundled \(apk) present", FileManager.default.fileExists(atPath: restoreDir.appendingPathComponent(apk).path))
}
check("bundled in the app (Resources) and kept in git",
      pbx.contains("E5A000A01 /* AOJITRestore in Resources */,") && gitignore.contains("!src/ios/AOJITRestore/*.apk"))
func at(_ s: String) -> String.Index { restoreSh.range(of: s)?.lowerBound ?? restoreSh.endIndex }
check("restore.sh: rollback download → dry run → install → rollback, in that order",
      at("apk fetch -q -o \"$ROLLBACK\"") < at("apk add --simulate --no-network $files")
      && at("apk add --simulate --no-network $files") < at("if apk add --no-network $files && healthy; then")
      && at("if apk add --no-network $files && healthy; then") < at("if apk add --no-network \"$ROLLBACK\"/*.apk && healthy; then"))
check("restore.sh: the rollback must be the exact installed build", restoreSh.contains("if [ ! -f \"$ROLLBACK/$p-$have.apk\" ]; then"))
check("restore.sh: the dry run allows only downgrade/upgrade/replace of these packages",
      restoreSh.contains("case \"$verb\" in Downgrading|Upgrading|Replacing) ;; *) echo \"$verb $name\"; continue ;; esac")
      && restoreSh.contains("case \" $names \" in *\" $name \"*) ;; *) echo \"$verb $name\" ;; esac"))
check("restore.sh: world is put back (no checksum pins left)",
      restoreSh.components(separatedBy: "restore_world; rm -rf \"$ROLLBACK\"").count - 1 == 2)
check("every restore.sh exit code has a message",
      ["case 0:", "case 1:", "case 11:", "case 12:", "case 13:", "case 14:", "default:"].allSatisfy { view.contains($0) }
      && ["exit 11", "exit 12", "exit 13", "exit 14"].allSatisfy { restoreSh.contains($0) })
check("staged files are removed from inside the guest",
      view.contains("\"sh \\(stage)/restore.sh \\(stage) \\(packages) 2>&1; rc=$?; rm -rf \\(stage); exit $rc\""))
check("staging registers files in meta.db", rootfsMgr.contains("func stageFiles(from dir: URL, toLinuxDir linuxDir: String) throws {")
      && rootfsMgr.contains("ensureFakefsMetadata(for: relativePath, isDirectory: false, mode: 0o100644)"))

// MARK: - [3d] Pillow stack: soname links

print("\n▶️  3d. Pillow stack: probing through soname links (fakefs)")
/// Verbatim port of AOJITModuleProbe.linkTarget (checked against the source below).
enum Probe {
    static func linkTarget(_ d: Data, from path: String) -> String? {
        guard d.count < 1024, !d.starts(with: [0x7f, 0x45, 0x4c, 0x46]),
              let text = String(data: d, encoding: .utf8),
              !text.isEmpty, !text.contains("\0"), !text.contains("\n") else { return nil }
        if text.hasPrefix("/") { return text }
        let dir = (path as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent(text)
    }
}
func linkBody(_ src: String) -> String {
    guard let a = src.range(of: "static func linkTarget(_ d: Data, from path: String) -> String? {"),
          let b = src.range(of: "return (dir as NSString).appendingPathComponent(text)", range: a.upperBound..<src.endIndex) else { return "" }
    return String(src[a.lowerBound..<b.upperBound]).filter { !$0.isWhitespace }
}
check("port of linkTarget is verbatim", !linkBody(view).isEmpty && linkBody(view) == linkBody(me))
check("a relative soname link resolves in its directory",
      Probe.linkTarget(Data("libz.so.1.3.1".utf8), from: "/usr/lib/libz.so.1") == "/usr/lib/libz.so.1.3.1")
check("an absolute link is taken as is", Probe.linkTarget(Data("/opt/lib/libz.so.9".utf8), from: "/usr/lib/libz.so.1") == "/opt/lib/libz.so.9")
check("an ELF is not a link", Probe.linkTarget(makeELF(id: id), from: "/usr/lib/libz.so.1") == nil)
check("text with a newline (a script) is not a link", Probe.linkTarget(Data("#!/bin/sh\necho\n".utf8), from: "/bin/x") == nil)
check("a large file is not a link", Probe.linkTarget(Data(repeating: 0x61, count: 2048), from: "/x") == nil)
// The real bundled rootfs: libz.so.1 is a fakefs link to the 1.3.1-r2 file.
let zlink = rootfs.appendingPathComponent("usr/lib/libz.so.1")
if let d = try? Data(contentsOf: zlink), let target = Probe.linkTarget(d, from: "/usr/lib/libz.so.1") {
    let real = (try? Data(contentsOf: rootfs.appendingPathComponent(String(target.dropFirst()))))?.prefix(64 * 1024)
    check("bundled libz.so.1 → \(target), build-id of the 1.3.1-r2 image",
          target == "/usr/lib/libz.so.1.3.1" && real.flatMap { buildId(inELF: Data($0)) } == "0b23d104a896ab2e7e3a8144b70175fb3ce8cbd9")
} else {
    print("  ⚠️  bundled libz.so.1 not present or not a fakefs link — skipped")
}
check("probe follows links (bounded) before reading the build-id",
      view.contains("for _ in 0..<4 {") && view.contains("if let next = linkTarget(head, from: path) { path = next; continue }"))
check("coverage totals the family; Rejected uses the recorded file",
      view.contains("if let c = model.runtime.coverage(for: image), c.blocks > 0 {")
      && view.contains("if model.runtime.rejected.contains(image.recordedPath) {")
      && view.contains("var recordedPath: String { build.path ?? module }"))
let workload = read(repo.appendingPathComponent("deps/aot/workloads/pillow.py"))
check("the Pillow workload is in the repo (decode, Lanczos, filters, JPEG/WebP, zlib/gzip)",
      workload.contains("Image.Resampling.LANCZOS") && workload.contains("UnsharpMask") && workload.contains("\"WEBP\"")
      && workload.contains("\"JPEG\"") && workload.contains("zlib.compress") && workload.contains("gzip."))
check("README keeps the NEON note", readme.contains("NEON"))

// MARK: - [3e] family matching in the UI

print("\n▶️  3e. the screen explains full / partial / no image")
check("badges: Ready (exact), Partial (family), No image, Not installed, Rejected",
      sectionSrc.contains("case .matched: badge(\"Ready\", color: .green)") && sectionSrc.contains("case .family: badge(\"Partial\", color: .blue)")
      && sectionSrc.contains("case .mismatch: badge(\"No image\", color: .orange)") && sectionSrc.contains("badge(\"Rejected\", color: .red)"))
check("each state says what the installed file gets",
      sectionSrc.contains("Text(\"Full speed: this is the recorded build.\")")
      && sectionSrc.contains("Text(\"Another version is installed (\\(file)): code unchanged since \\(image.build.package) runs from the image, the rest is emulated.\")")
      && sectionSrc.contains("Text(\"The installed file is not a version this image can serve, so it runs without AOJIT.\")"))
check("the row names the recorded build and shows real coverage (incl. blocks reused by content)",
      sectionSrc.contains("Text(\"Image recorded from \\(image.build.package)\")")
      && sectionSrc.contains("Text(\"AOT coverage: \\(Self.percent(c.hits, of: c.blocks)) of \\(c.blocks) blocks\")")
      && sectionSrc.contains("Text(\"\\(c.moved) of them reused from another version by content\")"))
check("in the family state the Fix is offered as the way to full speed",
      sectionSrc.contains("case .notInstalled, .mismatch, .family: return true")
      && sectionSrc.contains("Text(\"Install \\(image.build.package) for full speed\")"))
check("footer explains one image per library and partial gain for other versions",
      sectionSrc.contains("Each library has one image, recorded from the build listed: that build runs at full speed.")
      && !sectionSrc.contains("only the exact builds listed benefit"))
let xc = read(ios.appendingPathComponent("Localizable.xcstrings"))
for key in ["Partial", "No image", "Image recorded from %@", "Full speed: this is the recorded build.", "Install %@ for full speed",
            "AOT coverage: %@ of %lld blocks", "%lld of them reused from another version by content"] {
    check("string catalog has \(key)", xc.contains("\"\(key)\" : {"))
}
for gone in ["Supported: %@", "Using the image for %@", "Version mismatch", "AOT hits: %lld / %lld blocks"] {
    check("stale string removed: \(gone)", !xc.contains("\"\(gone)\" : {"))
}

// MARK: - [4] wiring

print("\n▶️  4. wiring")
// [T-aojit-default-on] Default on: an absent key reads YES, a stored value wins.
check("default on: absent key reads true",
      kernel.contains("if ([defaults objectForKey:AOJITEnabledDefaultsKey] == nil) return YES;\n    return [defaults boolForKey:AOJITEnabledDefaultsKey];"))
check("no registerDefaults that could mask the absent-key check", !kernel.contains("registerDefaults:@{AOJITEnabledDefaultsKey"))
let applyAt = kernel.range(of: "[ISHKernel applyAOJIT];")
let firstProc = kernel.range(of: "err = become_first_process();")
check("applied before the first guest process",
      applyAt != nil && firstProc != nil && applyAt!.lowerBound < firstProc!.lowerBound)
check("changing the setting applies at once", kernel.contains("[NSUserDefaults.standardUserDefaults setBool:enabled forKey:AOJITEnabledDefaultsKey];\n    [self applyAOJIT];"))
check("libish is AOT-only (setup)", buildIsh.contains("-Dguest_arch=arm64 \\\n            -Djit=true \\\n            -Djit_emit=false"))
check("libish is AOT-only (reconfigure)", buildIsh.contains("-Db_ndebug=\"$MESON_NDEBUG\" \\\n            -Djit=true \\\n            -Djit_emit=false"))
check("images archive built by build_ish.sh", buildIsh.contains("bash \"$SCRIPT_DIR/build_aot.sh\""))
check("empty archive when no images (link never breaks)", buildAot.contains("void ish_aot_none(void) {}"))
check("archive force-loaded in both configurations",
      pbx.components(separatedBy: "\"-force_load\",\n\t\t\t\t\t\"$(SRCROOT)/../../deps/libs/libish_aot.a\",").count - 1 == 2)
check(".S images kept out of git", gitignore.contains("deps/aot/*.S"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
