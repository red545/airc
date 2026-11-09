// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // agentspike: a dev-build prototype (docs/agent-ready.md); public builds compile none of Agent/
import Foundation
import Darwin
import Security

/// Where the agent socket lives: `Agent.sock` in Airc's data folder, or (a data folder whose path is too long for a socket
/// address) a name derived from it in the per-user temporary folder. airc-mcp computes the same path.
enum AgentPaths {
    static func socket(dataDir: URL) -> String {
        let dir = dataDir.standardizedFileURL.path
        let direct = (dir as NSString).appendingPathComponent("Agent.sock")
        if direct.utf8.count < 100 { return direct }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let temp = n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        var hash: UInt64 = 0xcbf29ce484222325
        for b in dir.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return (temp as NSString).appendingPathComponent(String(format: "airc-agent-%016llx.sock", hash))
    }
    /// The loopback HTTP transport's port and per-launch token (0600), when it's on.
    static func httpInfo(dataDir: URL) -> URL { dataDir.appendingPathComponent("Agent-http.json") }

    /// Writes `data` to a file readable by this user only (no umask games: the process's umask is shared).
    static func writePrivate(_ data: Data, to path: String, append: Bool = false) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        fchmod(fd, 0o600)
        return data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }
}

/// One client: a socket connection (one MCP session, its profile chosen once) or one HTTP request.
final class AgentSession {
    let id: Int
    var client = "unknown"
    var via = "local"
    /// The client's process (the helper), from the socket's peer credentials; nil over HTTP.
    var peerPID: pid_t?
    /// The profile this session may use (AircKit profile ID). Set once; another one needs a new connection.
    var profileID: String?
    /// The profile the hello asked for (a name or an ID), resolved on first use.
    var requestedProfile: String?
    /// The agent window computer-use calls act on when they name none.
    var currentWindow: Int?
    /// left_mouse_down without its left_mouse_up yet: moves are drags.
    var leftDown = false
    /// Legacy MCP (an `initialize` handshake) and its version; nil for per-request (2026-07-28) clients.
    var legacyVersion: String?
    /// HTTP requests are one-shot: their windows outlive the request and belong to the client's name instead.
    let persistent: Bool
    var ownerKey: String { persistent ? "session-\(id)" : "http-\(client)" }

    init(id: Int, persistent: Bool) { self.id = id; self.persistent = persistent }
}

/// The agent server: a 0600 Unix socket (same-user peers only) and, optionally, HTTP on 127.0.0.1 with a bearer token.
/// I/O runs on its own queue; every request is handled on the main thread, one at a time per session, in order
/// (computer-use batches must run in the order they were sent).
final class AgentServer {
    typealias Handler = (_ line: Data, _ session: AgentSession, _ reply: @escaping (Data?) -> Void) -> Void
    typealias Hello = (_ session: AgentSession) -> String?   // nil: ready; else the refusal

    static let maxLine = 1 << 20          // 1 MiB requests (answers may be larger: screenshots)
    static let maxQueued = 32
    static let maxConnections = 16

    private let queue = DispatchQueue(label: "airc.agent.server")
    private let socketPath: String
    private let handler: Handler
    private let hello: Hello
    private var listenSource: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var connections: [Int: Connection] = [:]
    private var nextID = 1
    private var http: HTTPListener?
    var onConnectionsChanged: ((Int) -> Void)?
    var onDisconnect: ((AgentSession) -> Void)?

    init(socketPath: String, handler: @escaping Handler, hello: @escaping Hello) {
        self.socketPath = socketPath
        self.handler = handler
        self.hello = hello
    }

    private func releaseLock() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    /// Opens the socket. Answers why not when it can't (another Airc already serves this data folder…).
    func start() -> String? {
        // One owner per path: a lock file next to the socket, held for the server's life.
        lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            releaseLock()
            return "another Airc serves agents for this data folder"
        }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { releaseLock(); return "socket: \(errno)" }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); releaseLock(); return "socket path too long" }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        // The socket is made with the process's umask (others can't write it, so can't connect), then made 0600
        // before it listens.
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
            let e = errno
            close(fd); unlink(socketPath); releaseLock()
            return "bind: \(e)"
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
        return nil
    }

    /// The optional loopback transport (Streamable HTTP, JSON answers only). Writes port and token to `info` (0600).
    func startHTTP(info: URL) -> String? {
        let h = HTTPListener(queue: queue, handler: { [weak self] line, session, reply in
            DispatchQueue.main.async {
                guard let self else { return reply(nil) }
                self.handler(line, session, reply)
            }
        }, nextID: { [weak self] in self?.takeID() ?? 0 })
        if let error = h.start(info: info) { return error }
        http = h
        return nil
    }

    /// The kill switch and quit: every connection closes, the socket goes away.
    func stop() {
        queue.sync {
            listenSource?.cancel(); listenSource = nil
            unlink(socketPath)
            for c in connections.values { c.close() }
            connections.removeAll()
            http?.stop(); http = nil
            releaseLock()
        }
        onConnectionsChanged?(0)
    }

    private func takeID() -> Int { let i = nextID; nextID += 1; return i }

    private func accept(_ listenFD: Int32) {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Only processes of this user (the socket's mode says the same; this says it for the kernel's view).
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), connections.count < Self.maxConnections else {
                close(fd); continue
            }
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            let hasPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let session = AgentSession(id: takeID(), persistent: true)
            session.peerPID = hasPID ? pid : nil
            let c = Connection(fd: fd, session: session, queue: queue, server: self)
            connections[session.id] = c
            c.start()
            let n = connections.count
            DispatchQueue.main.async { self.onConnectionsChanged?(n) }
        }
    }

    fileprivate func closed(_ c: Connection) {
        connections[c.session.id] = nil
        let n = connections.count
        DispatchQueue.main.async {
            self.onConnectionsChanged?(n)
            self.onDisconnect?(c.session)
        }
    }

    fileprivate func helloAnswer(_ session: AgentSession, done: @escaping (String?) -> Void) {
        DispatchQueue.main.async { done(self.hello(session)) }
    }

    fileprivate func handle(_ line: Data, _ session: AgentSession, _ reply: @escaping (Data?) -> Void) {
        DispatchQueue.main.async { self.handler(line, session, reply) }
    }

    /// One socket client: the hello line, then MCP lines handled in order. Everything here runs on the server's queue.
    fileprivate final class Connection {
        let fd: Int32
        let session: AgentSession
        let queue: DispatchQueue
        weak var server: AgentServer?
        private var source: DispatchSourceRead?
        private var suspended = false
        private var buffer = Data()
        private var lines: [Data] = []
        private var busy = false
        private var greeted = false
        private var closed = false
        /// The client half-closed (airc-mcp's stdin ended): answer what's queued, then close.
        private var eof = false

        init(fd: Int32, session: AgentSession, queue: DispatchQueue, server: AgentServer) {
            self.fd = fd; self.session = session; self.queue = queue; self.server = server
        }

        func start() {
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            s.setEventHandler { [weak self] in self?.readable() }
            let fd = self.fd
            s.setCancelHandler { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
            s.resume()
            source = s
        }

        /// Closes the socket (in the source's cancel handler, as libdispatch requires).
        func close() {
            guard !closed else { return }
            closed = true
            if suspended { source?.resume(); suspended = false }
            source?.cancel(); source = nil
        }

        private func finish() {
            guard !closed else { return }
            close()
            server?.closed(self)
        }

        private func readable() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR || errno == EAGAIN { return }; return finish() }
            if n == 0 {
                // No more requests; the answers still go out.
                eof = true
                if !suspended { source?.suspend(); suspended = true }
                if !busy && lines.isEmpty { finish() }
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let i = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<i])
                buffer.removeSubrange(buffer.startIndex...i)
                if !line.isEmpty { lines.append(line) }
            }
            if buffer.count > AgentServer.maxLine || lines.count > AgentServer.maxQueued { return finish() }
            pump()
        }

        private func pump() {
            guard !busy, !closed, let server else { return }
            guard !lines.isEmpty else { if eof { finish() }; return }
            let line = lines.removeFirst()
            busy = true
            if !greeted {
                greeted = true
                // The helper's hello; a client without one (nc -U) is "unknown", over "local".
                if let hello = try? JSONSerialization.jsonObject(with: line) as? [String: Any], hello["airc"] as? String == "hello" {
                    session.client = String((hello["client"] as? String ?? "unknown").prefix(64))
                    session.via = hello["via"] as? String == "ssh" ? "ssh" : "local"
                    session.requestedProfile = (hello["profile"] as? String).map { String($0.prefix(128)) }
                    server.helloAnswer(session) { [weak self] refusal in
                        self?.queue.async {
                            guard let self else { return }
                            let answer: [String: Any] = refusal.map { ["airc": "refused", "reason": $0] } ?? ["airc": "ready", "v": 1]
                            self.send((try? JSONSerialization.data(withJSONObject: answer)) ?? Data())
                            if refusal != nil { return self.finish() }
                            self.busy = false
                            self.pump()
                        }
                    }
                    return
                }
                lines.insert(line, at: 0)
                server.helloAnswer(session) { [weak self] refusal in
                    self?.queue.async {
                        guard let self else { return }
                        if refusal != nil { return self.finish() }
                        self.busy = false
                        self.pump()
                    }
                }
                return
            }
            server.handle(line, session) { [weak self] answer in
                self?.queue.async {
                    guard let self else { return }
                    if let answer { self.send(answer) }
                    self.busy = false
                    self.pump()
                }
            }
        }

        /// Writes one line; a client that stops reading for 5 s is cut off (never a stuck queue or main thread).
        private func send(_ data: Data) {
            guard !closed else { return }
            var out = data
            out.append(0x0A)
            let deadline = Date().addingTimeInterval(5)
            let ok = out.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN, Date() < deadline { usleep(1000); continue }
                        return false
                    }
                    off += n
                }
                return true
            }
            if !ok { finish() }
        }
    }
}

/// Streamable HTTP on 127.0.0.1 (MCP 2025-11-25 and 2026-07-28): POST /mcp with a JSON-RPC body, answered as JSON.
/// Every request needs `Authorization: Bearer <token>` (a new random token each launch), a loopback `Host`, and no
/// `Origin` (browsers always send one; a web page can therefore never use this, DNS rebinding or not). The profile
/// comes from `X-Airc-Profile` on every request; the client's name from `X-Airc-Client`.
final class HTTPListener {
    private let queue: DispatchQueue
    private let handler: AgentServer.Handler
    private let nextID: () -> Int
    private var source: DispatchSourceRead?
    private(set) var port: UInt16 = 0
    private var token = ""
    private var info: URL?

    init(queue: DispatchQueue, handler: @escaping AgentServer.Handler, nextID: @escaping () -> Int) {
        self.queue = queue; self.handler = handler; self.nextID = nextID
    }

    func start(info: URL) -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "no random token" }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return "socket: \(errno)" }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 16) == 0 else { close(s); return "bind: \(errno)" }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(s, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        let json: [String: Any] = ["url": "http://127.0.0.1:\(port)/mcp", "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: json), AgentPaths.writePrivate(data, to: info.path) else {
            close(s); return "can't write \(info.lastPathComponent)"
        }
        self.info = info
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.accept(s) }
        src.setCancelHandler { close(s) }
        src.resume()
        source = src
        return nil
    }

    func stop() {
        source?.cancel(); source = nil
        if let info { try? FileManager.default.removeItem(at: info) }
    }

    private func accept(_ fd: Int32) {
        while true {
            let c = Darwin.accept(fd, nil, nil)
            if c < 0 { return }
            // Accepted sockets inherit O_NONBLOCK on macOS; this one is read and written blocking, off the queue.
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { self.serve(c) }
        }
    }

    private func respond(_ c: Int32, _ status: String, _ body: Data = Data(), type: String = "application/json") {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: \(type)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(c, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; break }
                off += n
            }
        }
        close(c)
    }

    /// Constant-time token comparison.
    private func tokenMatches(_ given: String) -> Bool {
        let a = Array(given.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private func serve(_ c: Int32) {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { close(c); return }
            data.append(contentsOf: chunk[0..<n])
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
            if data.count > 65536 { return respond(c, "431 Request Header Fields Too Large") }
        }
        let head = String(decoding: data[..<headerEnd!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard request.count >= 2, request[1] == "/mcp" else { return respond(c, "404 Not Found") }
        // DNS rebinding and web pages: a loopback Host only, and no Origin at all.
        let host = headers["host"] ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return respond(c, "421 Misdirected Request") }
        guard headers["origin"] == nil else { return respond(c, "403 Forbidden") }
        let auth = headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "), tokenMatches(String(auth.dropFirst(7))) else { return respond(c, "401 Unauthorized") }
        guard request[0] == "POST" else { return respond(c, "405 Method Not Allowed") }
        guard let length = Int(headers["content-length"] ?? ""), length >= 0, length <= AgentServer.maxLine else {
            return respond(c, "411 Length Required")
        }
        var body = Data(data[headerEnd!.upperBound...])
        while body.count < length {
            let n = read(c, &chunk, min(chunk.count, length - body.count))
            if n <= 0 { close(c); return }
            body.append(contentsOf: chunk[0..<n])
        }
        let session = AgentSession(id: queue.sync { nextID() }, persistent: false)
        session.client = String((headers["x-airc-client"] ?? headers["user-agent"] ?? "http").prefix(64))
        session.via = "http"
        session.requestedProfile = headers["x-airc-profile"]
        if let v = headers["mcp-protocol-version"], v != AgentMCP.modern { session.legacyVersion = v }
        let done = DispatchSemaphore(value: 0)
        var answer: Data?
        handler(body, session) { answer = $0; done.signal() }
        if done.wait(timeout: .now() + 360) == .timedOut { return respond(c, "504 Gateway Timeout") }
        if let answer { respond(c, "200 OK", answer) } else { respond(c, "202 Accepted") }
    }
}
#endif
