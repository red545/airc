// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Combine
import AircKit

struct BlockingListDescriptor: Identifiable {
    let id: String
    let title: String
    let category: String
    let url: URL
    let bundled: Bool
    let license: String
    static let catalog: [Self] = [
        .init(id: "easylist", title: "EasyList", category: "Ads", url: URL(string: "https://easylist.to/easylist/easylist.txt")!, bundled: true, license: "CC BY-SA 3.0 or later"),
        .init(id: "easyprivacy", title: "EasyPrivacy", category: "Trackers", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, bundled: true, license: "CC BY-SA 3.0 or later"),
        .init(id: "cookies", title: "EasyList Cookie List", category: "Cookie banners", url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!, bundled: false, license: "CC BY 3.0"),
        .init(id: "germany", title: "EasyList Germany", category: "Regional", url: URL(string: "https://easylist.to/easylistgermany/easylistgermany.txt")!, bundled: false, license: "See the authors’ list license"),
        .init(id: "france", title: "Liste FR", category: "Regional", url: URL(string: "https://easylist-downloads.adblockplus.org/liste_fr.txt")!, bundled: false, license: "See the authors’ list license"),
    ]
}

/// Local, content-addressed snapshots. The pointer manifest changes only after
/// validation and compilation succeed, so interrupted updates keep the old rules.
@MainActor final class BlockingListStore: ObservableObject {
    struct Snapshot {
        let bytes: Data
        let version: BlockingListVersion
    }
    typealias Fetch = (URLRequest) async throws -> BlockingListUpdate.Response
    @Published private(set) var versions: [String: BlockingListVersion] = [:]
    @Published private(set) var updating: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    private let root: URL
    private let seeds: URL?
    private let networkAllowed: Bool
    private let fetch: Fetch
    private var snapshots: [String: Snapshot] = [:]
    private var retries: [String: (failures: Int, date: Date)] = [:]
    var didChange: (() -> Void)?
    var validate: ((String, String) async throws -> Void)?
    static let converterVersion: UInt32 = 2
    enum StoreError: Error { case unavailable, invalidDigest, invalidResponse, updatesDisabled, staleSelection }

    init(directory: URL, seeds: URL?, networkAllowed: Bool, fetch: Fetch? = nil) {
        root = directory.appendingPathComponent("Blocking/Lists", isDirectory: true)
        self.seeds = seeds; self.networkAllowed = networkAllowed
        self.fetch = networkAllowed ? (fetch ?? Self.fetchFromAuthors) : { _ in throw StoreError.updatesDisabled }
        load()
    }
    func text(for selected: Set<String>, replacing: (id: String, text: String)? = nil) throws -> String {
        try selected.sorted().map { id in
            if let replacing, replacing.id == id { return replacing.text }
            guard let snapshot = snapshots[id], let text = String(data: snapshot.bytes, encoding: .utf8) else { throw StoreError.unavailable }
            return text
        }.joined(separator: "\n")
    }
    func has(_ id: String) -> Bool { snapshots[id] != nil }

    func refresh(selected: Set<String>, force: Bool = false, now: Date = Date()) async {
        guard networkAllowed else { return }
        for list in BlockingListDescriptor.catalog where selected.contains(list.id) {
            guard !updating.contains(list.id), force || (versions[list.id]?.nextRefresh ?? .distantPast) <= now,
                  force || (retries[list.id]?.date ?? .distantPast) <= now else { continue }
            await update(list, now: now)
        }
    }
    func downloadOptional(_ id: String) async throws {
        guard networkAllowed else { throw StoreError.updatesDisabled }
        guard let list = BlockingListDescriptor.catalog.first(where: { $0.id == id && !$0.bundled }) else { throw StoreError.unavailable }
        if has(id) { return }
        await update(list, now: Date())
        guard has(id) else { throw StoreError.unavailable }
    }
    #if AIRC_TESTING
    var checkNetworkIsDisabled: Bool { !networkAllowed }
    func installCheckRules(_ rules: String) {
        precondition(!networkAllowed)
        let bytes = Data(("[Adblock Plus 2.0]\n! Title: Loopback check\n! Version: 1\n" + rules).utf8)
        guard let metadata = try? BlockingListMetadata.parse(bytes) else { return }
        let version = BlockingListVersion(digest: Self.digest(bytes), converterVersion: Self.converterVersion,
                                          metadata: metadata, checkedAt: Date())
        snapshots["check-fixture"] = Snapshot(bytes: bytes, version: version)
        versions["check-fixture"] = version
    }
    #endif

    private func update(_ list: BlockingListDescriptor, now: Date) async {
        guard !updating.contains(list.id) else { return }
        updating.insert(list.id); defer { updating.remove(list.id) }
        do {
            var request = URLRequest(url: list.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            for (name, value) in versions[list.id]?.conditionalHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
            let response = try await fetch(request)
            var changed = false
            switch try BlockingListUpdate.evaluate(response, current: versions[list.id], now: now) {
            case .unchanged(let version):
                guard let old = snapshots[list.id] else { throw StoreError.unavailable }
                try install(Snapshot(bytes: old.bytes, version: version), id: list.id)
            case .candidate(let bytes, let metadata):
                let text = String(decoding: bytes, as: UTF8.self)
                guard let validate else { throw StoreError.unavailable }
                try await validate(list.id, text)
                let version = BlockingListVersion(digest: Self.digest(bytes), converterVersion: Self.converterVersion,
                    metadata: metadata, etag: response.etag, lastModified: response.lastModified, checkedAt: now, httpExpires: response.expires)
                changed = snapshots[list.id]?.version.digest != version.digest
                try install(Snapshot(bytes: bytes, version: version), id: list.id)
            }
            errors[list.id] = nil; retries[list.id] = nil
            if changed { didChange?() }
        } catch {
            errors[list.id] = "Couldn’t update. Your previous rules are still in use."
            let failures = min(10, (retries[list.id]?.failures ?? 0) + 1)
            retries[list.id] = (failures, now.addingTimeInterval(BlockingListUpdate.retryDelay(failures: failures)))
        }
    }
    private func load() {
        let manifest = root.appendingPathComponent("current.json")
        let cached = Self.readBounded(manifest).flatMap { try? JSONDecoder().decode([String: BlockingListVersion].self, from: $0) } ?? [:]
        var seeded: [String] = []
        for list in BlockingListDescriptor.catalog {
            var current: Snapshot?
            if let version = cached[list.id], Self.validDigest(version.digest),
               let bytes = Self.readBounded(root.appendingPathComponent(version.digest + ".txt")),
               Self.digest(bytes) == version.digest, (try? BlockingListMetadata.parse(bytes)) != nil {
                current = Snapshot(bytes: bytes, version: version)
            }
            if list.bundled, let file = seeds?.appendingPathComponent(list.id + ".txt"),
               let bytes = Self.readBounded(file), let metadata = try? BlockingListMetadata.parse(bytes) {
                let old = current?.version.metadata.version
                let new = metadata.version
                let newer = old.flatMap { old in new.map { new in
                    old.count == new.count && old.allSatisfy(\.isNumber) && new.allSatisfy(\.isNumber) && new > old
                }} ?? false
                if current == nil || newer {
                    let version = BlockingListVersion(digest: Self.digest(bytes), converterVersion: Self.converterVersion,
                                                      metadata: metadata, checkedAt: Date())
                    current = Snapshot(bytes: bytes, version: version); seeded.append(list.id)
                }
            }
            if let current { snapshots[list.id] = current; versions[list.id] = current.version }
        }
        // Persist first check dates after loading every manifest entry, so cache
        // collection cannot remove a different list before it has been loaded.
        for id in seeded { if let snapshot = snapshots[id] { try? install(snapshot, id: id) } }
    }
    private static func readBounded(_ file: URL) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= BlockingListMetadata.maxBytes else { return nil }
        return try? Data(contentsOf: file)
    }
    private func install(_ snapshot: Snapshot, id: String) throws {
        guard Self.validDigest(snapshot.version.digest), Self.digest(snapshot.bytes) == snapshot.version.digest else { throw StoreError.invalidDigest }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try snapshot.bytes.write(to: root.appendingPathComponent(snapshot.version.digest + ".txt"), options: .atomic)
        var next = versions; next[id] = snapshot.version
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: root.appendingPathComponent("current.json"), options: .atomic)
        versions = next; snapshots[id] = snapshot
        // Remove only our obsolete content-addressed list files, never another
        // cache or directory. Keep files referenced by the committed manifest.
        let keep = Set(next.values.map { $0.digest + ".txt" })
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "txt" && Self.validDigest(file.deletingPathExtension().lastPathComponent) && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    private static func httpDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
    private static func fetchFromAuthors(_ request: URLRequest) async throws -> BlockingListUpdate.Response {
        guard let url = request.url, url.scheme == "https", let host = url.host else { throw StoreError.invalidResponse }
        let redirect = AuthorListTransport(host: host)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: redirect, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https", response.url?.host == host else { throw StoreError.invalidResponse }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= BlockingListMetadata.maxBytes else { throw BlockingListMetadata.ParseError.tooLarge }
        return .init(status: response.statusCode, body: try Data(contentsOf: temporary),
            etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            expires: httpDate(response.value(forHTTPHeaderField: "Expires")))
    }
}

private final class AuthorListTransport: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == host ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > Int64(BlockingListMetadata.maxBytes) { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
