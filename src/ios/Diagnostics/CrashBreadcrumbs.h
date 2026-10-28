#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// [T-crash-breadcrumbs] What the app was doing just before it died.
///
/// A 64 KB ring of short ASCII event lines plus a few fixed "current value"
/// slots (page, sheet, latest resource sample), in a file mapped MAP_SHARED:
/// a write is a memcpy into the mapping and survives the process dying -
/// nothing to flush. Each launch rotates the previous run's file to
/// `crumbs-<launch time>.bin` (the last 5 are kept) for the crash report and
/// for MetricKit diagnostics delivered later.
///
/// Discrete events only (navigation, sheets, foreground/background, list
/// structural changes, request/tool start-end, resource samples). Never call
/// it from scrolling, streaming deltas or cell measurement. Privacy: kinds,
/// counts, enums and 8-hex hashes only - no titles, chat text, URLs, paths,
/// commands or keys.
@interface CrashBreadcrumbs : NSObject

/// Rotate the previous run's file and map a fresh one. Call once, early.
+ (void)start;

/// Append `kind detail`. The same kind again within 250 ms replaces the last
/// line (with a repeat count) instead of taking a new slot.
+ (void)record:(NSString *)kind detail:(NSString *)detail;

/// Set a fixed slot: "page", "sheet" or "res".
+ (void)setSlot:(NSString *)slot value:(NSString *)value;

/// 8 hex characters (FNV-1a 32-bit) - for session ids and the like.
+ (NSString *)hash8:(NSString *)value;

/// Rotated files of earlier runs, newest first.
+ (NSArray<NSString *> *)previousRunFiles;

/// Readable text of a crumbs file: header, fixed slots, then the ring oldest
/// to newest. Empty string if the file is not a crumbs file.
+ (NSString *)renderFileAtPath:(NSString *)path;

/// The previous run whose launch is at or before `date` and closest to it.
+ (nullable NSString *)previousRunFileCoveringDate:(NSDate *)date;

/// The previous run recorded by process `pid`, if its file is still kept.
+ (nullable NSString *)previousRunFileForPid:(int)pid;

/// The directory holding current.bin and the rotated files.
+ (NSString *)directory;

@end

NS_ASSUME_NONNULL_END
