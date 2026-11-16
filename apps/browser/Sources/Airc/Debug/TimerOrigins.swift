// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import Foundation
import ObjectiveC

/// MEM-6 (idletimers): who made each run-loop timer. Perf runs only (`--script perf`): NSTimer's public factories are
/// wrapped at launch so each new timer's creation stack is kept, keyed by the timer's address. The idle census
/// (PerfScenario's `timer_census`) pairs every CFRunLoopTimer in the main run loop with its stack; infra/perf/gaps.py
/// turns the app's frames into symbols (and file:line where debug info allows) with `atos`. Timers made through
/// CoreFoundation directly (Core Animation's, Chromium's message pump, AppKit's perform-after-delay) have no entry and
/// are named by their callout instead. Dispatch timer sources can't be listed from inside the process; the harness
/// counts the process's idle wakeups for those.
enum TimerOrigins {
    struct Origin {
        let frames: [UInt]
        let interval: TimeInterval
        let made: Date
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var origins: [UInt: Origin] = [:]
    nonisolated(unsafe) private static var order: [UInt] = []
    nonisolated(unsafe) private static var installed = false
    private static let cap = 4096

    static var isEnabled: Bool { lock.withLock { installed } }

    /// Before the app makes any timer (main.swift). Only for perf runs; no other build or run is changed.
    static func installIfPerfRun() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--script"), i + 1 < args.count, args[i + 1] == "perf" else { return }
        install()
    }

    static func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        // Block timers: +scheduledTimerWithTimeInterval:repeats:block:, +timerWithTimeInterval:repeats:block:.
        typealias BlockFactory = @convention(c) (AnyObject, Selector, TimeInterval, ObjCBool, AnyObject) -> AnyObject
        for name in ["scheduledTimerWithTimeInterval:repeats:block:", "timerWithTimeInterval:repeats:block:"] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getClassMethod(Timer.self, sel) else { continue }
            let original = unsafeBitCast(method_getImplementation(m), to: BlockFactory.self)
            let wrapped: @convention(block) (AnyObject, TimeInterval, ObjCBool, AnyObject) -> AnyObject = { cls, interval, repeats, block in
                let t = original(cls, sel, interval, repeats, block)
                record(t, interval: repeats.boolValue ? interval : 0)
                return t
            }
            method_setImplementation(m, imp_implementationWithBlock(wrapped))
        }
        // Target/selector timers: +scheduledTimerWithTimeInterval:target:selector:userInfo:repeats: and +timerWith….
        typealias TargetFactory = @convention(c) (AnyObject, Selector, TimeInterval, AnyObject?, Selector, AnyObject?, ObjCBool) -> AnyObject
        for name in ["scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", "timerWithTimeInterval:target:selector:userInfo:repeats:"] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getClassMethod(Timer.self, sel) else { continue }
            let original = unsafeBitCast(method_getImplementation(m), to: TargetFactory.self)
            let wrapped: @convention(block) (AnyObject, TimeInterval, AnyObject?, Selector, AnyObject?, ObjCBool) -> AnyObject = { cls, interval, target, action, info, repeats in
                let t = original(cls, sel, interval, target, action, info, repeats)
                record(t, interval: repeats.boolValue ? interval : 0)
                return t
            }
            method_setImplementation(m, imp_implementationWithBlock(wrapped))
        }
        // -initWithFireDate:interval:repeats:block: (Swift's Timer(fire:interval:repeats:block:)), on NSTimer and on the
        // concrete class if it has its own.
        typealias BlockInit = @convention(c) (AnyObject, Selector, NSDate, TimeInterval, ObjCBool, AnyObject) -> AnyObject
        let initSel = NSSelectorFromString("initWithFireDate:interval:repeats:block:")
        var seen = Set<OpaquePointer>()
        for cls in [Timer.self as AnyClass, NSClassFromString("__NSCFTimer")].compactMap({ $0 }) {
            guard let m = class_getInstanceMethod(cls, initSel) else { continue }
            guard seen.insert(m).inserted else { continue }
            let original = unsafeBitCast(method_getImplementation(m), to: BlockInit.self)
            let wrapped: @convention(block) (AnyObject, NSDate, TimeInterval, ObjCBool, AnyObject) -> AnyObject = { obj, fire, interval, repeats, block in
                let t = original(obj, initSel, fire, interval, repeats, block)
                record(t, interval: repeats.boolValue ? interval : 0)
                return t
            }
            method_setImplementation(m, imp_implementationWithBlock(wrapped))
        }
    }

    private static func record(_ timer: AnyObject, interval: TimeInterval) {
        let key = UInt(bitPattern: Unmanaged.passUnretained(timer).toOpaque())
        // Drop the wrapper's own frames later (gaps.py skips TimerOrigins symbols); keep enough to reach the app's caller.
        let frames = Thread.callStackReturnAddresses.prefix(14).map { $0.uintValue }
        lock.lock(); defer { lock.unlock() }
        if origins[key] == nil { order.append(key) }
        origins[key] = Origin(frames: Array(frames), interval: interval, made: Date())
        if order.count > cap {
            let drop = order.count - cap
            for k in order.prefix(drop) { origins[k] = nil }
            order.removeFirst(drop)
        }
    }

    /// The census entry for each timer address in the main run loop's description: its stack, with each frame's image
    /// and the image's load address, so `atos -o <image> -l <base> <frame>` names it. Frames in system libraries are
    /// left out (Foundation's own factory and wrapper frames), apart from the first, so engine-made timers keep a hint.
    static func describe(addresses: [UInt], intervals: [UInt: TimeInterval]) -> [[String: Any]] {
        let known: [UInt: Origin] = lock.withLock { origins }
        return addresses.map { address in
            var row: [String: Any] = ["address": String(format: "0x%lx", address)]
            guard let o = known[address] else { row["origin"] = "not made through NSTimer (CoreFoundation, engine or AppKit)"; return row }
            // An address reused by a later CF timer would carry a stale entry: the intervals must agree.
            if let seen = intervals[address], abs(seen - o.interval) > 0.001, !(o.interval == 0 && seen == 0) {
                row["origin"] = "stale entry (interval \(o.interval) vs \(seen))"; return row
            }
            row["made_s_ago"] = (Date().timeIntervalSince(o.made) * 100).rounded() / 100
            row["frames"] = o.frames.compactMap { pc -> [String: Any]? in
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0, let fname = info.dli_fname else { return nil }
                let path = String(cString: fname)
                if path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") { return nil }
                var f: [String: Any] = ["pc": String(format: "0x%lx", pc), "image": path,
                                        "base": String(format: "0x%lx", UInt(bitPattern: info.dli_fbase))]
                if let s = info.dli_sname { f["symbol"] = String(cString: s) }
                return f
            }
            return row
        }
    }
}
#endif
