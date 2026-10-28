#!/usr/bin/env swift
// [T-browser-pool-caller-session] Concurrent chats driving the browser through
// `minis-browser-use` navigated each other's tabs (two xiaohongshu sessions and
// one goofish session kept being switched to each other's pages).
//
// Root cause: BrowserUseOffloadBridge picked the tab pool from
// `ISHExecutionCoordinator.mountedSessionIdSnapshot` — the most recently
// mounted session, process-wide. Shell commands from different chats run
// concurrently, so every CLI call went to whichever chat started a command last.
// Now the handler reads the CALLING task's fs_context on its own guest thread
// (`noff_current_fs_context()` → current->group->fs_context, stamped per chat by
// the executor and inherited through fork) and the bridge maps it back to that
// chat with MinisFsRouter.
//
// [1] models the resolution rule, [2] pins the wiring in the shipping sources.
//
// Run: swift BrowserPoolCallerSessionTests.swift
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

print("1. Resolution rule (model of callerSessionId)")
do {
    let router: [UInt64: String] = [11: "xhs-1", 12: "xhs-2", 13: "goofish"]
    var mounted: String? = "goofish"   // whoever started a command last
    func resolve(_ ctx: UInt64) -> String? { router[ctx] ?? mounted }
    func old(_ ctx: UInt64) -> String? { mounted }

    // Three chats' CLI calls interleave while the goofish chat mounted last.
    let calls: [(chat: String, ctx: UInt64)] = [("xhs-1", 11), ("xhs-2", 12), ("goofish", 13)]
    check("OLD: every call went to the last-mounted chat (the reported crosstalk)",
          calls.allSatisfy { old($0.ctx) == "goofish" })
    check("NEW: every call goes to the chat that issued it", calls.allSatisfy { resolve($0.ctx) == $0.chat })
    mounted = "xhs-1"
    check("NEW: independent of which chat mounted last", calls.allSatisfy { resolve($0.ctx) == $0.chat })
    check("no fs_context (interactive terminal) → the mounted chat, as before", resolve(0) == "xhs-1")
    mounted = nil
    check("…and nothing mounted → nil (bridge uses its unmounted sentinel pool)", resolve(0) == nil)
}

print("\n2. Wiring")
let bridge = source("NativeOffloads/BrowserUseOffloadBridge.swift")
let offload = source("NativeOffloads/BrowserUseOffload.m")
let utilsH = source("NativeOffloads/NativeOffloadUtils.h")
let utilsM = source("NativeOffloads/NativeOffloadUtils.m")
let coord = source("Agent/ISH/ISHExecutionCoordinator.swift")
let exec = source("iSH/ISHShellExecutor.m")
let fork = (try? String(contentsOfFile: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("deps/ish/kernel/fork.c").path, encoding: .utf8)) ?? ""

check("helper reads the calling task's fs_context",
      utilsH.contains("uint64_t noff_current_fs_context(void);")
      && utilsM.contains("if (current == NULL || current->group == NULL) return 0;\n    return current->group->fs_context;"))
check("the ObjC handler passes it, read on its own guest thread",
      offload.contains("fsContext:noff_current_fs_context()"))
check("the bridge takes it and resolves the caller from it",
      bridge.contains("fsContext: UInt64,\n        completion: @escaping (NSDictionary) -> Void")
      && bridge.contains("let caller = ISHExecutionCoordinator.callerSessionId(fsContext: fsContext)"))
check("the bridge no longer picks the pool from the last-mounted snapshot",
      !bridge.contains("let sid = ISHExecutionCoordinator.mountedSessionIdSnapshot"))
check("resolution: fs_context first, mounted snapshot only as the fallback",
      coord.contains("if let sid = MinisFsRouter.shared.sid(for: fsContext) { return (sid, \"fs_context\") }\n        return (mountedSessionIdSnapshot,"))
check("the executor stamps each command's task group with its chat's fs_context",
      exec.contains("task->group->fs_context = fsContext;"))
check("fork copies the task group, so the offloaded child inherits it", fork.contains("*group = *old_group;"))
check("the log names how each call was resolved", bridge.contains("sid=\\(sid.prefix(8)) via=\\(caller.source)"))

print("\n3. [T-offload-caller-session] minis-scheduled and minis-model-use use the same rule")
let schedM = source("NativeOffloads/ScheduledOffload.m")
let schedB = source("NativeOffloads/ScheduledOffloadBridge.swift")
let muM = source("NativeOffloads/ModelUseOffload.m")
let muB = source("NativeOffloads/ModelUseOffloadBridge.swift")
check("scheduled: handler passes the caller's fs_context in the args",
      schedM.contains("args[@\"caller_fs_context\"] = @(noff_current_fs_context());"))
check("scheduled: the default (follow-up) target resolves from it",
      schedB.contains("let caller = ISHExecutionCoordinator.callerSessionId(fsContext: callerFsContext)")
      && schedB.contains("let callerSid = caller.sid"))
check("model-use: both run calls (stream / non-stream) pass it",
      muM.components(separatedBy: "fsContext:noff_current_fs_context()").count - 1 == 2)
check("model-use: resolved once and threaded to the provider header and media saving",
      muB.contains("let caller = ISHExecutionCoordinator.callerSessionId(fsContext: fsContext)")
      && muB.contains("callerSid: caller.sid") && muB.contains("sessionId: OpenCodeChannel.normalizedSessionId(callerSid) ?? OpenCodeChannel.oneOffSessionId())")
      && muB.contains("let callerSid2 = callerSid ?? \"\"")
      && muB.components(separatedBy: "callerSid: callerSid\n").count - 1 == 3)
for (name, src) in [("scheduled", schedB), ("model-use", muB)] {
    let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    check("\(name): no caller taken from mountedSessionIdSnapshot any more", !code.contains("mountedSessionIdSnapshot"))
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
