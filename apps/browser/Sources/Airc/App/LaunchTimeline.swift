// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import os

/// The launch's critical path, from process start: points and intervals (os_signpost "launch" on the Points of
/// Interest track, so an Instruments trace lines them up with samples) plus an in-memory list that the perf scenario
/// and the launch timeline check read. Recording stops after the first 60 s or 400 entries; it costs a lock and an
/// array append per entry. `AIRC_LAUNCH_TIMELINE=<file>` also writes the list as JSON 20 s after launch, for a
/// launch the way the owner launches.
enum LaunchTimeline {
    struct Entry { let name: String; let start: Double; var end: Double?; let main: Bool }
    static let signposts = OSLog(subsystem: "app.airc.launch", category: .pointsOfInterest)
    private static let lock = NSLock()
    private static var entries: [Entry] = []
    /// Process start (kernel), as a Date: every entry is milliseconds since it.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
    }()

    static func now() -> Double { Date().timeIntervalSince(processStart) * 1000 }

    /// A point on the timeline.
    static func mark(_ name: String) {
        guard append(name) != nil else { return }
        os_signpost(.event, log: signposts, name: "launch", "%{public}s", name)
    }

    /// An interval; call the returned closure when it ends (at most once).
    static func begin(_ name: String) -> () -> Void {
        guard let i = append(name) else { return {} }
        let id = OSSignpostID(log: signposts)
        os_signpost(.begin, log: signposts, name: "launch", signpostID: id, "%{public}s", name)
        var ended = false
        return {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            if i < entries.count { entries[i].end = now() }
            lock.unlock()
            os_signpost(.end, log: signposts, name: "launch", signpostID: id)
        }
    }

    /// "interactive": the first time the main run loop is about to wait after the window is up (Core Animation has
    /// committed its frame and no work is queued), as the perf scenario's interactive_ms.
    static func markInteractiveAtNextIdle() {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            mark("interactive")
            if let o = observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
            observer = nil
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The first entry with this name (its start), in ms since process start.
    static func first(_ name: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.name == name }?.start
    }

    static var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    static var json: [[String: Any]] {
        all.map { e in
            var d: [String: Any] = ["name": e.name, "ms": (e.start * 10).rounded() / 10, "main": e.main]
            if let end = e.end { d["end_ms"] = (end * 10).rounded() / 10; d["dur_ms"] = ((end - e.start) * 10).rounded() / 10 }
            return d
        }
    }

    /// Text lines, "   812.3 ms  +41.0  name", for reports.
    static var text: String {
        all.map { e in
            let dur = e.end.map { String(format: "%8.1f", $0 - e.start) } ?? "        "
            return String(format: "%9.1f ms %@  %@%@", e.start, dur, e.main ? "" : "[bg] ", e.name)
        }.joined(separator: "\n")
    }

    private static var fileScheduled = false
    private static func append(_ name: String) -> Int? {
        let t = now()
        lock.lock(); defer { lock.unlock() }
        guard t < 60_000, entries.count < 400 else { return nil }
        entries.append(Entry(name: name, start: t, end: nil, main: Thread.isMainThread))
        if !fileScheduled, let path = ProcessInfo.processInfo.environment["AIRC_LAUNCH_TIMELINE"], !path.isEmpty {
            fileScheduled = true
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                try? data?.write(to: URL(fileURLWithPath: path))
            }
        }
        return entries.count - 1
    }
}
