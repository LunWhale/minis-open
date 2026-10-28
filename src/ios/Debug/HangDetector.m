//
//  HangDetector.m
//

#import "HangDetector.h"

#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/thread_act.h>
#import <os/lock.h>
#import <pthread.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <stdatomic.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>

#if defined(__arm64__)
#import <pthread/stack_np.h>
#endif

#pragma mark - HangFrame / HangEvent

@implementation HangFrame
@end

@implementation HangEvent
@end

#pragma mark - State

static atomic_bool g_running = ATOMIC_VAR_INIT(false);
static atomic_uint_fast64_t g_lastBeat = ATOMIC_VAR_INIT(0);
static atomic_uint_fast32_t g_lastActivity = ATOMIC_VAR_INIT(0);
// Default 1500ms. Codex review 2026-05-13 showed that 1020ms hangs were
// dominated by detector quantization (threshold/4 polling), so we raise
// the threshold and tighten the poll period for finer granularity.
static double g_thresholdMs = 1500.0;
// TEMP(2026-05-14) — when a single hang has been pinned for >=
// kAllThreadsDumpThresholdMs continuously, capture every thread's stack
// once. Helps see what *other* threads (streaming queue, sync queue,
// writer queue) are doing while main is wedged. Only fires once per
// continuous-hang run thanks to g_allThreadsDumpedHash.
static const double kAllThreadsDumpThresholdMs = 3000.0;
static uint64_t g_allThreadsDumpedHash = 0;
// Fixed 100ms poll regardless of threshold — lets us re-sample throughout
// a 10s watchdog window instead of only once per second.
static const useconds_t kPollUs = 100 * 1000;
// [T-hang-suspend-gap] A monitor poll that comes back this late means the
// whole process was not running (suspended in the background, device asleep):
// the main thread was frozen, not busy. That time is excluded from busyMs.
static const double kSuspendGapMs = 1000.0;
// Stack-hash de-dup: when the captured frame addresses match the last
// recorded event exactly, increment a counter on the last event instead
// of pushing a duplicate. Prevents a 10s spin from filling the ring with
// 100 identical entries.
static uint64_t g_lastStackHash = 0;
static uint32_t g_lastStackRepeats = 0;

static CFRunLoopObserverRef g_observer = NULL;
static pthread_t g_monitorThread = (pthread_t)NULL;
static pthread_t g_mainPthread = (pthread_t)NULL;

// [T-ios-mem-footprint-delta-logging] System memory-pressure level, updated by
// a process-wide dispatch memory-pressure source and read by the [MemMonitor]
// sampler. 0=normal, 1=warn, 2=critical. Atomic: source fires on a dispatch
// queue, sampler reads on the monitor thread.
static atomic_uint_fast32_t g_memPressureLevel = ATOMIC_VAR_INIT(0);
static dispatch_source_t g_memPressureSource = nil;

// Mach time -> ms conversion factor, computed once at first use.
static double g_machToMs = 0.0;
/// [T-hang-symbol-section] dladdr names the nearest PRECEDING exported
/// symbol, which is meaningless for a PC outside the image's __text section:
/// a call through a symbol stub (swift_retain / swift_bridgeObjectRelease …)
/// or into the iSH AOT blob came out as "restore_termios" - an unrelated iSH C
/// function hundreds of MB away (field report 2026-10-03, 1.15 (8): PCs
/// Minis+0xeb98160 / +0xeb98178 are the __stubs entries for
/// swift_bridgeObjectRelease / swift_bridgeObjectRetain). Returns the
/// __TEXT section name when the PC is in __TEXT but not in __text, so the
/// frame can be labelled "<__stubs>" instead (copied NUL-terminated into
/// `out`, since sectname is a fixed 16-byte field); false otherwise.
static bool hd_nonCodeTextSection(const Dl_info *info, uintptr_t pc, char out[17]) {
    if (!info || !info->dli_fbase) return false;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)info->dli_fbase;
    if (mh->magic != MH_MAGIC_64) return false;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                uintptr_t slide = (uintptr_t)mh - (uintptr_t)seg->vmaddr;
                const struct section_64 *sect = (const struct section_64 *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
                    uintptr_t lo = (uintptr_t)sect->addr + slide;
                    if (pc >= lo && pc < lo + (uintptr_t)sect->size) {
                        if (strncmp(sect->sectname, "__text", 16) == 0) return false;
                        memcpy(out, sect->sectname, 16);
                        out[16] = 0;
                        return true;
                    }
                }
                return false;
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return false;
}

static void initMachTimebase(void) {
    if (g_machToMs != 0.0) return;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    // mach_continuous_time() returns ticks; ticks * (numer/denom) = nanoseconds.
    g_machToMs = ((double)tb.numer / (double)tb.denom) / 1.0e6;
}

// Ring buffer of captured events, protected by g_eventsLock.
// Capacity intentionally small so dumps are fast and we don't hoard memory.
#define HANG_RING_CAPACITY 64
static NSMutableArray<HangEvent *> *g_events = nil; // append-only ring; capped at HANG_RING_CAPACITY
static os_unfair_lock g_eventsLock = OS_UNFAIR_LOCK_INIT;

#pragma mark - Helpers

static inline double ticksToMs(uint64_t deltaTicks) {
    initMachTimebase();
    return (double)deltaTicks * g_machToMs;
}

/// Walk the frame pointer chain on ARM64. Caller must have suspended `thread`
/// already. Writes up to `maxFrames` PC values into `outFrames` (PC first,
/// then return addresses from the FP chain). Returns the count written.
///
/// SAFETY: this function must NOT call malloc / Objective-C / Foundation
/// APIs while the target thread is suspended — only mach calls + raw
/// pointer reads. Caller does the dladdr resolution after thread_resume.
#if defined(__arm64__)
static int captureFramesARM64(thread_t thread, uintptr_t *outFrames, int maxFrames) {
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr != KERN_SUCCESS) return 0;

    int n = 0;
    uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(state);
    uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(state);
    uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(state);

    if (pc) outFrames[n++] = pc;
    // Some leaf functions don't push fp; include lr explicitly when available
    // and distinct from pc.
    if (lr && lr != pc && n < maxFrames) outFrames[n++] = lr;

    // Walk frame records: at *fp = saved fp, at fp+8 = saved lr.
    while (fp && n < maxFrames) {
        // Defensive sanity: an FP must be 16-byte aligned and non-degenerate.
        if (fp & 0xF) break;
        uintptr_t nextFp = *(uintptr_t *)fp;
        uintptr_t retAddr = *(uintptr_t *)(fp + sizeof(uintptr_t));
        if (retAddr == 0) break;
        outFrames[n++] = retAddr;
        if (nextFp == 0 || nextFp <= fp) break; // end of chain or corruption guard
        fp = nextFp;
    }
    return n;
}
#endif

// TEMP(2026-05-14) — dump every thread's stack to NSLog. Heavy: suspends
// each non-monitor thread briefly, samples up to 32 frames, resumes.
// Caller is responsible for de-duping (we only fire once per continuous
// main-hang run).
static void dumpAllThreadsToLog(thread_t monitorTid, double busyMs) {
    task_t task = mach_task_self();
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(task, &threads, &count) != KERN_SUCCESS) return;

    NSMutableString *out = [NSMutableString stringWithFormat:
        @"[HangDetector] 🧵 ALL-THREADS DUMP busyMs=%.0f threads=%u",
        busyMs, (unsigned)count];

    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_t t = threads[i];
        if (t == monitorTid) continue;

        // Try to get a name via pthread_t. Many threads have nothing.
        pthread_t pt = pthread_from_mach_thread_np(t);
        char nameBuf[64] = {0};
        if (pt) pthread_getname_np(pt, nameBuf, sizeof(nameBuf));

        kern_return_t kr = thread_suspend(t);
        if (kr != KERN_SUCCESS) continue;

        uintptr_t frames[32];
        int n = 0;
#if defined(__arm64__)
        n = captureFramesARM64(t, frames, 32);
#endif
        thread_resume(t);

        if (n <= 0) {
            [out appendFormat:@"\n  tid=0x%x name=\"%s\" (no frames)",
                (unsigned)t, nameBuf];
            continue;
        }

        [out appendFormat:@"\n  tid=0x%x name=\"%s\" frames=%d",
            (unsigned)t, nameBuf, n];
        int show = MIN(n, 8);
        for (int j = 0; j < show; j++) {
            Dl_info info;
            const char *img = "?";
            const char *sym = "?";
            uintptr_t off = 0;
            if (dladdr((const void *)frames[j], &info) != 0) {
                if (info.dli_fname) {
                    const char *slash = strrchr(info.dli_fname, '/');
                    img = slash ? slash + 1 : info.dli_fname;
                }
                if (info.dli_sname) sym = info.dli_sname;
                // [T-hang-symbol-section] No borrowed name for stub / AOT PCs.
                static char sectBuf[17];
                if (hd_nonCodeTextSection(&info, frames[j], sectBuf)) sym = sectBuf;
                if (info.dli_fbase) off = frames[j] - (uintptr_t)info.dli_fbase;
            }
            [out appendFormat:@"\n    #%d %s + 0x%lx %s", j, img,
                (unsigned long)off, sym];
        }
    }

    // Release thread port array.
    vm_deallocate(task, (vm_address_t)threads, count * sizeof(thread_t));

    NSLog(@"%@", out);
}

/// Write the current hang stack to a persistent file so CrashReporter
/// can include it in the next-launch crash report even after SIGKILL.
/// Called from the monitor thread (main thread is hung, so this is safe).
/// Uses POSIX I/O (open/write/close) — no ObjC, no malloc after format.
static void persistHangStackToDisk(NSMutableArray<HangFrame *> *frames, double busyMs, uint32_t repeatCount) {
    static NSString *cachedPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            cachedPath = [dirs[0] stringByAppendingPathComponent:@"last_hang_snapshot.txt"];
        }
    });
    if (!cachedPath) return;

    NSMutableString *out = [NSMutableString stringWithFormat:
        @"Hang: %.0fms repeat=%u\n", busyMs, repeatCount];
    NSUInteger limit = MIN(frames.count, (NSUInteger)30);
    for (NSUInteger i = 0; i < limit; i++) {
        HangFrame *f = frames[i];
        [out appendFormat:@"  #%lu %@ +0x%lx %@\n",
         (unsigned long)i,
         f.imageName ?: @"?",
         (unsigned long)f.imageOffset,
         f.symbol ?: @""];
    }

    int fd = open(cachedPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *utf8 = out.UTF8String;
        write(fd, utf8, strlen(utf8));
        close(fd);
    }
}

#pragma mark - RunLoop observer

// TEMP(2026-05-14) — runloop activity ring buffer. The monitor dumps the
// most recent 30 activities + timestamps when a fresh hang is captured.
// Helps distinguish "stuck in source0 immediately after wakeup" from
// "stuck before timers" or "stuck after long beforeWaiting".
#define ACTIVITY_RING_CAPACITY 30
static struct {
    uint32_t activity;
    uint64_t mach_ts;
} g_activityRing[ACTIVITY_RING_CAPACITY] = {{0}};
static atomic_uint_fast32_t g_activityRingHead = 0;
static atomic_int g_activityRingFilled = 0;
// [T-main-stall-diag] Start of the current main run-loop awake span (main thread only).
static uint64_t g_awakeStart = 0;

static void runLoopObserverCallback(CFRunLoopObserverRef observer,
                                     CFRunLoopActivity activity,
                                     void *info) {
    initMachTimebase();
    uint64_t now = mach_continuous_time();
    atomic_store_explicit(&g_lastBeat, now, memory_order_relaxed);
    atomic_store_explicit(&g_lastActivity, (uint_fast32_t)activity, memory_order_relaxed);
    // Record into ring (single producer = main thread, multiple readers
    // = monitor thread; use relaxed atomic head + plain writes — small
    // race risk on read-side is acceptable for diagnostics).
    uint32_t head = atomic_fetch_add(&g_activityRingHead, 1) % ACTIVITY_RING_CAPACITY;
    g_activityRing[head].activity = (uint32_t)activity;
    g_activityRing[head].mach_ts = now;
    atomic_store_explicit(&g_activityRingFilled, 1, memory_order_relaxed);
    // [T-main-stall-diag] Open an awake span on wake-up; closed by
    // lateBeforeWaitingCallback. Entry also fires on a mode switch while
    // already awake, so only the first opener counts.
    if ((activity == kCFRunLoopAfterWaiting || activity == kCFRunLoopEntry) && g_awakeStart == 0) {
        g_awakeStart = now;
    }
}

#pragma mark - [T-main-stall-diag] Sub-threshold main-thread stalls

// The hang path below fires only at g_thresholdMs (2 s in the field), so the
// stalls users see while browsing - a 30-150 ms freeze as a back swipe starts,
// dropped frames in a list fling (field video 2026-10-03) - never reached the
// log. This measures every main run-loop "awake span": from waking
// (AfterWaiting / Entry) to going back to sleep, closed by a second observer
// ordered AFTER Core Animation's commit so the layout and SwiftUI graph work
// done inside the commit is counted. No frame is committed during a span, so
// a 60 ms span is a 60 ms freeze.
//
// Cost: the main thread does one subtraction and compare per loop iteration;
// the monitor thread, already polling every 100 ms, writes the lines - a
// summary at most every 10 s and only when something was slow, plus one line
// per span >= kStallDetailMs (at most one per second). No display link: an
// always-on CADisplayLink costs a wake-up per frame and perturbs the very
// frame timing it measures (see ThinkingHitchMonitor).
static const double kStallBucketMs[3] = {25.0, 50.0, 100.0};
// Lowered from 200 ms: the back-swipe hitch users report is 100-250 ms, and
// with the marks below each detail line now names its cause. Still at most
// one detail line per second.
static const double kStallDetailMs = 100.0;
// Longer spans are a suspension or a nested run loop in another mode; real
// ones that long are the hang path's, with a stack.
static const double kStallIgnoreMs = 5000.0;
static const double kStallSummaryEveryMs = 10000.0;
static atomic_uint_fast32_t g_stallCount[3];
static atomic_uint_fast32_t g_stallMaxMs = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t g_stallMaxAtMs = ATOMIC_VAR_INIT(0);     // wall clock, ms since 1970
static atomic_uint_fast32_t g_stallDetailMs = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t g_stallDetailAtMs = ATOMIC_VAR_INIT(0);
static CFRunLoopObserverRef g_lateObserver = NULL;

// [T-main-stall-marks] Ring of named main-thread events (written on main only).
#define MARK_RING 16
#define MARK_LABEL 40
static struct { uint64_t ts; char label[MARK_LABEL]; } g_marks[MARK_RING];
static uint32_t g_markHead = 0;          // main thread only
// What the last detail span contained, written on main before g_stallDetailMs
// is published (release) and read by the monitor after it (acquire).
static char g_stallDetailMarks[320];

static uint64_t hd_wallMs(void) {
    return (uint64_t)((CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970) * 1000.0);
}

/// "HH:mm:ss.SSS" local time, so a line can be matched to the log's own
/// timestamps and to the [HomeListPerf] / nav lines around it.
static void hd_formatClock(uint64_t wallMs, char out[16]) {
    time_t secs = (time_t)(wallMs / 1000);
    struct tm tmv;
    localtime_r(&secs, &tmv);
    snprintf(out, 16, "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(wallMs % 1000));
}

static void lateBeforeWaitingCallback(CFRunLoopObserverRef observer,
                                      CFRunLoopActivity activity,
                                      void *info) {
    uint64_t start = g_awakeStart;
    g_awakeStart = 0;
    if (start == 0) return;
    uint64_t now = mach_continuous_time();
    if (now <= start) return;
    double ms = ticksToMs(now - start);
    if (ms < kStallBucketMs[0] || ms >= kStallIgnoreMs) return;
    for (int i = 0; i < 3; i++) {
        if (ms >= kStallBucketMs[i]) atomic_fetch_add_explicit(&g_stallCount[i], 1, memory_order_relaxed);
    }
    uint64_t at = hd_wallMs();
    uint32_t whole = (uint32_t)ms;
    if (whole > atomic_load_explicit(&g_stallMaxMs, memory_order_relaxed)) {
        atomic_store_explicit(&g_stallMaxMs, whole, memory_order_relaxed);
        atomic_store_explicit(&g_stallMaxAtMs, at, memory_order_relaxed);
    }
    if (ms >= kStallDetailMs) {
        // [T-main-stall-marks] The marks made inside this span, oldest first,
        // with their offset from the span start; dropped from the front if
        // they do not fit.
        size_t used = 0;
        g_stallDetailMarks[0] = 0;
        uint32_t n = g_markHead < MARK_RING ? g_markHead : MARK_RING;
        // The last mark BEFORE the span too: a stall often lands a pass or two
        // after the event that set it off (a pop, then the home list pass).
        int before = -1;
        for (uint32_t k = n; k > 0; k--) {
            uint32_t i = (g_markHead - k) % MARK_RING;
            if (g_marks[i].ts < start) before = (int)i;
        }
        if (before >= 0) {
            int w = snprintf(g_stallDetailMarks, sizeof(g_stallDetailMarks), "(after %s -%.0fms)",
                             g_marks[before].label, ticksToMs(start - g_marks[before].ts));
            if (w > 0 && (size_t)w < sizeof(g_stallDetailMarks)) used = (size_t)w;
        }
        for (uint32_t k = n; k > 0; k--) {
            uint32_t i = (g_markHead - k) % MARK_RING;
            if (g_marks[i].ts < start || g_marks[i].ts > now) continue;
            int w = snprintf(g_stallDetailMarks + used, sizeof(g_stallDetailMarks) - used,
                             "%s%s +%.0fms", used ? ", " : "", g_marks[i].label,
                             ticksToMs(g_marks[i].ts - start));
            if (w < 0 || used + (size_t)w >= sizeof(g_stallDetailMarks)) break;
            used += (size_t)w;
        }
        atomic_store_explicit(&g_stallDetailAtMs, at, memory_order_relaxed);
        atomic_store_explicit(&g_stallDetailMs, whole, memory_order_release);
    }
}

/// Monitor-thread side: the per-span detail line and the periodic summary.
static void hd_reportStalls(void) {
    static uint64_t lastSummaryTicks = 0;
    static uint64_t lastDetailTicks = 0;
    uint64_t t = mach_continuous_time();
    char clock[16];

    uint32_t detail = atomic_load_explicit(&g_stallDetailMs, memory_order_acquire);
    if (detail != 0 && (lastDetailTicks == 0 || ticksToMs(t - lastDetailTicks) >= 1000.0)) {
        atomic_store_explicit(&g_stallDetailMs, 0, memory_order_relaxed);
        lastDetailTicks = t;
        hd_formatClock(atomic_load_explicit(&g_stallDetailAtMs, memory_order_relaxed), clock);
        if (g_stallDetailMarks[0]) {
            NSLog(@"[MainStall] 🐢 main thread busy %ums with no frame committed (ended %s) | during: %s", detail, clock, g_stallDetailMarks);
        } else {
            NSLog(@"[MainStall] 🐢 main thread busy %ums with no frame committed (ended %s) | during: no marks", detail, clock);
        }
    }

    if (lastSummaryTicks == 0) { lastSummaryTicks = t; return; }
    double sinceMs = ticksToMs(t - lastSummaryTicks);
    if (sinceMs < kStallSummaryEveryMs) return;
    lastSummaryTicks = t;
    uint32_t c25 = (uint32_t)atomic_exchange_explicit(&g_stallCount[0], 0, memory_order_relaxed);
    uint32_t c50 = (uint32_t)atomic_exchange_explicit(&g_stallCount[1], 0, memory_order_relaxed);
    uint32_t c100 = (uint32_t)atomic_exchange_explicit(&g_stallCount[2], 0, memory_order_relaxed);
    uint32_t maxMs = (uint32_t)atomic_exchange_explicit(&g_stallMaxMs, 0, memory_order_relaxed);
    if (c25 == 0) return;
    hd_formatClock(atomic_load_explicit(&g_stallMaxAtMs, memory_order_relaxed), clock);
    NSLog(@"[MainStall] last %.0fs: busy spans >=25ms=%u >=50ms=%u >=100ms=%u, longest %ums ended %s",
          sinceMs / 1000.0, c25, c50, c100, maxMs, clock);
}

#pragma mark - Monitor thread

static void *monitorThreadMain(void *arg) {
    pthread_setname_np("com.minis.hangdetector.monitor");
    initMachTimebase();

    // [T-hang-suspend-gap] busyMs is measured with mach_continuous_time, which
    // keeps counting while the process is suspended. When iOS suspended the
    // app with the main run loop mid-pass (any activity but BeforeWaiting),
    // the first poll after resume saw the whole suspension as one main-thread
    // stall and captured whatever main happened to run on resume - field
    // reports of "1095217ms" / "55848ms" hangs (2026-10-03, 1.15 (8)) whose
    // start was minutes after the app had gone to the background. Track the
    // monitor thread's own gaps and subtract those belonging to the current
    // beat.
    uint64_t lastPollTicks = 0;
    uint64_t suspendedTicks = 0;   // frozen time since `suspendedBeat`
    uint64_t suspendedBeat = 0;    // the main-thread beat those gaps belong to

    // Monitor cadence: 1/4 of the threshold, clamped. 50ms is a sane default
    // for a 100ms threshold — gives ~2 samples worth of headroom without
    // burning too much CPU on a thread that's mostly sleeping.
    while (atomic_load_explicit(&g_running, memory_order_relaxed)) {
        double thresholdMs = g_thresholdMs; // read once per loop
        usleep(kPollUs);

        if (!atomic_load_explicit(&g_running, memory_order_relaxed)) break;

        {   // [T-hang-suspend-gap]
            uint64_t pollNow = mach_continuous_time();
            if (lastPollTicks != 0 && pollNow > lastPollTicks) {
                double gapMs = ticksToMs(pollNow - lastPollTicks);
                if (gapMs > kSuspendGapMs) {
                    uint64_t beat = atomic_load_explicit(&g_lastBeat, memory_order_relaxed);
                    if (beat != suspendedBeat) { suspendedBeat = beat; suspendedTicks = 0; }
                    suspendedTicks += (pollNow - lastPollTicks);
                    NSLog(@"[HangDetector] monitor gap %.0fms (process suspended / device asleep) — not counted as main-thread hang time", gapMs);
                }
            }
            lastPollTicks = pollNow;
        }

        hd_reportStalls(); // [T-main-stall-diag]

        // ---- [MemMonitor] low-overhead memory footprint sampling ----
        // [T-ios-mem-footprint-delta-logging] Piggyback on this existing
        // background monitor thread (no new timer). Sample app memory ~once a
        // second (every 10 ticks at kPollUs=100ms) and log ONLY when the
        // footprint has moved >= 10MB since the last logged value (rise OR
        // fall), so the log stays quiet under steady memory. All state below is
        // monitor-thread-private (function-local statics) — no cross-thread
        // access, no atomics needed. This block is independent of the hang
        // detection below and must run every tick BEFORE the hang-path
        // `continue`s, so it sits here right after the g_running re-check.
        {
            static const int kMemSampleEvery = 10; // ~1s at 100ms ticks
            static const double kMemDeltaBytes = 10.0 * 1024.0 * 1024.0; // 10MB
            static int memSampleCounter = 0;
            static double lastLoggedFootprint = -1.0; // <0 = not yet baselined
            if (++memSampleCounter >= kMemSampleEvery) {
                memSampleCounter = 0;
                // phys_footprint via TASK_VM_INFO — the metric iOS uses for
                // memory-pressure / jetsam accounting, more representative than
                // resident_size. On task_info failure: skip silently (no log,
                // no lastLogged update), never affecting hang detection.
                task_vm_info_data_t vmInfo;
                mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
                kern_return_t mkr = task_info(mach_task_self(), TASK_VM_INFO,
                                              (task_info_t)&vmInfo, &vmCount);
                if (mkr == KERN_SUCCESS) {
                    double cur = (double)vmInfo.phys_footprint; // bytes
                    if (lastLoggedFootprint < 0.0 ||
                        fabs(cur - lastLoggedFootprint) >= kMemDeltaBytes) {
                        double curMB = cur / 1024.0 / 1024.0;
                        double lastMB = lastLoggedFootprint < 0.0 ? curMB
                                          : lastLoggedFootprint / 1024.0 / 1024.0;

                        // System-wide totals + free water-line via host_statistics64.
                        // Free ≈ (free + inactive) pages: inactive is reclaimable,
                        // so it counts as effectively available. All best-effort:
                        // on failure these stay 0 and we just print "-".
                        double totalMB = (double)[NSProcessInfo processInfo].physicalMemory / 1024.0 / 1024.0;
                        double freeMB = -1.0;
                        vm_statistics64_data_t vmStat;
                        mach_msg_type_number_t statCount = HOST_VM_INFO64_COUNT;
                        if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                                              (host_info64_t)&vmStat, &statCount) == KERN_SUCCESS) {
                            vm_size_t pageSize = 0;
                            if (host_page_size(mach_host_self(), &pageSize) != KERN_SUCCESS) pageSize = 16384;
                            double freeBytes = ((double)vmStat.free_count + (double)vmStat.inactive_count) * (double)pageSize;
                            freeMB = freeBytes / 1024.0 / 1024.0;
                        }

                        // App memory pressure water-line (per-process headroom
                        // before jetsam) + system pressure level from the source.
                        uint32_t plevel = (uint32_t)atomic_load_explicit(&g_memPressureLevel, memory_order_relaxed);
                        const char *pname = plevel >= 2 ? "CRITICAL" : (plevel == 1 ? "warn" : "normal");

                        if (freeMB >= 0.0) {
                            NSLog(@"[MemMonitor] 📈 footprint=%.1fMB (Δ%+.1fMB) | sys free=%.0f/%.0fMB (%.0f%%) | pressure=%s",
                                  curMB, curMB - lastMB, freeMB, totalMB,
                                  totalMB > 0 ? (freeMB / totalMB * 100.0) : 0.0, pname);
                        } else {
                            NSLog(@"[MemMonitor] 📈 footprint=%.1fMB (Δ%+.1fMB) | sys free=- /%.0fMB | pressure=%s",
                                  curMB, curMB - lastMB, totalMB, pname);
                        }
                        lastLoggedFootprint = cur;
                    }
                }
            }
        }

        uint64_t lastBeat = atomic_load_explicit(&g_lastBeat, memory_order_relaxed);
        if (lastBeat == 0) continue; // observer hasn't fired yet
        uint32_t activity = (uint32_t)atomic_load_explicit(&g_lastActivity, memory_order_relaxed);

        // BeforeWaiting = main thread idle, waiting for next event. Not a hang.
        if (activity == kCFRunLoopBeforeWaiting) {
            // TEMP(2026-05-14) — runloop fully drained → main thread is
            // healthy. Reset stack-hash de-dup state so the next hang
            // run starts fresh (different stack OR same stack treated as
            // a new event, with its own ALL-THREADS dump opportunity).
            if (g_lastStackRepeats > 0) {
                g_lastStackHash = 0;
                g_lastStackRepeats = 0;
                g_allThreadsDumpedHash = 0;
            }
            continue;
        }

        uint64_t now = mach_continuous_time();
        if (now <= lastBeat) continue;
        // [T-hang-suspend-gap] Minus the time the process was frozen since
        // this beat; a stall that was all suspension is no hang at all.
        uint64_t span = now - lastBeat;
        uint64_t frozen = (lastBeat == suspendedBeat) ? suspendedTicks : 0;
        if (frozen >= span) continue;
        double busyMs = ticksToMs(span - frozen);
        if (busyMs < thresholdMs) continue;

        // ---- HANG DETECTED ----

        // Capture stack with the main thread suspended. Only mach calls +
        // pointer reads inside this critical section.
        thread_t mainMachThread = pthread_mach_thread_np(g_mainPthread);
        if (mainMachThread == MACH_PORT_NULL) continue;

        // Reject capturing the monitor itself (defensive — we never run on main).
        if (mach_thread_self() == mainMachThread) {
            mach_port_deallocate(mach_task_self(), mach_thread_self());
            continue;
        }
        // Drop the self-port allocated by mach_thread_self() to keep counts clean.
        mach_port_deallocate(mach_task_self(), mach_thread_self());

        kern_return_t kr = thread_suspend(mainMachThread);
        if (kr != KERN_SUCCESS) continue;

        uintptr_t frames[64];
        int frameCount = 0;
#if defined(__arm64__)
        frameCount = captureFramesARM64(mainMachThread, frames, 64);
#endif

        thread_resume(mainMachThread);

        if (frameCount <= 0) continue;

        // ---- POST-CAPTURE: now we can do whatever (no main lock contention). ----

        // First: idle filter. The main thread's RunLoop spends most of its
        // time blocked in mach_msg waiting for the next event — that is
        // not a hang. If the PC (frames[0]) lives inside
        // libsystem_kernel.dylib (any mach_msg* / __semwait_signal etc.)
        // and the immediate caller is CoreFoundation's runloop kernel, we
        // discard the event before it pollutes the ring buffer.
        //
        // We do this with dladdr on at most the first two frames so the
        // common "idle" case bails out before we allocate the full
        // resolved array.
        Dl_info leafInfo;
        if (dladdr((const void *)frames[0], &leafInfo) != 0 && leafInfo.dli_fname) {
            const char *base = strrchr(leafInfo.dli_fname, '/');
            base = base ? base + 1 : leafInfo.dli_fname;
            if (strstr(base, "libsystem_kernel") != NULL) {
                // Almost certainly RunLoop idle. Refresh the heartbeat so
                // we don't fire again next loop on the same wait.
                atomic_store_explicit(&g_lastBeat, mach_continuous_time(), memory_order_relaxed);
                continue;
            }
        }

        // Compute a fast 64-bit hash of the PC frames so we can de-dup
        // when the main thread is spinning on the same call site across
        // multiple samples (typical for a 10s watchdog wait — N samples
        // of the same fillLayoutHole frame). FNV-1a, plenty for this use.
        uint64_t hash = 0xcbf29ce484222325ULL;
        for (int i = 0; i < frameCount; i++) {
            uint64_t v = (uint64_t)frames[i];
            for (int b = 0; b < 8; b++) {
                hash ^= (v & 0xff);
                hash *= 0x100000001b3ULL;
                v >>= 8;
            }
        }

        NSTimeInterval nowSec = [[NSDate date] timeIntervalSince1970];

        // Same-stack repeat: bump the last event's counter + lastSeenAt
        // and log a single repeat line instead of a full dump.
        os_unfair_lock_lock(&g_eventsLock);
        BOOL coalesced = NO;
        HangEvent *coalesceTarget = nil;
        if (hash == g_lastStackHash && g_events.count > 0) {
            coalesceTarget = g_events.lastObject;
            coalesceTarget.repeatCount += 1;
            coalesceTarget.lastSeenAt = nowSec;
            coalesceTarget.durationMs = busyMs; // refresh to current busy time
            g_lastStackRepeats += 1;
            coalesced = YES;
        }
        os_unfair_lock_unlock(&g_eventsLock);

        if (coalesced) {
            // Emit a single short "still pinned" line per repeat. Avoids
            // duplicating 64 frame addresses every 100ms when nothing
            // has actually changed.
            NSLog(@"[HangDetector] ⏳ MAIN STILL PINNED %.0fms (activity=0x%x) repeat=%u",
                  busyMs, activity, g_lastStackRepeats);
            if (coalesceTarget) {
                persistHangStackToDisk(coalesceTarget.frames, busyMs, g_lastStackRepeats);
            }
            // TEMP(2026-05-14) — once per continuous main-hang run, when
            // the hang has been pinned >=3s, dump every thread's stack so
            // we can see what background queues are doing while main is
            // wedged. g_allThreadsDumpedHash gates re-fire until a new
            // stack hash takes over (i.e. main recovered and re-stuck on
            // something different).
            if (busyMs >= kAllThreadsDumpThresholdMs && g_allThreadsDumpedHash != hash) {
                g_allThreadsDumpedHash = hash;
                thread_t selfTid = mach_thread_self();
                dumpAllThreadsToLog(selfTid, busyMs);
                mach_port_deallocate(mach_task_self(), selfTid);
            }
            // DO NOT reset lastBeat — we want the next poll to still see
            // the main thread as hung if it hasn't recovered.
            continue;
        }

        // New stack — full resolve + log.
        g_lastStackHash = hash;
        g_lastStackRepeats = 1;

        NSMutableArray<HangFrame *> *resolved = [NSMutableArray arrayWithCapacity:frameCount];
        for (int i = 0; i < frameCount; i++) {
            HangFrame *f = [HangFrame new];
            f.address = frames[i];
            Dl_info info;
            if (dladdr((const void *)frames[i], &info) != 0) {
                if (info.dli_fname) {
                    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
                    f.imageName = [path lastPathComponent];
                }
                if (info.dli_fbase) {
                    f.imageOffset = frames[i] - (uintptr_t)info.dli_fbase;
                }
                // [T-hang-symbol-section] A PC in __stubs / __ish_aot gets its
                // section name, not the nearest exported symbol before it.
                char sect[17];
                if (hd_nonCodeTextSection(&info, frames[i], sect)) {
                    f.symbol = [NSString stringWithFormat:@"<%s>", sect];
                } else if (info.dli_sname) {
                    f.symbol = [NSString stringWithUTF8String:info.dli_sname];
                }
            }
            [resolved addObject:f];
        }

        HangEvent *event = [HangEvent new];
        event.timestamp = nowSec;
        event.lastSeenAt = nowSec;
        event.durationMs = busyMs;
        event.runLoopActivity = activity;
        event.frames = resolved;
        event.repeatCount = 1;

        os_unfair_lock_lock(&g_eventsLock);
        if (!g_events) g_events = [NSMutableArray arrayWithCapacity:HANG_RING_CAPACITY];
        if (g_events.count >= HANG_RING_CAPACITY) [g_events removeObjectAtIndex:0];
        [g_events addObject:event];
        NSUInteger total = g_events.count;
        os_unfair_lock_unlock(&g_eventsLock);

        // Surface the most-likely-relevant frames in the daily log so the
        // event is grep-able even without the structured dump RPC.
        NSMutableString *summary = [NSMutableString stringWithFormat:
            @"[HangDetector] ⚠️ MAIN HANG %.0fms (activity=0x%x) buffered=%lu",
            busyMs, activity, (unsigned long)total];
        NSUInteger logFrames = MIN(resolved.count, (NSUInteger)8);
        for (NSUInteger i = 0; i < logFrames; i++) {
            HangFrame *frame = resolved[i];
            [summary appendFormat:@"\n  #%lu %@ + 0x%lx %@",
             (unsigned long)i,
             frame.imageName ?: @"?",
             (unsigned long)frame.imageOffset,
             frame.symbol ?: @""];
        }
        NSLog(@"%@", summary);
        persistHangStackToDisk(resolved, busyMs, 1);

        // TEMP(2026-05-14) — emit recent runloop activity sequence so we
        // can see what the main thread was doing in the seconds leading
        // up to the hang. Walks the ring backwards from current head.
        if (atomic_load_explicit(&g_activityRingFilled, memory_order_relaxed)) {
            uint32_t head = atomic_load_explicit(&g_activityRingHead, memory_order_relaxed);
            NSMutableString *trail = [NSMutableString stringWithString:
                @"[HangDetector] runloop activity trail (newest→oldest, mach_continuous_time deltas):"];
            uint64_t now2 = mach_continuous_time();
            for (int i = 0; i < ACTIVITY_RING_CAPACITY; i++) {
                int idx = (int)((head + ACTIVITY_RING_CAPACITY - 1 - i) % ACTIVITY_RING_CAPACITY);
                uint64_t ts = g_activityRing[idx].mach_ts;
                if (ts == 0) break;
                uint32_t act = g_activityRing[idx].activity;
                double agoMs = ticksToMs(now2 - ts);
                // CFRunLoopActivity flag → short label.
                const char *name = "?";
                switch (act) {
                    case kCFRunLoopEntry:         name = "Entry"; break;
                    case kCFRunLoopBeforeTimers:  name = "BeforeTimers"; break;
                    case kCFRunLoopBeforeSources: name = "BeforeSources"; break;
                    case kCFRunLoopBeforeWaiting: name = "BeforeWaiting"; break;
                    case kCFRunLoopAfterWaiting:  name = "AfterWaiting"; break;
                    case kCFRunLoopExit:          name = "Exit"; break;
                    default: break;
                }
                [trail appendFormat:@" %s(-%.0fms)", name, agoMs];
            }
            NSLog(@"%@", trail);
        }

        // DO NOT reset lastBeat. If main thread is still stuck on the
        // next poll, the next iteration will hit "coalesce" path above
        // (cheap) and emit a repeat line. Only the natural runloop tick
        // (CFRunLoopObserver callback in observeRunLoop) updates
        // lastBeat — recovery is detected then.
    }
    return NULL;
}

#pragma mark - HangDetector class

@implementation HangDetector

+ (BOOL)isRunning {
    return atomic_load_explicit(&g_running, memory_order_relaxed);
}

+ (double)thresholdMs {
    return g_thresholdMs;
}

+ (NSUInteger)eventCount {
    os_unfair_lock_lock(&g_eventsLock);
    NSUInteger n = g_events.count;
    os_unfair_lock_unlock(&g_eventsLock);
    return n;
}

+ (BOOL)startWithThresholdMs:(double)thresholdMs {
    if (atomic_load_explicit(&g_running, memory_order_relaxed)) return NO;

    // Clamp.
    if (thresholdMs < 16.0) thresholdMs = 16.0;
    if (thresholdMs > 5000.0) thresholdMs = 5000.0;
    g_thresholdMs = thresholdMs;

    // Capture the main pthread for cross-thread suspends. We rely on the
    // monitor only running while the main thread is alive (i.e. for the
    // app's whole lifetime).
    g_mainPthread = pthread_from_mach_thread_np(pthread_mach_thread_np(pthread_self()));
    // If we're not on the main thread when start is called, look up main
    // via NSThread's main thread directly.
    if (![NSThread isMainThread]) {
        // Run a no-op block on main to capture the main pthread reliably.
        dispatch_sync(dispatch_get_main_queue(), ^{
            g_mainPthread = pthread_self();
        });
    } else {
        g_mainPthread = pthread_self();
    }
    if (!g_mainPthread) return NO;

    initMachTimebase();
    atomic_store_explicit(&g_lastBeat, mach_continuous_time(), memory_order_relaxed);
    atomic_store_explicit(&g_lastActivity, (uint_fast32_t)kCFRunLoopBeforeSources, memory_order_relaxed);
    atomic_store_explicit(&g_running, true, memory_order_release);

    // Install observer on main runloop, all common modes.
    CFRunLoopObserverContext ctx = {0};
    g_observer = CFRunLoopObserverCreate(
        NULL,
        kCFRunLoopAllActivities,
        true, // repeats
        0,
        runLoopObserverCallback,
        &ctx);
    CFRunLoopAddObserver(CFRunLoopGetMain(), g_observer, kCFRunLoopCommonModes);
    // [T-main-stall-diag] Ordered last, after Core Animation's commit
    // observer, so the commit's layout / SwiftUI work falls inside the span.
    g_lateObserver = CFRunLoopObserverCreate(
        NULL, kCFRunLoopBeforeWaiting, true, LONG_MAX, lateBeforeWaitingCallback, &ctx);
    CFRunLoopAddObserver(CFRunLoopGetMain(), g_lateObserver, kCFRunLoopCommonModes);

    // Spin the monitor thread.
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int err = pthread_create(&g_monitorThread, &attr, monitorThreadMain, NULL);
    pthread_attr_destroy(&attr);
    if (err != 0) {
        atomic_store_explicit(&g_running, false, memory_order_release);
        if (g_observer) {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), g_observer, kCFRunLoopCommonModes);
            CFRelease(g_observer);
            g_observer = NULL;
        }
        if (g_lateObserver) {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), g_lateObserver, kCFRunLoopCommonModes);
            CFRelease(g_lateObserver);
            g_lateObserver = NULL;
        }
        return NO;
    }

    // [T-ios-mem-footprint-delta-logging] Process-wide memory-pressure source:
    // updates g_memPressureLevel so the [MemMonitor] sampler can report the
    // system pressure water-line. Event-driven (no polling cost); the handler
    // also logs transitions immediately since a pressure change is significant.
    if (g_memPressureSource == nil) {
        unsigned long mask = DISPATCH_MEMORYPRESSURE_NORMAL |
                             DISPATCH_MEMORYPRESSURE_WARN |
                             DISPATCH_MEMORYPRESSURE_CRITICAL;
        g_memPressureSource = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, mask,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
        if (g_memPressureSource) {
            dispatch_source_set_event_handler(g_memPressureSource, ^{
                unsigned long flags = dispatch_source_get_data(g_memPressureSource);
                uint32_t level = 0;
                const char *name = "normal";
                if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) { level = 2; name = "CRITICAL"; }
                else if (flags & DISPATCH_MEMORYPRESSURE_WARN) { level = 1; name = "warn"; }
                atomic_store_explicit(&g_memPressureLevel, level, memory_order_relaxed);
                NSLog(@"[MemMonitor] ⚠️ memory pressure → %s", name);
            });
            dispatch_resume(g_memPressureSource);
        }
    }

    NSLog(@"[HangDetector] started thresholdMs=%.0f", thresholdMs);
    return YES;
}

+ (void)stop {
    if (!atomic_load_explicit(&g_running, memory_order_relaxed)) return;
    atomic_store_explicit(&g_running, false, memory_order_release);

    if (g_observer) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), g_observer, kCFRunLoopCommonModes);
        CFRelease(g_observer);
        g_observer = NULL;
    }
    if (g_lateObserver) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), g_lateObserver, kCFRunLoopCommonModes);
        CFRelease(g_lateObserver);
        g_lateObserver = NULL;
    }
    // [T-ios-mem-footprint-delta-logging] Tear down the memory-pressure source.
    if (g_memPressureSource) {
        dispatch_source_cancel(g_memPressureSource);
        g_memPressureSource = nil;
    }
    // Monitor thread is detached; it will exit on its next loop check.
    g_monitorThread = (pthread_t)NULL;
    NSLog(@"[HangDetector] stopped");
}

+ (NSArray<HangEvent *> *)dumpLast:(NSUInteger)last clear:(BOOL)clear {
    os_unfair_lock_lock(&g_eventsLock);
    NSArray<HangEvent *> *snapshot;
    if (last == 0 || last >= g_events.count) {
        snapshot = [g_events copy] ?: @[];
    } else {
        NSRange r = NSMakeRange(g_events.count - last, last);
        snapshot = [g_events subarrayWithRange:r];
    }
    if (clear && g_events.count > 0) {
        [g_events removeAllObjects];
    }
    os_unfair_lock_unlock(&g_eventsLock);
    return snapshot;
}

+ (void)mark:(NSString *)label {
    if (!pthread_main_np()) return;
    uint32_t i = g_markHead % MARK_RING;
    g_marks[i].ts = mach_continuous_time();
    strlcpy(g_marks[i].label, label.UTF8String ?: "?", MARK_LABEL);
    g_markHead++;
}

+ (void)clearEvents {
    os_unfair_lock_lock(&g_eventsLock);
    [g_events removeAllObjects];
    os_unfair_lock_unlock(&g_eventsLock);
}

@end
