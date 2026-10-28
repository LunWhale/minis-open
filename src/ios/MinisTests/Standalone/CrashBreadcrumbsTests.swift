#!/usr/bin/env swift
// [T-crash-breadcrumbs] Tests for Diagnostics/CrashBreadcrumbs.{h,m} and the
// breadcrumb wiring.
//
// Builds the SHIPPING CrashBreadcrumbs.m into a macOS program (temp home via
// CFFIXED_USER_HOME) and runs it several times to cover:
//   [1] record + render; fixed slots; the same kind within 250 ms coalesces
//       with a repeat count, a different kind or a later one does not
//   [2] the ring keeps the newest 512 lines; long / multi-byte details are cut
//       on a character boundary
//   [3] a crashed run's file survives (written through the mapping, process
//       killed without any flush) and is rotated on the next start; only the
//       last 5 runs are kept; lookup by pid and by time
//   [4] hash8 is 8 hex characters and stable
//   [5] source guards: start order, lifecycle + MetricKit wiring, no
//       breadcrumbs on per-event streaming paths, the old live-command
//       attachment is gone, ResourceSampler releases thread ports
//
// Run: swift CrashBreadcrumbsTests.swift
import Foundation

let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
@discardableResult
func run(_ exe: String, _ args: [String], env: [String: String]? = nil) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    if let env { p.environment = env }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crumbs-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let home = tmp.appendingPathComponent("home")
try! FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
let crumbsDir = home.appendingPathComponent("Library/Application Support/Crumbs")

let harness = tmp.appendingPathComponent("main.m")
try! #"""
#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>
#import "CrashBreadcrumbs.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        [CrashBreadcrumbs start];
        printf("PID=%d\n", getpid());
        if ([mode isEqualToString:@"basic"]) {
            [CrashBreadcrumbs record:@"life" detail:@"active"];
            [CrashBreadcrumbs record:@"tool.start" detail:@"shell_execute"];
            [CrashBreadcrumbs record:@"tool.start" detail:@"shell_execute"];
            [CrashBreadcrumbs record:@"tool.start" detail:@"file_read"];
            usleep(300000);
            [CrashBreadcrumbs record:@"tool.start" detail:@"after-window"];
            [CrashBreadcrumbs setSlot:@"page" value:@"chat:deadbeef"];
            [CrashBreadcrumbs setSlot:@"sheet" value:@"settings"];
            [CrashBreadcrumbs setSlot:@"bogus" value:@"ignored"];
            NSString *cur = [[CrashBreadcrumbs directory] stringByAppendingPathComponent:@"current.bin"];
            printf("RENDER<<\n%s>>RENDER\n", [CrashBreadcrumbs renderFileAtPath:cur].UTF8String);
            printf("HASH=%s\n", [CrashBreadcrumbs hash8:@"F5A0B3C2-0000-4000-8000-000000000000"].UTF8String);
            printf("HASH2=%s\n", [CrashBreadcrumbs hash8:@"F5A0B3C2-0000-4000-8000-000000000000"].UTF8String);
        } else if ([mode isEqualToString:@"wrap"]) {
            for (int i = 0; i < 700; i++) {
                [CrashBreadcrumbs record:(i % 2 ? @"a" : @"b") detail:[NSString stringWithFormat:@"n=%d", i]];
            }
            NSMutableString *longDetail = [NSMutableString string];
            for (int i = 0; i < 80; i++) [longDetail appendString:@"界"];
            [CrashBreadcrumbs record:@"long" detail:longDetail];
            NSString *cur = [[CrashBreadcrumbs directory] stringByAppendingPathComponent:@"current.bin"];
            printf("RENDER<<\n%s>>RENDER\n", [CrashBreadcrumbs renderFileAtPath:cur].UTF8String);
        } else if ([mode isEqualToString:@"crash"]) {
            [CrashBreadcrumbs record:@"page.show" detail:@"chat:cafebabe"];
            [CrashBreadcrumbs record:@"req.start" detail:@"claude-sonnet-5-5"];
            fflush(stdout);
            kill(getpid(), SIGKILL);   // no flush, no exit handlers
        } else if ([mode isEqualToString:@"inspect"]) {
            NSArray *runs = [CrashBreadcrumbs previousRunFiles];
            printf("RUNS=%lu\n", (unsigned long)runs.count);
            int pid = atoi(argv[2]);
            NSString *byPid = [CrashBreadcrumbs previousRunFileForPid:pid];
            printf("BYPID<<\n%s>>BYPID\n", byPid ? [CrashBreadcrumbs renderFileAtPath:byPid].UTF8String : "nil");
            NSString *byTime = [CrashBreadcrumbs previousRunFileCoveringDate:[NSDate date]];
            printf("BYTIME=%s\n", byTime ? byTime.lastPathComponent.UTF8String : "nil");
            NSString *before = [CrashBreadcrumbs previousRunFileCoveringDate:[NSDate dateWithTimeIntervalSince1970:1]];
            printf("BEFORE=%s\n", before ? "found" : "nil");
        }
    }
    return 0;
}
"""#.write(to: harness, atomically: true, encoding: .utf8)

let bin = tmp.appendingPathComponent("crumbs").path
let (cs, co) = run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-framework", "Foundation",
                                      "-I", ios.appendingPathComponent("Diagnostics").path,
                                      "-o", bin, harness.path, ios.appendingPathComponent("Diagnostics/CrashBreadcrumbs.m").path])
guard cs == 0 else { print("❌ build failed:\n\(co)"); exit(1) }
var env = ProcessInfo.processInfo.environment
env["CFFIXED_USER_HOME"] = home.path
func block(_ out: String, _ tag: String) -> String {
    guard let a = out.range(of: "\(tag)<<\n"), let b = out.range(of: ">>\(tag)") else { return "" }
    return String(out[a.upperBound..<b.lowerBound])
}
func value(_ out: String, _ key: String) -> String {
    out.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } ?? ""
}

print("▶️  1. record, render, slots, coalescing")
let (_, basic) = run(bin, ["basic"], env: env)
let r1 = block(basic, "RENDER")
let lines1 = r1.split(separator: "\n").map(String.init)
check("header names the format, pid and event count", lines1.first?.hasPrefix("crumbs v1 pid=") == true)
check("fixed slots page / sheet are shown; unknown slot ignored",
      r1.contains("[page] ") && r1.contains("chat:deadbeef") && r1.contains("[sheet] ") && !r1.contains("ignored"))
check("same kind within 250 ms -> one line with a repeat count",
      lines1.contains { $0.contains("tool.start file_read (x3)") } && !lines1.contains { $0.hasSuffix("tool.start shell_execute") })
check("…a different kind is its own line", lines1.contains { $0.contains(" life active") })
check("…and the same kind after the window is a new line", lines1.contains { $0.contains("tool.start after-window") && !$0.contains("(x") })
check("events counted after coalescing", lines1.first?.contains("events=3") == true)

print("▶️  4. hash8")
let h = value(basic, "HASH")
check("8 lowercase hex characters", h.count == 8 && h.allSatisfy { "0123456789abcdef".contains($0) })
check("stable", h == value(basic, "HASH2"))

print("▶️  2. ring wrap-around and cutting")
let (_, wrap) = run(bin, ["wrap"], env: env)
let r2 = block(wrap, "RENDER").split(separator: "\n").map(String.init)
let events = r2.filter { $0.first?.isNumber == true }
check("only the newest 512 lines are kept", events.count == 512)
check("…oldest first, ending with the newest", events.first?.contains("n=189") == true && events.last?.contains(" long ") == true)
let longLine = events.last ?? ""
check("a long multi-byte detail is cut to the 128-byte slot without a broken character",
      longLine.utf8.count <= 127 && !longLine.contains("\u{FFFD}") && longLine.hasSuffix("界"))

print("▶️  3. a killed run survives and is rotated")
try? FileManager.default.removeItem(at: crumbsDir)
var crashedPid = ""
for i in 0..<7 {
    let (_, out) = run(bin, ["crash"], env: env)
    crashedPid = value(out, "PID")
    if i < 6 { Thread.sleep(forTimeInterval: 0.01) }
}
let (_, inspect) = run(bin, ["inspect", crashedPid], env: env)
check("only the last 5 runs are kept", value(inspect, "RUNS") == "5")
let byPid = block(inspect, "BYPID")
check("the SIGKILLed run's lines are on disk, found by its pid",
      byPid.contains("pid=\(crashedPid)") && byPid.contains("page.show chat:cafebabe") && byPid.contains("req.start claude-sonnet-5-5"))
check("lookup by time returns a run launched before now", value(inspect, "BYTIME").hasPrefix("crumbs-"))
check("nothing launched before 1970", value(inspect, "BEFORE") == "nil")

print("▶️  5. source guards")
let app = source("MinisApp.swift")
check("started right after CrashSignalHandler.install(), with the sampler",
      app.contains("CrashSignalHandler.install()\n        // [T-crash-breadcrumbs]") && app.contains("CrashBreadcrumbs.start()\n        ResourceSampler.shared.start()"))
let reporter = source("Diagnostics/CrashReporter.swift")
check("lifecycle phases record a breadcrumb and an extra sample",
      reporter.contains("CrashBreadcrumbs.record(\"life\", detail: phase)") && reporter.contains("ResourceSampler.shared.sampleNow(reason: phase)"))
check("MetricKit keeps the full JSON and attaches the crashed run's breadcrumbs",
      reporter.contains("saveMetricKitJSON(diagJSON, kind: \"crash\")") && reporter.contains("breadcrumbsForDiagnostic(diagJSON"))
check("the live shell-command ring is no longer attached to a MetricKit crash",
      !reporter.contains("let liveCommands = ShellCommandRingBuffer.syncSnapshot"))
let sse = source("Agent/Chat/AIChatViewModel+SSEStream.swift")
check("request start/end once per stream (model name)", sse.contains("CrashBreadcrumbs.record(\"req.start\", detail: streamDiagModel)"))
check("no breadcrumb inside the per-event stream switch",
      sse.components(separatedBy: "switch event {").dropFirst().allSatisfy { !$0.prefix(4000).contains("CrashBreadcrumbs") })
check("tool start/end by name only", source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift").contains("let crumbTool = String(tu.name.prefix(40))"))
let sampler = source("Diagnostics/ResourceSampler.swift")
check("ResourceSampler releases every thread port and the array",
      sampler.contains("mach_port_deallocate(mach_task_self_, list[i])") && sampler.contains("vm_deallocate(mach_task_self_"))
check("ResourceSampler runs on a utility queue every 15 s", sampler.contains("qos: .utility") && sampler.contains("static let interval: TimeInterval = 15"))

let cv = source("Views/ContentView/ContentView.swift")
check("ContentView: navigation depth, split selection (hashed), sheets and the terminal cover",
      cv.contains("CrashBreadcrumbs.record(\"nav\", detail: \"depth=\\(navigationPath.count)\")")
      && cv.contains("CrashBreadcrumbs.hash8($0)") && cv.contains(".onChange(of: activeToolSheet)") && cv.contains("detail: \"terminal\")"))
let sidebar = source("Views/ContentView/Sidebar/SidebarIdentityTracer.swift")
let structure = sidebar.components(separatedBy: "enum SidebarStructureCrumb").last ?? ""
check("sidebar structure breadcrumb is Release-safe and counts-only",
      sidebar.contains("#endif\n\n// MARK: - [T-crash-breadcrumbs] Release-safe structure breadcrumb")
      && structure.contains("groups.reduce(0) { $0 + $1.ids.count }") && !structure.contains("flatMap"))
let list = source("Views/ContentView/ContentView+SessionList.swift")
check("both sidebar lists report outside #if DEBUG",
      list.contains("let _ = SidebarStructureCrumb.note(groups, site: \"sidebar\")\n            #if DEBUG")
      && list.contains("let _ = SidebarStructureCrumb.note(groups, site: \"selection\")\n            #if DEBUG"))

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)\n--- basic ---\n\(basic)\n--- inspect ---\n\(inspect)")
exit(failures == 0 ? 0 : 1)
