#!/usr/bin/env swift
// [T-crash-bss-once-watch] Crashpoint B4LPSQGXQ_-FoK1Wew-WSu, 1.15 (12),
// iPhone18,2 / iOS 27.0: SIGSEGV at 0x28 in Published.projectedValue.getter <-
// QuickActionWorkflow.$state.getter <- ContentView.body. In the build's binary
// the getter checks the once token of QuickActionWorkflow.shared (still ~0,
// "done") and then loads the static's storage word from __common - which read
// 0. The two [BssCanary] words sit 10 MB away at the start of __bss and never
// fired. DataOnceWatch watches every completed once token instead.
//
//   [1] the shipping block, compiled into a C harness on this Mac, finds real
//       dispatch_once tokens and simulated ones, and skips non-resident pages
//       (~0 words already in __data at load, i.e. -1 initialisers, are not)
//   [2] a token that moved from ~0 to another value is not reported
//   [3] a memset wipe is reported with "page all zero=yes, replaced=no"
//   [4] a page replaced by a MAP_FIXED mapping is reported "replaced=yes"
//   [5] reports stop after DATA_ONCE_MAX_REPORTS
//   [6] source guards: starts from an image constructor, logs via NSLog
//
// Run: swift DataOnceWatchTests.swift   (needs clang)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let kernel = source("iSH/ISHKernel.m")
guard let block = between(kernel, "// BEGIN DataOnceWatch", "// END DataOnceWatch") else {
    print("❌ DataOnceWatch block not found"); exit(1)
}

let harness = """
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <dispatch/dispatch.h>
\(block)

static int fails;
#define CHECK(label, cond) do { bool ok_ = (cond); printf("  %s %s\\n", ok_ ? "✅" : "❌", label); if (!ok_) fails++; } while (0)

static char logbuf[65536];
static size_t loglen;
static unsigned loglines;
static void capture(const char *line) {
    size_t n = strlen(line);
    if (loglen + n + 2 < sizeof(logbuf)) { memcpy(logbuf + loglen, line, n); loglen += n; logbuf[loglen++] = '\\n'; logbuf[loglen] = 0; }
    loglines++;
    printf("      log: %s\\n", line);
}
static void clear_log(void) { loglen = 0; logbuf[0] = 0; loglines = 0; }

#define ARENA_PAGES 4
static uint64_t arena[ARENA_PAGES * 2048] __attribute__((aligned(16384)));
static dispatch_once_t token_a, token_b;
// like iSH's `static int cached = -1` pairs: ~0 in __data from the start
static volatile int64_t preset_word = -1;
static struct data_once_watch w;

static bool watched(uint64_t addr) {
    for (size_t i = 0; i < w.count; i++) if (w.slots[i] == addr) return true;
    return false;
}

int main(void) {
    size_t page = (size_t)vm_page_size, wpp = page / sizeof(uint64_t);
    CHECK("arena pages are VM pages", page <= 16384);
    // libdispatch marks a token ~0 on a later call, once quiesced
    for (int i = 0; i < 300 && (token_a != (dispatch_once_t)DATA_ONCE_DONE || token_b != (dispatch_once_t)DATA_ONCE_DONE); i++) {
        dispatch_once(&token_a, ^{});
        dispatch_once(&token_b, ^{});
        usleep(10000);
    }
    CHECK("dispatch_once tokens settle to ~0", token_a == (dispatch_once_t)DATA_ONCE_DONE && token_b == (dispatch_once_t)DATA_ONCE_DONE);
    arena[0 * wpp + 3] = DATA_ONCE_DONE;
    arena[0 * wpp + 4] = DATA_ONCE_DONE;
    arena[1 * wpp + 5] = DATA_ONCE_DONE;
    arena[1 * wpp + 77] = DATA_ONCE_DONE;
    arena[2 * wpp + 9] = DATA_ONCE_DONE;
    // arena page 3 is never touched

    puts("[1] scan");
    CHECK("init finds this image's static data", data_once_init(&w, (const void *)&main));
    data_once_scan(&w);
    CHECK("real dispatch_once tokens are watched", watched((uint64_t)&token_a) && watched((uint64_t)&token_b));
    CHECK("simulated tokens on three pages are watched",
          watched((uint64_t)&arena[3]) && watched((uint64_t)&arena[4]) && watched((uint64_t)&arena[wpp + 5])
          && watched((uint64_t)&arena[wpp + 77]) && watched((uint64_t)&arena[2 * wpp + 9]));
    char res = 1;
    mincore(&arena[3 * wpp], page, &res);
    CHECK("an untouched page is not faulted in by the scan", !(res & MINCORE_INCORE));
    CHECK("regions were recorded at the first scan", w.region_count > 0);
    CHECK("an intact image reports nothing", data_once_check(&w, 1, capture) == 0 && loglines == 0);

    CHECK("a word that was ~0 at load is not watched", !watched((uint64_t)&preset_word) && w.preset_count >= 1);
    preset_word = 0;
    CHECK("a -1 initialiser set to 0 is not reported", data_once_check(&w, 1, capture) == 0 && loglines == 0);

    puts("[2] a -1 variable that moves on");
    arena[4] = 7;
    CHECK("~0 -> 7 is not counted or logged", data_once_check(&w, 2, capture) == 0 && loglines == 0);

    puts("[3] memset wipe of one page");
    memset(&arena[wpp], 0, page);
    CHECK("both tokens on the page are counted", data_once_check(&w, 3, capture) == 2);
    CHECK("headline names the count and uptime", strstr(logbuf, "2 of ") && strstr(logbuf, "at 3s since launch"));
    CHECK("page line: 2/2 zeroed, all zero, same region",
          strstr(logbuf, "2/2 tokens zeroed, page all zero=yes, region replaced=no") != NULL);
    CHECK("one headline + one page line", loglines == 2);

    puts("[4] page replaced by a new mapping");
    clear_log();
    void *m = mmap(&arena[2 * wpp], page, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK("MAP_FIXED landed", m == (void *)&arena[2 * wpp]);
    CHECK("three tokens now read 0", data_once_check(&w, 4, capture) == 3);
    CHECK("the replaced page says replaced=yes", strstr(logbuf, "1/1 tokens zeroed, page all zero=yes, region replaced=yes") != NULL);
    CHECK("the memset page still says replaced=no", strstr(logbuf, "region replaced=no") != NULL);

    puts("[5] report cap");
    data_once_check(&w, 5, capture);
    clear_log();
    data_once_check(&w, 6, capture);
    CHECK("no more lines after DATA_ONCE_MAX_REPORTS", w.reports == DATA_ONCE_MAX_REPORTS && loglines == 0);

    puts("[6] rescan forgets wiped words");
    data_once_scan(&w);
    CHECK("wiped words are no longer watched", !watched((uint64_t)&arena[wpp + 5]) && watched((uint64_t)&token_a));
    return fails;
}
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("data-once-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("h.c"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["clang", "-std=gnu11", "-fblocks", "-Wall", "-Werror",
                                         "-Wno-unused-function", src.path, "-o", bin])
check("block compiles in a C harness (-Wall -Werror)", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("harness checks all pass", status == 0 && !out.contains("❌"))
}

print("[7] source guards")
check("constructor starts the watch at image load",
      kernel.contains("__attribute__((constructor))\nstatic void data_once_watch_install(void) {\n    data_once_watch_start((const void *)&data_once_watch_install, data_once_watch_nslog);"))
check("logs go through NSLog (captured by LoggingManager)", kernel.contains("NSLog(@\"ISHKernel: %s\", line);"))
check("watches __data, __bss and __common", block.contains("{\"__data\", \"__bss\", \"__common\"}"))
check("first scan after launch-time initialisers, rescans every minute",
      block.contains("20 * NSEC_PER_SEC") && block.contains("ticks % 12 == 0"))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
