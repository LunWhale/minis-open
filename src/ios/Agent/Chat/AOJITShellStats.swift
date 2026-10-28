//
//  AOJITShellStats.swift
//  MinisApp
//
//  [T-aojit-shell-stats] One `[AOJIT] ... exec` line in the app log per
//  shell_execute, with AOJIT on or off (off gives the baseline):
//  whether AOT was on, how many code blocks the command compiled, how many of
//  them came from an AOT image (and how many of those through family
//  matching), per module, so AOJIT's effect on real agent work can be read
//  back from the daily log files.
//
//  The runtime keeps only global, cumulative counters (/proc/ish/jit, via
//  ISHKernel.aojitStatusReport), so this takes a snapshot before and after the
//  command and logs the difference. Two limits follow and are stated in the
//  line itself:
//    - `overlap` counts other shell_execute calls running during this one;
//      their blocks are mixed in when it is above 0. Terminal commands and
//      background daemons are not counted at all.
//    - Counters are per compiled block, not per execution: a hot loop counts
//      once. The rate is "share of newly compiled code that came from an
//      image", not a share of CPU time.
//

import Foundation

enum AOJITShellStats {
    private static let logger = AppLogger(category: "AOJIT")
    /// Only the start of the command goes into the log ("…" marks a cut).
    static let maxCommandChars = 100

    /// Parsed global counters of the runtime's report.
    struct Snapshot: Equatable {
        var aotOn = false
        var blocks = 0
        var installs = 0
        var moved = 0
        var modules: [String: AOJITRuntimeStatus.Coverage] = [:]

        init(report: String) {
            aotOn = report.contains("\nAOT: on")
            blocks = Self.int(after: "blocks translated or looked up: ", in: report)
            installs = Self.int(after: "AOT installs: ", in: report)
            moved = Self.int(after: "(moved: ", in: report)
            modules = AOJITRuntimeStatus(report: report).hits
        }

        private static func int(after key: String, in s: String) -> Int {
            guard let r = s.range(of: key) else { return 0 }
            return Int(s[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
    }

    /// Taken before the command starts.
    struct Token {
        let before: Snapshot
        let start: Date
        let othersAtStart: Int
        let startsAtStart: Int
    }

    private static let lock = NSLock()
    private static var inFlight = 0
    private static var starts = 0

    /// The report, read off the main thread: jit_describe briefly takes the
    /// same locks the JIT takes while compiling.
    private static func report() async -> String {
        await Task.detached(priority: .utility) { ISHKernel.aojitStatusReport() }.value
    }

    /// nil when this build has no JIT runtime (empty report): nothing to log.
    /// Logged with AOJIT off too (`aot=off`): the baseline to compare with.
    static func begin() async -> Token? {
        let text = await report()
        guard text.contains("images:") else { return nil }
        let (others, startsNow) = lock.withLock { () -> (Int, Int) in
            let others = inFlight
            inFlight += 1
            starts += 1
            return (others, starts)
        }
        return Token(before: Snapshot(report: text), start: Date(), othersAtStart: others, startsAtStart: startsNow)
    }

    static func end(_ token: Token?, command: String, exitCode: Int) async {
        guard let token else { return }
        let text = await report()
        let overlap = lock.withLock { () -> Int in
            inFlight -= 1
            return token.othersAtStart + (starts - token.startsAtStart)
        }
        let line = format(before: token.before, after: Snapshot(report: text),
                          seconds: Date().timeIntervalSince(token.start), exitCode: exitCode,
                          overlap: overlap, command: command)
        logger.info(line)
    }

    /// The log line. Pure, so the format is tested directly.
    static func format(before: Snapshot, after: Snapshot, seconds: Double, exitCode: Int,
                       overlap: Int, command: String) -> String {
        let blocks = max(0, after.blocks - before.blocks)
        let installs = max(0, after.installs - before.installs)
        let moved = max(0, after.moved - before.moved)
        var perModule: [(name: String, blocks: Int, hits: Int)] = []
        for (path, now) in after.modules {
            let was = before.modules[path] ?? AOJITRuntimeStatus.Coverage()
            let b = now.blocks - was.blocks, h = now.hits - was.hits
            guard b > 0 else { continue }
            perModule.append(((path as NSString).lastPathComponent, b, max(0, h)))
        }
        perModule.sort { $0.blocks != $1.blocks ? $0.blocks > $1.blocks : $0.name < $1.name }
        let inModules = perModule.reduce(0) { $0 + $1.blocks }
        let modules = perModule.map { "\($0.name) \($0.hits)/\($0.blocks) (\(percent($0.hits, of: $0.blocks)))" }
            .joined(separator: " ")
        let cmd = command.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        let shortCmd = cmd.count > Self.maxCommandChars ? String(cmd.prefix(Self.maxCommandChars)) + "…" : cmd
        // The logger's category already prefixes "[AOJIT]".
        return "exec aot=\(after.aotOn ? "on" : "off") dur=\(String(format: "%.2f", seconds))s exit=\(exitCode) "
            + "overlap=\(overlap) blocks=+\(blocks) aot=+\(installs) (\(percent(installs, of: blocks))) moved=+\(moved)"
            + " | \(modules.isEmpty ? "-" : modules) other=+\(max(0, blocks - inModules))"
            + " | cmd=\"\(shortCmd)\""
    }

    /// Same rounding as the AOJIT screen: never a false 100% or 0%.
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "-" }
        var p = Int((Double(part) / Double(whole) * 100).rounded())
        if part < whole { p = min(p, 99) }
        if part > 0 { p = max(p, 1) }
        return "\(p)%"
    }
}
