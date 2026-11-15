// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A synthetic GitHub for tests and scripted checks (like SyncCloudMock): the few REST endpoints live folders use,
/// with GitHub's ETags, pagination, rate limit, tokens and device flow, and no network. Unit tests send requests to
/// it directly (`LiveHTTPClient`); the app's check serves `respond` on a loopback port. Never used by the app itself.
public final class FakeGitHub: LiveHTTPClient, @unchecked Sendable {
    public struct Pull: Sendable {
        public var repo: String
        public var number: Int
        public var title: String
        public var author: String
        public var draft = false
        public var labels: [String] = []
        public var reviewers: [String] = []
        public var state = "open"
        public var merged = false
        public var updated: Date
    }

    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        public init(status: Int, headers: [String: String], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    private let lock = NSLock()
    private var pulls: [Pull] = []
    private var clock: Date
    /// Where the pull requests' pages are ("https://github.com" by default; a check's loopback server for the app).
    public var webBase: String
    /// Items per page, whatever the request asks (small, to test pagination).
    public var pageSize: Int
    /// Token → login.
    private var tokens: [String: String] = [:]
    /// Unauthenticated requests left before the rate limit; nil = unlimited.
    private var remaining: Int?
    private var resetAt: Date
    private var offline = false
    private var delay: TimeInterval = 0
    private var failNextPage: Int?
    private var log: [(path: String, query: String, token: String?, etag: String?, status: Int)] = []
    // Device flow: polls answered "authorization_pending" before the token.
    private var devicePending = 0
    private var deviceToken: (token: String, login: String)?
    private var deviceDenied = false

    public init(webBase: String = "https://github.com", pageSize: Int = 30, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.webBase = webBase
        self.pageSize = pageSize
        clock = now
        resetAt = now.addingTimeInterval(3600)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Scenario

    /// Opens a pull request (`updated` defaults to a moment after the previous change).
    @discardableResult
    public func open(_ repo: String, _ number: Int, _ title: String, author: String = "octo", draft: Bool = false,
                     labels: [String] = [], reviewers: [String] = []) -> Int {
        locked {
            clock = clock.addingTimeInterval(60)
            pulls.append(Pull(repo: repo, number: number, title: title, author: author, draft: draft, labels: labels,
                              reviewers: reviewers, updated: clock))
            return number
        }
    }

    public func retitle(_ repo: String, _ number: Int, _ title: String) { change(repo, number) { $0.title = title } }
    public func merge(_ repo: String, _ number: Int) { change(repo, number) { $0.state = "closed"; $0.merged = true } }
    public func close(_ repo: String, _ number: Int) { change(repo, number) { $0.state = "closed" } }
    public func setDraft(_ repo: String, _ number: Int, _ draft: Bool) { change(repo, number) { $0.draft = draft } }

    private func change(_ repo: String, _ number: Int, _ edit: (inout Pull) -> Void) {
        locked {
            clock = clock.addingTimeInterval(60)
            guard let i = pulls.firstIndex(where: { $0.repo == repo && $0.number == number }) else { return }
            edit(&pulls[i])
            pulls[i].updated = clock
        }
    }

    public func addToken(_ token: String, login: String) { locked { tokens[token] = login } }
    /// The token stops working (expired or revoked): GitHub answers 401.
    public func revokeToken(_ token: String) { locked { tokens[token] = nil } }
    /// Unauthenticated requests left (GitHub's 60 an hour), nil for no limit.
    public func setRateLimit(remaining: Int?, resetAt: Date) { locked { self.remaining = remaining; self.resetAt = resetAt } }
    public func setOffline(_ on: Bool) { locked { offline = on } }
    /// Seconds before each answer (a request in flight long enough to delete its folder meanwhile).
    public func setDelay(_ seconds: TimeInterval) { locked { delay = seconds } }
    /// The next request for this page number fails with a 502.
    public func failPage(_ page: Int?) { locked { failNextPage = page } }
    public func setDeviceFlow(pendingPolls: Int, token: String, login: String, denied: Bool = false) {
        locked {
            devicePending = pendingPolls
            deviceToken = (token, login)
            deviceDenied = denied
        }
    }

    public var requestCount: Int { locked { log.count } }
    /// "path?query → status" for every request so far.
    public var requests: [String] { locked { log.map { "\($0.path)?\($0.query) → \($0.status)" } } }
    public var conditionalHits: Int { locked { log.filter { $0.status == 304 }.count } }
    public var isOffline: Bool { locked { offline } }
    public var answerDelay: TimeInterval { locked { delay } }

    // MARK: LiveHTTPClient

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isOffline { throw URLError(.notConnectedToInternet) }
        let wait = answerDelay
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        try Task.checkCancellation()
        let url = request.url!
        let r = respond(method: request.httpMethod ?? "GET", path: url.path, query: url.query ?? "",
                        headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Data())
        let response = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (r.body, response)
    }

    // MARK: The API

    /// One answer, as GitHub would give it. `query` is the URL's percent-encoded query.
    public func respond(method: String, path: String, query: String, headers: [String: String], body: Data) -> Response {
        locked {
            let h = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            let token = h["authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "").replacingOccurrences(of: "token ", with: "") }
            let r = route(method: method, path: path, query: query, token: token, ifNoneMatch: h["if-none-match"], body: body)
            log.append((path, query, token, h["if-none-match"], r.status))
            return r
        }
    }

    private func json(_ status: Int, _ object: Any, _ headers: [String: String] = [:]) -> Response {
        var hs = headers
        hs["Content-Type"] = "application/json; charset=utf-8"
        return Response(status: status, headers: hs,
                        body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    private func form(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (String(data: body, encoding: .utf8) ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func route(method: String, path: String, query: String, token: String?, ifNoneMatch: String?, body: Data) -> Response {
        // Device flow, on the website.
        if method == "POST", path.hasSuffix("/login/device/code") {
            guard form(body)["client_id"].map({ !$0.isEmpty }) == true else { return json(200, ["error": "incorrect_client_credentials"]) }
            return json(200, ["device_code": "fake-device", "user_code": "WDJB-MJHT", "verification_uri": webBase + "/login/device",
                              "expires_in": 900, "interval": 5])
        }
        if method == "POST", path.hasSuffix("/login/oauth/access_token") {
            if deviceDenied { return json(200, ["error": "access_denied"]) }
            if devicePending > 0 { devicePending -= 1; return json(200, ["error": "authorization_pending"]) }
            guard let t = deviceToken else { return json(200, ["error": "expired_token"]) }
            tokens[t.token] = t.login
            return json(200, ["access_token": t.token, "token_type": "bearer", "scope": "repo,read:org"])
        }

        // The API: tokens, then the rate limit.
        var login: String?
        if let token, !token.isEmpty {
            guard let l = tokens[token] else { return json(401, ["message": "Bad credentials"]) }
            login = l
        } else if let left = remaining {
            let limitHeaders = ["x-ratelimit-limit": "60", "x-ratelimit-remaining": String(max(0, left - 1)),
                                "x-ratelimit-reset": String(Int(resetAt.timeIntervalSince1970))]
            if left <= 0 {
                return json(403, ["message": "API rate limit exceeded for 127.0.0.1."],
                            limitHeaders.merging(["x-ratelimit-remaining": "0"]) { $1 })
            }
            remaining = left - 1
        }
        let params = Dictionary(query.split(separator: "&").map { pair -> (String, String) in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
            return (kv[0], kv.count > 1 ? kv[1] : "")
        }, uniquingKeysWith: { a, _ in a })
        let page = max(1, Int(params["page"] ?? "1") ?? 1)
        if failNextPage == page {
            failNextPage = nil
            return json(502, ["message": "Server Error"])
        }

        if path.hasSuffix("/user") {
            guard let login else { return json(401, ["message": "Requires authentication"]) }
            return json(200, ["login": login, "id": 1])
        }

        let parts = path.split(separator: "/").map(String.init)
        var list: [Pull]
        var search = false
        if let i = parts.firstIndex(of: "repos"), parts.count >= i + 4, parts[i + 3] == "pulls" {
            let repo = parts[i + 1] + "/" + parts[i + 2]
            if repo.hasPrefix("private/") && login == nil { return json(404, ["message": "Not Found"]) }
            list = pulls.filter { $0.repo.lowercased() == repo.lowercased() && $0.state == "open" }
        } else if path.hasSuffix("/search/issues") {
            guard login != nil else { return json(401, ["message": "Requires authentication"]) }
            search = true
            list = pulls
            for term in tokenize(params["q"] ?? "") {
                let t = term.lowercased()
                if t == "is:open" { list = list.filter { $0.state == "open" } }
                else if t == "author:@me" { list = list.filter { $0.author == login } }
                else if t == "review-requested:@me" { list = list.filter { $0.reviewers.contains(login!) } }
                else if t == "involves:@me" { list = list.filter { $0.author == login || $0.reviewers.contains(login!) } }
                else if t.hasPrefix("author:") { let a = String(t.dropFirst(7)); list = list.filter { $0.author.lowercased() == a } }
                else if t.hasPrefix("repo:") { let r = String(t.dropFirst(5)); list = list.filter { $0.repo.lowercased() == r } }
                else if t.hasPrefix("label:") {
                    let l = String(term.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
                    list = list.filter { $0.labels.map { $0.lowercased() }.contains(l) }
                } else if t == "draft:false" { list = list.filter { !$0.draft } }
            }
        } else {
            return json(404, ["message": "Not Found"])
        }
        list.sort { ($0.updated, $0.number) > ($1.updated, $1.number) }

        let start = (page - 1) * pageSize
        let slice = start < list.count ? Array(list[start..<min(list.count, start + pageSize)]) : []
        let rows = slice.map { encode($0, search: search) }
        let object: Any = search ? ["total_count": list.count, "incomplete_results": false, "items": rows] : rows
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        let etag = "W/\"\(Self.fnv(data))\""
        var headers = ["ETag": etag]
        if start + pageSize < list.count {
            var q = params
            q["page"] = String(page + 1)
            let next = q.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
                .joined(separator: "&")
            headers["Link"] = "<\(apiBase(path))\(path)?\(next)>; rel=\"next\""
        }
        if ifNoneMatch == etag { return Response(status: 304, headers: headers, body: Data()) }
        headers["Content-Type"] = "application/json; charset=utf-8"
        return Response(status: 200, headers: headers, body: data)
    }

    /// The API's base for Link headers: set by the server that serves this fake ("" keeps links relative to the host).
    public var apiOrigin = "https://api.github.com"
    private func apiBase(_ path: String) -> String { apiOrigin }

    private func tokenize(_ q: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in q {
            if ch == "\"" { quoted.toggle(); cur.append(ch) }
            else if ch == " " && !quoted { if !cur.isEmpty { out.append(cur) }; cur = "" }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func encode(_ p: Pull, search: Bool) -> [String: Any] {
        let f = ISO8601DateFormatter()
        var o: [String: Any] = [
            "number": p.number, "title": p.title, "html_url": "\(webBase)/\(p.repo)/pull/\(p.number)", "state": p.state,
            "draft": p.draft, "user": ["login": p.author], "labels": p.labels.map { ["name": $0] },
            "updated_at": f.string(from: p.updated),
        ]
        let mergedAt: Any = p.merged ? f.string(from: p.updated) as Any : NSNull()
        if search {
            o["repository_url"] = "\(apiOrigin)/repos/\(p.repo)"
            o["pull_request"] = ["url": "\(apiOrigin)/repos/\(p.repo)/pulls/\(p.number)", "merged_at": mergedAt] as [String: Any]
        } else {
            o["requested_reviewers"] = p.reviewers.map { ["login": $0] }
            o["merged_at"] = mergedAt
            o["base"] = ["repo": ["full_name": p.repo]]
        }
        return o
    }

    static func fnv(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
