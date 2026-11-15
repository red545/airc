// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import Foundation
import Darwin

/// Quit timeline for a scripted check, on only with AIRC_QUIT_DIAG=1 (quitflush). From the moment the check asks to
/// quit, it records when each child process (Chromium's renderers, GPU, network and other utility processes) exits,
/// and, at 2 s, 5 s and 9 s, samples this process and every child still alive and takes the main thread's backtrace. Written to
/// quit-diag-<pid>.txt next to the check's log. No AppKit and no main-queue work: the main thread is the one quitting.
enum QuitDiagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.environment["AIRC_QUIT_DIAG"] == "1" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var file: URL?
    nonisolated(unsafe) private static var t0: UInt64 = 0

    private static func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 }

    private static func note(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        lines.append(String(format: "t=%6.3f ", elapsed()) + s)
        try? lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// A step of the quit path (engine returned, willTerminate, exit), once the recorder runs; from any thread.
    static func mark(_ step: String) { note("quit path: " + step) }

    /// Starts the recorder. `mainBacktrace(path)` writes the main thread's backtrace to `path`.
    static func begin(directory: URL, mainBacktrace: @escaping @Sendable (String) -> Void) {
        let pid = getpid()
        lock.lock()
        file = directory.appendingPathComponent("quit-diag-\(pid).txt")
        t0 = DispatchTime.now().uptimeNanoseconds
        lines = [String(format: "quit requested at %.3f (wall clock), pid %d", Date().timeIntervalSince1970, pid)]
        lock.unlock()
        atexit { QuitDiagnostics.mark("exit() handlers") }
        Thread.detachNewThread {
            var kinds: [pid_t: String] = [:]
            var alive = Set<pid_t>()
            var sampled: Set<Int> = []
            while elapsed() < 40 {
                let now = Set(children(of: pid).filter(isRunning))
                let new = now.subtracting(kinds.keys)
                if !new.isEmpty {
                    for (p, k) in describe(Array(new)) { kinds[p] = k }
                    for p in new.sorted() { note("child \(p) running: \(kinds[p] ?? "?")") }
                }
                for p in alive.subtracting(now).sorted() { note("child \(p) exited: \(kinds[p] ?? "?")") }
                alive = now
                for mark in [2, 5, 9] where elapsed() >= Double(mark) && !sampled.contains(mark) {
                    sampled.insert(mark)
                    note("\(mark) s: \(alive.count) children alive: " + alive.sorted().map { "\($0) \(kinds[$0] ?? "?")" }.joined(separator: " | "))
                    let main = directory.appendingPathComponent("quit-main-\(mark)s-\(pid).txt").path
                    mainBacktrace(main)
                    note("\(mark) s: main thread backtrace in \((main as NSString).lastPathComponent)")
                    // Not the recorder's own `sample` runs or macOS helpers it starts (code-sign-clone-cleanup).
                    for p in [pid] + alive.sorted() where kinds[p].map({ $0.hasPrefix("utility") || $0.hasPrefix("gpu") || $0.hasPrefix("renderer") }) ?? (p == pid) {
                        let out = directory.appendingPathComponent("quit-sample-\(mark)s-\(p).txt").path
                        // Detached so it finishes even if this process exits meanwhile (sample writes on its own).
                        let s = Process()
                        s.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                        s.arguments = ["\(p)", "1", "-mayDie", "-file", out]
                        s.standardOutput = FileHandle.nullDevice
                        s.standardError = FileHandle.nullDevice
                        s.standardInput = FileHandle.nullDevice
                        try? s.run()
                        note("\(mark) s: sampling \(p) into \((out as NSString).lastPathComponent)")
                    }
                }
                usleep(20_000)
            }
        }
    }

    /// Child PIDs of `pid` (zombies included; isRunning drops them).
    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(buffer.prefix(Int(n))).filter { $0 > 0 } : []
    }

    /// A process that still has a task (an exited child waiting to be reaped has none).
    private static func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_taskinfo()
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
    }

    /// "renderer", "gpu-process", "utility network.mojom.NetworkService", … from each child's command line.
    private static func describe(_ pids: [pid_t]) -> [pid_t: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "pid=,args=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var result: [pid_t: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = pid_t(fields[0]) else { continue }
            let args = fields[1].split(separator: " ")
            func value(_ key: String) -> String? { args.first { $0.hasPrefix("--\(key)=") }.map { String($0.dropFirst(key.count + 3)) } }
            result[pid] = [value("type"), value("utility-sub-type")].compactMap { $0 }.joined(separator: " ").nonEmpty
                ?? String((args.first.map { ($0 as NSString).lastPathComponent } ?? "?").prefix(40))
        }
        return result
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
