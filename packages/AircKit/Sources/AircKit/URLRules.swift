// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// URL helpers: what the user typed, what the sidebar shows, and when a pinned tab has drifted.
/// Ported from the Airc Chrome extension's `urls.ts`.
public enum URLRules {
    public static let newTabURL = "about:blank"

    public static func isNewTab(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return true }
        return url == "about:blank" || url == "chrome://newtab/" || url == "chrome://new-tab-page/"
    }

    /// SB-2: the URL field shows the host only, with `www.` dropped.
    public static func displayHost(_ url: String) -> String {
        guard let u = URLComponents(string: url), let host = u.host, !host.isEmpty else {
            if isNewTab(url) { return "" }
            return url
        }
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        if isLocalDev(url), let port = u.port { return "\(h):\(port)" }
        return h
    }

    /// "github.com/foo" style label.
    public static func displayURL(_ url: String) -> String {
        guard let u = URLComponents(string: url), let host = u.host else { return url }
        var h = host
        if h.hasPrefix("www.") { h.removeFirst(4) }
        if let port = u.port { h += ":\(port)" }
        var path = u.path
        if path == "/" { path = "" }
        if path.hasSuffix("/") { path.removeLast() }
        return h + path
    }

    public static func isLocalDev(_ url: String) -> Bool {
        guard let h = URLComponents(string: url)?.host?.lowercased() else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "0.0.0.0" || h.hasSuffix(".localhost")
    }

    /// Turns what the user typed into a URL, or nil when it should be a search.
    public static func normalizeInput(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespaces) == nil else { return nil }
        if s.range(of: #"^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:\d+)?([/?#].*)?$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: "http://" + s) != nil ? "http://" + s : nil
        }
        if s.range(of: #"^(https?|file|ftp|about|mailto|data):"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: s) != nil ? s : nil
        }
        if s.range(of: #"^[^/:@]+\.[a-z]{2,}(:\d+)?([/?#].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: "https://" + s) != nil ? "https://" + s : nil
        }
        return nil
    }

    /// What Enter does with typed text: open it, or search for it with the profile's engine.
    public static func resolve(_ input: String, engine: SearchEngine) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = normalizeInput(s), let url = URL(string: u) { return url }
        return engine.searchURL(for: s)
    }

    /// SB-31: true when a pinned tab or Favorite has wandered away from its saved URL. A
    /// trailing slash, fragment or Google account index doesn't count; leaving the page does.
    public static func isDrifted(saved: String, current: String) -> Bool {
        if saved == current { return false }
        guard let a = URLComponents(string: stripGoogleAccount(saved)),
              let b = URLComponents(string: stripGoogleAccount(current)) else { return saved != current }
        if a.scheme?.lowercased() != b.scheme?.lowercased() || a.host?.lowercased() != b.host?.lowercased()
            || a.port != b.port {
            return true
        }
        let pa = a.path.trimmingSuffix("/")
        let pb = b.path.trimmingSuffix("/")
        if isGoogleAccountHost(a.host ?? "") {
            // Google apps are single-page apps under one path prefix (Gmail #inbox → #label).
            return !(pa == pb || pb.hasPrefix(pa + "/"))
        }
        if pa != pb { return true }
        // A saved query is part of the identity (youtube.com/watch?v=…).
        return (a.query ?? "") != "" && a.query != b.query
    }

    static let googleAccountHosts: Set<String> = [
        "mail.google.com", "calendar.google.com", "drive.google.com", "docs.google.com", "meet.google.com",
        "chat.google.com", "keep.google.com", "contacts.google.com", "photos.google.com",
        "gemini.google.com", "myaccount.google.com", "admin.google.com", "analytics.google.com",
    ]

    static func isGoogleAccountHost(_ host: String) -> Bool { googleAccountHosts.contains(host.lowercased()) }

    /// Removes `/u/<n>/` and `authuser=` from Google app URLs.
    public static func stripGoogleAccount(_ url: String) -> String {
        guard var c = URLComponents(string: url), let host = c.host, isGoogleAccountHost(host) else { return url }
        c.queryItems = c.queryItems?.filter { $0.name != "authuser" }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        if let r = c.path.range(of: #"/u/[^/?#]+(?=/|$)"#, options: .regularExpression) {
            c.path.removeSubrange(r)
            if c.path.isEmpty { c.path = "/" }
        }
        return c.string ?? url
    }

    /// SB-13: the unread count a page reports in its title: "Inbox (3) - Gmail", "(12) X".
    public static func unreadCount(fromTitle title: String) -> Int? {
        let patterns = [#"^\((\d+)\+?\)\s"#, #"\((\d+)\)"#]
        for p in patterns {
            if let r = title.range(of: p, options: .regularExpression) {
                let digits = title[r].filter(\.isNumber)
                if let n = Int(digits), n > 0 { return n }
            }
        }
        return nil
    }

    /// Hosts whose Favorites show an unread dot (Arc's TopApp list, SB-13).
    public static func showsUnreadBadge(_ url: String) -> Bool {
        let h = displayHost(url)
        return ["mail.google.com", "app.slack.com", "x.com", "twitter.com", "web.whatsapp.com",
                "linkedin.com", "outlook.office.com", "outlook.live.com"].contains(h)
    }

    public static func isCalendar(_ url: String) -> Bool { displayHost(url) == "calendar.google.com" }

    /// Google's per-day Calendar logo, so a Calendar tile shows today's date (SB-13).
    public static func calendarIconURL(day: Int) -> String {
        "https://ssl.gstatic.com/calendar/images/dynamiclogo_2020q4/calendar_\(day)_2x.png"
    }

    /// Markdown link for ⌥⇧⌘C.
    public static func markdownLink(title: String, url: String) -> String {
        let t = title.isEmpty ? displayURL(url) : title
        return "[\(t.replacingOccurrences(of: "]", with: "\\]"))](\(url))"
    }
}

extension String {
    func trimmingSuffix(_ suffix: Character) -> String {
        var s = self
        while s.last == suffix { s.removeLast() }
        return s
    }
}
