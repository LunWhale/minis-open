// Tests for [T-jit-recovery-offsets] — the app's JIT crash-recovery handler
// (ISHKernel.m) must use the cpu_state / fiber_frame offsets of the libish it
// links, never hand-copied literals.
//
// Crash (1.15 build 4, iPhone15,2 / iOS 16.2, 2026-09-29 17:20 and 17:22,
// both during `ldid`): EXC_CRASH (SIGILL) "attributed" to the idle main
// thread, a guest thread parked at fiber_exit+4 <- handle_miss_load32_*.
// The shipped handler loaded jit_exit_sp from +0x398 (920) while the iOS
// build's fiber_frame has it at +0x3b8 (952); fiber_exit's `ldr lr, [sp,#0x60]`
// then faulted on a bogus SP and XNU, unable to push the next signal frame,
// killed the process with SIGILL.
//
// Standalone: `swift JITRecoveryOffsetsTests.swift` from this directory.
import Foundation

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func src(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let kernel = src("iSH/ISHKernel.m")
check("ISHKernel.m readable", !kernel.isEmpty)

print("▶️  offsets come from the generated header")
check("includes the libish-generated cpu-offsets.h", kernel.contains("#include \"ish/cpu-offsets.h\""))
check("CRASH_* map to the generated names",
      kernel.contains("#define CRASH_CPU_pc                  CPU_pc")
      && kernel.contains("#define CRASH_CPU_segfault_addr       CPU_segfault_addr")
      && kernel.contains("#define CRASH_CPU_segfault_was_write  CPU_segfault_was_write")
      && kernel.contains("#define CRASH_LOCAL_jit_exit_sp       LOCAL_jit_exit_sp"))
let literal = try! NSRegularExpression(pattern: #"#define CRASH_[A-Za-z_]+\s+[0-9]+"#)
check("no numeric CRASH_* literal left",
      literal.firstMatch(in: kernel, range: NSRange(kernel.startIndex..., in: kernel)) == nil)

print("▶️  recovery body")
check("segfault_was_write stored as a 1-byte bool (the gadgets use strb)",
      kernel.contains("*(bool *)(cpu_ptr + CRASH_CPU_segfault_was_write) = was_write;")
      && !kernel.contains("*(int *)(cpu_ptr + CRASH_CPU_segfault_was_write)"))
check("never resumes on an SP outside this thread's stack (a bad SP = whole-app SIGILL)",
      kernel.contains("exit_sp != 0 && (exit_sp & 0xf) == 0")
      && kernel.contains("exit_sp > cur_sp && exit_sp <= stack_top")
      && kernel.contains("pthread_get_stackaddr_np(pthread_self())"))
check("pinned native-code registers are synced first (jit_crash_sync, weak)",
      kernel.contains("extern bool jit_crash_sync(void *ucontext) __attribute__((weak_import));")
      && kernel.contains("if (jit_crash_sync) jit_crash_sync(uc);"))

print("▶️  generated header (present after deps/build_ish.sh)")
let shipped = src("../../deps/include/ish/cpu-offsets.h")
if shipped.isEmpty {
    print("  ⚠️  deps/include/ish/cpu-offsets.h missing — run deps/build_ish.sh (skipped)")
} else {
    func value(_ name: String, _ text: String) -> Int? {
        guard let r = text.range(of: #"#define \#(name) ([0-9]+)"#, options: .regularExpression) else { return nil }
        return Int(text[r].split(separator: " ")[2])
    }
    check("header defines all four offsets",
          ["CPU_pc", "CPU_segfault_addr", "CPU_segfault_was_write", "LOCAL_jit_exit_sp"].allSatisfy { value($0, shipped) != nil })
    // Documents the drift this fix removes: the old literals were wrong for
    // the iOS build (920 / 832 / 840 vs the header's values).
    check("the old literals really were stale (jit_exit_sp != 920)", value("LOCAL_jit_exit_sp", shipped) != 920)
    let buildIOS = src("../../deps/ish/build-ios/cpu-offsets.h")
    if !buildIOS.isEmpty {
        check("copied header matches deps/ish/build-ios (same libish build)",
              ["CPU_pc", "CPU_segfault_addr", "CPU_segfault_was_write", "LOCAL_jit_exit_sp"]
                .allSatisfy { value($0, shipped) == value($0, buildIOS) })
    }
}

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
