// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// H01, H02, B03: Airc's sharing service on aircbrowser.com (apps/marketing/api, docs/dev/sharing-service.md).
///
/// - A shared Space or folder is a hosted snapshot, `https://aircbrowser.com/s/<id>`: titles and addresses only, in
///   the same JSON as a fragment link (ShareLink). Publishing returns the link and a secret token; the token takes the
///   link back (the app keeps it in the Keychain). A link that was taken back is a 404.
/// - The Boost gallery lists Boosts the owner approved; anyone can submit one (it waits for review) or report one.
///
/// Every answer is checked as untrusted input: a snapshot goes through ShareLink's strict decoder, a Boost through
/// BoostFile's, and bodies are capped before they're parsed.
public struct SharingService: Sendable {
    /// The service: aircbrowser.com, or a local or Preview deployment in tests.
    public var base: URL
    public var session: URLSession
    /// Sent with every request (a Preview's protection bypass in tests). Empty in releases.
    public var extraHeaders: [String: String]

    public static let site = URL(string: "https://aircbrowser.com")!

    public init(base: URL = SharingService.site, session: URLSession = .shared, extraHeaders: [String: String] = [:]) {
        self.base = base
        self.session = session
        self.extraHeaders = extraHeaders
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// The link was taken back, or never existed.
        case notFound
        case rateLimited
        /// The service refused it, with a sentence for the person (an unsafe address, a Boost the review won't take).
        case refused(String)
        case offline
        case unavailable
        /// An answer that isn't what the service sends.
        case damaged

        public var errorDescription: String? {
            switch self {
            case .notFound: "This link was taken back, or it never existed."
            case .rateLimited: "Too many shares from this network in the last hour. Try again later."
            case .refused(let why): why
            case .offline: "Airc can’t reach aircbrowser.com. Check your connection and try again."
            case .unavailable: "Sharing isn’t available right now. Try again in a few minutes."
            case .damaged: "aircbrowser.com sent something Airc doesn’t understand. Try again later."
            }
        }
    }

    /// A link that was just published.
    public struct Published: Codable, Equatable, Sendable {
        public var id: String
        public var url: URL
        /// Takes the link back. Only its hash is on the server.
        public var token: String
    }

    // MARK: Share links

    /// What the service would refuse (too large, an address that can't be shared), found before anything is sent.
    public static func check(_ snapshot: ShareSnapshot) throws {
        if case .boost = snapshot.kind { throw ShareLink.Failure.damaged }
        let data = try ShareLink.encode(snapshot)
        guard data.count <= ShareLink.maximumJSON else { throw ShareLink.Failure.tooLarge }
        _ = try ShareLink.decode(data)
    }

    /// Publishes `snapshot` (a Space or a folder) and returns its link and token.
    public func publish(_ snapshot: ShareSnapshot) async throws -> Published {
        if case .boost = snapshot.kind { throw Failure.refused("Boosts are shared through the Boost Gallery or a Boost link.") }
        let body = try ShareLink.encode(snapshot)
        guard body.count <= ShareLink.maximumJSON else { throw ShareLink.Failure.tooLarge }
        let data = try await send("POST", "api/share", body: body, expect: [201], limit: 4096)
        guard let p = try? JSONDecoder().decode(Published.self, from: data), HostedShareLink.isID(p.id),
              ["https", "http"].contains(p.url.scheme?.lowercased() ?? ""), p.token.count >= 20 else { throw Failure.damaged }
        return p
    }

    /// The snapshot behind a hosted link, checked as strictly as a fragment link's.
    public func snapshot(id: String) async throws -> ShareSnapshot {
        guard HostedShareLink.isID(id) else { throw Failure.notFound }
        let data = try await send("GET", "api/share", query: ["id": id], expect: [200], limit: ShareLink.maximumJSON + 4096)
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let snapshot = top["snapshot"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: snapshot) else { throw Failure.damaged }
        let s = try ShareLink.decode(raw)
        if case .boost = s.kind { throw Failure.damaged }
        return s
    }

    /// Takes a link back. A link that's already gone counts as taken back.
    public func revoke(id: String, token: String) async throws {
        guard HostedShareLink.isID(id) else { return }
        do {
            _ = try await send("DELETE", "api/share", query: ["id": id], headers: ["Authorization": "Bearer \(token)"], expect: [204], limit: 4096)
        } catch Failure.notFound {
            return
        }
    }

    // MARK: Easel links (P19c)

    /// Publishes a read-only snapshot of an Easel (`easel`, with the bytes of each of its pictures by name) and returns
    /// its link, `https://aircbrowser.com/e/<id>`, and the token that takes it back. Three steps: the Easel (the
    /// service answers which pictures it still needs), each picture, then publish; nothing shows at the link before the
    /// last. A failure on the way takes the unfinished link back (the service also sweeps those after a day).
    public func publishEasel(_ easel: EaselPublic, pictures: [String: Data], progress: (@Sendable (Double) -> Void)? = nil) async throws -> Published {
        try easel.check()
        for a in easel.assets {
            guard let d = pictures[a.name], d.count == a.size, EaselPublic.pictureName(d) == a.name else { throw Failure.refused("A picture on this Easel changed while it was being shared. Try again.") }
        }
        let data = try await send("POST", "api/easel", body: try easel.encoded(), expect: [201], limit: 64 * 1024)
        struct Created: Decodable { var id: String; var url: URL; var token: String; var missing: [String] }
        guard let c = try? JSONDecoder().decode(Created.self, from: data), HostedEaselLink.isLink(c.url, id: c.id), c.token.count >= 20,
              Set(c.missing).isSubset(of: Set(easel.assets.map(\.name))) else { throw Failure.damaged }
        let made = Published(id: c.id, url: c.url, token: c.token)
        do {
            let auth = ["Authorization": "Bearer \(c.token)"]
            for (i, name) in c.missing.enumerated() {
                guard let d = pictures[name] else { throw Failure.damaged }
                let type = name.hasSuffix(".png") ? "image/png" : name.hasSuffix(".jpg") ? "image/jpeg" : name.hasSuffix(".gif") ? "image/gif" : "image/webp"
                try await retrying {
                    _ = try await send("PUT", "api/easel", query: ["id": c.id, "asset": name], body: d, headers: auth, contentType: type, expect: [204], limit: 4096)
                }
                progress?(Double(i + 1) / Double(max(1, c.missing.count)))
            }
            try await retrying {
                _ = try await send("POST", "api/easel", query: ["id": c.id, "publish": "1"], headers: auth, expect: [200], limit: 4096)
            }
            return made
        } catch {
            try? await revokeEasel(id: c.id, token: c.token)
            throw error
        }
    }

    /// Takes an Easel link back: its page and pictures 404 from then on. A link that's already gone counts as taken back.
    public func revokeEasel(id: String, token: String) async throws {
        guard HostedShareLink.isID(id) else { return }
        do {
            _ = try await send("DELETE", "api/easel", query: ["id": id], headers: ["Authorization": "Bearer \(token)"], expect: [204], limit: 4096)
        } catch Failure.notFound {
            return
        }
    }

    // MARK: Opening an Easel link (P19d)

    /// Whether this service may be read from: https, or a loopback address (a local server in tests). An Easel link
    /// is never read over plain HTTP from anywhere else.
    public var isSecure: Bool {
        let scheme = base.scheme?.lowercased(), host = base.host?.lowercased() ?? ""
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
    }

    /// The shared Easel behind an Easel link, checked as strictly as the service checks what it takes (EaselImport).
    public func easel(id: String) async throws -> EaselPublic {
        guard HostedShareLink.isID(id) else { throw Failure.notFound }
        guard isSecure else { throw Failure.refused("Airc opens shared Easels only over a secure connection.") }
        let data = try await send("GET", "api/easel", query: ["id": id], expect: [200], limit: EaselPublic.maxJSON + 4096, sameHost: true)
        return try EaselImport.decodeAnswer(data)
    }

    /// One picture of a shared Easel (`/e/<id>/a/<name>`): exactly the bytes its name promises, a picture type Airc
    /// takes, with a size in pixels that decodes (EaselImport.checkPicture). The bytes and that size.
    public func easelPicture(id: String, _ asset: EaselPublic.Asset) async throws -> (data: Data, width: Double, height: Double) {
        guard HostedShareLink.isID(id), EaselImport.isAssetName(asset.name), asset.size <= EaselPublic.maxAssetBytes else { throw EaselImport.Failure.picture }
        guard isSecure else { throw Failure.refused("Airc opens shared Easels only over a secure connection.") }
        let data = try await send("GET", "e/\(id)/a/\(asset.name)", expect: [200], limit: asset.size, sameHost: true, accept: "image/*")
        guard let size = EaselImport.checkPicture(data, as: asset) else { throw EaselImport.Failure.picture }
        return (data, size.width, size.height)
    }

    /// A step that's safe to repeat (a picture's upload, publish), tried again twice when the network or the service
    /// had a moment.
    private func retrying(_ step: () async throws -> Void) async throws {
        for attempt in 0..<3 {
            do {
                return try await step()
            } catch let f as Failure where (f == .offline || f == .unavailable) && attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
            }
        }
    }

    // MARK: Boost gallery

    /// One approved Boost in the gallery.
    public struct GalleryEntry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// The Boost file's own id (the same in every revision), if it has one.
        public var fileID: String?
        public var name: String
        public var site: String
        public var author: String?
        public var about: String?
        /// It has JavaScript.
        public var code: Bool
        public var preview: Bool
        /// Its Boost link, unless the file is too large for one.
        public var link: URL?
        public var approvedAt: String
        /// The file's revision (entries listed before the service sent it have none).
        public var revision: Int?

        /// What the gallery's button offers, given the Boost installed from the same file (`fileID`): Get when there is
        /// none, Update when this entry is a later revision of the one installed from someone, Review otherwise (the
        /// same or an older revision, the person's own shared Boost, or a revision the gallery doesn't say).
        public func action(installed: Boost?) -> GalleryAction {
            guard let installed else { return .get }
            guard let origin = installed.origin, origin.kind == .installed, let fileID, origin.id == fileID,
                  let revision, revision > origin.revision else { return .review }
            return .update
        }
    }

    /// The gallery button's three labels (Airc's own Boosts use the same three).
    public enum GalleryAction: String, Equatable, Sendable {
        case get = "Get", review = "Review", update = "Update"
    }

    /// The gallery's approved Boosts, newest first.
    public func galleryEntries() async throws -> [GalleryEntry] {
        let data = try await send("GET", "api/boosts", expect: [200], limit: 4 * 1024 * 1024)
        struct List: Decodable { var boosts: [GalleryEntry] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw Failure.damaged }
        return list.boosts.filter { HostedShareLink.isID($0.id) && BoostFile.plainLine($0.name, max: 120) }
    }

    /// An approved Boost's file, for the usual review before it's installed.
    public func galleryFile(id: String) async throws -> BoostFile {
        guard HostedShareLink.isID(id) else { throw Failure.notFound }
        let data = try await send("GET", "api/boosts", query: ["id": id], expect: [200], limit: BoostFile.maximumBytes)
        guard let f = try? BoostFile.decode(data), f.preview == nil else { throw Failure.damaged }
        return f
    }

    /// An approved Boost's preview picture (PNG or JPEG), or nil.
    public func galleryPreview(id: String) async -> Data? {
        guard HostedShareLink.isID(id),
              let data = try? await send("GET", "api/boosts", query: ["preview": id], expect: [200], limit: BoostFile.maximumPreviewBytes)
        else { return nil }
        return BoostFile.previewImage(data.base64EncodedString())
    }

    /// Sends a Boost to the gallery's review queue. Returns the service's sentence for the person.
    @discardableResult
    public func submit(_ file: BoostFile) async throws -> String {
        let body = try file.encoded()
        let data = try await send("POST", "api/boosts", body: body, expect: [202], limit: 4096)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            ?? "Sent. It’s listed in the gallery once it’s been reviewed."
    }

    public enum ReportReason: String, CaseIterable, Sendable {
        case broken, harmful, spam, other
        public var title: String {
            switch self {
            case .broken: "It doesn’t work"
            case .harmful: "It’s harmful or deceptive"
            case .spam: "Spam or a copy"
            case .other: "Something else"
            }
        }
    }

    public func report(id: String, reason: ReportReason, note: String?) async throws {
        guard HostedShareLink.isID(id) else { throw Failure.notFound }
        var o: [String: String] = ["reason": reason.rawValue]
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { o["note"] = String(note.prefix(300)) }
        _ = try await send("POST", "api/boosts", query: ["report": id], body: try JSONSerialization.data(withJSONObject: o), expect: [202], limit: 4096)
    }

    // MARK: Requests

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, headers: [String: String] = [:],
                 contentType: String = "application/json", accept: String = "application/json") -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = method
        r.httpBody = body
        r.httpShouldHandleCookies = false
        if body != nil { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        r.setValue(accept, forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders.merging(headers, uniquingKeysWith: { _, b in b }) { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// `sameHost`: an answer that came from anywhere but the service (a redirect elsewhere, or to plain HTTP) is refused.
    func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, headers: [String: String] = [:],
              contentType: String = "application/json", expect: Set<Int>, limit: Int, sameHost: Bool = false,
              accept: String = "application/json") async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request(method, path, query: query, body: body, headers: headers, contentType: contentType, accept: accept))
        } catch {
            throw Failure.offline
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.damaged }
        if sameHost {
            guard let u = http.url, u.scheme?.lowercased() == base.scheme?.lowercased(), u.host?.lowercased() == base.host?.lowercased(),
                  u.port == base.port else { throw Failure.damaged }
        }
        if expect.contains(http.statusCode) {
            guard data.count <= limit else { throw Failure.damaged }
            return data
        }
        let message = (data.count <= 8192 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil)?["message"] as? String
        switch http.statusCode {
        case 404: throw Failure.notFound
        case 429: throw Failure.rateLimited
        case 400, 403, 409, 413, 422:
            // The service's own sentence, if it's one plain line; it's shown as text.
            throw Failure.refused(message.flatMap { BoostFile.plainLine($0, max: 400) ? $0 : nil } ?? "aircbrowser.com refused it.")
        case 500...599: throw Failure.unavailable
        default: throw Failure.damaged
        }
    }
}

/// A hosted share link: `https://aircbrowser.com/s/<id>` (`www.` too), the page's "Add to Airc" link
/// `airc://share/<id>`, or a link of the configured service (a local or Preview deployment, in tests).
public enum HostedShareLink {
    /// 12 letters and digits.
    public static func isID(_ s: String) -> Bool {
        s.utf8.count == 12 && s.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    /// The link's id, or nil when `url` isn't a hosted share link. `service` is the configured service's address.
    public static func id(from url: URL?, service: URL = SharingService.site) -> String? {
        guard let url, url.fragment == nil, url.query == nil, url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased() else { return nil }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "", parts.count > 2 { parts.removeLast() }
        if scheme == ShareLink.appScheme {
            guard url.host?.lowercased() == ShareLink.appHost, parts.count == 2, parts[0] == "", isID(parts[1]) else { return nil }
            return parts[1]
        }
        guard parts.count == 3, parts[0] == "", parts[1] == "s", isID(parts[2]), let host = url.host?.lowercased() else { return nil }
        let site = scheme == "https" && (host == ShareLink.host || host == "www." + ShareLink.host)
        let configured = scheme == service.scheme?.lowercased() && host == service.host?.lowercased() && url.port == service.port
        return site || configured ? parts[2] : nil
    }

    public static func isLink(_ url: URL?, service: URL = SharingService.site) -> Bool { id(from: url, service: service) != nil }

    /// The page's "Add to Airc" link for `id`.
    public static func appURL(id: String) -> URL? { isID(id) ? URL(string: "\(ShareLink.appScheme)://\(ShareLink.appHost)/\(id)") : nil }
}

/// A hosted Easel link (P19c): `https://aircbrowser.com/e/<id>`, or the configured service's in tests; its page's
/// "Add to Airc" link is `airc://easel/<id>` (P19d).
public enum HostedEaselLink {
    public static let appHost = "easel"

    /// The link's id, or nil when `url` isn't an Easel link (a picture's address, `/e/<id>/a/…`, isn't one).
    public static func id(from url: URL?, service: URL = SharingService.site) -> String? {
        guard let url, url.fragment == nil, url.query == nil, url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased() else { return nil }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "", parts.count > 2 { parts.removeLast() }
        if scheme == ShareLink.appScheme {
            guard url.host?.lowercased() == appHost, url.port == nil, parts.count == 2, parts[0] == "", HostedShareLink.isID(parts[1]) else { return nil }
            return parts[1]
        }
        guard parts.count == 3, parts[0] == "", parts[1] == "e", HostedShareLink.isID(parts[2]), let host = url.host?.lowercased() else { return nil }
        let site = scheme == "https" && url.port == nil && (host == ShareLink.host || host == "www." + ShareLink.host)
        let configured = scheme == service.scheme?.lowercased() && host == service.host?.lowercased() && url.port == service.port
        return site || configured ? parts[2] : nil
    }

    public static func isLink(_ url: URL?, service: URL = SharingService.site) -> Bool { id(from: url, service: service) != nil }

    /// The page's "Add to Airc" link for `id`.
    public static func appURL(id: String) -> URL? { HostedShareLink.isID(id) ? URL(string: "\(ShareLink.appScheme)://\(appHost)/\(id)") : nil }

    /// Whether `url` is the Easel link of `id` (the service's answer is checked against it).
    public static func isLink(_ url: URL?, id: String) -> Bool {
        guard let url, HostedShareLink.isID(id), url.query == nil, url.fragment == nil, url.user == nil,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        return url.path == "/e/\(id)"
    }
}

/// A link this Mac published, so it can be found and taken back later. The token isn't here: it's in the Keychain.
public struct SharedLinkRecord: Codable, Equatable, Sendable, Identifiable {
    /// `easel` (P19c): `sourceID` is the Easel's id.
    public enum Kind: String, Codable, Sendable { case space, folder, easel }
    public var id: String
    public var url: URL
    public var kind: Kind
    public var name: String
    /// The Space's or folder's id in the sidebar.
    public var sourceID: String
    public var createdAt: Date

    public init(id: String, url: URL, kind: Kind, name: String, sourceID: String, createdAt: Date) {
        self.id = id
        self.url = url
        self.kind = kind
        self.name = name
        self.sourceID = sourceID
        self.createdAt = createdAt
    }

    /// The list as Airc saves it (a small JSON file next to its data); unreadable files read as empty.
    public static func load(_ data: Data?) -> [SharedLinkRecord] {
        guard let data, data.count <= 4 * 1024 * 1024 else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        // One record a later build wrote (a kind this build doesn't know) leaves the others readable.
        struct Lenient: Decodable {
            var record: SharedLinkRecord?
            init(from decoder: Decoder) throws { record = try? SharedLinkRecord(from: decoder) }
        }
        return ((try? d.decode([Lenient].self, from: data)) ?? []).compactMap(\.record).filter { HostedShareLink.isID($0.id) }
    }

    public static func save(_ records: [SharedLinkRecord]) -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? e.encode(records)) ?? Data("[]".utf8)
    }
}
