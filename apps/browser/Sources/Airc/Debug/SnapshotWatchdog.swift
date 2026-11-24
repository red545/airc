// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import Foundation
import Darwin
import CoreGraphics

/// No AppKit or main-queue work here: a nested mouse-tracking loop can stop
/// SnapshotRunner's steps and every main-queue timeout from ever running.
final class SnapshotWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.airc.snapshot-watchdog", qos: .userInitiated))
    private let file: URL
    private let prefix: String
    private let script: String
    private let limit: Double
    private var messages: [String] = []
    private var terminating = false
    /// A bound on any one step (seconds), checked off the main thread: `events` has one by default
    /// (AIRC_STEP_LIMIT=<seconds> sets it for any check, 0 turns it off). A step that outlives it is a hang
    /// of the harness or of its environment, so the run fails fast instead of holding the UI lock to the hard timeout.
    private let stepLimit: Double?
    private var stepTimer: DispatchSourceTimer?
    private var stepNumber = 0
    private var stepStarted: Double = 0
    private var longestStep: (seconds: Double, number: Int, after: String) = (0, 0, "")
    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    init(directory: URL, script: String) {
        self.script = script
        file = directory.appendingPathComponent("log.txt")
        prefix = ((try? String(contentsOf: file, encoding: .utf8)).map { $0 + "\n" } ?? "") + "[\(script)]\n"
        // The short deadline belongs only to this deliberately blocked smoke
        // fixture. Ordinary checks and perf retain their existing budgets.
        limit = script == "watchdog-block-main" ? 5 : script == "perf" ? 660 : script == "idlecpu" ? 720 : script == "agentlong" ? 600 : 240
        let chosen = ProcessInfo.processInfo.environment["AIRC_STEP_LIMIT"].flatMap(Double.init) ?? (script == "events" ? 90 : script.hasPrefix("watchdog-step-") ? 4 : 0)
        stepLimit = chosen.isFinite && chosen > 0 ? chosen : nil
        let identity: [String: Any] = ["pid": getpid(), "script": script,
            "token": ProcessInfo.processInfo.environment["AIRC_UI_LAUNCH_TOKEN"] ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: identity) {
            try? data.write(to: directory.appendingPathComponent("ui-launch.json"), options: .atomic)
        }
        timer.setEventHandler { [weak self] in self?.expired() }
        timer.schedule(deadline: .now() + limit)
        timer.resume()
        if stepLimit != nil {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.airc.snapshot-step-watchdog", qos: .userInitiated))
            t.setEventHandler { [weak self] in self?.checkStep() }
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.resume()
            stepTimer = t
        }
    }

    /// The runner starts step `number` (no AppKit, no main-queue work here).
    func stepBegan(_ number: Int) {
        lock.lock(); defer { lock.unlock() }
        let t = Self.now()
        if stepNumber > 0, t - stepStarted > longestStep.seconds {
            longestStep = (t - stepStarted, stepNumber, messages.last(where: { !$0.hasPrefix("UI-FAIL-STATE") }) ?? "")
        }
        stepNumber = number
        stepStarted = t
    }

    /// "step 143 took 12.3 s" for the log, with the check line before it.
    var longestStepSummary: String {
        lock.lock(); defer { lock.unlock() }
        return String(format: "longest step: #%d, %.1f s (after \"%@\"); step limit %@", longestStep.number, longestStep.seconds,
                      String(longestStep.after.prefix(80)), stepLimit.map { String(format: "%.0f s", $0) } ?? "none")
    }

    private func checkStep() {
        lock.lock()
        guard let stepLimit, !terminating, stepNumber > 0 else { return lock.unlock() }
        let age = Self.now() - stepStarted
        let number = stepNumber
        let after = messages.last(where: { !$0.hasPrefix("UI-FAIL-STATE") }) ?? "the start of the run"
        lock.unlock()
        guard age > stepLimit else { return }
        stepTimer?.cancel()
        let evidence = Self.environmentEvidence()
        let head = String(format: "step %d stuck for %.0f s (limit %.0f s; last line: \"%@\")", number, age, stepLimit, String(after.prefix(100)))
        let line = evidence.map { "FAIL-ENV \(script): \(head): \($0)" } ?? "FAIL [independent] \(script): \(head), no environment evidence"
        fail(line)
    }

    /// What in the environment could stop a check's steps (no AppKit: runs while the main thread is stuck). Nil: nothing found.
    /// Reinstalls of the build Mac's UI driver post real pointer events and clicks of their own (w10, 2026-11-12:
    /// the menu bar began tracking in the middle of `events`), so a driver that is missing, was replaced a moment ago or
    /// is running right now is evidence. So is a locked screen.
    private static func environmentEvidence() -> String? {
        var found: [String] = []
        let path = UIDriverClient.path
        var info = stat()
        if stat(path, &info) != 0 {
            found.append("the UI driver is missing (\(path))")
        } else {
            let age = Date().timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec)
            if age < 900 { found.append("the UI driver binary was replaced \(Int(age)) s ago (a reinstall)") }
            else if access(path, X_OK) != 0 { found.append("the UI driver is not executable") }
        }
        let folder = (path as NSString).deletingLastPathComponent
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []) where name.hasPrefix("backup") || name.hasSuffix(".new") || name.hasSuffix(".tmp") {
            var sub = stat()
            if stat(folder + "/" + name, &sub) == 0 {
                let age = Date().timeIntervalSince1970 - TimeInterval(sub.st_mtimespec.tv_sec)
                if age < 900 { found.append("\(name) in the driver folder is \(Int(age)) s old (an install in progress)") }
            }
        }
        // The stable driver also runs as a long-lived service, so only a young process counts: a command (an install's
        // self-test, a click) in flight right now. etime is [[dd-]hh:]mm:ss.
        if let ps = shell("/bin/ps", ["-axo", "pid=,etime=,args="], timeout: 3) {
            let young = ps.split(separator: "\n").filter { line in
                guard line.contains("airc-ui-driver"), !line.contains("/bin/ps") else { return false }
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count >= 2 else { return false }
                let parts = fields[1].replacingOccurrences(of: "-", with: ":").split(separator: ":").compactMap { Int($0) }
                return parts.count == 2 && parts[0] * 60 + parts[1] < 120   // under two minutes old
            }
            if !young.isEmpty {
                found.append("a UI driver command is running right now: " + young.prefix(3).map { String($0.trimmingCharacters(in: .whitespaces).prefix(90)) }.joined(separator: " | "))
            }
        }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { found.append("the screen is locked") }
        guard !found.isEmpty else { return nil }
        let pointer = CGEvent(source: nil)?.location
        let held = CGEventSource.buttonState(.combinedSessionState, button: .left)
        return found.joined(separator: "; ") + String(format: " (real pointer at %.0f, %.0f, left button %@)", pointer?.x ?? -1, pointer?.y ?? -1, held ? "down" : "up")
    }

    /// Runs `path` and returns its output, killed after `timeout` seconds.
    private static func shell(_ path: String, _ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stop.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }

    private func flushLocked() {
        try? (prefix + messages.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        stepTimer?.cancel()
        flushLocked()
        // A beforeunload/modal termination path can hang too. Keep the watchdog
        // alive until the process exits, with a grace above Chromium's 10 s teardown bound.
        if !terminating {
            terminating = true
            timer.schedule(deadline: .now() + Self.terminationAllowance)
            // A slow quit is a warning, not a hang: Chromium's own Mac teardown watchdog ends a stuck shutdown at 10 s
            // (exit 2, "Teardown watchdog expired"), so a quit that is still running at 3 s or 9.5 s is recorded here,
            // flushed before that exit can happen, and only a quit past the allowance (15 s) fails (artifacts/quitflush).
            for mark in [3.0, 9.5] {
                quitQueue.asyncAfter(deadline: .now() + mark) { [weak self] in self?.slowQuit(after: mark) }
            }
            if QuitDiagnostics.enabled {
                let thread = mainThread
                QuitDiagnostics.begin(directory: file.deletingLastPathComponent()) { path in
                    if let thread { _ = Self.signalBacktrace(of: thread, to: path, deadline: 0.5) }
                }
            }
        }
    }

    private let quitQueue = DispatchQueue(label: "org.airc.snapshot-watchdog.quit", qos: .userInitiated)

    /// Still quitting `seconds` after finish(): a SLOW-QUIT line (never FAIL), on disk at once.
    private func slowQuit(after seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        let engine = seconds >= 9 ? "; Chromium's teardown watchdog ends the process at 10 s (exit 2)" : ""
        messages.append(String(format: "SLOW-QUIT %@: still quitting %.1f s after the check finished%@", script, seconds, engine))
        flushLocked()
    }

    /// Seconds a quit may take after finish(): 15, above Chromium's own 10 s teardown bound, or
    /// AIRC_TERMINATION_ALLOWANCE for a diagnostic run (quitflush).
    static let terminationAllowance: Double = ProcessInfo.processInfo.environment["AIRC_TERMINATION_ALLOWANCE"]
        .flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 15

    private func expired() {
        lock.lock()
        let reason = terminating ? "termination did not finish within \(Int(Self.terminationAllowance)) s" : "hard timeout after \(Int(limit)) s"
        lock.unlock()
        fail("FAIL [independent] \(script): \(reason)")
    }

    /// Records `line` (a FAIL or FAIL-ENV line) with the main thread's sample, then exits this process (exact PID: ours).
    private func fail(_ line: String) {
        let sample = file.deletingLastPathComponent().appendingPathComponent("watchdog-sample-\(getpid()).txt")
        lock.lock()
        timer.cancel()
        stepTimer?.cancel()
        let kind = line.hasPrefix("FAIL-ENV") ? "UI-FAIL-STATE \(Date().timeIntervalSince1970) unlocked" : nil
        if let kind { messages.append(kind) }
        messages.append("\(line) (off-main watchdog; main thread sample: \(sample.lastPathComponent))")
        // Flushed before sampling: the failure is on disk even if the exit below is all that still runs.
        flushLocked()
        lock.unlock()
        let how = Self.sampleMainThread(to: sample.path, mainThread: mainThread)
        lock.lock()
        messages.append("watchdog: main thread sample \(how)")
        flushLocked()
        lock.unlock()
        // Bypass AppKit and exit handlers, which can wait for the blocked main
        // thread. This is a failed check exit, not a deliberate crash.
        Darwin._exit(70)
    }

    /// The thread that made this watchdog, when it was the main thread (SnapshotRunner makes it there).
    private let mainThread: pthread_t? = pthread_main_np() != 0 ? pthread_self() : nil

    /// Evidence of what the stuck main thread is doing, in at most about 3.7 s, whatever happens. First the main
    /// thread's own backtrace from a signal (milliseconds), at `path`; then `sample` (every thread, symbolicated) at
    /// `<path>-full.txt` when it finishes within 3 s (it takes about 3–3.5 s on Airc, mostly symbolication). Returns
    /// what was written.
    private static func sampleMainThread(to path: String, mainThread: pthread_t?) -> String {
        let full = (path as NSString).deletingPathExtension + "-full.txt"
        unlink(path)
        unlink(full)
        var written: [String] = []
        if let thread = mainThread, signalBacktrace(of: thread, to: path, deadline: 0.5) {
            written.append("backtrace in " + (path as NSString).lastPathComponent)
        }
        let rc = runSample(path: full, seconds: 1, deadline: 3)
        if rc == 0, access(full, R_OK) == 0 {
            written.append("full sample in " + (full as NSString).lastPathComponent)
        } else {
            written.append(rc == nil ? "no full sample (sample unavailable or over 3 s)" : "no full sample (sample exit \(rc!))")
        }
        return access(path, R_OK) == 0 || access(full, R_OK) == 0 ? written.joined(separator: "; ") : "unavailable: " + written.joined(separator: "; ")
    }

    /// `/usr/bin/sample <own pid> <seconds> -mayDie -file <path>`, killed at `deadline`. Its exit status, or nil.
    private static func runSample(path: String, seconds: Int, deadline: Double) -> Int32? {
        let args = ["/usr/bin/sample", "\(getpid())", "\(seconds)", "-mayDie", "-file", path]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var child: pid_t = 0
        guard posix_spawn(&child, argv[0], &actions, nil, argv, environ) == 0 else { return nil }
        var status: Int32 = 0
        let end = Date().addingTimeInterval(deadline)
        while true {
            let r = waitpid(child, &status, WNOHANG)
            if r == child { return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1 }
            if r < 0 { return nil }
            if Date() >= end { break }
            usleep(20_000)
        }
        // Too slow: stop it, reap briefly, and never wait on it further (the exit reaps it anyway).
        kill(child, SIGKILL)
        for _ in 0..<10 where waitpid(child, &status, WNOHANG) == 0 { usleep(20_000) }
        return nil
    }

    /// The main thread writes its own backtrace from a SIGUSR2 handler (async-signal-safe calls only); waits at most
    /// `deadline` for it.
    private static func signalBacktrace(of thread: pthread_t, to path: String, deadline: Double) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        let header = "Main thread backtrace (SnapshotWatchdog), pid \(getpid()). Every thread: the -full.txt sample next to it, if it finished within 3 s.\n"
        _ = header.withCString { write(fd, $0, strlen($0)) }
        watchdogBacktraceFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 256)
        watchdogBacktraceFD = fd
        watchdogBacktraceDone = 0
        var action = sigaction()
        action.__sigaction_u.__sa_handler = watchdogBacktraceHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        guard sigaction(SIGUSR2, &action, nil) == 0, pthread_kill(thread, SIGUSR2) == 0 else { return false }
        let end = Date().addingTimeInterval(deadline)
        while watchdogBacktraceDone == 0 && Date() < end { usleep(10_000) }
        // Not delivered in time: the fd stays open (the process exits next), so a late handler can't write into a
        // reused descriptor such as log.txt's.
        guard watchdogBacktraceDone != 0 else { return false }
        close(fd)
        return true
    }
}

// The signal handler's state: set before the signal is sent, so the handler only reads it.
private var watchdogBacktraceFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private var watchdogBacktraceFD: Int32 = -1
private var watchdogBacktraceDone: Int32 = 0

private func watchdogBacktraceHandler(_: Int32) {
    guard let frames = watchdogBacktraceFrames else { return }
    let count = backtrace(frames, 256)
    backtrace_symbols_fd(frames, count, watchdogBacktraceFD)
    watchdogBacktraceDone = 1
}
#endif
