// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// One site's localStorage from Arc (P22b): every key and value as Chromium's own localStorage database holds them (a
/// format byte, then Latin-1 or UTF-16 text), which is what the engine's storage takes. Never logged.
public struct ImportedSiteStorage: Sendable, Equatable {
    /// The site's origin, as Chromium serializes it ("https://example.com", "http://localhost:8080").
    public var origin: String
    public var items: [Item]
    public var bytes: Int { items.reduce(0) { $0 + $1.key.count + $1.value.count } }

    public struct Item: Sendable, Equatable {
        public var key: Data
        public var value: Data
    }
}

/// What Arc kept of sites' own storage, per profile (Chromium 156, the same engine as Airc's): `Local Storage/leveldb`
/// (localStorage, one LevelDB for every site), `IndexedDB/<scheme>_<host>_<port>.indexeddb.leveldb` (a database per
/// site, with `.blob` files beside it), `Service Worker/` (registrations and cached scripts), `Session Storage/` (per
/// tab, gone when it closes) and `WebStorage/` (storage buckets and the quota database).
///
/// Airc imports the localStorage of the sites visited most, through the engine (a site keeps what Airc already holds
/// for it). IndexedDB isn't imported: a site's database can only be written through the engine's IndexedDB service,
/// whose values are the page's own serialized JavaScript objects with index keys the page computes, and copying the
/// files into a running profile risks the profile's other sites. Those sites are listed instead (from their folder
/// names; the databases aren't opened). Service workers aren't copied: a site installs its own again when it's opened.
public enum ArcSiteStorage {
    /// How many sites' storage comes over, the ones Arc's history says were visited most.
    public static let siteLimit = 50
    /// Chromium's localStorage quota for one site; a site holding more stays in Arc.
    public static let siteQuota = 10 << 20
    /// All sites' storage together.
    public static let totalLimit = 64 << 20

    static let indexedDBReason = "Its offline data (IndexedDB) stays in Arc: Airc can't import it"

    /// The site behind a localStorage key prefix ("_https://example.com\0…") or an IndexedDB folder
    /// ("https_example.com_0.indexeddb.leveldb"): HTTP(S) and first-party only (no partitioned "^" keys).
    static func origin(storageKey: String) -> String? {
        guard !storageKey.contains("^"), let u = URL(string: storageKey), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty, u.path.isEmpty || u.path == "/",
              u.query == nil, u.user == nil else { return nil }
        let h = host.contains(":") ? "[\(host)]" : host.lowercased()
        let port = u.port.flatMap { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? nil : $0 }
        return "\(scheme)://\(h)" + (port.map { ":\($0)" } ?? "")
    }
    static func origin(indexedDBFolder name: String) -> String? {
        guard name.hasSuffix(".indexeddb.leveldb") else { return nil }
        let parts = name.dropLast(".indexeddb.leveldb".count).split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3, let port = Int(parts.last!) else { return nil }
        let host = parts.dropFirst().dropLast().joined(separator: "_")
        return origin(storageKey: "\(parts[0])://\(host)" + (port == 0 ? "" : ":\(port)"))
    }

    /// Every first-party site's items from Local Storage's live entries.
    static func sites(_ entries: [Data: Data]) -> [String: [ImportedSiteStorage.Item]] {
        var out: [String: [ImportedSiteStorage.Item]] = [:]
        for (key, value) in entries where key.first == UInt8(ascii: "_") {
            guard let zero = key.firstIndex(of: 0), zero > key.startIndex + 1,
                  let storageKey = String(data: key[(key.startIndex + 1)..<zero], encoding: .utf8),
                  let origin = origin(storageKey: storageKey) else { continue }
            let item = Data(key[(zero + 1)...])
            guard !item.isEmpty else { continue }
            out[origin, default: []].append(.init(key: item, value: value))
        }
        for (k, v) in out { out[k] = v.sorted { $0.key.lexicographicallyPrecedes($1.key) } }
        return out
    }

    /// arcimport3: sites whose localStorage Arc kept only inside another site's pages (a storage key with a "^"
    /// partition, a third-party frame's), by the embedded site's origin. Not imported: Airc's engine binds local storage
    /// to first-party keys only, and a partitioned copy would follow the site everywhere.
    static func partitionedSites(_ entries: [Data: Data]) -> Set<String> {
        var out: Set<String> = []
        for key in entries.keys where key.first == UInt8(ascii: "_") {
            guard let zero = key.firstIndex(of: 0), zero > key.startIndex + 1,
                  let storageKey = String(data: key[(key.startIndex + 1)..<zero], encoding: .utf8),
                  let caret = storageKey.firstIndex(of: "^"),
                  let origin = origin(storageKey: String(storageKey[..<caret]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else { continue }
            out.insert(origin)
        }
        return out
    }

    public static let partitionedReason = "Kept only inside other sites' pages (partitioned storage): it stays in Arc"
    public static let workersReason = "Service workers and their offline caches aren't copied: each site sets them up again when you open it"

    /// Visits per site in Arc's history (its most visited sites first), or empty when it can't be read.
    static func visits(_ profileDirectory: URL, tempRoot: URL) -> [String: Int] {
        let url = profileDirectory.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: url.path),
              let rows = try? DatabaseCopy(url, tempRoot: tempRoot, immutableOnly: true).rows(
                  "SELECT url, visit_count FROM urls WHERE url LIKE 'http://%' OR url LIKE 'https://%'") else { return [:] }
        var out: [String: Int] = [:]
        for r in rows {
            guard let s = r["url"].flatMap({ String(data: $0, encoding: .utf8) }), let u = URL(string: s),
                  let scheme = u.scheme, let host = u.host,
                  let o = origin(storageKey: "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)" + (u.port.map { ":\($0)" } ?? "")) else { continue }
            out[o, default: 0] += Int(r["visit_count"].flatMap { String(data: $0, encoding: .utf8) }.flatMap { Int($0) } ?? 0)
        }
        return out
    }
}

extension ArcCredentialImporter {
    /// Reads the profile's localStorage for its most visited sites into `out.siteData`, with a note for each of those
    /// that keeps IndexedDB data, one for every site with data beyond them, and the database as failed (with why) when
    /// it can't be read. Arc may be running: it reads a private copy of the folder, made when no file changed during it.
    static func readSiteData(_ profileDirectory: URL, tempRoot: URL, into out: inout ImportedCredentials,
                             limit: Int = ArcSiteStorage.siteLimit) throws {
        let fm = FileManager.default
        let leveldb = profileDirectory.appendingPathComponent("Local Storage/leveldb")
        var local: [String: [ImportedSiteStorage.Item]] = [:]
        var partitioned: Set<String> = []
        if fm.fileExists(atPath: leveldb.path) {
            do {
                let copy = try FolderCopy(leveldb, tempRoot: tempRoot)
                let entries = try LevelDB.read(copy.folder)
                local = ArcSiteStorage.sites(entries)
                partitioned = ArcSiteStorage.partitionedSites(entries)
            } catch is CancellationError { throw CancellationError() }
            catch {
                out.failedDatabases.append("Local Storage"); out.fail("Local Storage: \(error)")
                out.databaseReasons["Local Storage"] = switch error {
                case let p as DatabaseCopy.Problem where p.kind == .busy: "Arc kept writing to it while Airc copied it. Quit Arc and try again."
                case let e as ImportError where e == .permissionDenied: "macOS didn't let Airc read it."
                case let p as LevelDB.Problem where p.reason.hasPrefix("compressed"): "It's stored in a way Airc can't read."
                default: "It's damaged, or isn't the kind of database Arc writes."
                }
            }
        }
        let indexed = Set(((try? fm.contentsOfDirectory(atPath: profileDirectory.appendingPathComponent("IndexedDB").path)) ?? [])
            .compactMap(ArcSiteStorage.origin(indexedDBFolder:)))
        // arcimport3: what of sites' own storage never comes over, said once each (not per site).
        if !partitioned.isEmpty {
            out.notes.append(.init(kind: .siteData, site: partitioned.count == 1 ? "1 site inside other sites" : "\(partitioned.count) sites inside other sites",
                                   skipped: true, reason: ArcSiteStorage.partitionedReason, detail: "local storage", count: partitioned.count))
        }
        if fm.fileExists(atPath: profileDirectory.appendingPathComponent("Service Worker").path) {
            out.notes.append(.init(kind: .siteData, site: "Offline caches", skipped: true, reason: ArcSiteStorage.workersReason,
                                   detail: "service workers"))
        }
        let all = Set(local.keys).union(indexed)
        guard !all.isEmpty else { return }
        let visits = ArcSiteStorage.visits(profileDirectory, tempRoot: tempRoot)
        let ranked = all.sorted { a, b in
            let (va, vb) = (visits[a] ?? 0, visits[b] ?? 0)
            return va != vb ? va > vb : a < b
        }
        var total = 0
        for site in ranked.prefix(limit) {
            if let items = local[site] {
                let data = ImportedSiteStorage(origin: site, items: items)
                if data.bytes > ArcSiteStorage.siteQuota {
                    out.notes.append(.init(kind: .siteData, site: site, skipped: true, reason: "More than 10 MB, over a site's limit: it stays in Arc",
                                           detail: "local storage"))
                } else if total + data.bytes > ArcSiteStorage.totalLimit {
                    out.notes.append(.init(kind: .siteData, site: site, skipped: true,
                                           reason: "Over the 64 MB Airc brings over for sites' storage: it stays in Arc", detail: "local storage"))
                } else {
                    total += data.bytes
                    out.siteData.append(data)
                }
            }
            if indexed.contains(site) {
                out.notes.append(.init(kind: .siteData, site: site, skipped: true, reason: ArcSiteStorage.indexedDBReason, detail: "offline data"))
            }
        }
        let rest = ranked.count - min(ranked.count, limit)
        if rest > 0 {
            out.notes.append(.init(kind: .siteData, site: rest == 1 ? "1 other site" : "\(rest) other sites", skipped: true,
                                   reason: "Not among the \(limit) sites you visit most: their storage stays in Arc", count: rest))
        }
    }
}

/// A private copy of one of Arc's LevelDB folders (its CURRENT, MANIFEST, logs and tables), made the way
/// `DatabaseCopy` copies a database: into a 0700 folder named like its copies (so `removeStaleCopies` finds a crash's
/// leftovers), retried until no file changed during the copy. Deleted when released.
final class FolderCopy {
    let folder: URL

    init(_ source: URL, tempRoot: URL) throws {
        let fm = FileManager.default
        folder = tempRoot.appendingPathComponent(DatabaseCopy.folderPrefix + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            func names() throws -> [String] {
                do {
                    return try fm.contentsOfDirectory(atPath: source.path).filter {
                        $0 == "CURRENT" || $0.hasPrefix("MANIFEST-") || $0.hasSuffix(".log") || $0.hasSuffix(".ldb") || $0.hasSuffix(".sst")
                    }.sorted()
                } catch let e as NSError where e.code == NSFileReadNoPermissionError { throw ImportError.permissionDenied }
            }
            func stamp(_ list: [String]) -> [String] {
                list.map { n in
                    guard let a = try? fm.attributesOfItem(atPath: source.appendingPathComponent(n).path) else { return n + " -" }
                    return "\(n) \((a[.size] as? NSNumber)?.int64Value ?? -1)@\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                }
            }
            var consistent = false
            for attempt in 0..<8 where !consistent {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.05 * Double(attempt)) }
                for n in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] { try? fm.removeItem(at: folder.appendingPathComponent(n)) }
                let list = try names()
                let before = stamp(list)
                for n in list {
                    let f = source.appendingPathComponent(n)
                    guard fm.isReadableFile(atPath: f.path) else { throw ImportError.permissionDenied }
                    do { try fm.copyItem(at: f, to: folder.appendingPathComponent(n)) }
                    catch let e as NSError where e.code == NSFileReadNoPermissionError { throw ImportError.permissionDenied }
                    catch let e as NSError where e.code == NSFileReadNoSuchFileError { break }   // compacted away: try again
                }
                consistent = (try names()) == list && stamp(list) == before
            }
            guard consistent else { throw DatabaseCopy.Problem(kind: .busy) }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}
