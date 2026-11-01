//
//  ISHJITStubs.c
//  Minis
//
//  [T-aojit-interpreter-build] Weak fallbacks for the guest JIT's AOJIT entry
//  points.
//
//  ISHKernel.m calls three symbols that only exist when libish is built with
//  -Djit: jit_control, jit_describe (driven by the AOJIT switch) and
//  jit_crash_sync (the crash handler). A libish built WITHOUT -Djit — the plain
//  interpreter, i.e. exactly what this fork shipped up to 1.14 and the only
//  configuration that needs no executable memory — defines none of them, so the
//  app failed to link:
//
//      "_jit_control",  "_jit_describe",  "_jit_crash_sync"
//
//  `weak_import` on the declarations is not enough here: the linker still
//  requires the symbols to exist when they are referenced from a static archive
//  linked straight into the executable. Weak DEFINITIONS are: an interpreter
//  build links against these inert implementations, and a JIT/AOT build's strong
//  definitions from libish override them with no duplicate-symbol error.
//
//  Behaviour with the stubs:
//    * jit_control  -> -1, so the AOJIT switch logs "unavailable" and does nothing;
//    * jit_describe -> writes an empty string, so the status row reads unavailable;
//    * jit_crash_sync -> false, i.e. "no JIT state to restore" (and in_jit is
//      always 0 without a JIT, so the recovery path is never taken anyway).
//

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

__attribute__((weak)) int jit_control(const char *cmd, size_t len) {
    (void) cmd; (void) len;
    return -1;
}

__attribute__((weak)) size_t jit_describe(char *buf, size_t size) {
    if (buf != NULL && size > 0) buf[0] = '\0';
    return 0;
}

__attribute__((weak)) bool jit_crash_sync(void *ucontext) {
    (void) ucontext;
    return false;
}
