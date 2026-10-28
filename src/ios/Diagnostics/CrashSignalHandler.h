#import <Foundation/Foundation.h>
#include <signal.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs signal handlers for SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE,
/// SIGILL and an NSUncaughtExceptionHandler. On crash, walks the crashing
/// thread's frame-pointer chain and writes the stack to a file at
/// `last_crash_stack.txt` inside Application Support, using only
/// async-signal-safe calls (open/write/close, no malloc/ObjC).
///
/// CrashReporter reads this file on the next launch and includes it in the
/// crash report. The file is deleted after reading.
@interface CrashSignalHandler : NSObject

/// Install handlers. Safe to call once at app launch.
+ (void)install;

/// Path to the crash stack file. Same directory as CrashReporter.hangSnapshotURL.
+ (NSString *)crashStackPath;

/// [T-crash-signal-refault] The previous run's minimal crash context (signal,
/// si_code, si_addr, pc/lr/sp/fp, far/esr, thread, time), kept by `install`
/// when that run wrote one. Empty file / absent when it did not crash on a
/// signal.
+ (NSString *)previousCrashContextPath;

@end

/// [T-crash-signal-refault] For a handler installed on top of this one (iSH's
/// JIT recovery handler): record a signal from a thread that handler does not
/// own. Async-signal-safe. Does not end the signal; the caller does.
void minis_crash_signal_record(int sig, siginfo_t *info, void *_Nullable ucontext, const char *via);

NS_ASSUME_NONNULL_END
