// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// One child process of the person's own CLI (docs/design/agent-cli.md): started in a process group of its own, so Stop
/// can end it and everything it started (the airc-mcp helper, Node workers) with one signal. Lines from stdout and the
/// exit arrive on the main thread; stdin is written in order on a private queue.
final class AgentCLIProcess {
    let pid: pid_t
    let executable: String
    /// One stdout line (without the newline), on the main thread.
    var onLine: ((Data) -> Void)?
    /// The exit status (or 128+signal) and the last lines of stderr, on the main thread, once.
    var onExit: ((Int32, String) -> Void)?
    private(set) var exited = false
    private var stdinFD: Int32
    private let writes = DispatchQueue(label: "airc.agent.cli.stdin")
    private let lock = NSLock()
    private var stderrTail = Data()
    private var killTimer: DispatchWorkItem?

    /// Starts `executable args` in `cwd` with exactly `env`. Throws a readable reason.
    init(executable: String, args: [String], env: [String: String], cwd: String) throws {
        self.executable = executable
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
            throw AgentCLIError("couldn't make pipes")
        }
        // Our ends never leak into the child (or into other children Airc starts later).
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        for fd in [inPipe[0], outPipe[1], errPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // A new process group (its id is the child's pid), default signal handling, and no other inherited fds.
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw AgentCLIError(rc == ENOENT ? "not found" : rc == EACCES ? "not executable" : String(cString: strerror(rc)))
        }
        pid = child
        stdinFD = inPipe[1]
        startReading(stdout: outPipe[0], stderr: errPipe[0])
    }

    private func startReading(stdout outFD: Int32, stderr errFD: Int32) {
        Thread { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(errFD, &chunk, chunk.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                guard let self else { continue }
                self.lock.lock()
                self.stderrTail.append(contentsOf: chunk[0..<n])
                if self.stderrTail.count > 4096 { self.stderrTail.removeFirst(self.stderrTail.count - 4096) }
                self.lock.unlock()
            }
            close(errFD)
        }.start()
        let pid = self.pid
        Thread { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(outFD, &chunk, chunk.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                var lines: [Data] = []
                while let i = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<i])
                    buffer.removeSubrange(buffer.startIndex...i)
                    if !line.isEmpty { lines.append(line) }
                }
                // A line longer than 16 MiB isn't a protocol line: drop it rather than grow without bound.
                if buffer.count > 16 << 20 { buffer.removeAll() }
                if !lines.isEmpty {
                    DispatchQueue.main.async { for l in lines { self?.onLine?(l) } }
                }
            }
            close(outFD)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async {
                guard let self, !self.exited else { return }
                self.exited = true
                self.killTimer?.cancel()
                // Anything the CLI started and left behind goes too.
                kill(-pid, SIGKILL)
                self.writes.async { close(self.stdinFD); self.stdinFD = -1 }
                self.lock.lock()
                let tail = String(decoding: self.stderrTail, as: UTF8.self)
                self.lock.unlock()
                self.onExit?(code, tail)
            }
        }.start()
    }

    /// Writes bytes to the CLI's stdin, in order. A closed pipe is ignored (the exit reports why).
    func write(_ data: Data) {
        writes.async { [weak self] in
            guard let self, self.stdinFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(self.stdinFD, raw.baseAddress! + off, raw.count - off)
                    if n < 0 { if errno == EINTR { continue }; return }
                    off += n
                }
            }
        }
    }

    /// Ends the whole process group: SIGTERM now, SIGKILL after `grace` seconds if it's still there.
    func terminate(grace: TimeInterval = 2) {
        guard !exited else { return }
        kill(-pid, SIGTERM)
        let p = pid
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.exited else { return }
            kill(-p, SIGKILL)
        }
        killTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: w)
    }

    /// The last non-empty stderr line (for "quit unexpectedly: …").
    static func lastLine(_ s: String) -> String {
        let l = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return String(l.prefix(200))
    }
}

struct AgentCLIError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
