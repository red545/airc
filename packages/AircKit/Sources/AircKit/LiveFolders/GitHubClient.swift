// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// GitHub's REST API for live folders (LiveFolders.swift): a repository's open pull requests (no sign-in needed:
// GitHub allows 60 unauthenticated requests an hour), or a signed-in search (your pull requests, review requests).
// Every page is asked with If-None-Match, so an unchanged list costs nothing; pages follow GitHub's Link header.
// Nothing here touches the network itself: requests go through `LiveHTTPClient`, which tests replace.

/// Sends one request. `URLSessionLiveHTTP` in the app; a synthetic GitHub in tests and checks.
public protocol LiveHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real network: an ephemeral session (no cookies, no shared cache), so only the folder's token signs requests.
public struct URLSessionLiveHTTP: LiveHTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Where GitHub is: its API and its website (sign-in). A check points both at a local fake.
public struct GitHubEndpoint: Sendable, Hashable {
    public var api: URL
    public var web: URL

    public init(api: URL, web: URL) {
        self.api = api
        self.web = web
    }

    public static let github = GitHubEndpoint(api: URL(string: "https://api.github.com")!, web: URL(string: "https://github.com")!)
}

/// Reads pull requests for a live folder.
public struct GitHubClient: Sendable {
    public var http: any LiveHTTPClient
    public var endpoint: GitHubEndpoint
    /// At most this many pages per listing (100 pull requests each).
    public var maxPages: Int
    public var now: @Sendable () -> Date

    public init(http: any LiveHTTPClient, endpoint: GitHubEndpoint = .github, maxPages: Int = 10,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.endpoint = endpoint
        self.maxPages = maxPages
        self.now = now
    }

    // MARK: Requests

    /// The first page of every listing the query needs: a repository's pulls, or one search per "@me" filter.
    public func startURLs(for q: GitHubPullQuery, pageSize: Int = 100) -> [URL] {
        if let repo = q.repository, !q.createdByMe, !q.reviewRequested {
            var c = URLComponents(url: endpoint.api.appendingPathComponent("repos/\(repo)/pulls"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "state", value: "open"), .init(name: "sort", value: "updated"),
                            .init(name: "direction", value: "desc"), .init(name: "per_page", value: String(pageSize))]
            return [c.url!]
        }
        var mine: [String] = []
        if q.createdByMe { mine.append("author:@me") }
        if q.reviewRequested { mine.append("review-requested:@me") }
        if mine.isEmpty { mine.append("involves:@me") }
        return mine.map { me in
            var terms = ["is:pr", "is:open", "archived:false", me]
            if let repo = q.repository { terms.append("repo:\(repo)") }
            if let author = q.author, me != "author:@me" { terms.append("author:\(author)") }
            for l in q.labels { terms.append(l.contains(" ") ? "label:\"\(l)\"" : "label:\(l)") }
            if !q.includeDrafts { terms.append("draft:false") }
            var c = URLComponents(url: endpoint.api.appendingPathComponent("search/issues"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "q", value: terms.joined(separator: " ")), .init(name: "sort", value: "updated"),
                            .init(name: "order", value: "desc"), .init(name: "per_page", value: String(pageSize))]
            return c.url!
        }
    }

    func request(_ url: URL, token: String?, etag: String?) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Airc-LiveFolders", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return r
    }

    // MARK: Fetch

    /// Every page of every listing the query needs. Any failure (a page past the first included) fails the whole
    /// fetch, so a partial list never retires rows. `pages`: the folder's cached pages, for If-None-Match.
    public func fetch(_ q: GitHubPullQuery, token: String?, pages cached: [String: LiveCachedPage],
                      viewer: String? = nil) async -> LiveFetchResult {
        if q.needsSignIn && (token ?? "").isEmpty { return .failure(.signedOut, retryAt: nil) }
        var all: [GitHubPull] = []
        var pages: [String: LiveCachedPage] = [:]
        for start in startURLs(for: q) {
            var url: URL? = start
            var count = 0
            while let u = url, count < maxPages {
                if Task.isCancelled { return .cancelled }
                count += 1
                let key = u.absoluteString
                let old = cached[key]
                let answer: (Data, HTTPURLResponse)
                do {
                    answer = try await http.send(request(u, token: token, etag: old?.etag))
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return .cancelled }
                    return .failure(Self.classify(error), retryAt: nil)
                }
                if Task.isCancelled { return .cancelled }
                let (data, response) = answer
                let page: LiveCachedPage
                if response.statusCode == 304, let old {
                    page = old
                } else if (200..<300).contains(response.statusCode) {
                    guard let pulls = Self.parse(data, fromSearch: key.contains("/search/")) else {
                        return .failure(.failed("GitHub sent something unexpected"), retryAt: nil)
                    }
                    page = LiveCachedPage(etag: response.value(forHTTPHeaderField: "ETag"), pulls: pulls,
                                          next: Self.nextLink(response.value(forHTTPHeaderField: "Link")))
                } else {
                    let (status, retry) = Self.classify(status: response.statusCode, headers: response, body: data,
                                                        signedIn: !(token ?? "").isEmpty, now: now())
                    return .failure(status, retryAt: retry)
                }
                pages[key] = page
                all += page.pulls
                url = page.next.flatMap(URL.init(string:))
            }
        }
        return .success(pulls: all, pages: pages, viewer: viewer)
    }

    /// The signed-in account's login (for "Signed in as …"), or why there's none.
    public func viewer(token: String) async -> Result<String, LiveFolderStatus> {
        let r = request(endpoint.api.appendingPathComponent("user"), token: token, etag: nil)
        do {
            let (data, response) = try await http.send(r)
            guard (200..<300).contains(response.statusCode) else {
                return .failure(Self.classify(status: response.statusCode, headers: response, body: data, signedIn: true, now: now()).0)
            }
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let login = o["login"] as? String else {
                return .failure(.failed("GitHub sent something unexpected"))
            }
            return .success(login)
        } catch {
            return .failure(Self.classify(error))
        }
    }

    // MARK: Responses

    /// Pull requests from a repository's list (an array) or a search (`items`). nil if it's neither.
    public static func parse(_ data: Data, fromSearch: Bool) -> [GitHubPull]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows: [[String: Any]]
        if let a = json as? [[String: Any]] { rows = a }
        else if let o = json as? [String: Any], let items = o["items"] as? [[String: Any]] { rows = items }
        else { return nil }
        return rows.compactMap { pull($0, fromSearch: fromSearch) }
    }

    nonisolated(unsafe) static let dates = ISO8601DateFormatter()

    static func pull(_ o: [String: Any], fromSearch: Bool) -> GitHubPull? {
        guard let number = o["number"] as? Int, let html = o["html_url"] as? String,
              let url = URL(string: html), url.scheme == "https" || url.scheme == "http" else { return nil }
        // Search lists issues too: only pull requests count.
        if fromSearch, o["pull_request"] == nil { return nil }
        let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "#\(number)"
        let repo: String? = {
            if let base = o["base"] as? [String: Any], let r = base["repo"] as? [String: Any], let n = r["full_name"] as? String { return n }
            if let r = o["repository_url"] as? String {
                let parts = r.split(separator: "/")
                if parts.count >= 2 { return parts.suffix(2).joined(separator: "/") }
            }
            let parts = url.path.split(separator: "/")   // /owner/name/pull/12
            return parts.count >= 2 ? parts.prefix(2).joined(separator: "/") : nil
        }()
        guard let repo else { return nil }
        let merged = (o["merged_at"] as? String) != nil || ((o["pull_request"] as? [String: Any])?["merged_at"] as? String) != nil
        let labels = (o["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        var reviewers = (o["requested_reviewers"] as? [[String: Any]])?.compactMap { $0["login"] as? String } ?? []
        reviewers += (o["requested_teams"] as? [[String: Any]])?.compactMap { ($0["slug"] as? String).map { "team:" + $0 } } ?? []
        return GitHubPull(repository: repo, number: number, title: title.isEmpty ? "#\(number)" : title, url: html,
                          author: (o["user"] as? [String: Any])?["login"] as? String, isDraft: o["draft"] as? Bool ?? false,
                          labels: labels, requestedReviewers: reviewers, state: o["state"] as? String ?? "open",
                          merged: merged, updatedAt: (o["updated_at"] as? String).flatMap(dates.date(from:)),
                          fromSearch: fromSearch)
    }

    /// The `rel="next"` URL of a Link header.
    public static func nextLink(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let bits = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard bits.count >= 2, bits.dropFirst().contains(where: { $0 == "rel=\"next\"" }) else { continue }
            let u = bits[0]
            guard u.hasPrefix("<"), u.hasSuffix(">") else { continue }
            return String(u.dropFirst().dropLast())
        }
        return nil
    }

    /// A refused request: signed out (401), rate limited (403/429 with GitHub's limit headers, or Retry-After),
    /// SSO, a repository that isn't there (or private without sign-in), or a plain failure.
    public static func classify(status: Int, headers: HTTPURLResponse, body: Data, signedIn: Bool,
                                now: Date) -> (LiveFolderStatus, Date?) {
        let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String ?? ""
        switch status {
        case 401:
            return (.signedOut, nil)
        case 403, 429:
            let remaining = headers.value(forHTTPHeaderField: "x-ratelimit-remaining")
            let reset = headers.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            let retryAfter = headers.value(forHTTPHeaderField: "retry-after").flatMap(Double.init).map { now.addingTimeInterval($0) }
            if remaining == "0" || retryAfter != nil || message.lowercased().contains("rate limit") || status == 429 {
                let until = retryAfter ?? reset
                return (.rateLimited(until: until), until)
            }
            if headers.value(forHTTPHeaderField: "x-github-sso") != nil { return (.failed("GitHub SSO required"), nil) }
            return (.failed(message.isEmpty ? "GitHub refused the request" : message), nil)
        case 404:
            return (.notFound, nil)
        case 500...:
            return (.failed("GitHub is having trouble (\(status))"), nil)
        default:
            return (.failed(message.isEmpty ? "GitHub answered \(status)" : message), nil)
        }
    }

    /// A request that never got an answer: offline, or another failure.
    public static func classify(_ error: Error) -> LiveFolderStatus {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            default:
                return .failed(e.localizedDescription)
            }
        }
        return .failed(String(describing: error))
    }
}

// MARK: - Sign-in: GitHub's OAuth device flow

/// Signing in with GitHub's device flow: Airc shows a code, the person enters it on github.com, Airc polls for the
/// token. It needs a GitHub OAuth App's client ID with device flow enabled (docs/user/live-folders.md, "For the
/// maintainer"); without one, a personal access token works the same way.
public struct GitHubDeviceFlow: Sendable {
    public var http: any LiveHTTPClient
    public var endpoint: GitHubEndpoint
    public var clientID: String
    /// `repo` lets a folder list private repositories' pull requests; GitHub's OAuth Apps have no read-only scope for
    /// them. `read:org` lets review requests to a team show.
    public var scope: String

    public init(http: any LiveHTTPClient, endpoint: GitHubEndpoint = .github, clientID: String, scope: String = "repo read:org") {
        self.http = http
        self.endpoint = endpoint
        self.clientID = clientID
        self.scope = scope
    }

    public struct Code: Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: URL
        public var interval: TimeInterval
        public var expiresAt: Date
    }

    public enum Failure: Error, Equatable {
        case notConfigured
        case denied
        case expired
        case failed(String)
    }

    private func post(_ path: String, _ fields: [(String, String)]) async throws -> [String: Any] {
        var r = URLRequest(url: endpoint.web.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("Airc-LiveFolders", forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await http.send(r)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(response.statusCode), o["error"] == nil {
            throw Failure.failed("GitHub answered \(response.statusCode)")
        }
        return o
    }

    /// Asks GitHub for a code to show.
    public func start(now: Date = Date()) async throws -> Code {
        guard !clientID.isEmpty else { throw Failure.notConfigured }
        let o = try await post("login/device/code", [("client_id", clientID), ("scope", scope)])
        if let e = o["error"] as? String {
            throw e == "device_flow_disabled" || e == "incorrect_client_credentials" ? Failure.notConfigured : Failure.failed(e)
        }
        guard let device = o["device_code"] as? String, let user = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.failed("GitHub sent something unexpected")
        }
        let interval = (o["interval"] as? Double) ?? Double(o["interval"] as? Int ?? 5)
        let expires = (o["expires_in"] as? Double) ?? Double(o["expires_in"] as? Int ?? 900)
        return Code(deviceCode: device, userCode: user, verificationURL: uri, interval: max(1, interval),
                    expiresAt: now.addingTimeInterval(expires))
    }

    /// Polls until the person has entered the code (the token), declined, or the code expired. `sleep` waits
    /// between polls (tests pass one that doesn't).
    public func token(for code: Code, now: @Sendable () -> Date = Date.init,
                      sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) async throws -> String {
        var interval = code.interval
        while true {
            try await sleep(interval)
            try Task.checkCancellation()
            if now() >= code.expiresAt { throw Failure.expired }
            let o = try await post("login/oauth/access_token", [
                ("client_id", clientID), ("device_code", code.deviceCode),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            if let token = o["access_token"] as? String, !token.isEmpty { return token }
            switch o["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = (o["interval"] as? Double) ?? Double(o["interval"] as? Int ?? Int(interval + 5))
            case "expired_token": throw Failure.expired
            case "access_denied": throw Failure.denied
            case "device_flow_disabled", "incorrect_client_credentials", "unsupported_grant_type": throw Failure.notConfigured
            case let e?: throw Failure.failed(e)
            case nil: throw Failure.failed("GitHub sent something unexpected")
            }
        }
    }
}
