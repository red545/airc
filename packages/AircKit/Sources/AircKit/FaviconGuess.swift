// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where a site's icon usually is, for items never loaded (the app's FaviconCache.guess): /favicon.ico on the page's
/// own origin, so a dev server at localhost:3000 is asked at localhost:3000. A default port (80 for http, 443 for
/// https) is left out, so a normal site's guess, and with it its cache key, is the same with or without one.
public enum FaviconGuess {
    public static func url(for pageURL: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let c = URLComponents(string: pageURL), let scheme = c.scheme, var host = c.host?.lowercased(),
              scheme.hasPrefix("http"), !host.isEmpty else { return nil }
        let port = c.port.flatMap { $0 == defaultPort(scheme) ? nil : $0 }
        if port == nil, let known = known(host: host, path: c.path, now: now, calendar: calendar) { return known }
        // An IPv6 literal keeps its brackets.
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")/favicon.ico"
    }

    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// Sites whose icon isn't at /favicon.ico. Calendar shows today's date (SB-13).
    private static func known(host: String, path: String, now: Date, calendar: Calendar) -> String? {
        switch host {
        case "calendar.google.com":
            let day = calendar.component(.day, from: now)
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
