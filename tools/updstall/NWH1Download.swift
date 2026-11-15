// HTTP/1.1 GET over Network.framework (NWConnection, TLS ALPN http/1.1): the
// same user-space TCP stack URLSession uses, but without HTTP/2. Separates
// "Network.framework TCP path" from "HTTP/2" when comparing with curl
// (kernel sockets). Follows one redirect. Prints one JSON line like
// sparkle-like-download. Usage: nw-h1-download <url> [--range N] [--stall S] [--connect IP]
import Foundation
import Network

var args = Array(CommandLine.arguments.dropFirst())
func value(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
let range = value("--range").flatMap { Int64($0) }
let stallLimit = value("--stall").flatMap { Double($0) } ?? 60
// --connect IP: open TCP to this address but keep SNI/Host (like curl --resolve).
let connectIP = value("--connect")
guard let first = args.first.flatMap(URL.init(string:)) else { print("usage"); exit(2) }

let start = Date()
var transactions: [[String: Any]] = []
var lastProgress = Date(), maxGap = 0.0, maxGapAt: Int64 = 0, firstByte: Double = -1

func fetch(_ url: URL, completion: @escaping (Int, [String: String], Int64, String?, Int64) -> Void) {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, url.host!)
    let conn = NWConnection(host: NWEndpoint.Host(connectIP ?? url.host!), port: 443, using: NWParameters(tls: tls))
    var header = Data(), headerDone = false, status = 0, headers: [String: String] = [:]
    var body: Int64 = 0, length: Int64 = -1, done = false
    func finish(_ err: String?) {
        if done { return }; done = true
        var t: [String: Any] = ["url": url.host ?? "", "protocol": "http/1.1-nw", "status": status, "rxBody": body]
        if case .hostPort(let h, _)? = conn.currentPath?.remoteEndpoint { t["peer"] = "\(h)" }
        transactions.append(t)
        conn.cancel()
        completion(status, headers, body, err, length)
    }
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            if let data, !data.isEmpty {
                if !headerDone {
                    header.append(data)
                    if let r = header.range(of: Data("\r\n\r\n".utf8)) {
                        headerDone = true
                        let text = String(decoding: header[..<r.lowerBound], as: UTF8.self)
                        let lines = text.components(separatedBy: "\r\n")
                        status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
                        for l in lines.dropFirst() {
                            if let c = l.firstIndex(of: ":") {
                                headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                            }
                        }
                        length = Int64(headers["content-length"] ?? "") ?? -1
                        body = Int64(header.count - r.upperBound)
                    }
                } else {
                    body += Int64(data.count)
                }
                if status / 100 == 2 {
                    let now = Date(), gap = now.timeIntervalSince(lastProgress)
                    if firstByte < 0 { firstByte = now.timeIntervalSince(start) }
                    if gap > maxGap { maxGap = gap; maxGapAt = body }
                    lastProgress = now
                }
                if headerDone && length >= 0 && body >= length { finish(nil); return }
            }
            if let error { finish("\(error)"); return }
            if complete { finish(headerDone ? nil : "closed before headers"); return }
            receive()
        }
    }
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            var req = "GET \(url.path) HTTP/1.1\r\nHost: \(url.host!)\r\nUser-Agent: updstall-nw\r\nAccept: */*\r\nCache-Control: no-cache\r\nConnection: close\r\n"
            if let range { req += "Range: bytes=0-\(range - 1)\r\n" }
            req += "\r\n"
            conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
            receive()
        case .failed(let e): finish("\(e)")
        case .waiting(let e): finish("waiting \(e)")
        default: break
        }
    }
    conn.start(queue: .main)
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
        if done { t.invalidate(); return }
        if Date().timeIntervalSince(lastProgress) > stallLimit { finish("stall \(stallLimit)s") }
    }
}

func emit(_ status: Int, _ bytes: Int64, _ err: String?, _ length: Int64) -> Never {
    let tail = Date().timeIntervalSince(lastProgress)
    if err != nil && tail > maxGap { maxGap = tail; maxGapAt = bytes }
    var out: [String: Any] = [
        "client": "nw-h1", "ok": err == nil && status / 100 == 2, "bytes": bytes, "status": status,
        "expectedHeader": length, "seconds": (Date().timeIntervalSince(start) * 1000).rounded() / 1000,
        "firstByte": (firstByte * 1000).rounded() / 1000, "maxGap": (maxGap * 1000).rounded() / 1000,
        "maxGapAtBytes": maxGapAt, "transactions": transactions,
    ]
    if let err { out["error"] = err }
    print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
    exit(err == nil ? 0 : 1)
}

fetch(first) { status, headers, bytes, err, length in
    if (300...399).contains(status), let loc = headers["location"], let next = URL(string: loc, relativeTo: first)?.absoluteURL {
        lastProgress = Date()
        fetch(next) { s, _, b, e, l in emit(s, b, e, l) }
    } else {
        emit(status, bytes, err, length)
    }
}
Timer.scheduledTimer(withTimeInterval: 150, repeats: false) { _ in emit(0, 0, "outer timeout", -1) }
RunLoop.main.run()
