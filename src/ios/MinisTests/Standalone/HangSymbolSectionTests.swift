#!/usr/bin/env swift
// [T-hang-symbol-section] HangDetector labelled a PC in the app's __stubs with
// the nearest preceding exported symbol: field report 2026-10-03 (1.15 (8))
// showed "Minis +0xeb98160 restore_termios" on top of the main thread, which
// is really the __stubs entry for swift_bridgeObjectRelease (+0xeb98178 =
// swift_bridgeObjectRetain) called from ChatSession's value witnesses - no
// terminal code involved. hd_nonCodeTextSection names the __TEXT section
// instead whenever the PC is not in __text.
//
// Extracts the shipped C function from Debug/HangDetector.m, compiles it into
// a tiny C program and checks it against that program's own __stubs / __text.
//
// Run: swift HangSymbolSectionTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let src = (try? String(contentsOf: root.appendingPathComponent("Debug/HangDetector.m"), encoding: .utf8)) ?? ""
guard let a = src.range(of: "static bool hd_nonCodeTextSection("),
      let b = src.range(of: "\nstatic void initMachTimebase(void)", range: a.upperBound..<src.endIndex) else {
    print("❌ hd_nonCodeTextSection not found"); exit(1)
}
let fn = String(src[a.lowerBound..<b.lowerBound])
let c = """
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
\(fn)
int main(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    unsigned long size = 0;
    uint8_t *stubs = getsectiondata(mh, "__TEXT", "__stubs", &size);
    char out[17];
    Dl_info info;
    if (stubs && size > 0 && dladdr(stubs + 4, &info)) {
        printf("R stubs=%s\\n", hd_nonCodeTextSection(&info, (uintptr_t)(stubs + 4), out) ? out : "none");
    } else { printf("R stubs=nosection\\n"); }
    uintptr_t code = (uintptr_t)&main;
    if (dladdr((void *)code, &info)) printf("R text=%s\\n", hd_nonCodeTextSection(&info, code, out) ? out : "none");
    uintptr_t libc = (uintptr_t)&strlen;
    if (dladdr((void *)libc, &info)) printf("R libc=%s\\n", hd_nonCodeTextSection(&info, libc, out) ? out : "none");
    return 0;
}
"""
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangsect-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let cf = dir.appendingPathComponent("t.c"), bin = dir.appendingPathComponent("t")
try? c.write(to: cf, atomically: true, encoding: .utf8)
let cc = Process(); cc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
cc.arguments = ["-O1", cf.path, "-o", bin.path]; try? cc.run(); cc.waitUntilExit()
var r: [String: String] = [:]
if cc.terminationStatus == 0 {
    let p = Process(); p.executableURL = bin; let o = Pipe(); p.standardOutput = o
    try? p.run(); p.waitUntilExit()
    for l in (String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n") where l.hasPrefix("R ") {
        let kv = l.dropFirst(2).split(separator: "=", maxSplits: 1); if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
    }
}
print("▶️  hd_nonCodeTextSection (shipped C, compiled)")
check("a PC in the image's __stubs is named by its section", r["stubs"] == "__stubs")
check("a PC in __text keeps the normal dladdr symbol", r["text"] == "none")
check("a PC in another image's __text (libc strlen) is left alone", r["libc"] == "none")
check("both resolution sites use it (log dump + persisted frames)",
      src.contains("if (hd_nonCodeTextSection(&info, frames[j], sectBuf)) sym = sectBuf;")
      && src.contains("if (hd_nonCodeTextSection(&info, frames[i], sect)) {\n                    f.symbol = [NSString stringWithFormat:@\"<%s>\", sect];"))
try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
