// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import ImageIO
import Network

/// A view that shows an icon the cache couldn't get yet (the sidebar's FaviconView): told when it arrives for anyone,
/// and asked to try again on a trigger that isn't its own (the network coming back, its window coming on screen).
protocol FaviconWatcher: AnyObject {
    func faviconArrived(_ image: NSImage, for url: String)
    func faviconRetry(_ trigger: FaviconBackoff.Trigger, in window: NSWindow?)
}

/// Favicon images by URL: memory first, then a small disk cache, then the network.
/// Engine-independent: the sidebar uses it for unloaded pinned items and Favorites.
///
/// A failed or empty fetch is never final (AircKit's FaviconBackoff). A transient failure is tried again a few times
/// within its round (4, 16, 40 s). After a failed round the icon backs off, per icon URL and profile: 1 min, 5 min,
/// 30 min, then a day. The next round starts on the next trigger after that: the row coming on screen, its page
/// loading, the network coming back. No timer runs while the browser is idle. At most `concurrentFetches` icons are
/// fetched at once, each URL once however many rows and profiles ask.
///
/// Private sessions (PrivateWindow.swift) have one of their own (`memoryOnly`): no disk cache read or written, nothing
/// shared with `shared`'s memory, and emptied when the session's last window closes (`forgetAll`).
final class FaviconCache {
    static let shared = FaviconCache()

    private let memory = NSCache<NSURL, NSImage>()
    /// Icons being fetched or between the tries of a round (by URL). Every one has callers or a try still to come, so
    /// these are never evicted: a record goes when its icon arrives or its round fails.
    private var fetches: [URL: Fetch] = [:]
    /// Failed rounds by icon URL and profile, and when each may be asked again. Bounded; long-past records expire.
    private var backoff = FaviconBackoff()
    /// A host whose icon fetch just failed, until when: none of its icons is asked for again before then, so a failing
    /// host gets one request per retry, however many rows show it. Bounded and pruned.
    private var hostRetryAt = ExpiringLRU<String, Date>(limit: FaviconCache.failureLimit)
    private var gate = FetchGate<URL>(limit: FaviconCache.concurrentFetches)
    /// Blank views waiting for an icon whose round failed, by icon URL (weak).
    private var watchers: [String: NSHashTable<AnyObject>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var prunedAt = Date()
    private let session: URLSession
    /// The disk cache; nil for a private session's cache.
    private let directory: URL?

    /// How many host deadlines are remembered at most.
    static let failureLimit = 4000
    /// How many icons are fetched from the network at once, at most.
    static let concurrentFetches = 6

    #if AIRC_TESTING
    /// Every icon asked of the network, in order, in scripted runs (BoostsCheck: the Command Bar asks for none while you
    /// type). Dev builds are test builds too: they don't keep it.
    private(set) var networkRequests: [URL] = []
    private let recording = LaunchOptions.current.snapshotDir != nil
    var failureCounts: (givenUp: Int, hosts: Int, fetching: Int) { (backoff.count, hostRetryAt.count, fetches.count) }
    /// Every icon written to the disk cache, in order, in scripted runs (`--script private`: none from a private window).
    private(set) var diskWrites: [URL] = []
    /// The file an icon is kept in on disk (nil: this cache keeps nothing on disk).
    func fileForTesting(_ url: URL) -> URL? { fileURL(for: url) }
    /// Forgets the icons in memory (the disk cache stays).
    func forgetMemoryForTesting() { memory.removeAllObjects() }
    /// An icon's backoff for a profile (nil: none).
    func backoffForTesting(_ url: String, profile: String?) -> FaviconBackoff.Record? { backoff.record(.init(url: url, profile: profile)) }
    /// The backoff with another policy, every failure forgotten (`--script favretry` shortens the waits).
    func setPolicyForTesting(_ p: FaviconBackoff.Policy) { backoff = FaviconBackoff(policy: p) }
    /// Tries waiting on a timer now (within a round), the most fetches that ran at once, and blank views watching.
    var timersPending: Int { fetches.values.filter { $0.retry != nil }.count }
    var peakConcurrentFetches: Int { gate.peak }
    var watcherCount: Int { watchers.values.reduce(0) { $0 + $1.allObjects.count } }
    #endif

    private final class Fetch {
        /// Answered after this attempt.
        var waiting: [(NSImage?) -> Void] = []
        /// Answered on success, or once the round fails (the sidebar's rows and tiles).
        var patient: [(NSImage?) -> Void] = []
        /// The profiles that asked during this round: each gets the round's failure.
        var profiles: Set<String> = []
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

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Forgets every icon, failure and pending fetch (a private session ended). Fetches still in flight answer no one.
    func forgetAll() {
        memory.removeAllObjects()
        fetches.values.forEach { $0.retry?.cancel() }
        fetches = [:]
        backoff.removeAll()
        hostRetryAt = ExpiringLRU(limit: Self.failureLimit)
        gate.removeAll()
        watchers = [:]
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

    /// `retrying`: the completion waits through the round's tries (it runs once, with the icon or with nil when the
    /// round fails). Otherwise it runs after this attempt; the round's tries go on in the background and fill the cache.
    /// `profile`: whose rows ask (failures back off per profile). `trigger`: why now; by default a row asking
    /// (`retrying`) is `.shown`, anyone else (the engine's page load, opening a site) `.pageLoaded`.
    func load(_ string: String?, retrying: Bool = false, profile: String? = nil, trigger: FaviconBackoff.Trigger? = nil,
              completion: @escaping (NSImage?) -> Void) {
        guard let s = string, let u = URL(string: s) else { return completion(nil) }
        load(u, retrying: retrying, profile: profile, trigger: trigger, completion: completion)
    }

    func load(_ url: URL, retrying: Bool = false, profile: String? = nil, trigger: FaviconBackoff.Trigger? = nil,
              completion: @escaping (NSImage?) -> Void) {
        if let img = memory.object(forKey: url as NSURL) { return completion(img) }
        let key = FaviconBackoff.Key(url: url.absoluteString, profile: profile)
        if let f = fetches[url] {
            // A round is under way: join it.
            f.profiles.insert(key.profile)
            if retrying { f.patient.append(completion) } else if f.inFlight { f.waiting.append(completion) } else {
                // Between two tries: an impatient caller hears now that the last one failed.
                completion(nil)
            }
            return
        }
        // Backing off: no new round yet. The caller asks again on its next trigger.
        guard backoff.mayStart(key, trigger: trigger ?? (retrying ? .shown : .pageLoaded)) else { return completion(nil) }
        let f = Fetch()
        f.profiles = [key.profile]
        fetches[url] = f
        if retrying { f.patient.append(completion) } else { f.waiting.append(completion) }
        // Another icon on this host failed a moment ago: this one waits for the host's retry time too.
        if let host = url.host?.lowercased(), let at = hostRetryAt.value(for: host) {
            schedule(url, f, at: at)
            if !retrying { f.waiting.removeAll(); completion(nil) }
            return
        }
        attempt(url, f)
    }

    /// The page whose icon this is loaded and its engine shows the icon: a retry trigger for an icon this cache failed
    /// to get for `profile` (its unloaded row shows the cache's copy later). Nothing for an icon never asked for.
    func pageLoaded(_ string: String, profile: String?) {
        guard let url = URL(string: string), memory.object(forKey: url as NSURL) == nil, fetches[url] == nil,
              backoff.record(.init(url: string, profile: profile)) != nil else { return }
        load(url, profile: profile, trigger: .pageLoaded) { _ in }
    }

    // MARK: Triggers from outside a row

    /// `view` waits for `url`, whose round failed: the next trigger asks it again, and the icon lands on it whoever
    /// fetched it.
    func watch(_ view: FaviconWatcher, _ url: String) {
        let table = watchers[url] ?? .weakObjects()
        table.add(view)
        watchers[url] = table
        if observers.isEmpty { observeTriggers() }
    }

    func unwatch(_ view: FaviconWatcher, _ url: String) {
        guard let table = watchers[url] else { return }
        table.remove(view)
        if table.allObjects.isEmpty { watchers[url] = nil }
    }

    /// The network path and windows coming on screen, observed from the first blank view on (none before: no cost).
    private func observeTriggers() {
        NetworkWatch.shared.start()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NetworkWatch.restored, object: nil, queue: .main) { [weak self] _ in self?.networkRestored() },
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] n in
                guard let self, let w = n.object as? NSWindow, w.occlusionState.contains(.visible) else { return }
                self.eachWatcher { $0.faviconRetry(.shown, in: w) }
            },
        ]
    }

    private func networkRestored() {
        backoff.networkRestored()
        eachWatcher { $0.faviconRetry(.networkRestored, in: nil) }
    }

    private func eachWatcher(_ body: (FaviconWatcher) -> Void) {
        let all = watchers.values.flatMap { $0.allObjects.compactMap { $0 as? FaviconWatcher } }
        watchers = watchers.filter { !$0.value.allObjects.isEmpty }
        all.forEach(body)
    }

    // MARK: Fetching

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
        DispatchQueue.global(qos: .userInitiated).async {
            let img = file.flatMap { try? Data(contentsOf: $0) }.flatMap(Self.decode)
            DispatchQueue.main.async {
                guard self.fetches[url] === f else { return }
                if let img { return self.finish(url, f, img, failure: nil) }
                // Not on disk: the network, when a place is free.
                if self.gate.request(url) == .start { self.fetch(url) }
            }
        }
    }

    /// Asks the network for `url` (its place in the gate is taken).
    private func fetch(_ url: URL) {
        guard let f = fetches[url], f.inFlight else { return startNext(after: url) }
        #if AIRC_TESTING
        if recording { networkRequests.append(url) }
        #endif
        let file = fileURL(for: url)
        session.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? (error == nil && response != nil ? 200 : nil)
            let img = data.flatMap { status.map { $0 < 400 } == true ? Self.decode($0) : nil }
            if img != nil, let data, let file, (try? data.write(to: file)) != nil {
                #if AIRC_TESTING
                if self.recording { DispatchQueue.main.async { self.diskWrites.append(url) } }
                #endif
            }
            let failure = FaviconBackoff.failure(status: status, bytes: data?.count ?? 0, decoded: img != nil)
            DispatchQueue.main.async {
                self.startNext(after: url)
                guard self.fetches[url] === f else { return }
                self.finish(url, f, img, failure: failure)
            }
        }.resume()
    }

    /// `url` left the gate: the next icon waiting goes (one whose fetch was dropped meanwhile gives its place on).
    private func startNext(after url: URL) {
        var done = url
        while let next = gate.finish(done) {
            if fetches[next]?.inFlight == true { return fetch(next) }
            done = next
        }
    }

    private func finish(_ url: URL, _ f: Fetch, _ image: NSImage?, failure: FaviconBackoff.Failure?) {
        f.inFlight = false
        let host = url.host?.lowercased()
        let waiting = f.waiting
        f.waiting = []
        pruneNow()
        if let image {
            memory.setObject(image, forKey: url as NSURL)
            if let host { hostRetryAt.remove(host) }
            fetches[url] = nil
            f.profiles.forEach { backoff.succeeded(.init(url: url.absoluteString, profile: $0)) }
            (waiting + f.patient).forEach { $0(image) }
            if let table = watchers.removeValue(forKey: url.absoluteString) {
                table.allObjects.compactMap { $0 as? FaviconWatcher }.forEach { $0.faviconArrived(image, for: url.absoluteString) }
            }
            return
        }
        waiting.forEach { $0(nil) }
        let failure = failure ?? .missing
        let online = NetworkWatch.shared.isOnline
        if online, let delay = backoff.policy.roundRetry(afterAttempts: f.attempts, failure) {
            let at = Date().addingTimeInterval(delay)
            if let host {
                let until = max(hostRetryAt.peek(host) ?? at, at)
                hostRetryAt.set(until, for: host, expires: until)
            }
            schedule(url, f, at: at)
            return
        }
        // The round failed: the icon backs off for each profile that asked, until the next trigger after its wait.
        fetches[url] = nil
        f.profiles.forEach { backoff.failed(.init(url: url.absoluteString, profile: $0), failure, online: online) }
        NetworkWatch.shared.start()
        let patient = f.patient
        f.patient = []
        patient.forEach { $0(nil) }
    }

    /// Expired host deadlines go, at most once a minute.
    private func pruneNow() {
        let now = Date()
        guard now.timeIntervalSince(prunedAt) > 60 else { return }
        prunedAt = now
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

    /// Where a site's icon usually is, for items we have never loaded: /favicon.ico on the page's own scheme, host and
    /// port, or a known site's own place (AircKit's FaviconGuess).
    static func guess(for pageURL: String) -> String? { FaviconGuess.url(for: pageURL) }

    /// A file:// page's icon (P04's file tabs): its type's icon as the Finder shows it, a folder's for a directory. Nil
    /// for any other page. Asked of NSWorkspace once per path.
    static func fileIcon(forPage page: String?) -> NSImage? {
        guard let page, page.hasPrefix("file:"), let u = URL(string: page), u.isFileURL else { return nil }
        let path = u.standardizedFileURL.path as NSString
        if let hit = fileIcons.object(forKey: path) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path as String)
        fileIcons.setObject(img, forKey: path)
        return img
    }
    private static let fileIcons = NSCache<NSString, NSImage>()
}

/// The network path (NWPathMonitor), watched from the first failed icon or blank view on: a failure while offline
/// doesn't climb the backoff, and the path coming back is a retry trigger. Event-driven, no polling.
final class NetworkWatch {
    static let shared = NetworkWatch()
    static let restored = Notification.Name("AircNetworkRestored")

    /// The path's last state (true until the monitor has said otherwise). Main thread.
    private(set) var isOnline = true
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let was = self.isOnline
                self.isOnline = online
                if online, !was { NotificationCenter.default.post(name: Self.restored, object: self) }
            }
        }
        m.start(queue: DispatchQueue(label: "airc.network-watch", qos: .utility))
        monitor = m
    }
}
