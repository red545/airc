// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Darwin
import Foundation
import Security

/// Other devices on the person's Tailscale network (Settings › Agents › Other devices; docs/user/agents.md, "From your
/// other devices"). Off by default. When on, Airc serves the same MCP tools as the local helper over Streamable HTTP
/// (POST /mcp, JSON answers), so Claude Code on another computer of the tailnet can use Airc on this Mac:
///
/// - It listens only on this Mac's Tailscale addresses (100.64.0.0/10, fd7a:115c:a1e0::/48), each socket bound to that
///   address *and* to the Tailscale interface (IP_BOUND_IF), never a wildcard. Every peer must be a tailnet address too.
///   No Tailscale: nothing listens. Addresses are re-read every 10 s and the sockets follow them; an address that
///   failed to bind is retried then too.
/// - Plain HTTP on purpose: Tailscale's WireGuard tunnel already encrypts and authenticates every packet between the
///   devices, and Claude Code takes an http:// MCP URL with no certificate setup (HTTPS would need the tailnet's HTTPS
///   certificates switched on and fetched, for no gain inside the tunnel).
/// - A device pairs once: Settings shows a one-time code (RemotePairing), the device trades it for its own bearer token
///   at POST /pair, and Airc keeps only the token's SHA-256, in its Keychain item (RemoteDeviceStore). Every other request
///   needs a paired token, or gets 401 and nothing else. Revoke in Settings ends the token and its sessions.
/// - After that everything is as for local apps (AgentCenter.hello): the one-time approval per app, now named for the
///   device ("Claude Code on build-box"), the profiles open to agents, fill-only passwords, no private windows, the
///   Agents folder, Watch, Stop.
///
/// Tokens, codes and request content are never logged; AgentLog.jsonl records the device's name and address only.
final class RemoteAgentListener {
    typealias Hello = (_ session: AgentSession, _ answer: @escaping (String?) -> Void) -> Void

    enum State: Equatable {
        case starting
        /// No Tailscale address on this Mac: nothing listens.
        case noTailscale
        case listening(addresses: [String], port: UInt16)
        case failed(String)
    }

    static let defaultPort: UInt16 = 47_830
    static let idleSession: TimeInterval = 900
    static let maxConnections = 32
    /// Sessions one device may hold; a new one ends its oldest idle one.
    static let maxSessionsPerDevice = 16

    private let queue = DispatchQueue(label: "airc.agent.remote")
    let port: UInt16
    private let handler: AgentServer.Handler
    private let hello: Hello
    private let store: RemoteDeviceStore
    /// Main thread: what Settings shows. `onChange` runs after each change.
    private(set) var state: State = .starting
    private(set) var hostName: String?
    var onChange: (() -> Void)?
    var onEnded: ((AgentSession) -> Void)?
    var onLog: (([String: Any]) -> Void)?

    // Server queue only.
    private var listeners: [(iface: TailnetAddress.Interface, source: DispatchSourceRead)] = []
    private var bound: [TailnetAddress.Interface] = []
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var open = 0
    private var lastFailure: String?

    // Any thread, under `lock`.
    private let lock = NSLock()
    private var registry: RemoteDeviceRegistry
    private var pairing = RemotePairing()
    private var sessions: [String: RemoteSession] = [:]
    private static var nextSessionID = 1_000_000

    init(port: UInt16, store: RemoteDeviceStore, handler: @escaping AgentServer.Handler, hello: @escaping Hello) {
        self.port = port
        self.store = store
        self.handler = handler
        self.hello = hello
        registry = store.load()
    }

    // MARK: Start, stop, follow the addresses

    func start() {
        queue.async {
            self.stopped = false
            self.rebind()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
            t.setEventHandler { [weak self] in
                self?.rebind()
                self?.endIdleSessions()
            }
            t.resume()
            self.timer = t
        }
    }

    /// Closes every socket and ends every session (Off, Stop Agents, quit).
    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            closeListeners()
        }
        let ended: [RemoteSession] = lock.withLock {
            let all = Array(sessions.values)
            sessions.removeAll()
            pairing.cancel()
            return all
        }
        for s in ended { end(s) }
    }

    private func closeListeners() {
        for l in listeners { l.source.cancel() }
        listeners.removeAll()
        bound = []
    }

    /// Server queue: follows this Mac's tailnet addresses (RemoteBindPlan): closes sockets whose address is gone, keeps
    /// the rest, and tries every address without a socket, so one that failed to bind (another app had the port, the
    /// interface wasn't ready) is retried on each refresh, not only when the addresses change.
    private func rebind() {
        guard !stopped else { return }
        let now = TailnetAddress.current()
        let plan = RemoteBindPlan(wanted: now, listening: bound)
        if plan.isSteady {   // every address has its socket (or there's none, said once)
            if now.isEmpty, lastPublished != .noTailscale { publish(.noTailscale, host: nil) }
            return
        }
        for l in listeners where plan.close.contains(l.iface) { l.source.cancel() }
        listeners.removeAll { plan.close.contains($0.iface) }
        guard !now.isEmpty else { bound = []; return publish(.noTailscale, host: nil) }
        var failure: String?
        for iface in plan.open {
            switch listen(on: iface) {
            case .success(let fd):
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                src.setEventHandler { [weak self] in self?.accept(fd) }
                src.setCancelHandler { Darwin.close(fd) }
                src.resume()
                listeners.append((iface, src))
            case .failure(.why(let why)):
                failure = failure ?? "\(iface.address): \(why)"
            }
        }
        listeners.sort { ($0.iface.isIPv6 ? 1 : 0, $0.iface.address) < ($1.iface.isIPv6 ? 1 : 0, $1.iface.address) }
        let before = bound
        bound = listeners.map(\.iface)
        if let failure, failure != lastFailure { onLog?(["event": listeners.isEmpty ? "remote-failed" : "remote-partial", "reason": failure]) }
        lastFailure = failure
        if listeners.isEmpty {
            return publish(.failed(failure ?? "Airc couldn't listen on the Tailscale network."), host: nil)
        }
        guard bound != before else { return }   // a retry that failed again: nothing changed
        let addresses = listeners.map(\.iface.address)
        onLog?(["event": "remote-listening", "addresses": addresses, "port": Int(port)])
        let state = State.listening(addresses: addresses, port: port)
        publish(state, host: nil)
        // The tailnet's name for this Mac (MagicDNS), for the command Settings shows; its address when there's none.
        // Looked up off the server's queue (the CLI or a resolver may take a moment).
        let mine = bound
        DispatchQueue.global(qos: .utility).async {
            guard let name = Self.magicDNSName(addresses: addresses) else { return }
            self.queue.async { if self.bound == mine, !self.stopped { self.publish(state, host: name) } }
        }
    }

    /// The last state handed to Settings (server queue), so "No Tailscale" is published once, not every 10 s.
    private var lastPublished: State?

    private func publish(_ s: State, host: String?) {
        lastPublished = s
        DispatchQueue.main.async {
            guard s != self.state || host != self.hostName else { return }
            self.state = s
            self.hostName = host
            self.onChange?()
        }
    }

    private enum BindError: Error { case why(String) }

    private func listen(on iface: TailnetAddress.Interface) -> Result<Int32, BindError> {
        let v6 = iface.isIPv6
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.why("socket: \(errno)")) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        // Only packets that came in through the Tailscale interface (macOS would otherwise take a packet for this
        // address on any interface).
        var index = iface.index
        if index != 0 {
            let r = v6 ? setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                       : setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            if r != 0 { Darwin.close(fd); return .failure(.why("bound_if: \(errno)")) }
        }
        let rc: Int32
        if v6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, iface.address, &a.sin6_addr) == 1 else { Darwin.close(fd); return .failure(.why("address")) }
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            guard inet_pton(AF_INET, iface.address, &a.sin_addr) == 1 else { Darwin.close(fd); return .failure(.why("address")) }
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard rc == 0, Darwin.listen(fd, 16) == 0 else {
            let e = errno
            Darwin.close(fd)
            return .failure(.why(e == EADDRINUSE ? "Port \(port) is already in use on this Mac." : "bind: \(e)"))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return .success(fd)
    }

    /// This Mac's MagicDNS name ("my-mac.example.ts.net"): from the Tailscale CLI (`tailscale status --json`, the
    /// app's own binary or the CLI it installs; TailscaleName checks the answer), else a reverse lookup, else nil (the
    /// command then shows the address).
    static func magicDNSName(addresses: [String]) -> String? {
        for path in TailscaleName.cliPaths where FileManager.default.isExecutableFile(atPath: path) {
            if let data = run(path, TailscaleName.arguments, timeout: 3),
               let name = TailscaleName.magicDNSName(statusJSON: data, addresses: addresses) { return name }
        }
        for a in addresses where !a.contains(":") { if let name = reverseName(a) { return name } }
        return nil
    }

    /// A short command's standard output, or nil if it fails or takes longer than `timeout` seconds (then it's ended).
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        let ended = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in ended.signal() }
        guard (try? p.run()) != nil else { return nil }
        var data = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let read = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        guard ended.wait(timeout: .now() + timeout) == .success else {
            p.terminate()
            _ = ended.wait(timeout: .now() + 1)
            return nil
        }
        guard read.wait(timeout: .now() + 1) == .success, p.terminationStatus == 0, data.count <= 4 << 20 else { return nil }
        return data
    }

    /// MagicDNS's name for a tailnet address ("my-mac.example.ts.net"), or nil.
    static func reverseName(_ address: String) -> String? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &a.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        var name = String(cString: host)
        if name.hasSuffix(".") { name.removeLast() }
        return name.hasSuffix(".ts.net") ? name.lowercased() : nil
    }

    #if AIRC_TESTING
    /// Marketing shots only: Settings shows this listener as listening at made-up addresses and name, with made-up
    /// paired devices. Nothing is bound (the listener never starts) and nothing is saved.
    func stageForMarketing(addresses: [String], host: String, devices: [(name: String, paired: Date, used: Date?, address: String)]) {
        lock.withLock {
            for d in devices {
                guard let added = registry.add(name: d.name, now: d.paired, address: d.address) else { continue }
                if let used = d.used { _ = registry.touch(added.device.id, now: used, address: d.address) }
            }
        }
        state = .listening(addresses: addresses, port: port)
        hostName = host
        onChange?()
    }
    #endif

    // MARK: Devices and pairing (main thread)

    var devices: [RemoteDevice] { lock.withLock { registry.devices } }

    /// A new code for Settings ("ABCD-EFGH"), valid for 10 minutes or one pairing.
    func startPairing() -> String { lock.withLock { pairing.start() } }
    func cancelPairing() { lock.withLock { pairing.cancel() } }
    var pairingCode: String? { lock.withLock { pairing.isActive() ? pairing.display : nil } }
    var pairingExpires: Date? { lock.withLock { pairing.isActive() ? pairing.expires : nil } }

    /// Revoke: the token stops working at once, and the device's sessions end.
    func revoke(_ id: String) {
        let ended: [RemoteSession] = lock.withLock {
            registry.revoke(id)
            let mine = sessions.values.filter { $0.deviceID == id }
            for s in mine { sessions[s.sid] = nil }
            return mine
        }
        store.save(lock.withLock { registry })
        for s in ended { end(s) }
    }

    /// Ends the sessions whose AgentSession matches (an app removed or stopped in Airc).
    func disconnect(where match: (AgentSession) -> Bool) {
        let ended: [RemoteSession] = lock.withLock {
            let mine = sessions.values.filter { match($0.session) }
            for s in mine { sessions[s.sid] = nil }
            return mine
        }
        for s in ended { end(s) }
    }

    private func end(_ s: RemoteSession) {
        DispatchQueue.main.async { if s.admitted { self.onEnded?(s.session) } }
    }

    private func endIdleSessions() {
        let now = Date()
        let ended: [RemoteSession] = lock.withLock {
            let idle = sessions.values.filter { !$0.busy && now.timeIntervalSince($0.lastUsed) > Self.idleSession }
            for s in idle { sessions[s.sid] = nil }
            return idle
        }
        for s in ended { end(s) }
    }

    // MARK: Connections

    private func accept(_ listenFD: Int32) {
        while true {
            var peer = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let c = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &len) }
            }
            if c < 0 { return }
            let address = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { TailnetAddress.tailnetText($0) } }
            // Tailnet peers only, and a bounded number at a time.
            guard let address, open < Self.maxConnections else { Darwin.close(c); continue }
            open += 1
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async {
                self.serve(c, peer: address)
                self.queue.async { self.open -= 1 }
            }
        }
    }

    struct Request {
        var method: String
        var path: String
        /// Lower-case names.
        var headers: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var body: Data = Data()
        var type = "application/json"
        var headers: [String: String] = [:]

        static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> Response {
            Response(status: status, body: AgentMCP.encode(object), headers: headers)
        }
        static func text(_ status: Int, _ s: String) -> Response {
            Response(status: status, body: Data((s + "\n").utf8), type: "text/plain; charset=utf-8")
        }
        static func rpcError(_ status: Int, _ message: String) -> Response {
            json(status, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32000, "message": message]])
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Error"
        }
    }

    /// One HTTP request per connection (Connection: close), read and answered blocking on a worker thread.
    private func serve(_ c: Int32, peer: String) {
        defer { Darwin.close(c) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            data.append(contentsOf: chunk[0..<n])
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil, data.count > 32768 { return write(c, .text(431, "Headers too large.")) }
        }
        let head = String(decoding: data[..<headerEnd!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return write(c, .text(400, "Bad request.")) }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var request = Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data())
        // Decide before reading a body: an unpaired request gets its 401 without Airc reading what it sent.
        let decision = lock.withLock {
            RemoteAgentGate.decide(method: request.method, path: request.path, headers: headers, peer: peer, registry: registry)
        }
        if case .reject(let status, _) = decision { return write(c, status == 401 ? unauthorized : .text(status, Self.reason(status) + ".")) }
        let limit = decision == .pair ? 4096 : AgentServer.maxLine
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return write(c, .text(411, "Content-Length required.")) }
        guard length <= limit else { return write(c, .text(413, "Too large.")) }
        guard headers["transfer-encoding"] == nil else { return write(c, .text(411, "Content-Length required.")) }
        var body = Data(data[headerEnd!.upperBound...])
        while body.count < length {
            let n = read(c, &chunk, min(chunk.count, length - body.count))
            if n <= 0 { return }
            body.append(contentsOf: chunk[0..<n])
        }
        request.body = body.prefix(length)
        write(c, respond(request, decision: decision, peer: peer))
    }

    private var unauthorized: Response {
        var r = Response.text(401, "Pair this device first: Airc › Settings › Agents › Other devices.")
        r.headers["WWW-Authenticate"] = "Bearer realm=\"Airc\""
        return r
    }

    private func write(_ c: Int32, _ r: Response) {
        var head = "HTTP/1.1 \(r.status) \(Self.reason(r.status))\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if !r.body.isEmpty { head += "Content-Type: \(r.type)\r\n" }
        for (k, v) in r.headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(c, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; break }
                off += n
            }
        }
    }

    // MARK: Requests (worker threads; checks call `respond` directly with a tailnet peer)

    func respond(_ request: Request, decision: RemoteAgentGate.Decision, peer: String) -> Response {
        switch decision {
        case .reject(let status, _): return status == 401 ? unauthorized : .text(status, Self.reason(status) + ".")
        case .pair: return pair(request, peer: peer)
        case .endSession(let device):
            guard let sid = request.headers["mcp-session-id"] else { return .text(400, "Mcp-Session-Id required.") }
            let s: RemoteSession? = lock.withLock {
                guard let s = sessions[sid], s.deviceID == device else { return nil }
                sessions[sid] = nil
                return s
            }
            guard let s else { return .text(404, "No such session.") }
            end(s)
            return Response(status: 200)
        case .mcp(let device): return mcp(request, device: device, peer: peer)
        }
    }

    private func pair(_ request: Request, peer: String) -> Response {
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let code = request.headers["x-airc-pairing-code"] ?? json?["code"] as? String ?? ""
        let name = request.headers["x-airc-device"] ?? json?["device"] as? String
        let outcome = lock.withLock { pairing.attempt(code, peer: peer) }
        switch outcome {
        case .paired:
            let added: (device: RemoteDevice, token: String)? = lock.withLock { registry.add(name: name ?? "", address: peer) }
            guard let added else { return .text(403, "Airc has 20 paired devices. Revoke one in Settings › Agents › Other devices first.") }
            store.save(lock.withLock { registry })
            onLog?(["event": "remote-paired", "device": added.device.name, "address": peer])
            DispatchQueue.main.async { self.onChange?() }
            // The token, once: a device keeps it in its MCP settings.
            return .text(200, added.token)
        case .wrongCode:
            onLog?(["event": "remote-pair-refused", "address": peer, "why": "wrong-code"])
            return .text(403, "That pairing code isn't right. Check the code in Airc › Settings › Agents › Other devices.")
        case .noCode:
            onLog?(["event": "remote-pair-refused", "address": peer, "why": "no-code"])
            return .text(403, "No pairing code is showing in Airc, or it expired. In Airc: Settings › Agents › Other devices › Pair a Device.")
        case .rateLimited(let after):
            onLog?(["event": "remote-pair-refused", "address": peer, "why": "rate-limited"])
            var r = Response.text(429, "Too many tries. Wait \(after) seconds.")
            r.headers["Retry-After"] = "\(after)"
            return r
        }
    }

    private func mcp(_ request: Request, device deviceID: String, peer: String) -> Response {
        let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let method = message?["method"] as? String
        let sid = request.headers["mcp-session-id"]
        let device: RemoteDevice? = lock.withLock {
            let changed = registry.touch(deviceID, address: peer)
            let d = registry.devices.first { $0.id == deviceID }
            if changed { store.save(registry) }
            return d
        }
        guard let device else { return unauthorized }
        // The session: the one named, a new one for `initialize`, else the device's own (clients without sessions).
        var created = false
        var evicted: RemoteSession?
        let found: RemoteSession? = lock.withLock {
            if let sid {
                guard let s = sessions[sid], s.deviceID == deviceID else { return nil }
                return s
            }
            if method != "initialize", let s = sessions.values.first(where: { $0.deviceID == deviceID && $0.isDefault }) { return s }
            let theirs = sessions.values.filter { $0.deviceID == deviceID }
            if theirs.count >= Self.maxSessionsPerDevice {
                guard let oldest = theirs.filter({ !$0.busy }).min(by: { $0.lastUsed < $1.lastUsed }) else { return nil }
                sessions[oldest.sid] = nil
                evicted = oldest
            }
            Self.nextSessionID += 1
            let session = AgentSession(id: Self.nextSessionID, persistent: true)
            let info = (message?["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
            let reported = (info?["name"] as? String) ?? request.headers["x-airc-client"] ?? request.headers["user-agent"].map(Self.clientFromAgent)
            session.client = String((reported ?? "mcp-client").prefix(64))
            session.via = "tailnet"
            session.remote = AgentSession.Remote(deviceID: deviceID, deviceName: device.name, address: peer)
            session.requestedProfile = request.headers["x-airc-profile"].map { String($0.prefix(128)) }
            let s = RemoteSession(sid: Self.newSessionID(), deviceID: deviceID, session: session, isDefault: method != "initialize")
            sessions[s.sid] = s
            created = true
            return s
        }
        if let evicted { end(evicted) }
        guard let s = found else {
            return .json(404, ["jsonrpc": "2.0", "id": message?["id"] ?? NSNull(),
                               "error": ["code": -32001, "message": "Session not found: start a new one (initialize)."]])
        }
        // A session's requests run in order (computer-use batches), as on the socket.
        s.lane.wait()
        defer { s.lane.signal() }
        lock.withLock { s.busy = true; s.lastUsed = Date() }
        defer { lock.withLock { s.busy = false; s.lastUsed = Date() } }
        // The first request asks, as a local app's first connection does (once per app; this device is its own app).
        if !s.admitted {
            let gate = DispatchSemaphore(value: 0)
            var refusal: String?
            DispatchQueue.main.async {
                self.hello(s.session) { r in refusal = r; gate.signal() }
            }
            if gate.wait(timeout: .now() + 180) == .timedOut { refusal = "Airc didn't answer in time." }
            if let refusal {
                lock.withLock { if sessions[s.sid] === s { sessions[s.sid] = nil } }
                return .json(200, ["jsonrpc": "2.0", "id": message?["id"] ?? NSNull(), "error": ["code": -32000, "message": refusal]])
            }
            s.admitted = true
        }
        // Still ours? Revoke or Stop may have ended it while it waited.
        guard lock.withLock({ sessions[s.sid] === s }) else { return .rpcError(404, "This session was ended in Airc.") }
        if let v = request.headers["mcp-protocol-version"], v != AgentMCP.modern { s.session.legacyVersion = v }
        let done = DispatchSemaphore(value: 0)
        var answer: Data?
        DispatchQueue.main.async {
            self.handler(request.body, s.session) { answer = $0; done.signal() }
        }
        if done.wait(timeout: .now() + 360) == .timedOut { return .rpcError(504, "Airc didn't answer in time.") }
        let headers = created && !s.isDefault ? ["Mcp-Session-Id": s.sid] : [:]
        guard let answer else { return Response(status: 202, headers: headers) }
        return Response(status: 200, body: answer, headers: headers)
    }

    /// "claude-code/2.1.3 (cli)" → "claude-code".
    static func clientFromAgent(_ ua: String) -> String {
        String(ua.split(separator: "/").first.map(String.init)?.split(separator: " ").first ?? "mcp-client")
    }

    static func newSessionID() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }

    #if AIRC_TESTING
    /// Checks: a request as it would arrive from `peer`, through the same gate and answers (no sockets: the listener's
    /// sockets take only packets from the Tailscale interface, so this Mac can't reach them itself).
    func simulate(_ method: String, _ path: String, headers: [String: String], body: Data = Data(), peer: String) -> Response {
        var h: [String: String] = [:]
        for (k, v) in headers { h[k.lowercased()] = v }
        let decision = lock.withLock { RemoteAgentGate.decide(method: method, path: path, headers: h, peer: peer, registry: registry) }
        return respond(Request(method: method, path: path, headers: h, body: body), decision: decision, peer: peer)
    }
    #endif
}

/// One MCP session of a paired device.
final class RemoteSession {
    let sid: String
    let deviceID: String
    let session: AgentSession
    /// Requests without Mcp-Session-Id share it.
    let isDefault: Bool
    let lane = DispatchSemaphore(value: 1)
    var admitted = false
    var busy = false
    var lastUsed = Date()

    init(sid: String, deviceID: String, session: AgentSession, isDefault: Bool) {
        self.sid = sid; self.deviceID = deviceID; self.session = session; self.isDefault = isDefault
    }
}

/// The paired devices, in Airc's Keychain item (a test run's memory only). One item holds the list: names, dates and
/// each token's SHA-256, never a token.
final class RemoteDeviceStore {
    static let service = "Airc Agent Devices"
    private let keychain: Bool
    private var memory = RemoteDeviceRegistry()

    init(keychain: Bool) { self.keychain = keychain }

    func load() -> RemoteDeviceRegistry {
        guard keychain else { return memory }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: "devices", kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return RemoteDeviceRegistry() }
        return RemoteDeviceRegistry.decode(out as? Data)
    }

    func save(_ r: RemoteDeviceRegistry) {
        guard keychain else { memory = r; return }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: "devices"]
        if r.devices.isEmpty { SecItemDelete(match as CFDictionary); return }
        let data = r.encoded()
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = Self.service
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: What Settings shows

extension AgentCenter {
    /// Settings › Agents › Other devices: the switch's line, what's true now.
    var remoteStatus: String {
        guard isOn else { return "Turn on “Let AI apps use Airc” first." }
        guard remoteWanted else { return "Off. Nothing on this Mac listens on the network." }
        switch remote?.state ?? .starting {
        case .starting: return "Starting…"
        case .noTailscale: return "Tailscale isn't connected on this Mac, so nothing is listening. Airc starts when it connects."
        case .failed(let why): return "Not listening: " + why
        case .listening:
            return "On · listening only on your Tailscale network, at " + (remoteBaseURL ?? "") + ". Other devices need pairing."
        }
    }

    var remoteListening: Bool {
        if case .listening = remote?.state { return true }
        return false
    }

    /// "http://my-mac.example.ts.net:47830" (MagicDNS name, else the address).
    var remoteBaseURL: String? {
        guard let r = remote, case .listening(let addresses, let port) = r.state, let first = addresses.first else { return nil }
        let host = r.hostName ?? (first.contains(":") ? "[\(first)]" : first)
        return "http://\(host):\(port)"
    }

    /// The command for Claude Code on the other device: trades the code for the device's token, then adds Airc with it.
    /// The token goes from the pairing answer straight into Claude Code's config; it's never shown here.
    static func remoteCommand(base: String, code: String) -> String {
        "t=$(curl -fsS -X POST \(base)/pair -H 'X-Airc-Pairing-Code: \(code)' -H \"X-Airc-Device: $(hostname)\")"
            + " && claude mcp add --transport http --scope user airc \(base)/mcp --header \"Authorization: Bearer $t\""
    }
}
