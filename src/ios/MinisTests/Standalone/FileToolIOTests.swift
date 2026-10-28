#!/usr/bin/env swift
// [T-filetool-io-offmain] Tests for Agent/Chat/FileToolIO.swift, compiled as
// shipped (Foundation only).
//
//   [1] run(): a syscall that never returns (open() of a FIFO nobody writes) is given up
//       on after the timeout — the caller gets IOError.timedOut on time and
//       is not blocked with it
//   [2] cloud-backed paths are read under NSFileCoordinator, and a
//       coordination wait (another writer holding the file) is CANCELLED when
//       the timeout fires, so the worker thread comes back too
//   [3] editFile: strict match, fuzzy match, several matches without /
//       with replace_all, not found (with preview), size cap, non-UTF-8,
//       and the same edit on a cloud-backed path (coordinated read+write)
//   [4] writeData: overwrite, append, parent directory creation
//   [5] source guards: the three tools go through FileToolIO; no direct
//       String(contentsOf:) / Data(contentsOf:) / .write(to:) left in them
//   [6] [T-filetool-icloud-wait] no status poll gating iCloud access (the
//       coordinated access waits for the download), timeout / download-error
//       messages carry the iCloud state, non-cloud files are untouched
//
// Run: swift FileToolIOTests.swift
import Foundation

let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("filetoolio-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let main = tmp.appendingPathComponent("main.swift")
try! #"""
import Foundation
let work = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
func out(_ k: String, _ v: Any) { print("\(k)\t\("\(v)".replacingOccurrences(of: "\n", with: "⏎"))") }
let sema = DispatchSemaphore(value: 0)
Task {
    // [1] blocking read() on a FIFO
    let fifo = work.appendingPathComponent("never.fifo")
    mkfifo(fifo.path, 0o644)
    let t0 = Date()
    do {
        // open(2) on a FIFO with no writer blocks in the kernel - the same
        // shape as read() on an iCloud file the provider never serves.
        // (Foundation's Data(contentsOf:) refuses a FIFO outright on macOS.)
        _ = try await FileToolIO.run("Reading never.fifo", timeout: 1.0) { _ -> Int32 in open(fifo.path, O_RDONLY) }
        out("FIFO", "returned")
    } catch let e as FileToolIO.IOError {
        out("FIFO", "timedOut"); out("FIFO_MSG", e.description)
    } catch { out("FIFO", "other \(error)") }
    out("FIFO_SECS", String(format: "%.2f", Date().timeIntervalSince(t0)))

    // [2] cloud-backed path + a coordination wait that must be cancelled
    let cloudDir = work.appendingPathComponent("Library/Mobile Documents/iCloud~test/Documents")
    try! fm.createDirectory(at: cloudDir, withIntermediateDirectories: true)
    let cloudFile = cloudDir.appendingPathComponent("Mobile.conf")
    try! "[General]\nloglevel = notify\n".write(to: cloudFile, atomically: true, encoding: .utf8)
    out("CLOUD_DETECT", FileToolIO.isCloudBacked(cloudFile))
    out("LOCAL_DETECT", FileToolIO.isCloudBacked(work.appendingPathComponent("plain.txt")))
    let holding = DispatchSemaphore(value: 0)
    let holder = Thread {
        NSFileCoordinator().coordinate(writingItemAt: cloudFile, options: [], error: nil) { _ in
            holding.signal()
            Thread.sleep(forTimeInterval: 4.0)
        }
    }
    holder.start()
    holding.wait()
    let workerDone = DispatchSemaphore(value: 0)
    let t1 = Date()
    do {
        _ = try await FileToolIO.run("Reading Mobile.conf", timeout: 1.0) { c -> Data in
            defer { workerDone.signal() }
            return try FileToolIO.readData(cloudFile, cancellation: c)
        }
        out("COORD", "returned")
    } catch is FileToolIO.IOError {
        out("COORD", "timedOut")
    } catch { out("COORD", "other \(error)") }
    out("COORD_SECS", String(format: "%.2f", Date().timeIntervalSince(t1)))
    // The cancelled coordinator lets the worker return well before the holder's 4s.
    out("COORD_WORKER_FREED", workerDone.wait(timeout: .now() + 1.5) == .success)
    Thread.sleep(forTimeInterval: 3.2)   // let the holder finish

    // [3] editFile
    func edit(_ url: URL, _ old: String, _ new: String, all: Bool = false) -> String {
        do {
            let r = try FileToolIO.editFile(url, path: "/p/" + url.lastPathComponent, oldString: old, newString: new,
                                            replaceAll: all, cancellation: FileToolIO.Cancellation())
            switch r {
            case let .edited(n, bytes, fuzzy): return "edited n=\(n) bytes=\(bytes) fuzzy=\(fuzzy ?? "nil")"
            case let .failed(m): return "failed " + m
            }
        } catch { return "threw \(error)" }
    }
    let f = work.appendingPathComponent("a.txt")
    try! "let a = 1\nlet b = \u{201C}x\u{201D}   \nlet a = 1\n".write(to: f, atomically: true, encoding: .utf8)
    out("E_MULTI", edit(f, "let a = 1", "let a = 2"))
    out("E_ALL", edit(f, "let a = 1", "let a = 2", all: true))
    out("E_ALL_FILE", try! String(contentsOf: f, encoding: .utf8))
    out("E_FUZZY", edit(f, "let b = \"x\"", "let b = \"y\""))
    out("E_FUZZY_FILE", try! String(contentsOf: f, encoding: .utf8))
    out("E_MISS", edit(f, "nothing like this", "z"))
    let big = work.appendingPathComponent("big.txt")
    try! Data(count: FileToolIO.maxEditBytes + 1).write(to: big)
    out("E_BIG", edit(big, "a", "b"))
    let bin = work.appendingPathComponent("bin.dat")
    try! Data([0xff, 0xfe, 0x00, 0x81]).write(to: bin)
    out("E_BIN", edit(bin, "a", "b"))
    out("E_CLOUD", edit(cloudFile, "loglevel = notify", "loglevel = verbose"))
    out("E_CLOUD_FILE", try! String(contentsOf: cloudFile, encoding: .utf8))

    // [4] writeData
    let nested = work.appendingPathComponent("x/y/z.txt")
    do {
        try FileToolIO.writeData(Data("one\n".utf8), to: nested, append: false, createDirs: false, cancellation: .init())
        try FileToolIO.writeData(Data("two\n".utf8), to: nested, append: true, createDirs: false, cancellation: .init())
        out("W_FILE", try String(contentsOf: nested, encoding: .utf8))
        try FileToolIO.writeData(Data("three\n".utf8), to: nested, append: false, createDirs: true, cancellation: .init())
        out("W_OVER", try String(contentsOf: nested, encoding: .utf8))
    } catch { out("W_ERR", error) }
    // [6] T-filetool-icloud-wait: messages and the non-cloud no-ops
    let cloudTimeout = FileToolIO.IOError.timedOut(operation: "Editing /m/Mobile.conf", seconds: 45, mayHaveWritten: false,
                                                   cloudState: "not downloaded to this device, download in progress")
    out("MSG_CLOUD_TIMEOUT", cloudTimeout.description)
    out("MSG_WRITE_TIMEOUT", FileToolIO.IOError.timedOut(operation: "Writing /x", seconds: 45, mayHaveWritten: true).description)
    out("MSG_DL_FAILED", FileToolIO.IOError.downloadFailed(reason: "The Internet connection appears to be offline. (NSURLErrorDomain -1009)").description)
    let plain = work.appendingPathComponent("plain.txt")
    try? "x".write(to: plain, atomically: true, encoding: .utf8)
    do { try FileToolIO.requestDownload(plain); out("REQ_LOCAL", "noop") } catch { out("REQ_LOCAL", "threw \(error)") }
    out("STATE_LOCAL", FileToolIO.cloudState(plain) ?? "nil")
    // A timeout on a non-cloud url keeps the generic cause.
    let fifo2 = work.appendingPathComponent("never2.fifo")
    mkfifo(fifo2.path, 0o644)
    do {
        _ = try await FileToolIO.run("Reading never2.fifo", timeout: 0.5, url: fifo2) { _ -> Int32 in open(fifo2.path, O_RDONLY) }
        out("URL_TIMEOUT", "returned")
    } catch let e as FileToolIO.IOError {
        out("URL_TIMEOUT", e.description)
    } catch { out("URL_TIMEOUT", "\(error)") }
    sema.signal()
}
sema.wait()
exit(0)   // the FIFO reader thread is still blocked by design
"""#.write(to: main, atomically: true, encoding: .utf8)

let bin = tmp.appendingPathComponent("t").path
let (cs, co) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-o", bin,
                                      ios.appendingPathComponent("Agent/Chat/FileToolIO.swift").path, main.path])
guard cs == 0 else { print("❌ compile failed:\n\(co)"); exit(1) }
let work = tmp.appendingPathComponent("work")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let (rs, out) = run(bin, [work.path])
var r: [String: String] = [:]
for line in out.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1)
    if parts.count == 2 { r[String(parts[0])] = String(parts[1]) }
}
func v(_ k: String) -> String { (r[k] ?? "").replacingOccurrences(of: "⏎", with: "\n") }
if rs != 0 { print("❌ harness exited \(rs):\n\(out)"); exit(1) }

print("▶️  1. blocking read() is abandoned on time")
check("timed out instead of returning", r["FIFO"] == "timedOut")
check("caller got control back after ~1s", (Double(r["FIFO_SECS"] ?? "") ?? 99) < 2.0)
check("message tells the agent what happened", v("FIFO_MSG").contains("did not finish within 1s"))

print("▶️  2. cloud paths: coordinated, cancellable")
check("Mobile Documents path is cloud-backed", r["CLOUD_DETECT"] == "true")
check("plain temp file is not", r["LOCAL_DETECT"] == "false")
check("waiting on another writer times out", r["COORD"] == "timedOut")
check("…on time", (Double(r["COORD_SECS"] ?? "") ?? 99) < 2.0)
check("…and the cancelled coordinator frees the worker thread", r["COORD_WORKER_FREED"] == "true")

print("▶️  3. editFile")
check("several matches without replace_all is refused", v("E_MULTI").hasPrefix("failed Error: old_string matches 2 locations in /p/a.txt"))
check("replace_all replaces both", v("E_ALL").hasPrefix("edited n=2") && v("E_ALL_FILE").components(separatedBy: "let a = 2").count == 3)
check("fuzzy match (smart quotes, trailing spaces)", v("E_FUZZY").contains("fuzzy=fuzzy-matched") && v("E_FUZZY_FILE").contains("let b = \"y\""))
check("not found: error plus preview", v("E_MISS").hasPrefix("failed Error: old_string not found in /p/a.txt") && v("E_MISS").contains("First 20 lines:"))
check("over the size cap: refused before reading", v("E_BIG").contains("file_edit handles files up to"))
check("non-UTF-8: same error as before", v("E_BIN") == "failed Error: Could not read /p/bin.dat as UTF-8 text")
check("cloud-backed file edited under coordination", v("E_CLOUD").hasPrefix("edited n=1") && v("E_CLOUD_FILE").contains("loglevel = verbose"))

print("▶️  4. writeData")
check("creates the parent and appends", v("W_FILE") == "one\ntwo\n")
check("overwrites", v("W_OVER") == "three\n")

print("▶️  6. iCloud: request, then wait inside the coordinated access; say why on failure")
check("a cloud timeout states the item's iCloud state and says not to use an older copy",
      v("MSG_CLOUD_TIMEOUT") == "Editing /m/Mobile.conf did not finish within 45s. The file is in iCloud: not downloaded to this device, download in progress. Retry in a moment; do not work from an older copy.")
check("a write timeout still says the write may complete", v("MSG_WRITE_TIMEOUT").contains("The write may still complete; re-read the file before retrying."))
check("a download error iCloud reports is passed on, and nothing was touched",
      v("MSG_DL_FAILED") == "the file is in iCloud and iCloud could not download it to this device: The Internet connection appears to be offline. (NSURLErrorDomain -1009). Nothing was read or written.")
check("requestDownload is a no-op for a local file", r["REQ_LOCAL"] == "noop")
check("cloudState is nil for a local file", r["STATE_LOCAL"] == "nil")
check("a timeout on a non-cloud url keeps the generic cause", v("URL_TIMEOUT").contains("did not finish within 0s") || v("URL_TIMEOUT").contains("may be in iCloud or another file provider"))
let io = (try? String(contentsOf: ios.appendingPathComponent("Agent/Chat/FileToolIO.swift"), encoding: .utf8)) ?? ""
check("no status poll gating the access any more (the coordinated access waits for the download)",
      !io.contains("Thread.sleep") && !io.contains("downloadWait") && !io.contains("notDownloaded(seconds"))
check("reads, writes and edits ask for the download, then coordinate",
      io.components(separatedBy: "try requestDownload(url)\n").count - 1 == 3)
check("the download error and conflicts are read", io.contains(".ubiquitousItemDownloadingErrorKey") && io.contains(".ubiquitousItemHasUnresolvedConflictsKey"))

print("▶️  5. source guards")
let tools = (try? String(contentsOf: ios.appendingPathComponent("Agent/Chat/AIChatViewModel+FileTools.swift"), encoding: .utf8)) ?? ""
let executors = tools.components(separatedBy: "func executeFileRead").dropFirst().joined()
    .components(separatedBy: "func ensureParentDirsInMetaDB").first ?? tools
let code = executors.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
check("file_read / file_write / file_edit call FileToolIO.run",
      code.components(separatedBy: "FileToolIO.run(").count - 1 >= 3)
check("…passing the file, so a timeout can report its iCloud state",
      code.components(separatedBy: "url: hostURL)").count - 1 >= 3)
check("no direct file I/O left in the three tools",
      !code.contains("String(contentsOf") && !code.contains("Data(contentsOf") && !code.contains(".write(to:") && !code.contains("FileHandle(forWritingTo"))

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)\n\(out)")
exit(failures == 0 ? 0 : 1)
