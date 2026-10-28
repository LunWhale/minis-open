//
//  InjectedTweakSelectorGuard.m
//
//  [T-injected-tweak-selector-guard] Keep a jailbreak tweak's unrecognized
//  selector from killing the app.
//
//  Background: Organizer crash point tanDShNvpdyl28yv6yxX4 (1.15 (6),
//  iPhone14,3, iOS 16.6.1) - an uncaught Objective-C exception on the main
//  thread during touch / menu event handling. The Last Exception Backtrace
//  runs CoreFoundation's message forwarding (___forwarding___ /
//  _CF_forwarding_prep_0) straight out of ActionBarReborn.dylib, a jailbreak
//  tweak that adds actions to the text-selection menu. It and CydiaSubstrate
//  were packaged into Minis.app/Frameworks of a re-signed copy. No Minis code
//  is on the stack: the tweak sent a selector its receiver does not implement,
//  and the default forwarding path raises "unrecognized selector".
//
//  What this does: ONLY when hooking code is present in the process (see
//  minis_injectedHookingEvidence), it wraps -[NSObject
//  forwardingTargetForSelector:]. For a selector the receiver genuinely does
//  not handle - the original returns nil AND -methodSignatureForSelector:
//  returns nil, i.e. the class is not doing its own forwarding - the message
//  goes to a sink object whose method for any selector returns nil / 0, and
//  one log line names the class and selector. Everything else (real methods,
//  classes that forward themselves, NSProxy, class-side messages) takes the
//  untouched original path.
//
//  Scope and limits:
//   - Off for a normal install: Minis ships no loose .dylib in its
//     Frameworks and loads no hooking framework, so nothing is installed and
//     an unrecognized selector in our own code still crashes and gets fixed.
//   - The swallowed call returns nil / 0. Fine for object, integer and BOOL
//     returns and for void; a struct-returning selector would read junk, and
//     the tweak's feature behind that call simply does nothing.
//   - Only the unrecognized-selector class of exception is covered; other
//     exceptions a tweak raises still terminate.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>

#pragma mark - Sink

/// Answers any selector with nil / 0. Methods are added on demand.
@interface MinisTweakSelectorSink : NSObject
@end

static id minis_sinkReturnNil(id self, SEL _cmd) {
    return nil;
}

@implementation MinisTweakSelectorSink
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    // The type string only matters for introspection; the IMP ignores any
    // arguments (arm64 callers own their argument registers / stack) and
    // returns 0 in x0.
    class_addMethod(self, sel, (IMP)minis_sinkReturnNil, "@@:");
    return YES;
}
@end

#pragma mark - Guard

static id (*gOriginalForwardingTarget)(id, SEL, SEL) = NULL;
static MinisTweakSelectorSink *gSink = nil;
static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gLogged = nil;

static void minis_logSwallowed(id receiver, SEL sel) {
    NSString *key = [NSString stringWithFormat:@"-[%s %s]",
                     class_getName(object_getClass(receiver)), sel_getName(sel)];
    BOOL first = NO;
    os_unfair_lock_lock(&gLogLock);
    if (gLogged.count < 64 && ![gLogged containsObject:key]) {
        [gLogged addObject:key];
        first = YES;
    }
    os_unfair_lock_unlock(&gLogLock);
    if (first) {
        NSLog(@"[TweakGuard] swallowed unrecognized selector %@ (injected code present; returning nil instead of raising)", key);
    }
}

static id minis_forwardingTargetForSelector(id self, SEL _cmd, SEL sel) {
    id target = gOriginalForwardingTarget(self, _cmd, sel);
    if (target) return target;
    // A class that answers -methodSignatureForSelector: does its own
    // forwarding through -forwardInvocation:; leave it alone.
    if ([self methodSignatureForSelector:sel] != nil) return nil;
    minis_logSwallowed(self, sel);
    return gSink;
}

/// A short description of hooking code found in the process, or nil.
static NSString *minis_injectedHookingEvidence(void) {
    NSString *frameworks = [[[NSBundle mainBundle] bundlePath]
                            stringByAppendingPathComponent:@"Frameworks"];
    NSArray<NSString *> *markers = @[
        @"cydiasubstrate", @"libsubstrate", @"libsubstitute", @"ellekit",
        @"libhooker", @"tweakinject", @"mobilesubstrate", @"/var/jb/", @"/.jbroot",
    ];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        NSString *path = [NSString stringWithUTF8String:raw];
        if (!path) continue;
        NSString *lower = path.lowercaseString;
        for (NSString *marker in markers) {
            if ([lower containsString:marker]) return path.lastPathComponent;
        }
        // Minis ships only .framework bundles; a loose .dylib in its own
        // Frameworks folder was added after the build.
        if ([path hasPrefix:frameworks] && [lower hasSuffix:@".dylib"]) {
            return path.lastPathComponent;
        }
    }
    return nil;
}

@interface MinisInjectedTweakSelectorGuard : NSObject
@end

@implementation MinisInjectedTweakSelectorGuard

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *evidence = minis_injectedHookingEvidence();
        if (!evidence) return;
        Method m = class_getInstanceMethod([NSObject class], @selector(forwardingTargetForSelector:));
        if (!m) return;
        gLogged = [NSMutableSet set];
        gSink = [MinisTweakSelectorSink new];
        gOriginalForwardingTarget = (id (*)(id, SEL, SEL))method_setImplementation(
            m, (IMP)minis_forwardingTargetForSelector);
        NSLog(@"[TweakGuard] injected code detected (%@); unrecognized-selector guard installed", evidence);
    });
}

@end
