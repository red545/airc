// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// MEM-3's exemption, as in Arc: sites people keep open for their notifications and calls (mail, calendars, chat,
/// calls, a few trackers) whose pinned tabs and Favorites never unload (Settings → General → "Keep chat and mail sites
/// loaded", on by default). Today tabs of these sites unload like any other.
///
/// A page matches by its site, the registrable domain of its host by the complete public suffix list (`BoostDomain`,
/// the rule Boosts and Chromium's site isolation use):
/// - a site entry ("slack.com") matches every page of that site ("acme.slack.com", "app.slack.com");
/// - a host entry ("mail.google.com") matches that host and the hosts beneath it, and nothing else of its site: Gmail
///   stays loaded, Google Search doesn't.
/// A name that only looks alike is another site ("slack.com.example.io" is example.io's, "notslack.com" its own), and
/// so is a tenant of a private suffix. Only http(s) pages match.
public enum KeepLoadedSites {
    /// The built-in list. Every entry is a site (a registrable domain) or a host beneath one (the tests hold it to that).
    public static let entries: [String] = [
        // Mail
        "mail.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com", "outlook.cloud.microsoft",
        "mail.proton.me", "app.fastmail.com", "mail.superhuman.com", "app.hey.com", "mail.zoho.com",
        // Calendars
        "calendar.google.com", "calendar.notion.so",
        // Chat and calls
        "slack.com", "discord.com", "web.whatsapp.com", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
        "messenger.com", "web.telegram.org", "chat.google.com", "meet.google.com", "messages.google.com",
        "app.element.io", "zulipchat.com",
        // Trackers people keep for their notifications
        "linear.app",
    ]

    /// The entries, by the site each one belongs to.
    static func index(_ entries: [String], suffixes: PublicSuffixList) -> [String: [String]] {
        var bySite: [String: [String]] = [:]
        for e in entries {
            guard let host = BoostDomain.normalize(e), let site = BoostDomain.key(forHost: host, suffixes: suffixes) else { continue }
            bySite[site, default: []].append(host)
        }
        return bySite
    }

    /// Whether a page at `url` stays loaded. `extra`: more entries (the scripted checks list a loopback host).
    public static func keepsLoaded(_ url: URL?, extra: [String] = [], suffixes: PublicSuffixList = .shared) -> Bool {
        guard let host = BoostDomain.webHost(of: url) else { return false }
        return keepsLoaded(host: host, extra: extra, suffixes: suffixes)
    }

    /// The same for a page's host.
    public static func keepsLoaded(host: String, extra: [String] = [], suffixes: PublicSuffixList = .shared) -> Bool {
        guard let h = BoostDomain.normalize(host), let site = BoostDomain.key(forHost: h, suffixes: suffixes) else { return false }
        let bySite = extra.isEmpty ? builtInIndex(suffixes) : index(entries + extra, suffixes: suffixes)
        guard let candidates = bySite[site] else { return false }
        return candidates.contains { $0 == site || h == $0 || h.hasSuffix("." + $0) }
    }

    /// The site of `url` if it's on the list (Settings and the checks show it); nil otherwise.
    public static func listedSite(_ url: URL?, extra: [String] = [], suffixes: PublicSuffixList = .shared) -> String? {
        guard keepsLoaded(url, extra: extra, suffixes: suffixes), let host = BoostDomain.webHost(of: url) else { return nil }
        return BoostDomain.key(forHost: host, suffixes: suffixes)
    }

    // The built-in entries' index for the last suffix list asked about (the app's, installed once at launch).
    nonisolated(unsafe) private static var cached: (list: PublicSuffixList, index: [String: [String]])?
    private static let lock = NSLock()

    private static func builtInIndex(_ suffixes: PublicSuffixList) -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached, c.list === suffixes { return c.index }
        let built = index(entries, suffixes: suffixes)
        cached = (suffixes, built)
        return built
    }
}
