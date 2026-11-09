// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// airc-mcp: the stdio MCP server that Claude Code, Codex or a T3 thread start. It holds no logic: it finds the running
// Airc's agent socket (docs/agent-ready.md §3.2), says who is asking and for which profile in one hello line, and then
// pipes MCP's newline-delimited JSON-RPC both ways. Airc decides everything (agents on, the profile granted, the tools).
//
//   claude mcp add airc -- airc-mcp --profile Agent
//   claude mcp add airc -- ssh <the Mac> "<path>/airc-mcp --profile Agent"     (an agent on another machine)
//
// No network: the socket is a 0600 Unix socket in Airc's data folder (or the per-user temporary folder when that path
// is too long for a socket address), which only processes of the same user can open.
import Foundation
import Darwin

let helperVersion = 1

struct Options {
    var dataDir: String?
    var socket: String?
    var profile: String?
    var client: String?
    var wait: Double = 0
    var printConfig = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: airc-mcp [--profile <name or id>] [--client <name>] [--data-dir <Airc data folder>] [--socket <path>]
                    [--wait <seconds>] [--print-config] [--version]

    """.utf8))
    exit(64)
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        func value() -> String {
            if args.isEmpty { usage() }
            return args.removeFirst()
        }
        switch a {
        case "--data-dir": o.dataDir = value()
        case "--socket": o.socket = value()
        case "--profile": o.profile = value()
        case "--client": o.client = value()
        case "--wait": o.wait = Double(value()) ?? 0
        case "--print-config": o.printConfig = true
        case "--version": print("airc-mcp \(helperVersion)"); exit(0)
        default: usage()
        }
    }
    return o
}

/// The same rule as the app's `AgentPaths.socket` (apps/browser/Sources/Airc/Agent/AgentServer.swift).
func socketPath(dataDir raw: String) -> String {
    // As the app's URL(fileURLWithPath:).standardizedFileURL.path: no trailing slash, ~ and relative paths resolved.
    let dataDir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    let direct = (dataDir as NSString).appendingPathComponent("Agent.sock")
    if direct.utf8.count < 100 { return direct }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let temp = n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    var hash: UInt64 = 0xcbf29ce484222325
    for b in dataDir.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
    return (temp as NSString).appendingPathComponent(String(format: "airc-agent-%016llx.sock", hash))
}

func defaultDataDir() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Airc")
}

func fail(_ message: String, code: Int32 = 69) -> Never {
    FileHandle.standardError.write(Data("airc-mcp: \(message)\n".utf8))
    exit(code)
}

func connect(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok != 0 { close(fd); return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

func writeAll(_ fd: Int32, _ data: UnsafeRawBufferPointer) -> Bool {
    var off = 0
    while off < data.count {
        let n = write(fd, data.baseAddress! + off, data.count - off)
        if n < 0 { if errno == EINTR { continue }; return false }
        off += n
    }
    return true
}


signal(SIGPIPE, SIG_IGN)
let options = parse()
let dataDir = options.dataDir ?? defaultDataDir()
let path = options.socket ?? socketPath(dataDir: dataDir)

if options.printConfig {
    let me = (CommandLine.arguments[0] as NSString).standardizingPath
    let profile = options.profile.map { " --profile '\($0)'" } ?? ""
    print("""
    # This Mac (Claude Code):
    claude mcp add airc -- '\(me)'\(profile)
    # An agent on another machine, over SSH (no port opens):
    claude mcp add airc -- ssh <this Mac> "'\(me)'\(profile)"
    # Codex (~/.codex/config.toml):
    [mcp_servers.airc]
    command = "\(me)"
    args = [\(options.profile.map { "\"--profile\", \"\($0)\"" } ?? "")]
    """)
    exit(0)
}

// Airc may still be starting (a headless launch): wait for the socket up to --wait seconds.
var fd: Int32? = connect(path)
let deadline = Date().addingTimeInterval(options.wait)
while fd == nil, Date() < deadline {
    usleep(200_000)
    fd = connect(path)
}
guard let sock = fd else {
    fail("Airc isn't running, or agents are off (no socket at \(path)). In a dev build: Airc's Dock menu › Agents.")
}

// One hello line, one answer line, then a plain pipe.
var hello: [String: Any] = ["airc": "hello", "v": helperVersion, "client": options.client ?? ProcessInfo.processInfo.environment["AIRC_MCP_CLIENT"] ?? "mcp-client",
                            "via": ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil ? "ssh" : "local"]
if let p = options.profile { hello["profile"] = p }
var helloLine = try! JSONSerialization.data(withJSONObject: hello)
helloLine.append(0x0A)
guard helloLine.withUnsafeBytes({ writeAll(sock, $0) }) else { fail("the socket closed") }

var pending = Data()
func readLine(_ fd: Int32) -> Data? {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        if let i = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(upTo: i)
            pending.removeSubrange(...i)
            return Data(line)
        }
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return nil }
        pending.append(contentsOf: chunk[0..<n])
        if pending.count > 65536 { return nil }
    }
}
guard let answerLine = readLine(sock),
      let answer = try? JSONSerialization.jsonObject(with: answerLine) as? [String: Any] else {
    fail("Airc closed the connection")
}
if answer["airc"] as? String != "ready" {
    fail((answer["reason"] as? String) ?? "Airc refused the connection", code: 77)
}

// Socket → stdout on a thread (the rest of the hello read's buffer first), stdin → socket here.
let leftover = pending
let reader = Thread {
    if !leftover.isEmpty { _ = leftover.withUnsafeBytes { writeAll(STDOUT_FILENO, $0) } }
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(sock, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { exit(0) }
        guard chunk.withUnsafeBytes({ writeAll(STDOUT_FILENO, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) else { exit(0) }
    }
}
reader.start()
var input = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(STDIN_FILENO, &input, input.count)
    if n < 0, errno == EINTR { continue }
    if n <= 0 { shutdown(sock, SHUT_WR); break }
    guard input.withUnsafeBytes({ writeAll(sock, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) else { break }
}
// The client closed stdin: let the last answers out, then go.
Thread.sleep(forTimeInterval: 2)
exit(0)
