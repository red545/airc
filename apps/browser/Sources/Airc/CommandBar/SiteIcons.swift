// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SQLite3

/// The icons the profile already has, by site, for Command Bar rows of pages that aren't open (history, typed
/// addresses, site searches): never a network fetch.
///
/// Where they come from, first hit wins:
/// 1. memory (this process);
/// 2. Airc's own site icon store on disk: the icon each page showed in a normal window (`remember`, from
///    WindowController's favicon change), one small PNG per site;
/// 3. the Chromium profile's own favicon database (`<profile>/Favicons`), read-only and `immutable` (the engine keeps it
///    open with an exclusive lock; a stale snapshot is fine for an icon). Everything you visited in the engine, imported
///    history included, has its icon there.
/// The row asks FaviconCache's memory and disk for the /favicon.ico guess as well, and draws a lettered tile until one
/// arrives (CommandRowView).
///
/// Lookups run on one serial queue, batched: one keystroke's rows open the database once. Found and missing sites are
/// remembered (misses for a minute), so typing on asks nothing again. A private window never uses this (its rows show
/// letter tiles; nothing of a private page is written here, as only WindowController remembers icons).
final class SiteIcons {
    static let shared = SiteIcons()

    private let memory = NSCache<NSString, NSImage>()
    /// Sites looked up and not found, and when; asked again after `missTTL`.
    private var misses: [String: Date] = [:]
    private static let missTTL: TimeInterval = 60
    /// Sites being looked up, with the rows waiting for them.
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    /// The next batch, by database (nil: Airc's store only).
    private var pending: [(site: String, database: URL?)] = []
    private var drainScheduled = false
    /// Sites whose icon this process already wrote to disk (the engine reports an icon on every page load).
    private var written = Set<String>()
    private let queue = DispatchQueue(label: "airc.siteicons", qos: .userInitiated)
    let directory: URL

    #if AIRC_TESTING
    /// A favicon database the main window's rows read instead of the profile's (CmdTrustCheck's synthetic one).
    static var databaseOverrideForTesting: URL?
    /// How many batches opened the engine's favicon database, and the sites it answered (CmdTrustCheck).
    private(set) var databaseReads = 0
    private(set) var databaseHits: [String] = []
    #endif

    init(directory: URL = AppPaths.dataDirectory.appendingPathComponent("SiteIcons", isDirectory: true)) {
        self.directory = directory
        memory.countLimit = 600
    }

    /// The key a page's icon is kept under: its host, lowercased, without "www.". nil for anything not http(s).
    static func site(forPage page: String) -> String? {
        guard page.hasPrefix("http"), let c = URLComponents(string: page), let s = c.scheme?.lowercased(),
              s == "https" || s == "http", var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let port = c.port, port != 80, port != 443 { host += ":\(port)" }
        return host
    }

    /// The icon in memory, for a row being configured on the main thread.
    func cached(page: String) -> NSImage? {
        Self.site(forPage: page).flatMap { memory.object(forKey: $0 as NSString) }
    }

    /// The site's icon from Airc's store or the engine's database (`database`: the profile's Favicons file), off the
    /// main thread; `completion` runs on the main thread, with nil if neither has one.
    func lookup(page: String, database: URL?, completion: @escaping (NSImage?) -> Void) {
        guard let site = Self.site(forPage: page) else { return completion(nil) }
        if let img = memory.object(forKey: site as NSString) { return completion(img) }
        if let t = misses[site], Date().timeIntervalSince(t) < Self.missTTL { return completion(nil) }
        if waiting[site] != nil { waiting[site]!.append(completion); return }
        waiting[site] = [completion]
        pending.append((site, database))
        guard !drainScheduled else { return }
        drainScheduled = true
        // After this turn's rows have all asked: one batch for the keystroke.
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        drainScheduled = false
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }
        let dir = directory
        queue.async { [weak self] in
            var found: [String: NSImage] = [:]
            var rest: [String: URL] = [:]
            for (site, db) in batch {
                if let img = Self.readStored(site, in: dir) { found[site] = img } else if let db { rest[site] = db }
            }
            var opened = 0
            for (db, sites) in Dictionary(grouping: rest.keys, by: { rest[$0]! }) {
                opened += 1
                for (site, img) in Self.readEngineIcons(Array(sites), database: db) { found[site] = img }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                #if AIRC_TESTING
                self.databaseReads += opened
                self.databaseHits += batch.map(\.site).filter { found[$0] != nil && rest[$0] != nil }
                #endif
                for (site, _) in batch {
                    let img = found[site]
                    if let img { self.memory.setObject(img, forKey: site as NSString); self.misses[site] = nil } else { self.misses[site] = Date() }
                    for c in self.waiting.removeValue(forKey: site) ?? [] { c(img) }
                }
                if self.misses.count > 2000 { self.misses = self.misses.filter { Date().timeIntervalSince($0.value) < Self.missTTL } }
            }
        }
    }

    /// A page in a normal window shows `image`: keep it for its site (memory now, disk once per site and process).
    func remember(_ image: NSImage?, page: URL?) {
        guard let image, let page, let site = Self.site(forPage: page.absoluteString) else { return }
        memory.setObject(image, forKey: site as NSString)
        misses[site] = nil
        guard written.insert(site).inserted else { return }
        let file = directory.appendingPathComponent(FaviconCache.stableName(site) + ".png")
        let dir = directory
        // Drawn into a 32 px bitmap on the main thread (NSImage isn't for sharing across threads); encoded and
        // written off it.
        guard let rep = Self.bitmap(of: image, pixels: 32) else { return }
        queue.async {
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Forgets everything (Clear Browsing Data, tests).
    func forgetAll() {
        memory.removeAllObjects()
        misses = [:]
        written = []
        let dir = directory
        queue.async { try? FileManager.default.removeItem(at: dir) }
    }

    #if AIRC_TESTING
    func forgetMemoryForTesting() {
        memory.removeAllObjects()
        misses = [:]
        databaseReads = 0
        databaseHits = []
    }
    #endif

    // MARK: Off the main thread

    private static func readStored(_ site: String, in dir: URL) -> NSImage? {
        let file = dir.appendingPathComponent(FaviconCache.stableName(site) + ".png")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return FaviconCache.decode(data)
    }

    /// The best bitmap (16–64 px, largest first) of any page on each site, from Chromium's favicon database: rows of
    /// `icon_mapping` whose page URL starts with the site, for https and http, with and without "www.".
    static func readEngineIcons(_ sites: [String], database: URL) -> [String: NSImage] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [:] }
        var db: OpaquePointer?
        var uri = URLComponents()
        uri.scheme = "file"
        uri.path = database.path
        uri.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard let u = uri.string,
              sqlite3_open_v2(u, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url >= ?1 AND m.page_url < ?2 AND length(b.image_data) > 0
            ORDER BY (b.width BETWEEN 16 AND 64) DESC, b.width DESC, b.last_updated DESC LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var out: [String: NSImage] = [:]
        for site in sites {
            for prefix in ["https://\(site)/", "https://www.\(site)/", "http://\(site)/", "http://www.\(site)/"] {
                // [prefix, prefix with its last "/" raised to "0"): every page URL under it, by the page_url index.
                let upper = String(prefix.dropLast()) + "0"
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, prefix, -1, transient)
                sqlite3_bind_text(stmt, 2, upper, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
                if let img = FaviconCache.decode(data) { out[site] = img; break }
            }
        }
        return out
    }

    private static func bitmap(of image: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

extension WindowController {
    /// The Favicons database of the Chromium profile this window's Space uses (nil on WebKit).
    var commandBarFaviconDatabase: URL? {
        #if AIRC_TESTING
        if let db = SiteIcons.databaseOverrideForTesting { return db }
        #endif
        #if canImport(AircCore)
        let profile = store.profile(ofSpace: currentSpaceID)
        guard let p = profiles.engineProfile(for: profile.id) as? ChromiumProfile else { return nil }
        // Directory hints: without them, building the URL stats the disk twice, on every keystroke (cbperf3).
        return URL(fileURLWithPath: p.core.path, isDirectory: true).appendingPathComponent("Favicons", isDirectory: false)
        #else
        return nil
        #endif
    }
}
