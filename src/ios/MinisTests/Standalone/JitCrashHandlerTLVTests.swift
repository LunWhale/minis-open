#!/usr/bin/env swift
// [T-crash-quickaction-tlv] Crash 2026-10-05 19:21 (1.15, iOS 27.0.1, voice input
// + several streaming replies): main thread EXC_BAD_ACCESS at PC 0, CODESIGNING
// "Invalid Page", via jit_crash_handler+92 <- _sigtramp <-
// _swift_updateClassMetadataImpl <- QuickActionWorkflow metadata completion <-
// QuickActionWorkflow.shared one-time init <- QuickActionObserverModifier.body.
//
// What the report shows (verified against the same-configuration archive,
// where jit_crash_handler+92 is the return address of `blr x8` after
// `adrp x0, in_jit@TLV; ldr x8, [x0]`): x8 = 0, x0 = the `in_jit` TLV
// descriptor. The descriptor thunk, QuickActionWorkflow.shared's once token
// and its metadata cache had ALL reverted to zero (ContentView.body
// initialises the singleton at launch, two hours earlier) - the app's own
// static data around ISHKernel.m's 128 KB static signal altstack was
// overwritten.
//
//   [1] JitAltstack (BEGIN/END block in ISHKernel.m) compiled into a C program:
//       the altstack is its own mapping, writable inside, PROT_NONE one page
//       below and one page above (read back with mach_vm_region), page-rounded.
//   [2] a write one byte past either end faults (child process dies by
//       SIGSEGV/SIGBUS) instead of landing in neighbouring data.
//   [3] Source guards: the handler forwards main-thread signals before any
//       `__thread` read; the installer gives each thread its own guarded
//       altstack and no static altstack array is left; canaries are set and
//       checked.
//
// Run: swift JitCrashHandlerTLVTests.swift   (needs clang)
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let kernel = (try? String(contentsOf: iosRoot.appendingPathComponent("iSH/ISHKernel.m"), encoding: .utf8)) ?? ""
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

guard let block = between(kernel, "// BEGIN JitAltstack", "// END JitAltstack") else {
    print("❌ JitAltstack block not found"); exit(1)
}

print("1/2. Guarded altstack (compiled from ISHKernel.m)")
let program = """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
\(block)
static int prot_at(void *addr) {
    mach_vm_address_t a = (mach_vm_address_t)addr; mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj;
    if (mach_vm_region(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS) return -1;
    if (a > (mach_vm_address_t)addr) return -2;   /* addr is in no region */
    return info.protection;
}
static int child_writes(char *p) {
    pid_t pid = fork();
    if (pid == 0) { *(volatile char *)p = 1; _exit(0); }
    int st = 0; waitpid(pid, &st, 0);
    return WIFSIGNALED(st) ? WTERMSIG(st) : 0;
}
int main(void) {
    size_t page = (size_t)getpagesize();
    char *s = jit_altstack_alloc(SIGSTKSZ);
    printf("R alloc=%d\\n", s != NULL);
    if (!s) return 1;
    size_t size = (SIGSTKSZ + page - 1) & ~(page - 1);
    memset(s, 0xA5, size);
    printf("R inside_rw=%d\\n", prot_at(s) == (VM_PROT_READ | VM_PROT_WRITE) && prot_at(s + size - 1) == (VM_PROT_READ | VM_PROT_WRITE));
    printf("R guard_below=%d\\n", prot_at(s - 1) == VM_PROT_NONE);
    printf("R guard_above=%d\\n", prot_at(s + size) == VM_PROT_NONE);
    printf("R page_aligned=%d\\n", ((size_t)s % page) == 0);
    int below = child_writes(s - 1), above = child_writes(s + size);
    printf("R fault_below=%d\\n", below == SIGSEGV || below == SIGBUS);
    printf("R fault_above=%d\\n", above == SIGSEGV || above == SIGBUS);
    printf("R two_allocs_distinct=%d\\n", jit_altstack_alloc(SIGSTKSZ) != s);
    return 0;
}
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("altstack_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("t.c"), bin = tmp.appendingPathComponent("t")
try? program.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["clang", "-O1", src.path, "-o", bin.path])
check("JitAltstack block compiles standalone", cc == 0)
if cc != 0 { print(ccOut) }
let (_, out) = run(bin.path, [])
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}
check("altstack allocated", r["alloc"] == "1")
check("usable (read/write) over its whole size", r["inside_rw"] == "1")
check("PROT_NONE guard page right below", r["guard_below"] == "1")
check("PROT_NONE guard page right above", r["guard_above"] == "1")
check("page aligned", r["page_aligned"] == "1")
check("a write one byte below faults instead of landing in other data", r["fault_below"] == "1")
check("a write one byte above faults instead of landing in other data", r["fault_above"] == "1")
check("each call gets its own altstack (no sharing between threads)", r["two_allocs_distinct"] == "1")

print("\n3. Source guards (iSH/ISHKernel.m)")
let handler = between(kernel, "static void jit_crash_handler(int sig, siginfo_t *info, void *ctx) {\n", "// Non-JIT crash in an iSH guest thread.") ?? ""
let mainIdx = handler.range(of: "if (pthread_main_np()) {\n        jit_forward_non_ish_signal(sig, info, ctx);\n        return;\n    }")?.lowerBound
let tlvIdx = handler.range(of: "&& in_jit)")?.lowerBound
check("main-thread signals are forwarded first", mainIdx != nil)
check("…before the first `__thread` read (in_jit)", mainIdx != nil && tlvIdx != nil && mainIdx! < tlvIdx!)
let fwd = between(kernel, "static void jit_forward_non_ish_signal(int sig, siginfo_t *info, void *ctx) {", "\n}\n") ?? ""
check("the forwarding helper reads no thread-local storage",
      !fwd.contains("in_jit") && !fwd.contains("ish_thread_marker") && fwd.contains("minis_signal_finish(sig, info, ctx);"))
check("non-iSH threads still forward through the same helper",
      kernel.contains("if (!ish_thread_marker) {\n        jit_forward_non_ish_signal(sig, info, ctx);\n        return;\n    }"))
let installer = between(kernel, "static void install_jit_crash_handler(void) {", "NSLog(@\"ISHKernel: JIT crash recovery handler installed\");") ?? ""
check("installer allocates a guarded altstack per installing thread",
      installer.contains("void *altstack = jit_altstack_alloc(SIGSTKSZ);") && installer.contains("sigaltstack(&ss, NULL);"))
check("no static altstack array left in the app's __bss", !kernel.contains("static char altstack[SIGSTKSZ]"))
check("an altstack this thread already has is kept",
      installer.contains("if (sigaltstack(NULL, &old) != 0 || (old.ss_flags & SS_DISABLE) || old.ss_sp == NULL) {"))
check("bss canaries set at install and checked on a timer, logged once",
      installer.contains("bss_canary_start();") && kernel.contains("dispatch_source_set_event_handler(timer, ^{ bss_canary_check(); });")
      && kernel.contains("[BssCanary] ⚠️ app __bss canary overwritten"))
check("JIT recovery path unchanged",
      kernel.contains("uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;") && kernel.contains("=== iSH GUEST CRASH: signal %d ==="))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
