//
//  CrashSignalPolicy.h
//
//  [T-crash-signal-refault] How a crash signal handler must END, shared by the
//  app's handler (Diagnostics/CrashSignalHandler.m) and iSH's JIT recovery
//  handler (iSH/ISHKernel.m) for threads that are not iSH guest threads.
//  Header-only and async-signal-safe: only sigaction() and raise().
//
//  Both handlers used to finish with `SIG_DFL` + `raise(sig)`. For a hardware
//  fault that turns the kernel's EXC_BAD_ACCESS / EXC_BREAKPOINT into a SECOND,
//  software-sent signal, so the system crash report reads
//  `EXC_CRASH (SIGSEGV)` with codes 0 and far 0 - the faulting address, the
//  KERN_* code and any pointer-authentication hint are gone. A main-thread
//  SwiftUI crash on 2026-10-01 (iPhone18,1, iOS 27.0) arrived exactly like
//  that and could not be attributed.
//
//  For a synchronous fault the right ending is: restore SIG_DFL and RETURN.
//  The faulting instruction re-executes, faults again with no handler, and the
//  kernel reports the real exception. A signal somebody SENT (abort(), kill,
//  pthread_kill) is re-raised instead - returning from it would just carry on.
//
//  Telling the two apart: NOT by si_code. Measured on Darwin arm64, a null
//  write and `kill(getpid(), SIGSEGV)` both arrive with si_code 2 (SEGV_ACCERR)
//  and si_pid 0, a `brk` trap with si_code 0, a sent SIGBUS with si_code 1.
//  Returning from a sent signal misread that way swallows it. What does
//  differ is the thread's exception state in the ucontext:
//    - a fault: ESR exception class = data/instruction abort (and FAR equals
//      si_addr), BRK64, undefined instruction, PC alignment or PAC failure;
//    - a sent signal: ESR = SVC (the thread was in a syscall), FAR 0.
//  Only those exception classes count, and a data/instruction abort only when
//  FAR matches si_addr, so a stale abort left in the state by an earlier,
//  transparently handled page fault cannot pass. Anything else - and any
//  non-arm64 build - is treated as sent: re-raised, as before.
//
//  MinisTests/Standalone/CrashSignalRefaultTests.swift compiles this header
//  as shipped.
//

#ifndef CrashSignalPolicy_h
#define CrashSignalPolicy_h

#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/ucontext.h>

/// True when the signal was raised by the instruction that was executing
/// (re-executing it faults again), false for a sent signal or anything we do
/// not recognise.
static inline bool minis_signal_is_synchronous_fault(int sig, const siginfo_t *info, const void *ucontext) {
#if defined(__arm64__)
    if (info == NULL || ucontext == NULL) return false;
    if (info->si_code == SI_USER || info->si_code == SI_QUEUE) return false;
    const ucontext_t *uc = (const ucontext_t *)ucontext;
    if (uc->uc_mcontext == NULL) return false;
    const uint32_t esr = uc->uc_mcontext->__es.__esr;
    const uint64_t far = uc->uc_mcontext->__es.__far;
    const uint32_t ec = (esr >> 26) & 0x3f;
    const bool farMatches = far == (uint64_t)(uintptr_t)info->si_addr;
    switch (sig) {
        case SIGSEGV:
        case SIGBUS:
            // 0x20/0x21 instruction abort, 0x24/0x25 data abort,
            // 0x22 PC alignment, 0x1c PAC failure (FPAC).
            if (ec == 0x20 || ec == 0x21 || ec == 0x24 || ec == 0x25) return farMatches;
            return ec == 0x22 || ec == 0x1c;
        case SIGILL:
            // 0x00 unknown reason (undefined instruction), 0x0e illegal
            // execution state, 0x1c PAC failure.
            return ec == 0x00 || ec == 0x0e || ec == 0x1c;
        case SIGTRAP:
            // 0x3c BRK64: Swift traps, __builtin_trap, assertions.
            return ec == 0x3c;
        default:
            return false;
    }
#else
    (void)sig; (void)info; (void)ucontext;
    return false;
#endif
}

/// Ends a crash handler: back to the default action, then either return (a
/// synchronous fault re-faults into the real exception) or re-raise (a sent
/// signal). The signal is blocked while its handler runs, so a re-raise is
/// delivered - with SIG_DFL - right after the handler returns.
static inline void minis_signal_finish(int sig, const siginfo_t *info, const void *ucontext) {
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
    if (minis_signal_is_synchronous_fault(sig, info, ucontext)) return;
    raise(sig);
}

#endif /* CrashSignalPolicy_h */
