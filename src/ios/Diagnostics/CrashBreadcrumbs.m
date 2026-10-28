#import "CrashBreadcrumbs.h"

#import <fcntl.h>
#import <os/lock.h>
#import <sys/mman.h>
#import <sys/time.h>
#import <unistd.h>

// [T-crash-breadcrumbs] File layout (all little-endian, fixed size):
//   header   64 bytes   magic, version, pid, launch time, next sequence
//   slots    3 x 256    "page", "sheet", "res" - latest value, NUL-terminated
//   ring     512 x 128  one event line per entry, NUL-terminated
// Compile-time constants (enum), so they can size arrays.
enum {
    kHeaderSize = 64,
    kSlotSize = 256,
    kSlotCount = 3,
    kEntrySize = 128,
    kEntryCount = 512,     // 64 KB ring
    kFileSize = kHeaderSize + kSlotSize * kSlotCount + kEntrySize * kEntryCount,
};
static const uint32_t kMagic = 0x4D435242;   // "BRCM"
static const uint32_t kVersion = 1;
static const uint64_t kCoalesceMs = 250;
static const NSUInteger kKeepRuns = 5;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t pid;
    uint32_t entryCount;
    uint64_t launchMs;
    uint64_t nextSeq;          // sequence of the NEXT entry; entry = seq % entryCount
    uint8_t reserved[kHeaderSize - 32];
} CrumbHeader;

static uint8_t *gMap = NULL;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static char gLastKind[24] = {0};
static uint64_t gLastMs = 0;
static uint32_t gLastRepeat = 0;

static uint64_t now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

static int crumb_slot_index(NSString *slot) {
    if ([slot isEqualToString:@"page"]) return 0;
    if ([slot isEqualToString:@"sheet"]) return 1;
    if ([slot isEqualToString:@"res"]) return 2;
    return -1;
}

static NSString *crumb_slot_name(int i) {
    return i == 0 ? @"page" : (i == 1 ? @"sheet" : @"res");
}

static uint8_t *entry_ptr(uint8_t *map, uint64_t seq) {
    return map + kHeaderSize + kSlotSize * kSlotCount + (size_t)(seq % kEntryCount) * kEntrySize;
}

/// Drops a UTF-8 sequence that snprintf's truncation cut short at the end of
/// `s`, so a rendered line never holds a broken character.
static void trim_partial_utf8(char *s) {
    size_t n = strlen(s);
    size_t i = n;
    // Walk back over continuation bytes (at most 3) to the lead byte.
    while (i > 0 && n - i < 4 && (((unsigned char)s[i - 1]) & 0xC0) == 0x80) i--;
    if (i == 0) return;
    unsigned char lead = (unsigned char)s[i - 1];
    size_t need = (lead & 0x80) == 0 ? 1 : (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
    if (n - (i - 1) < need) s[i - 1] = '\0';
}

/// Copies at most `cap - 1` bytes of `s` and terminates; never splits a UTF-8
/// sequence.
static void copy_cstr(uint8_t *dst, size_t cap, const char *s) {
    size_t n = strlen(s);
    if (n > cap - 1) {
        n = cap - 1;
        while (n > 0 && (((unsigned char)s[n]) & 0xC0) == 0x80) n--;
    }
    memcpy(dst, s, n);
    memset(dst + n, 0, cap - n);
}

@implementation CrashBreadcrumbs

+ (NSString *)directory {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        ?: NSTemporaryDirectory();
    return [support stringByAppendingPathComponent:@"Crumbs"];
}

+ (NSString *)currentPath {
    return [[self directory] stringByAppendingPathComponent:@"current.bin"];
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [self directory];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *current = [self currentPath];

        // Rotate the previous run, named by ITS launch time.
        NSData *head = [NSData dataWithContentsOfFile:current options:NSDataReadingMappedIfSafe error:nil];
        if (head.length >= kHeaderSize) {
            const CrumbHeader *h = (const CrumbHeader *)head.bytes;
            if (h->magic == kMagic) {
                NSString *name = [NSString stringWithFormat:@"crumbs-%llu.bin", (unsigned long long)h->launchMs];
                NSString *dest = [dir stringByAppendingPathComponent:name];
                [fm removeItemAtPath:dest error:nil];
                [fm moveItemAtPath:current toPath:dest error:nil];
            }
        }
        NSArray<NSString *> *old = [self previousRunFiles];
        for (NSUInteger i = kKeepRuns; i < old.count; i++) [fm removeItemAtPath:old[i] error:nil];

        int fd = open(current.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) return;
        if (ftruncate(fd, (off_t)kFileSize) != 0) { close(fd); return; }
        void *map = mmap(NULL, kFileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (map == MAP_FAILED) return;
        memset(map, 0, kFileSize);
        CrumbHeader *h = (CrumbHeader *)map;
        h->magic = kMagic;
        h->version = kVersion;
        h->pid = (uint32_t)getpid();
        h->entryCount = kEntryCount;
        h->launchMs = now_ms();
        h->nextSeq = 0;
        gMap = map;
    });
}

+ (void)record:(NSString *)kind detail:(NSString *)detail {
    if (!gMap) return;
    const char *k = kind.UTF8String ?: "?";
    const char *d = detail.UTF8String ?: "";
    uint64_t ms = now_ms();
    os_unfair_lock_lock(&gLock);
    CrumbHeader *h = (CrumbHeader *)gMap;
    BOOL coalesce = h->nextSeq > 0 && strncmp(gLastKind, k, sizeof(gLastKind)) == 0 && ms - gLastMs < kCoalesceMs;
    uint64_t seq = coalesce ? h->nextSeq - 1 : h->nextSeq;
    gLastRepeat = coalesce ? gLastRepeat + 1 : 1;
    char line[kEntrySize];
    if (gLastRepeat > 1) {
        snprintf(line, sizeof(line), "%llu %llu %s %s (x%u)", (unsigned long long)seq, (unsigned long long)ms, k, d, gLastRepeat);
    } else {
        snprintf(line, sizeof(line), "%llu %llu %s %s", (unsigned long long)seq, (unsigned long long)ms, k, d);
    }
    trim_partial_utf8(line);
    copy_cstr(entry_ptr(gMap, seq), kEntrySize, line);
    if (!coalesce) h->nextSeq = seq + 1;
    strlcpy(gLastKind, k, sizeof(gLastKind));
    gLastMs = ms;
    os_unfair_lock_unlock(&gLock);
}

+ (void)setSlot:(NSString *)slot value:(NSString *)value {
    if (!gMap) return;
    int i = crumb_slot_index(slot);
    if (i < 0) return;
    char line[kSlotSize];
    snprintf(line, sizeof(line), "%llu %s", (unsigned long long)now_ms(), value.UTF8String ?: "");
    trim_partial_utf8(line);
    os_unfair_lock_lock(&gLock);
    copy_cstr(gMap + kHeaderSize + kSlotSize * (size_t)i, kSlotSize, line);
    os_unfair_lock_unlock(&gLock);
}

+ (NSString *)hash8:(NSString *)value {
    uint32_t h = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)(value.UTF8String ?: ""); *p; p++) {
        h ^= *p;
        h *= 16777619u;
    }
    return [NSString stringWithFormat:@"%08x", h];
}

+ (NSArray<NSString *> *)previousRunFiles {
    NSString *dir = [self directory];
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray<NSString *> *runs = [NSMutableArray array];
    for (NSString *n in names) {
        if ([n hasPrefix:@"crumbs-"] && [n hasSuffix:@".bin"]) [runs addObject:[dir stringByAppendingPathComponent:n]];
    }
    // Names carry the launch time in ms, all the same width for years.
    [runs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [b compare:a]; }];
    return runs;
}

+ (nullable NSString *)previousRunFileCoveringDate:(NSDate *)date {
    uint64_t target = (uint64_t)(date.timeIntervalSince1970 * 1000);
    for (NSString *path in [self previousRunFiles]) {   // newest first
        NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
        uint64_t launch = strtoull([[name substringFromIndex:7] UTF8String], NULL, 10);
        if (launch <= target) return path;
    }
    return nil;
}

+ (nullable NSString *)previousRunFileForPid:(int)pid {
    for (NSString *path in [self previousRunFiles]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        NSData *head = [fh readDataOfLength:kHeaderSize];
        [fh closeFile];
        if (head.length < kHeaderSize) continue;
        const CrumbHeader *h = (const CrumbHeader *)head.bytes;
        if (h->magic == kMagic && (int)h->pid == pid) return path;
    }
    return nil;
}

+ (NSString *)renderFileAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length < kFileSize) return @"";
    const uint8_t *map = data.bytes;
    const CrumbHeader *h = (const CrumbHeader *)map;
    if (h->magic != kMagic || h->entryCount != kEntryCount) return @"";
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"crumbs v%u pid=%u launchMs=%llu events=%llu\n", h->version, h->pid,
        (unsigned long long)h->launchMs, (unsigned long long)h->nextSeq];
    for (int i = 0; i < kSlotCount; i++) {
        const char *s = (const char *)(map + kHeaderSize + kSlotSize * (size_t)i);
        size_t len = strnlen(s, kSlotSize);
        if (len) [out appendFormat:@"[%@] %@\n", crumb_slot_name(i),
                     [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding] ?: @"?"];
    }
    uint64_t first = h->nextSeq > kEntryCount ? h->nextSeq - kEntryCount : 0;
    for (uint64_t seq = first; seq < h->nextSeq; seq++) {
        const char *s = (const char *)(map + kHeaderSize + kSlotSize * kSlotCount + (size_t)(seq % kEntryCount) * kEntrySize);
        size_t len = strnlen(s, kEntrySize);
        if (!len) continue;
        [out appendString:[[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding] ?: @"?"];
        [out appendString:@"\n"];
    }
    return out;
}

@end
