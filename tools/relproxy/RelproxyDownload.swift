// relproxy: tools/updstall/SparkleLikeDownload.swift plus the sha256 of the finished file and the response's
// Content-Encoding / Content-Length, to prove a proxied download is byte-identical (URLSession decodes br/gzip).
// Synthetic download probe configured like Sparkle 2.10.1's SPUDownloader:
// NSURLSessionConfiguration.defaultSessionConfiguration, a download task,
// NSURLRequestReloadIgnoringLocalCacheData, the default 60 s request timeout,
// networkServiceType .default (or .background with --background, as Sparkle
// uses for scheduled background checks), no waitsForConnectivity, no retry.
// Prints one JSON line: bytes received, longest gap between progress
// callbacks, error, and URLSessionTaskMetrics (protocol, peer address) per
// transaction. Usage:
//   sparkle-like-download <url> [--background] [--ephemeral] [--range N]
//                         [--timeout S] [--stall S]
// --stall S cancels when no bytes arrive for S seconds (default: off, so the
// task ends exactly as Sparkle's would: on the 60 s idle timeout or a TCP error).
import Foundation
import CryptoKit

final class Probe: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    let start = Date()
    var lastProgress = Date()
    var maxGap: TimeInterval = 0
    var maxGapAtBytes: Int64 = 0
    var bytes: Int64 = 0
    var expected: Int64 = -1
    var firstByteAt: TimeInterval?
    var status = 0
    var transactions: [[String: Any]] = []
    var error: NSError?
    var stalledCancel = false
    var finished = false
    var sha256 = ""
    var encoding = ""
    var contentLength = ""

    func note(_ total: Int64) {
        let now = Date()
        let gap = now.timeIntervalSince(lastProgress)
        if gap > maxGap { maxGap = gap; maxGapAtBytes = bytes }
        lastProgress = now
        if firstByteAt == nil { firstByteAt = now.timeIntervalSince(start) }
        bytes = total
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        expected = totalBytesExpectedToWrite
        if let r = downloadTask.response as? HTTPURLResponse { status = r.statusCode }
        note(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let r = downloadTask.response as? HTTPURLResponse { status = r.statusCode }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)??.int64Value ?? 0
        if let r = downloadTask.response as? HTTPURLResponse {
            encoding = r.value(forHTTPHeaderField: "Content-Encoding") ?? ""
            contentLength = r.value(forHTTPHeaderField: "Content-Length") ?? ""
        }
        if let h = FileHandle(forReadingAtPath: location.path) {
            var hasher = SHA256()
            while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        note(size)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for t in metrics.transactionMetrics {
            var d: [String: Any] = [
                "url": t.request.url.map { "\($0.host ?? "")\($0.path.hasSuffix(".zip") ? " zip" : $0.path.hasSuffix(".delta") ? " delta" : "")" } ?? "",
                "protocol": t.networkProtocolName ?? "",
                "reused": t.isReusedConnection,
                "status": (t.response as? HTTPURLResponse)?.statusCode ?? 0,
                "rxBody": t.countOfResponseBodyBytesReceived,
            ]
            if let a = t.remoteAddress { d["peer"] = a }
            if let a = t.localAddress { d["local"] = a }
            if let s = t.connectStartDate, let e = t.connectEndDate { d["connectMs"] = Int(e.timeIntervalSince(s) * 1000) }
            d["proxy"] = t.isProxyConnection
            transactions.append(d)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = error as NSError?
        finished = true
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }
func value(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
let background = flag("--background")
let ephemeral = flag("--ephemeral")
let range = value("--range").flatMap { Int64($0) }
let timeout = value("--timeout").flatMap { Double($0) }
let stall = value("--stall").flatMap { Double($0) }
guard let urlString = args.first, let url = URL(string: urlString) else {
    FileHandle.standardError.write("usage: sparkle-like-download <url> [--background] [--ephemeral] [--range N] [--timeout S] [--stall S]\n".data(using: .utf8)!)
    exit(2)
}

let probe = Probe()
let config = ephemeral ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
let session = URLSession(configuration: config, delegate: probe, delegateQueue: OperationQueue.main)
var request = URLRequest(url: url)
request.cachePolicy = .reloadIgnoringLocalCacheData
request.networkServiceType = background ? .background : .default
if let timeout { request.timeoutInterval = timeout }
if let range { request.setValue("bytes=0-\(range - 1)", forHTTPHeaderField: "Range") }
let task = session.downloadTask(with: request)
task.resume()

if let stall {
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        if !probe.finished && Date().timeIntervalSince(probe.lastProgress) > stall {
            probe.stalledCancel = true
            task.cancel()
        }
    }
}
// Hard bound so a wedged task can't hang a matrix run.
Timer.scheduledTimer(withTimeInterval: 400, repeats: false) { _ in task.cancel() }
while !probe.finished { CFRunLoopRun() }
// Let didFinishCollecting metrics land (it can arrive just after completion).
RunLoop.main.run(until: Date().addingTimeInterval(0.2))

let tailGap = Date().timeIntervalSince(probe.lastProgress)
var out: [String: Any] = [
    "client": "urlsession" + (background ? "-bg" : "") + (ephemeral ? "-eph" : ""),
    "ok": probe.error == nil && (200...299).contains(probe.status),
    "bytes": probe.bytes,
    "expected": probe.expected,
    "status": probe.status,
    "seconds": (Date().timeIntervalSince(probe.start) * 1000).rounded() / 1000,
    "firstByte": probe.firstByteAt.map { ($0 * 1000).rounded() / 1000 } ?? -1,
    "maxGap": (max(probe.maxGap, probe.error != nil ? tailGap : 0) * 1000).rounded() / 1000,
    "maxGapAtBytes": probe.error != nil && tailGap > probe.maxGap ? probe.bytes : probe.maxGapAtBytes,
    "stallCancel": probe.stalledCancel,
    "transactions": probe.transactions,
    "sha256": probe.sha256,
    "contentEncoding": probe.encoding,
    "contentLength": probe.contentLength,
]
if let e = probe.error {
    out["error"] = "\(e.domain) \(e.code)"
    if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
        out["underlying"] = "\(u.domain) \(u.code) stream \(u.userInfo["_kCFStreamErrorDomainKey"] ?? "") \(u.userInfo["_kCFStreamErrorCodeKey"] ?? "")"
    }
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
exit(probe.error == nil ? 0 : 1)
