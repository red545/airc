// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Empties the system allocator's cache of freed large blocks once the blocking lists' compiles are done (webkitmem,
/// artifacts/webkitmem/REPORT.md).
///
/// macOS's malloc keeps recently freed large blocks (a bounded number of entries) for reuse, dirty, and they count in
/// the process's footprint. After a launch's list compile that cache held 60–190 MB in the main process for minutes.
/// `malloc_zone_pressure_relief` and the memory-pressure handler don't touch it, and turning it off for the whole app
/// (MallocLargeCache=0) slowed New Space 5–10×. Freeing a batch of large blocks that were never touched pushes every
/// older entry out: the evicted blocks go back to macOS, and the new ones cost no memory (never written, so never
/// resident). 128 × 8 MB of address space for well under a millisecond. Allocation behaviour stays the same afterwards:
/// the cache refills with whatever the app frees next. On a macOS whose allocator works differently this is a few
/// harmless map/unmap calls.
enum AllocatorCacheFlush {
    static let blocks = 128
    static let blockBytes = 8 << 20
    static let delay: TimeInterval = 2

    static var enabled: Bool {
        #if AIRC_TESTING
        // A/B (artifacts/webkitmem): AIRC_WEBKITMEM_BASELINE=1 is the previous behaviour; AIRC_WEBKITMEM_FLUSH=0 only this.
        let env = ProcessInfo.processInfo.environment
        return env["AIRC_WEBKITMEM_BASELINE"] != "1" && env["AIRC_WEBKITMEM_FLUSH"] != "0"
        #else
        return true
        #endif
    }
    private static let lock = NSLock()
    private static var generation = 0

    /// Call when a big compile has finished (any thread). Only the last call within `delay` flushes.
    static func afterCompile() {
        guard enabled else { return }
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            lock.lock(); let latest = generation == mine; lock.unlock()
            if latest { flush() }
        }
    }

    /// The flush itself. The zone calls (not malloc/free) keep the compiler from removing the unused pair.
    static func flush() {
        let end = LaunchTimeline.begin("allocator cache flush")
        #if AIRC_TESTING
        let before = footprint(), start = LaunchTimeline.now()
        #endif
        guard let zone = malloc_default_zone() else { return end() }
        var taken: [UnsafeMutableRawPointer] = []
        taken.reserveCapacity(blocks)
        for _ in 0..<blocks {
            guard let p = malloc_zone_malloc(zone, blockBytes) else { break }
            taken.append(p)
        }
        for p in taken { malloc_zone_free(zone, p) }
        end()
        #if AIRC_TESTING
        log(["at_ms": Int(start), "ms": (LaunchTimeline.now() - start).rounded(), "blocks": taken.count,
             "footprint_before": before, "footprint_after": footprint()])
        #endif
    }

    #if AIRC_TESTING
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        } }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    /// AIRC_BLOCKING_MEMORY_LOG=<file>: one JSON line per flush.
    private static func log(_ entry: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment["AIRC_BLOCKING_MEMORY_LOG"], !path.isEmpty,
              var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(line); try? handle.close() }
        else { try? line.write(to: URL(fileURLWithPath: path)) }
    }
    #endif
}
