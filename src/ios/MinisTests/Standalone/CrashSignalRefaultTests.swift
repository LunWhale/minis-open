#!/usr/bin/env swift
// [T-crash-signal-refault] Crash signal handlers end so the system records the
// REAL exception.
//
// Builds the SHIPPING Diagnostics/CrashSignalHandler.m + CrashSignalPolicy.h
// into small macOS programs, crashes them on purpose on a background (non-iSH)
// thread, and reads the crash report macOS writes to
// ~/Library/Logs/DiagnosticReports - the same ReportCrash pipeline as iOS.
//
//   [1] app handler only, null-page write -> EXC_BAD_ACCESS with the address
//       (not EXC_CRASH), and the pre-opened context file has signal, si_code,
//       si_addr, pc/lr/sp/fp, far/esr, thread, time, sync_fault=1, via=app
//   [2] a handler installed ON TOP that chains back exactly the way iSH's
//       jit_crash_handler does for a non-iSH thread (minis_crash_signal_record
//       + minis_signal_finish) -> still EXC_BAD_ACCESS, context via=ish-chained
//   [3] a SENT SIGSEGV (kill) is still re-raised: dies by SIGSEGV, sync_fault=0
//   [4] brk / __builtin_trap -> EXC_BREAKPOINT, not EXC_CRASH
//   [5] a SIGSEGV pthread_kill'ed from another thread into a BUSY thread (whose
//       exception state may hold a stale abort) is re-raised, not swallowed
//   Note: on macOS ReportCrash keeps the thread's first hardware exception, so
//   the OLD ending (SIG_DFL + raise) also reads EXC_BAD_ACCESS here; the
//   EXC_CRASH it produced is iOS behaviour and can only be seen on a device.
//   [6] source guards on ISHKernel.m's non-iSH branch and installer
//
// The iSH guest-crash and JIT-recovery paths (in_jit / ish_thread_marker) are
// untouched by this change; AOJITTests and the iSH tests cover them.
//
// Writes go to a temp home (CFFIXED_USER_HOME); the crash reports this test
// causes are deleted after reading.
// Run: swift CrashSignalRefaultTests.swift
import Foundation

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let ios = here.deletingLastPathComponent().deletingLastPathComponent()
let handlerM = ios.appendingPathComponent("Diagnostics/CrashSignalHandler.m")
let policyH = ios.appendingPathComponent("Diagnostics/CrashSignalPolicy.h")
let kernelM = ios.appendingPathComponent("iSH/ISHKernel.m")

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
@discardableResult
func run(_ exe: String, _ args: [String], env: [String: String]? = nil) -> (Int32, Process.TerminationReason, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    if let env { p.environment = env }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, .exit, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, p.terminationReason, String(decoding: data, as: UTF8.self))
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("refault-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let home = tmp.appendingPathComponent("home")
try! FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support"),
                                         withIntermediateDirectories: true)

let harness = tmp.appendingPathComponent("main.m")
try! #"""
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import "CrashSignalHandler.h"
#import "CrashSignalPolicy.h"

/// Mirrors iSH's jit_crash_handler for a thread that is not an iSH thread.
static void on_top_handler(int sig, siginfo_t *info, void *ctx) {
    minis_crash_signal_record(sig, info, ctx, "ish-chained");
    minis_signal_finish(sig, info, ctx);
}
/// The ending both handlers used before the fix.
static void old_handler(int sig, siginfo_t *info, void *ctx) {
    (void)info; (void)ctx;
    signal(sig, SIG_DFL);
    raise(sig);
}
static void install_on_top(void (*h)(int, siginfo_t *, void *)) {
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL); sigaction(SIGILL, &sa, NULL);
}
static void *fault_thread(void *arg) {
    const char *mode = arg;
    if (strcmp(mode, "trap") == 0) { __builtin_trap(); }
    if (strcmp(mode, "sent") == 0) { kill(getpid(), SIGSEGV); sleep(5); return NULL; }
    if (strcmp(mode, "busy") == 0) { for (volatile unsigned long k = 0; ; k++) { if (k % 4096 == 0) { volatile char *page = malloc(16384); page[0] = 1; free((void *)page); } } }
    volatile int *p = (int *)0x18; *p = 7;   // null-page write
    return NULL;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        const char *setup = argv[1], *mode = argv[2];
        [CrashSignalHandler install];
        if (strcmp(setup, "chained") == 0) install_on_top(on_top_handler);
        if (strcmp(setup, "old") == 0) install_on_top(old_handler);
        pthread_t t; pthread_create(&t, NULL, fault_thread, (void *)mode);
        if (strcmp(mode, "busy") == 0) { usleep(200000); pthread_kill(t, SIGSEGV); }
        pthread_join(t, NULL);
        printf("SURVIVED\n");
    }
    return 0;
}
"""#.write(to: harness, atomically: true, encoding: .utf8)

func build(_ name: String) -> String? {
    let out = tmp.appendingPathComponent(name).path
    let (c, _, o) = run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-framework", "Foundation",
                                           "-I", ios.appendingPathComponent("Diagnostics").path,
                                           "-o", out, harness.path, handlerM.path])
    if c != 0 { print("❌ build \(name) failed:\n\(o)"); return nil }
    return out
}

struct Outcome { var signal: Int32; var exception: String; var subtype: String; var context: String }
let reports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")

func crash(_ setup: String, _ mode: String) -> Outcome? {
    let name = "minisRefault_\(setup)_\(mode)_\(UInt32.random(in: 0..<UInt32.max))"
    guard let bin = build(name) else { return nil }
    // A fresh home per scenario so each context file is this run's.
    try? FileManager.default.removeItem(at: home.appendingPathComponent("Library/Application Support/last_crash_context.txt"))
    var env = ProcessInfo.processInfo.environment
    env["CFFIXED_USER_HOME"] = home.path
    let (status, reason, _) = run(bin, [setup, mode], env: env)
    let sig: Int32 = reason == .uncaughtSignal ? status : 0
    var report: URL?
    for _ in 0..<40 {
        report = (try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(name) && $0.pathExtension == "ips" }
        if report != nil { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    var exc = "(no report)", sub = ""
    if let report, let text = try? String(contentsOf: report, encoding: .utf8) {
        let body = text.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? ""
        if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
           let e = json["exception"] as? [String: Any] {
            exc = e["type"] as? String ?? "?"
            sub = e["subtype"] as? String ?? ""
        }
        try? FileManager.default.removeItem(at: report)   // only the report this run caused
    }
    let ctx = (try? String(contentsOf: home.appendingPathComponent("Library/Application Support/last_crash_context.txt"),
                           encoding: .utf8)) ?? ""
    return Outcome(signal: sig, exception: exc, subtype: sub, context: ctx)
}

print("▶️  1. app handler, null-page write on a background thread")
if let o = crash("app", "segv") {
    check("dies by SIGSEGV", o.signal == SIGSEGV)
    check("the system records EXC_BAD_ACCESS, not EXC_CRASH (got \(o.exception))", o.exception == "EXC_BAD_ACCESS")
    check("…with the real faulting address (\(o.subtype))", o.subtype.contains("0x0000000000000018"))
    check("context: signal, si_code, si_addr", o.context.contains("signal=SIGSEGV") && o.context.contains("si_code=0x")
          && o.context.contains("si_addr=0x18"))
    check("context: registers, thread, time", ["pc=0x", "lr=0x", "sp=0x", "fp=0x", "far=0x", "esr=0x", "thread=", "main=0", "time="]
          .allSatisfy { o.context.contains($0) })
    check("context: classified as a synchronous fault, written by the app handler",
          o.context.contains("sync_fault=1") && o.context.contains("via=app"))
}
print("▶️  2. handler on top chaining back like iSH's non-iSH-thread branch")
if let o = crash("chained", "segv") {
    check("still EXC_BAD_ACCESS (got \(o.exception))", o.exception == "EXC_BAD_ACCESS")
    check("the app's record still runs, marked ish-chained", o.context.contains("via=ish-chained") && o.context.contains("si_addr=0x18"))
}
print("▶️  3. a SENT SIGSEGV is re-raised, not swallowed")
if let o = crash("app", "sent") {
    check("dies by SIGSEGV", o.signal == SIGSEGV)
    check("classified as not a synchronous fault", o.context.contains("sync_fault=0"))
}
print("▶️  4. brk trap")
if let o = crash("app", "trap") {
    check("the system records EXC_BREAKPOINT (got \(o.exception))", o.exception == "EXC_BREAKPOINT")
}
print("▶️  5. SIGSEGV sent into a busy thread from another thread")
if let o = crash("app", "busy") {
    check("dies by SIGSEGV (re-raised, not swallowed)", o.signal == SIGSEGV)
    check("classified as not a synchronous fault", o.context.contains("sync_fault=0"))
}

print("▶️  6. source guards (iSH/ISHKernel.m)")
let kernel = (try? String(contentsOf: kernelM, encoding: .utf8)) ?? ""
// [T-crash-quickaction-tlv] The non-iSH forwarding now lives in one helper,
// used by the main-thread fast path and by the `!ish_thread_marker` branch.
let nonIsh = kernel.components(separatedBy: "static void jit_forward_non_ish_signal(int sig, siginfo_t *info, void *ctx) {").dropFirst().first ?? ""
let branch = nonIsh.components(separatedBy: "\n}\n").first ?? ""
check("non-iSH branch chains to the app record", branch.contains("minis_crash_signal_record(sig, info, ctx, \"ish-chained\")"))
check("non-iSH branch ends with minis_signal_finish, no bare raise", branch.contains("minis_signal_finish(sig, info, ctx);") && !branch.contains("raise(sig)"))
check("the `!ish_thread_marker` branch forwards through that helper",
      kernel.contains("if (!ish_thread_marker) {\n        jit_forward_non_ish_signal(sig, info, ctx);\n        return;\n    }"))
check("installer keeps the previous handlers, never itself", kernel.contains("g_prev_crash_actions[s] = current;")
      && kernel.contains("current.sa_sigaction == jit_crash_handler"))
check("JIT recovery and guest-crash paths are still there",
      kernel.contains("uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;") && kernel.contains("=== iSH GUEST CRASH: signal %d ==="))

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
