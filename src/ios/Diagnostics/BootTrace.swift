//
//  BootTrace.swift
//  Minis
//
//  [T-boot-trace] A synchronous, fsync'd breadcrumb trail for the launch path.
//
//  Why this exists: a launch that dies before any UI cannot be diagnosed from
//  inside the app — there is no settings screen to open and, until now, the
//  Documents directory was not even visible in the Files app. Three shipped
//  builds were guesses because of that.
//
//  Each mark is written with O_APPEND and fsync'd, so the line survives even if
//  the process is killed on the very next instruction. The file is
//  Documents/boot.log, visible under "On My iPhone → Minis" once
//  UIFileSharingEnabled is on.
//
//  Cost: a handful of tiny writes per launch. Never throws, never blocks on a
//  lock, and is a no-op if the file cannot be opened.
//

import Foundation

enum BootTrace {
    private static let path: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("boot.log").path
    }()

    /// Append one line and flush it to disk before returning.
    static func mark(_ event: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [boot] \(event)\n"
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
        fsync(fd)
    }
}
