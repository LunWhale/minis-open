import Foundation
import Darwin

/// [T-crash-breadcrumbs] Periodic resource sample for the crash breadcrumbs:
/// every 15 s and on every foreground/background switch, one line of
///   fp   phys_footprint (what jetsam judges), MB
///   vm   virtual_size (address space in use, incl. iSH's reservation), MB
///   thr  thread count
///   gp   live iSH guest processes (-1 when the process table was busy)
///   gmem iSH guest anonymous memory, MB
/// into the ring and the fixed "res" slot.
///
/// On 2026-10-01 a crash came 11 s after the app returned from 37 s in the
/// background with app memory up from 326 to 738 MB, and the log - sampled
/// only on lifecycle switches - could not say whether the app or the guest
/// (31 node threads) had grown. This answers that.
///
/// Cost: one task_info, one task_threads (ports released) and one non-blocking
/// guest table scan per sample, on a utility queue - not on the main thread
/// and nowhere near scrolling or streaming.
final class ResourceSampler {
    static let shared = ResourceSampler()

    static let interval: TimeInterval = 15

    private let queue = DispatchQueue(label: "com.minis.resourceSampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: Self.interval, leeway: .seconds(2))
            t.setEventHandler { [weak self] in self?.sample(reason: "tick") }
            t.resume()
            self.timer = t
        }
    }

    /// An extra sample now - on foreground/background switches.
    func sampleNow(reason: String) {
        queue.async { self.sample(reason: reason) }
    }

    private func sample(reason: String) {
        let vm = Self.vmInfo()
        let threads = Self.threadCount()
        var guestProcs: Int32 = -1
        var guestAnon: Int64 = 0
        let kernel = ISHKernel.shared
        if kernel.isBooted {
            kernel.getGuestProcessCount(&guestProcs, anonBytes: &guestAnon)
        }
        let line = "fp=\(vm.footprint >> 20)MB vm=\(vm.virtual >> 20)MB thr=\(threads) "
            + "gp=\(guestProcs) gmem=\(guestAnon >> 20)MB why=\(reason)"
        CrashBreadcrumbs.record("res", detail: line)
        CrashBreadcrumbs.setSlot("res", value: line)
    }

    static func vmInfo() -> (footprint: UInt64, virtual: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, info.virtual_size)
    }

    /// Thread count. Every port task_threads hands out is released, and the
    /// array is freed - a leaked port per sample would add up over a day.
    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        for i in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, list[i])
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}

/// [T-ios-chat-body-stack-erase] How much of the main thread's stack is left
/// at a few deep SwiftUI body points, recorded only when it reaches a new low.
///
/// The main thread has 1MB of stack on iOS. The 2026-10-02 13:34 crash ran it
/// out (stack-guard SIGSEGV) while the chat page's body was first evaluated
/// during a push, with no log line pointing at it. A new low below
/// `warnBelow` becomes a crash breadcrumb and a warning, so the next
/// "how close was it" question has a number. Cost per call: a pthread field
/// read and an integer compare; a breadcrumb only on a new 32KB step down.
enum MainStackHeadroom {
    private static let step = 32 * 1024
    private static let warnBelow = 384 * 1024
    private static let logger = AppLogger(category: "StackHeadroom")
    /// Lowest headroom seen so far, rounded down to `step`. Main thread only.
    nonisolated(unsafe) private static var lowest = Int.max

    static func note(_ site: StaticString) {
        guard pthread_main_np() != 0 else { return }
        let thread = pthread_self()
        // pthread_get_stackaddr_np is the HIGH end; the stack grows down.
        let top = Int(bitPattern: pthread_get_stackaddr_np(thread))
        let size = pthread_get_stacksize_np(thread)
        var marker = 0
        let here = withUnsafeMutablePointer(to: &marker) { Int(bitPattern: $0) }
        let headroom = here - (top - size)
        let bucket = headroom / step * step
        guard bucket < lowest else { return }
        lowest = bucket
        guard headroom < warnBelow else { return }
        CrashBreadcrumbs.record("stack.low", detail: "\(site) headroom=\(headroom / 1024)KB of \(size / 1024)KB")
        logger.warning("[StackHeadroom] \(site) main-thread headroom \(headroom / 1024)KB of \(size / 1024)KB")
    }
}
