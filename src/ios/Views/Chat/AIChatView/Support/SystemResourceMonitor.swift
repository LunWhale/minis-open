//
//  SystemResourceMonitor.swift
//  Minis - chat page (AIChatView)
//
//  SystemResourceMonitor: samples device CPU and app memory every 2 s for the
//  tool sheets' resource readout (ToolLiveSheet).
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - System Resource Monitor

class SystemResourceMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0     // 0-100
    @Published var memUsed: UInt64 = 0      // bytes
    @Published var memTotal: UInt64 = 0     // bytes
    private var timer: Timer?
    private var prevCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    func start() {
        sampleCPU() // prime the previous ticks
        updateMemory()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sampleCPU()
                self?.updateMemory()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sampleCPU() {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &loadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let cur = (user: loadInfo.cpu_ticks.0, system: loadInfo.cpu_ticks.1, idle: loadInfo.cpu_ticks.2, nice: loadInfo.cpu_ticks.3)
        if let prev = prevCPUTicks {
            let userD = Double(cur.user &- prev.user)
            let sysD = Double(cur.system &- prev.system)
            let idleD = Double(cur.idle &- prev.idle)
            let niceD = Double(cur.nice &- prev.nice)
            let total = userD + sysD + idleD + niceD
            if total > 0 {
                cpuUsage = ((userD + sysD + niceD) / total) * 100
            }
        }
        prevCPUTicks = cur
    }

    private func updateMemory() {
        // App memory: internal + compressed (excludes external mappings like mmap/IOKit)
        // This matches Xcode's Memory Gauge more closely than phys_footprint
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        if result == KERN_SUCCESS {
            memUsed = UInt64(info.internal) + UInt64(info.compressed)
        }
        memTotal = ProcessInfo.processInfo.physicalMemory
    }

    var formattedCPU: String {
        String(format: "CPU %2.0f%%", cpuUsage)
    }

    func formattedMem(compact: Bool = false) -> String {
        let usedGB = Double(memUsed) / 1_073_741_824
        if compact {
            return String(format: "MEM %.1fG", usedGB)
        }
        let totalGB = Double(memTotal) / 1_073_741_824
        return String(format: "MEM %.1f/%.1f GB", usedGB, totalGB)
    }
}
