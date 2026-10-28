#!/usr/bin/env swift
// [T-injected-tweak-selector-guard] Tests for Shared/InjectedTweakSelectorGuard.m.
//
// Builds the SHIPPING .m into two macOS test binaries with clang:
//   A) linked against a dummy "libsubstitute_guardtest.dylib" - the guard must
//      detect hooking code and install itself;
//   B) without it - the guard must stay off, so an unrecognized selector still
//      raises (our own bugs keep crashing and get fixed).
// Checked in A: an unrecognized selector returns nil instead of raising; real
// methods, a class that forwards through -forwardInvocation:, and
// respondsToSelector: are untouched; one [TweakGuard] line per selector.
//
// Run: swift InjectedTweakSelectorGuardTests.swift
import Foundation

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let guardFile = here.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Shared/InjectedTweakSelectorGuard.m")
guard FileManager.default.fileExists(atPath: guardFile.path) else { print("❌ missing \(guardFile.path)"); exit(1) }

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
func run(_ exe: String, _ args: [String], env: [String: String]? = nil) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    if let env { p.environment = env }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tweakguard-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let dummy = tmp.appendingPathComponent("dummy.c")
try! "int guardtest_dummy(void) { return 1; }\n".write(to: dummy, atomically: true, encoding: .utf8)
let dylib = tmp.appendingPathComponent("libsubstitute_guardtest.dylib")

let harness = tmp.appendingPathComponent("main.m")
try! #"""
#import <Foundation/Foundation.h>
#import <objc/message.h>
extern int guardtest_dummy(void) __attribute__((weak_import));

@interface Plain : NSObject
- (NSString *)real;
@end
@implementation Plain
- (NSString *)real { return @"real"; }
@end

/// Forwards everything it does not implement to a Plain instance.
@interface Forwarder : NSObject
@end
@implementation Forwarder
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [Plain instanceMethodSignatureForSelector:sel] ?: [super methodSignatureForSelector:sel];
}
- (void)forwardInvocation:(NSInvocation *)inv { [inv invokeWithTarget:[Plain new]]; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (guardtest_dummy) guardtest_dummy();
        Plain *p = [Plain new];
        SEL bogus = NSSelectorFromString(@"tweakOnlySelector:");
        @try {
            id r = ((id (*)(id, SEL, id))objc_msgSend)(p, bogus, @"x");
            ((id (*)(id, SEL, id))objc_msgSend)(p, bogus, @"x");   // second call: no second log line
            printf("BOGUS=%s\n", r == nil ? "nil" : "nonnil");
        } @catch (NSException *e) {
            printf("BOGUS=raised:%s\n", e.name.UTF8String);
        }
        printf("REAL=%s\n", [[p real] UTF8String]);
        id fw = [Forwarder new];
        NSString *viaForward = ((id (*)(id, SEL))objc_msgSend)(fw, @selector(real));
        printf("FORWARDER=%s\n", viaForward.UTF8String ?: "nil");
        printf("RESPONDS=%d\n", (int)[p respondsToSelector:bogus]);
    }
    return 0;
}
"""#.write(to: harness, atomically: true, encoding: .utf8)

let (c1, o1) = run("/usr/bin/xcrun", ["clang", "-dynamiclib", "-o", dylib.path, dummy.path, "-install_name", "@rpath/libsubstitute_guardtest.dylib"])
guard c1 == 0 else { print("❌ dylib build failed\n\(o1)"); exit(1) }
let binA = tmp.appendingPathComponent("withTweak").path
let binB = tmp.appendingPathComponent("plain").path
let (c2, o2) = run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-framework", "Foundation", "-o", binA,
                                      harness.path, guardFile.path, dylib.path, "-Wl,-rpath," + tmp.path])
guard c2 == 0 else { print("❌ build A failed\n\(o2)"); exit(1) }
let (c3, o3) = run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-framework", "Foundation", "-o", binB,
                                      harness.path, guardFile.path, "-Wl,-U,_guardtest_dummy"])
guard c3 == 0 else { print("❌ build B failed\n\(o3)"); exit(1) }

let (sa, outA) = run(binA, [])
let (_, outB) = run(binB, [])
print("▶️  A. hooking library present")
check("the process exits normally", sa == 0)
check("the guard announces itself with the evidence", outA.contains("[TweakGuard] injected code detected (libsubstitute_guardtest.dylib)"))
check("an unrecognized selector returns nil instead of raising", outA.contains("BOGUS=nil"))
check("one log line for the selector, not one per call",
      outA.components(separatedBy: "swallowed unrecognized selector -[Plain tweakOnlySelector:]").count == 2)
check("real methods are untouched", outA.contains("REAL=real"))
check("a class doing its own forwarding still forwards", outA.contains("FORWARDER=real"))
check("respondsToSelector: still answers NO", outA.contains("RESPONDS=0"))
print("▶️  B. normal install (no hooking library)")
check("the guard stays off", !outB.contains("[TweakGuard]"))
check("an unrecognized selector still raises", outB.contains("BOGUS=raised:NSInvalidArgumentException"))

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)\n--- A ---\n\(outA)\n--- B ---\n\(outB)")
exit(failures == 0 ? 0 : 1)
