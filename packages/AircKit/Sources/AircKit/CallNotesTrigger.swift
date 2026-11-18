// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Settings › Calendar › "Start Granola notes when a call starts" (docs/user/call-notes.md): when a tab on a known call
/// site starts using the microphone, the app asks a note taker to start once for that call. This is the decision only;
/// the app feeds it each tab's microphone changes (both engines' capture state) and opens the URL it returns.
///
/// Once per call: a call is its site plus its meeting code where the address has one (Meet, Zoom, Whereby, Jitsi), else
/// the site. A microphone start on a call that had the microphone on within `rejoinWindow` (a rejoin, a second tab, a
/// device switch) asks nothing. Private windows never ask, and leave nothing behind.
public struct CallNotesTrigger {
    public static let rejoinWindow: TimeInterval = 5 * 60

    /// Granola's undocumented deep link (verified in Granola 7.786.3's app bundle; artifacts/granola/bundle-findings.md):
    /// a new note that starts transcribing. `creation_source` is stored on the note; "airc" keeps Granola's own stats apart.
    public static let granolaURL = URL(string: "granola://new-document?creation_source=airc")!

    private var micOn: [AnyHashable: String] = [:]   // tab → its call key, while that tab has the microphone on
    private var lastActive: [String: Date] = [:]     // call key → last moment a tab of it had the microphone

    public init() {}

    /// A tab's microphone state now. Returns true when a note should start. `tab` is any stable identity of the tab.
    public mutating func microphone(_ on: Bool, tab: AnyHashable, url: URL?, isPrivate: Bool, enabled: Bool,
                                    now: Date = Date()) -> Bool {
        prune(now)
        guard !isPrivate, let key = Self.callKey(url) else {
            if let old = micOn.removeValue(forKey: tab) { lastActive[old] = now }
            return false
        }
        if !on {
            if let old = micOn.removeValue(forKey: tab) { lastActive[old] = now }
            return false
        }
        if let old = micOn[tab] {
            if old == key { lastActive[key] = now; return false }   // still on; a repeat notice (zoom, security…)
            lastActive[old] = now                                  // the tab moved to another call with the mic on
        }
        micOn[tab] = key
        let recent = lastActive[key].map { now.timeIntervalSince($0) < Self.rejoinWindow } ?? false
            || micOn.contains { $0.key != tab && $0.value == key }
        lastActive[key] = now
        return enabled && !recent
    }

    /// The tab closed or went away.
    public mutating func forget(tab: AnyHashable, now: Date = Date()) {
        if let old = micOn.removeValue(forKey: tab) { lastActive[old] = now }
    }

    private mutating func prune(_ now: Date) {
        lastActive = lastActive.filter { now.timeIntervalSince($0.value) < Self.rejoinWindow }
    }

    // MARK: Call sites

    /// The call's identity on a known call site's page, or nil for any other page.
    public static func callKey(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard let site = site(of: host) else { return nil }
        let parts = url.path.split(separator: "/").map { $0.lowercased() }
        switch site {
        case .meet, .whereby, .jitsi:
            if let code = parts.first, !code.isEmpty, !Self.nonRoomPaths.contains(code) { return "\(host)/\(code)" }
        case .zoom:
            if let id = parts.first(where: { $0.count >= 9 && $0.allSatisfy(\.isNumber) }) { return "zoom/\(id)" }
        case .other:
            break
        }
        return host
    }

    private enum Site { case meet, zoom, whereby, jitsi, other }
    private static let nonRoomPaths: Set<String> = ["landing", "new", "_meet", "lookup", "user", "org", "static"]

    private static func site(of host: String) -> Site? {
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "meet.google.com" { return .meet }
        if under("zoom.us") || under("zoom.com") || under("zoomgov.com") { return .zoom }
        if under("whereby.com") { return .whereby }
        if host == "meet.jit.si" || host == "8x8.vc" { return .jitsi }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) { return .other }
        if under("webex.com") || host == "app.gather.town" || host == "app.around.co" || host == "riverside.fm" { return .other }
        return nil
    }
}
