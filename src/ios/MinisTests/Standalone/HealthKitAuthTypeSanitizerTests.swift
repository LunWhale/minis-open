#!/usr/bin/env swift
// [GH#393] `apple-healthkit log-blood-pressure` always failed with
// authorization_denied: it passed the blood-pressure CORRELATION type to
// requestAuthorizationToShareTypes:, HealthKit raised NSInvalidArgumentException
// while validating the request, and the @catch around the call dressed that up
// as HKErrorAuthorizationDenied — "enable it in Settings", which can never work.
//
// 1. Compiles the real sanitizer block (between `// BEGIN HKTypeSanitizers` and
//    `// END HKTypeSanitizers` in NativeOffloads/HealthKitOffload.m) against the
//    macOS HealthKit SDK and checks which real HealthKit types it keeps or drops.
// 2. Pins the call-site fixes in the shipping source.
//
// Run: swift HealthKitAuthTypeSanitizerTests.swift   (needs clang + macOS SDK)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let hk = source("NativeOffloads/HealthKitOffload.m")
guard let a = hk.range(of: "// BEGIN HKTypeSanitizers"),
      let b = hk.range(of: "// END HKTypeSanitizers", range: a.upperBound..<hk.endIndex) else {
    print("❌ sanitizer block not found"); exit(1)
}
let block = String(hk[a.lowerBound..<b.upperBound])

let harness = #"""
#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
BLOCK
static NSString *ids(NSSet *set) {
    NSMutableArray *out = [NSMutableArray array];
    for (HKObjectType *t in set) [out addObject:t.identifier];
    return set ? [[out sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] : @"nil";
}
int main(void) { @autoreleasepool {
    HKQuantityType *sys = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierBloodPressureSystolic];
    HKQuantityType *dia = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierBloodPressureDiastolic];
    HKCorrelationType *bp = [HKCorrelationType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure];
    HKCorrelationType *food = [HKCorrelationType correlationTypeForIdentifier:HKCorrelationTypeIdentifierFood];
    HKCategoryType *mindful = [HKCategoryType categoryTypeForIdentifier:HKCategoryTypeIdentifierMindfulSession];
    HKObjectType *sex = [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierBiologicalSex];
    HKObjectType *rings = [HKObjectType activitySummaryType];
    HKObjectType *ecg = [HKObjectType electrocardiogramType];

    printf("SHARE_BP=%s\n", ids(sanitizeShareTypes([NSSet setWithObjects:sys, dia, bp, nil])).UTF8String);
    printf("READ_BP=%s\n", ids(sanitizeReadTypes([NSSet setWithObjects:sys, dia, bp, nil])).UTF8String);
    printf("SHARE_FOOD_ONLY=%s\n", ids(sanitizeShareTypes([NSSet setWithObject:food])).UTF8String);
    printf("SHARE_MIXED=%s\n", ids(sanitizeShareTypes((NSSet *)[NSSet setWithObjects:mindful, sex, rings, ecg, nil])).UTF8String);
    printf("READ_KEEPS_READONLY=%s\n", ids(sanitizeReadTypes([NSSet setWithObjects:sex, rings, ecg, nil])).UTF8String);
    printf("SHARE_EMPTY=%s\n", ids(sanitizeShareTypes([NSSet set])).UTF8String);
    printf("NEVER_SHAREABLE bp=%d food=%d sex=%d rings=%d ecg=%d sys=%d mindful=%d\n",
           hkTypeNeverShareable(bp), hkTypeNeverShareable(food), hkTypeNeverShareable(sex),
           hkTypeNeverShareable(rings), hkTypeNeverShareable(ecg),
           hkTypeNeverShareable(sys), hkTypeNeverShareable(mindful));
} return 0; }
"""#.replacingOccurrences(of: "BLOCK", with: block)

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hk-sanitize-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("t.m"), bin = tmp.appendingPathComponent("t")
try harness.write(to: src, atomically: true, encoding: .utf8)

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

print("1. Sanitizers (real HealthKit types, macOS SDK)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-mmacosx-version-min=14.0",
                                         "-framework", "Foundation", "-framework", "HealthKit",
                                         src.path, "-o", bin.path])
check("shipping sanitizer block compiles", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("harness ran", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where !line.contains("[healthkit/auth]") {
    let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}
let bpPair = "HKQuantityTypeIdentifierBloodPressureDiastolic,HKQuantityTypeIdentifierBloodPressureSystolic"
check("share set: blood-pressure correlation dropped, systolic + diastolic kept (\(r["SHARE_BP"] ?? "?"))", r["SHARE_BP"] == bpPair)
check("read set: correlation dropped too, constituents kept", r["READ_BP"] == bpPair)
check("a share set of only a correlation (food) sanitizes to nil", r["SHARE_FOOD_ONLY"] == "nil")
check("characteristic / activity rings / ECG dropped from share, category kept (\(r["SHARE_MIXED"] ?? "?"))",
      r["SHARE_MIXED"] == "HKCategoryTypeIdentifierMindfulSession")
check("read set keeps read-only types (they are readable)", (r["READ_KEEPS_READONLY"] ?? "").split(separator: ",").count == 3)
check("empty set passes through", r["SHARE_EMPTY"] == "")
check("hkTypeNeverShareable classifies by class",
      r["NEVER_SHAREABLE bp"] == "1 food=1 sex=1 rings=1 ecg=1 sys=0 mindful=0")

print("\n2. Call sites")
check("log-blood-pressure authorizes only the two quantity types",
      hk.contains("NSSet *writeTypes = [NSSet setWithObjects:sysType, diaType, nil];")
      && !hk.contains("setWithObjects:sysType, diaType, bpType"))
check("log-blood-pressure's auth retry re-requests both halves",
      hk.contains("saveWithAuthRetry(bpCorrelation, writeTypes, &saveErr)"))
check("saveWithAuthRetry takes the whole share set",
      hk.contains("static BOOL saveWithAuthRetry(HKObject *sample,\n                               NSSet<HKSampleType *> *shareTypes,"))
check("the request's @catch no longer fabricates HKErrorAuthorizationDenied",
      !hk.contains("code:HKErrorAuthorizationDenied\n                                            userInfo:@{NSLocalizedDescriptionKey:\n                    [NSString stringWithFormat:@\"HealthKit rejected the authorization request")
      && hk.contains("rejection = ex;"))
check("a rejected request is reported as invalid_args, a denial stays authorization_denied",
      hk.contains("if (result == NoffHKAuthRejected) {\n        noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, command,\n                       NOFF_ERR_INVALID_ARGS, authErr), compact, quiet);\n        return NOFF_EXIT_INVALID_ARGS;"))
let reportSites = hk.components(separatedBy: "return hkEmitAuthFailure(stdout_fd, @\"").count - 1
check("every first-time authorization site reports through hkEmitAuthFailure (\(reportSites))", reportSites == 26)
check("no call site still maps any auth failure straight to authorization_denied",
      !hk.contains("if (!requestHealthKitAccess(") || hk.components(separatedBy: "if (!requestHealthKitAccess(").count - 1 == 1)
check("both sets are sanitized before the request",
      hk.contains("shareTypes = sanitizeShareTypes(shareTypes);\n    readTypes = sanitizeReadTypes(readTypes);"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
