// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import ImageIO

/// Favicon images by URL: memory first, then a small disk cache, then the network.
/// Engine-independent: the sidebar uses it for unloaded pinned items and Favorites.
///
/// Private sessions (PrivateWindow.swift) have one of their own (`memoryOnly`): no disk cache read or written, nothing
/// shared with `shared`'s memory, and emptied when the session's last window closes (`forgetAll`).
final class FaviconCache {
    static let shared = FaviconCache()

    private let memory = NSCache<NSURL, NSImage>()
    /// Icons being fetched or waiting for a retry (by URL). Every one has callers or a retry still to come, so these are
    /// never evicted: a record goes when its icon arrives or its last retry fails.
    private var fetches: [URL: Fetch] = [:]
    /// Icons given up on for now (by URL; true: missing, not just failing): asked for again before their cooldown
    /// ends, they answer nil at once. Expired ones are dropped, and at most `failureLimit` are kept, the least recently
    /// asked for going first.
    private var givenUp = ExpiringLRU<URL, Bool>(limit: FaviconCache.failureLimit)
    /// A host whose icon fetch just failed, until when: none of its icons is asked for again before then, so a failing
    /// host gets one request per retry, however many rows show it. Bounded and pruned like `givenUp`.
    private var hostRetryAt = ExpiringLRU<String, Date>(limit: FaviconCache.failureLimit)
    private var prunedAt = Date()
    private let session: URLSession
    /// The disk cache; nil for a private session's cache.
    private let directory: URL?

    /// How many failed icons and failing hosts are remembered at most.
    static let failureLimit = 4000

    #if AIRC_TESTING
    /// Every icon asked of the network, in order, in scripted runs (BoostsCheck: the Command Bar asks for none while you
    /// type). Dev builds are test builds too: they don't keep it.
    private(set) var networkRequests: [URL] = []
    private let recording = LaunchOptions.current.snapshotDir != nil
    var failureCounts: (givenUp: Int, hosts: Int, fetching: Int) { (givenUp.count, hostRetryAt.count, fetches.count) }
    /// Every icon written to the disk cache, in order, in scripted runs (`--script private`: none from a private window).
    private(set) var diskWrites: [URL] = []
    /// The file an icon is kept in on disk (nil: this cache keeps nothing on disk).
    func fileForTesting(_ url: URL) -> URL? { fileURL(for: url) }
    /// Forgets the icons in memory (the disk cache stays).
    func forgetMemoryForTesting() { memory.removeAllObjects() }
    #endif

    /// A failed fetch (no answer, a timeout, 408, 429 or 5xx) is tried again after each of these delays: three more
    /// tries over about a minute. A missing icon (404, an image ImageIO can't read) isn't retried.
    static var retryDelays: [TimeInterval] = [4, 16, 40]
    /// After the last retry, a row that asks again (the next page load, the row coming on screen) starts a new round,
    /// but not sooner than this after the last failure.
    static var cooldown: TimeInterval = 30
    /// The same for a site that has no icon there (404, not an image): ten minutes.
    static var missingCooldown: TimeInterval = 600

    private final class Fetch {
        /// Answered after this attempt.
        var waiting: [(NSImage?) -> Void] = []
        /// Answered on success, or once the retries are used up (the sidebar's rows and tiles).
        var patient: [(NSImage?) -> Void] = []
        var attempts = 0
        var inFlight = false
        var retry: DispatchWorkItem?
    }

    /// `memoryOnly`: a private session's cache, which never touches the disk.
    init(memoryOnly: Bool = false) {
        // One session for every profile, so it must not link them: no cookies in or out, no shared cache beyond the
        // icon files below (code review M6).
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        if memoryOnly {
            directory = nil
            memory.countLimit = 500
            return
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airc/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
    }

    /// Forgets every icon, failure and pending fetch (a private session ended). Fetches still in flight answer no one.
    func forgetAll() {
        memory.removeAllObjects()
        fetches.values.forEach { $0.retry?.cancel() }
        fetches = [:]
        givenUp = ExpiringLRU(limit: Self.failureLimit)
        hostRetryAt = ExpiringLRU(limit: Self.failureLimit)
    }

    func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    func cached(_ string: String?) -> NSImage? { string.flatMap(URL.init(string:)).flatMap(cached) }

    /// The icon if it's in memory or in the disk cache, never from the network: rows for sites you haven't opened
    /// (the Command Bar while you type) mustn't tell a site you might.
    func stored(_ string: String?, completion: @escaping (NSImage?) -> Void) {
        guard let s = string, let url = URL(string: s) else { return completion(nil) }
        if let img = memory.object(forKey: url as NSURL) { return completion(img) }
        guard let file = fileURL(for: url) else { return completion(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = (try? Data(contentsOf: file)).flatMap(Self.decode)
            DispatchQueue.main.async {
                if let img { self.memory.setObject(img, forKey: url as NSURL) }
                completion(img)
            }
        }
    }

    private func fileURL(for url: URL) -> URL? { directory?.appendingPathComponent(Self.stableName(url.absoluteString) + ".icon") }

    /// `retrying`: the completion waits through the retries (it runs once, with the icon or with nil when they're used
    /// up). Otherwise it runs after this attempt; the retries go on in the background and fill the cache.
    func load(_ string: String?, retrying: Bool = false, completion: @escaping (NSImage?) -> Void) {
        guard let s = string, let u = URL(string: s) else { return completion(nil) }
        load(u, retrying: retrying, completion: completion)
    }

    func load(_ url: URL, retrying: Bool = false, completion: @escaping (NSImage?) -> Void) {
        if let img = memory.object(forKey: url as NSURL) { return completion(img) }
        // Given up on a moment ago: no new round yet (an expired record is dropped, and this starts one).
        if fetches[url] == nil, givenUp.value(for: url) != nil { return completion(nil) }
        let f = fetches[url] ?? Fetch()
        fetches[url] = f
        if retrying { f.patient.append(completion) } else { f.waiting.append(completion) }
        if f.inFlight { return }
        if f.retry != nil {
            // A retry is due: an impatient caller hears now that the last attempt failed.
            if !retrying { f.waiting.removeAll(); completion(nil) }
            return
        }
        // Another icon on this host failed a moment ago: this one waits for the host's retry time too.
        if let host = url.host?.lowercased(), let at = hostRetryAt.value(for: host) {
            schedule(url, f, at: at)
            if !retrying { f.waiting.removeAll(); completion(nil) }
            return
        }
        attempt(url, f)
    }

    private func schedule(_ url: URL, _ f: Fetch, at date: Date) {
        f.retry?.cancel()
        let work = DispatchWorkItem { [weak self, weak f] in
            guard let self, let f, self.fetches[url] === f else { return }
            f.retry = nil
            self.attempt(url, f)
        }
        f.retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow), execute: work)
    }

    private func attempt(_ url: URL, _ f: Fetch) {
        f.inFlight = true
        f.attempts += 1
        let file = fileURL(for: url)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if let file, let data = try? Data(contentsOf: file), let img = Self.decode(data) {
                DispatchQueue.main.async { self.finish(url, img, transient: false) }
                return
            }
            #if AIRC_TESTING
            if self.recording { DispatchQueue.main.async { self.networkRequests.append(url) } }
            #endif
            session.dataTask(with: url) { data, response, error in
                var img: NSImage?
                let status = (response as? HTTPURLResponse)?.statusCode ?? (error == nil ? 200 : 0)
                if let data, status < 400, let i = Self.decode(data) {
                    img = i
                    if let file {
                        try? data.write(to: file)
                        #if AIRC_TESTING
                        if self.recording { DispatchQueue.main.async { self.diskWrites.append(url) } }
                        #endif
                    }
                }
                // No answer at all, or the server asking to come back later: worth another try.
                let transient = img == nil && (response == nil || [408, 429].contains(status) || status >= 500)
                DispatchQueue.main.async { self.finish(url, img, transient: transient) }
            }.resume()
        }
    }

    private func finish(_ url: URL, _ image: NSImage?, transient: Bool) {
        guard let f = fetches[url] else { return }
        f.inFlight = false
        let host = url.host?.lowercased()
        let waiting = f.waiting
        f.waiting = []
        pruneNow()
        if let image {
            memory.setObject(image, forKey: url as NSURL)
            if let host { hostRetryAt.remove(host) }
            fetches[url] = nil
            givenUp.remove(url)
            (waiting + f.patient).forEach { $0(image) }
            return
        }
        waiting.forEach { $0(nil) }
        if transient, f.attempts <= Self.retryDelays.count {
            let at = Date().addingTimeInterval(Self.retryDelays[f.attempts - 1])
            if let host {
                let until = max(hostRetryAt.peek(host) ?? at, at)
                hostRetryAt.set(until, for: host, expires: until)
            }
            schedule(url, f, at: at)
            return
        }
        // Given up for now: the record leaves the fetches for the bounded failures, which only answer "not yet".
        fetches[url] = nil
        givenUp.set(!transient, for: url, expires: Date().addingTimeInterval(transient ? Self.cooldown : Self.missingCooldown))
        let patient = f.patient
        f.patient = []
        patient.forEach { $0(nil) }
    }

    /// Expired failures and host deadlines go, at most once a minute.
    private func pruneNow() {
        let now = Date()
        guard now.timeIntervalSince(prunedAt) > 60 else { return }
        prunedAt = now
        givenUp.prune(now: now)
        hostRetryAt.prune(now: now)
    }

    /// Untrusted bytes from the network: at most 256 KB, decoded by ImageIO into a bitmap of at most 128 px a side, so
    /// a hostile icon can't make the browser process decode something huge (M6).
    static func decode(_ data: Data) -> NSImage? {
        guard data.count <= 256 * 1024 else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            // SVG icons (ImageIO doesn't read them): AppKit's renderer, still under the size limit.
            let head = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
            guard head.contains("<svg"), let svg = NSImage(data: data), svg.size.width > 0 else { return nil }
            return svg
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 128,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), cg.width > 0 else { return nil }
        let scale = max(1, CGFloat(max(cg.width, cg.height)) / 32)
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    /// FNV-1a: `hashValue` changes every launch, a disk cache needs a stable name.
    static func stableName(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    /// Where a site's icon usually is, for items we have never loaded.
    static func guess(for pageURL: String) -> String? {
        guard let c = URLComponents(string: pageURL), let scheme = c.scheme, let host = c.host?.lowercased(),
              scheme.hasPrefix("http") else { return nil }
        if let known = known(host: host, path: c.path) { return known }
        return "\(scheme)://\(host)/favicon.ico"
    }

    /// Sites whose icon isn't at /favicon.ico. Calendar shows today's date (SB-13).
    private static func known(host: String, path: String) -> String? {
        switch host {
        case "calendar.google.com":
            let day = Calendar.current.component(.day, from: Date())
            return "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_\(day).ico"
        case "mail.google.com": return "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico"
        case "docs.google.com":
            if path.hasPrefix("/spreadsheets") { return "https://ssl.gstatic.com/docs/spreadsheets/favicon3.ico" }
            if path.hasPrefix("/presentation") { return "https://ssl.gstatic.com/docs/presentations/images/favicon5.ico" }
            return "https://ssl.gstatic.com/docs/documents/images/kix-favicon7.ico"
        case "drive.google.com": return "https://ssl.gstatic.com/images/branding/product/1x/drive_2020q4_32dp.png"
        case "www.notion.so", "notion.so": return "https://www.notion.so/images/favicon.ico"
        default: return nil
        }
    }
}
