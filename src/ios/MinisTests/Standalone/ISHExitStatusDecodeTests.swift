// [T-ish-exit-status-decode] shell_execute reported the kernel's raw wait(2)
// status as the exit code: `exit 1` showed as "(exit code: 256)", and
// "command not found" (127) as 32512. Every non-zero code was 256× too big,
// and a signal death looked like a small exit code. The model summarising
// a scheduled task's prefilled command (T-scheduled-preset-tool) reads that
// number directly.
//
//   A. ISHDecodeWaitStatus, extracted from ISHShellExecutor.m and compiled with
//      clang. Its results are compared against the host's own
//      <sys/wait.h> macros over every exit code and signal, plus the literal
//      cases: exit 0/1/2/127/255, SIGKILL/SIGTERM/SIGINT, SIGSEGV with a
//      core-dump bit, and the executor's negative sentinels.
//   B. Wiring:
//      - processDidExit decodes before the value reaches the result;
//      - the kernel still encodes `status << 8` for exit and the raw signal
//        for a fatal signal, so a decode here is not a double decode;
//      - the bash-missing sentinel check still matches the decoded 119.
//
// Standalone: `swift ISHExitStatusDecodeTests.swift` (needs clang).

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = FileManager.default.currentDirectoryPath
func file(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: root)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent(rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("not found: \(rel)")
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

let executor = file("src/ios/iSH/ISHShellExecutor.m")
let exitC = file("deps/ish/kernel/exit.c")
let signalC = file("deps/ish/kernel/signal.c")
let ishCommand = file("src/ios/Agent/Chat/AIChatViewModel+ISHCommand.swift")

// MARK: - A. The shipping decoder, compiled

print("A. ISHDecodeWaitStatus (compiled from ISHShellExecutor.m)")
let decoder = between(executor, "// [T-ish-exit-status-decode] BEGIN decode-wait-status",
                      "// [T-ish-exit-status-decode] END decode-wait-status")
check("decoder found between markers", decoder != nil)

if let decoder {
    // Doc comments use `///`, which C accepts as a line comment.
    let harness = """
    #include <stdio.h>
    #include <signal.h>
    #include <sys/wait.h>
    \(decoder)
    static int fails = 0;
    static void expect(const char *label, int got, int want) {
        if (got == want) printf("  ✅ %s → %d\\n", label, got);
        else { printf("  ❌ %s → %d (want %d)\\n", label, got, want); fails++; }
    }
    int main(void) {
        // The literal cases the report named.
        expect("exit 0 (0 << 8)", ISHDecodeWaitStatus(0 << 8), 0);
        expect("exit 1 (was shown as 256)", ISHDecodeWaitStatus(1 << 8), 1);
        expect("exit 2", ISHDecodeWaitStatus(2 << 8), 2);
        expect("command not found 127 (was 32512)", ISHDecodeWaitStatus(127 << 8), 127);
        expect("exit 255", ISHDecodeWaitStatus(255 << 8), 255);
        expect("killed by SIGKILL → 137", ISHDecodeWaitStatus(SIGKILL), 137);
        expect("killed by SIGTERM → 143", ISHDecodeWaitStatus(SIGTERM), 143);
        expect("killed by SIGINT → 130", ISHDecodeWaitStatus(SIGINT), 130);
        expect("SIGSEGV with core dump bit → 139", ISHDecodeWaitStatus(SIGSEGV | 0x80), 139);
        expect("timeout sentinel -1 passes through", ISHDecodeWaitStatus(-1), -1);

        // Exhaustive agreement with the host's own wait(2) macros.
        int mismatches = 0;
        for (int code = 0; code <= 255; code++) {
            int st = code << 8;
            if (!WIFEXITED(st) || ISHDecodeWaitStatus(st) != WEXITSTATUS(st)) mismatches++;
        }
        for (int sig = 1; sig < 32; sig++) {
            for (int core = 0; core <= 1; core++) {
                int st = sig | (core ? 0x80 : 0);
                if (!WIFSIGNALED(st) || ISHDecodeWaitStatus(st) != 128 + WTERMSIG(st)) mismatches++;
            }
        }
        expect("mismatches vs WEXITSTATUS / 128+WTERMSIG over all codes & signals", mismatches, 0);
        printf("HARNESS fails=%d\\n", fails);
        return fails == 0 ? 0 : 1;
    }
    """
    do {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("waitstatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("t.c")
        try harness.write(to: src, atomically: true, encoding: .utf8)
        let bin = tmp.appendingPathComponent("t")
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
        let (cc, ccOut) = run("/usr/bin/xcrun", ["clang", "-Wall", "-Werror", src.path, "-o", bin.path])
        check("decoder compiles cleanly (-Wall -Werror)", cc == 0)
        if cc != 0 { print(ccOut) }
        let (rc, out) = run(bin.path, [])
        print(out, terminator: "")
        check("all decode cases pass", rc == 0 && out.contains("HARNESS fails=0"))
    } catch {
        check("harness setup: \(error)", false)
    }
}

// MARK: - B. Wiring

print("B. Wiring")
check("processDidExit decodes the notification's status",
      executor.contains("int rawStatus = [notification.userInfo[@\"code\"] intValue];\n    int exitCode = ISHDecodeWaitStatus(rawStatus);"))
check("no other read of the raw status as an exit code",
      executor.components(separatedBy: "userInfo[@\"code\"]").count - 1 == 1)
check("kernel sys_exit still encodes status << 8 (decode is not a double decode)",
      exitC.contains("do_exit(status << 8);") && exitC.contains("do_exit_group(status << 8);"))
check("kernel fatal signal still exits with the raw signal number",
      signalC.contains("do_exit_group(sig);"))
check("bash-missing sentinel still matches the decoded 119",
      ishCommand.contains("result.exitCode == Self.bashMissingSentinel"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
