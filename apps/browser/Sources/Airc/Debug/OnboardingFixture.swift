// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircImport
import Foundation

/// A synthetic Arc import for automated runs (`--script onboarding`): neutral demo profiles, Spaces, themes, pinned
/// trees, Favorites and one warning. Never the owner's data. Decoded through AircImport's own Codable types, so it is
/// exactly what `ArcImporter.plan` returns.
enum OnboardingFixture {
    static func plan() -> ImportPlan? { useBigPlan || LaunchOptions.current.script == "onboarding-e2e" ? bigPlan() : decode(json) }

    /// `--script importux`: onboarding (Airc menu → Import from Arc… included) reads the big plan. `onboarding-e2e`
    /// reads it from launch on, first run included.
    static var useBigPlan = false

    /// A real-size Arc (the owner's has 6 Spaces, 6 profiles and about 176 tabs; importux, 2026-11-06), all synthetic:
    /// 6 Spaces on 6 profiles, 175 pinned tabs on example.com hosts, folders nested three deep, long titles, emoji
    /// icons and a Space without one, 12 Favorites in one profile, Today tabs, a Space whose profile folder is missing
    /// from Arc's profile list, an unused profile, and one of each warning the import step explains.
    static func bigPlan() -> ImportPlan? { decode(bigJSON) }

    private static func decode(_ text: String) -> ImportPlan? {
        do {
            return try JSONDecoder().decode(ImportPlan.self, from: Data(text.utf8))
        } catch {
            print("[onboarding] fixture failed to decode: \(error)")
            return nil
        }
    }

    private static func gradient(_ colors: [(Double, Double, Double)], intensity: Double = 0.81, noise: Double = 0.25) -> String {
        let c = colors.map { #"{"red":\#($0.0),"green":\#($0.1),"blue":\#($0.2),"alpha":1}"# }.joined(separator: ",")
        return #"{"background":{"single":{"_0":{"style":{"color":{"_0":{"blendedGradient":{"_0":{"baseColors":[\#(c)],"overlayColors":[],"modifiers":{"intensityFactor":\#(intensity),"noiseFactor":\#(noise),"overlay":{"grain":{}}}}}}}}}}}}"#
    }

    private static func tab(_ id: String, _ url: String, _ title: String) -> String {
        #"{"tab":{"_0":{"id":"\#(id)","url":"\#(url)","pageTitle":"\#(title)","lastActiveAt":783100000}}}"#
    }

    private static func folder(_ id: String, _ title: String, _ children: [String]) -> String {
        #"{"folder":{"_0":{"id":"\#(id)","title":"\#(title)","children":[\#(children.joined(separator: ","))]}}}"#
    }

    private static func plain(_ id: String, _ url: String, _ title: String) -> String {
        #"{"id":"\#(id)","url":"\#(url)","pageTitle":"\#(title)","lastActiveAt":783100000}"#
    }

    private static func space(_ id: String, _ name: String, _ emoji: String, theme: String, profile: String, pinned: [String], today: [String]) -> String {
        #"{"id":"\#(id)","name":"\#(name)","emoji":"\#(emoji)","icon":{"emoji_v2":"\#(emoji)"},"theme":{"color":"8edcc0","colors":[],"raw":\#(theme)},"profileID":"\#(profile)","pinned":[\#(pinned.joined(separator: ","))],"today":[\#(today.joined(separator: ","))]}"#
    }

    /// Source IDs of the big plan's profiles, for the checks.
    enum Big {
        static let personal = "arc-profile:Default"
        static let work = "arc-profile:Profile 1"
        static let side = "arc-profile:Profile 2"
        static let family = "arc-profile:Profile 3"
        static let studio = "arc-profile:Profile 4"
        /// Used by a Space but missing from Arc's profile list.
        static let missing = "arc-profile:Profile 7"
        static let spaces = ["arc-space:big-personal", "arc-space:big-work", "arc-space:big-side", "arc-space:big-family",
                             "arc-space:big-studio", "arc-space:big-reading"]
    }

    static let bigJSON: String = {
        var n = 0
        func next() -> String { n += 1; return "big\(n)" }
        let topics = ["Quarterly planning", "Budget", "Roadmap", "Meeting notes", "Reading list", "Design review", "Invoices",
                      "Recipes", "Training plan", "Release checklist", "Interview loop", "Garden plan", "Trip ideas", "Weekly report",
                      "Style guide", "Customer research", "Onboarding doc", "Server dashboard", "Photo album", "Book club"]
        let long = " – the very long document title that keeps going well past the edge of the sidebar"
        func title(_ i: Int, _ space: String) -> String {
            let t = "\(topics[(i * 7 + space.count) % topics.count]) \(i + 1)"
            return i % 6 == 2 ? t + long : t
        }
        let hosts = ["example.com", "docs.example.com", "example.org", "notes.example.net", "example.net", "app.example.com"]
        func tabs(_ count: Int, _ space: String, from start: Int = 0) -> [String] {
            (start..<start + count).map { i in
                tab(next(), "https://\(hosts[i % hosts.count])/\(space.lowercased().filter(\.isLetter))/\(i)", title(i, space))
            }
        }
        func todays(_ count: Int, _ space: String) -> [String] {
            (0..<count).map { i in plain(next(), "https://\(hosts[(i + 2) % hosts.count])/today/\(i)", "Today: " + title(i + 3, space)) }
        }
        let spaces = [
            // 40 pinned: three folders deep, long titles, 12 Favorites in its profile.
            space("big-personal", "Personal", "🏡", theme: gradient([(0.62, 0.86, 0.93), (0.48, 0.60, 0.94)]), profile: "default",
                  pinned: tabs(4, "Personal") + [
                      folder(next(), "Trips", [
                          folder(next(), "Lisbon, March", tabs(3, "Lisbon", from: 4) + [folder(next(), "Day trips", tabs(4, "Day trips", from: 7))]),
                          folder(next(), "Kyoto someday", tabs(3, "Kyoto", from: 11)),
                      ]),
                  ] + tabs(26, "Personal", from: 14),
                  today: todays(5, "Personal")),
            space("big-work", "Work", "💼", theme: gradient([(0.97, 0.69, 0.52), (0.94, 0.54, 0.60)]), profile: "Profile 1",
                  pinned: [folder(next(), "Launch", tabs(6, "Launch")), folder(next(), "Hiring", tabs(5, "Hiring", from: 6))]
                      + tabs(34, "Work", from: 11),
                  today: todays(3, "Work")),
            space("big-side", "Side project with a name long enough to truncate", "🚀",
                  theme: gradient([(0.96, 0.85, 0.43), (0.61, 0.86, 0.54)]), profile: "Profile 2",
                  pinned: tabs(30, "Side"), today: []),
            space("big-family", "Family", "👨‍👩‍👧", theme: gradient([(0.95, 0.72, 0.80), (0.85, 0.66, 0.95)]), profile: "Profile 3",
                  pinned: [folder(next(), "School", tabs(8, "School"))] + tabs(12, "Family", from: 8), today: todays(2, "Family")),
            space("big-studio", "Studio", "🎨", theme: gradient([(0.73, 0.64, 0.95), (0.94, 0.64, 0.77)]), profile: "Profile 4",
                  pinned: tabs(25, "Studio"), today: []),
            // No icon, and its profile folder is missing from Arc's profile list.
            space("big-reading", "Reading", "•", theme: gradient([(0.70, 0.80, 0.74), (0.52, 0.66, 0.60)]), profile: "Profile 7",
                  pinned: tabs(15, "Reading"), today: []),
        ]
        let favoritesPersonal = (0..<12).map { i in plain(next(), "https://\(hosts[i % hosts.count])/favorite/\(i)", topics[i]) }
        let favoritesWork = (0..<8).map { i in plain(next(), "https://\(hosts[(i + 1) % hosts.count])/work-favorite/\(i)", topics[i + 5]) }
        let favoritesSide = (0..<3).map { i in plain(next(), "https://\(hosts[(i + 3) % hosts.count])/side-favorite/\(i)", topics[i + 9]) }
        let favorites = """
        "default":[\(favoritesPersonal.joined(separator: ","))],
        "Profile 1":[\(favoritesWork.joined(separator: ","))],
        "Profile 2":[\(favoritesSide.joined(separator: ","))]
        """
        let warnings = [("easel", "Skipped an Easel (Arc-only)."), ("note", "Skipped a Note (Arc-only)."), ("note", "Skipped a Note (Arc-only)."),
                        ("liveFolder", "Imported a live folder as a regular folder."), ("splitView", "Flattened a split view into individual tabs."),
                        ("missingProfile", "A referenced Chromium profile folder is missing.")]
            .map { #"{"code":"\#($0.0)","message":"\#($0.1)"}"# }
            + [#"{"code":"unsupportedItem","message":"Flattened or skipped an unsupported sidebar item.","kind":"tabGroup"}"#]
        return """
        {"profiles":[
          {"id":"default","directory":"Default","name":"Personal","isAvailable":true},
          {"id":"Profile 1","directory":"Profile 1","name":"Work","color":-12088065,"isAvailable":true},
          {"id":"Profile 2","directory":"Profile 2","name":"Side project","color":-756480,"isAvailable":true},
          {"id":"Profile 3","directory":"Profile 3","name":"Family","isAvailable":true},
          {"id":"Profile 4","directory":"Profile 4","name":"Studio","isAvailable":true},
          {"id":"Profile 5","directory":"Profile 5","name":"Old job","isAvailable":true}],
         "spaces":[\(spaces.joined(separator: ","))],
         "favorites":{\(favorites)},
         "warnings":[\(warnings.joined(separator: ","))]}
        """
    }()

    static let json: String = {
        let spaces = [
            space("demo-personal", "Personal", "🏡", theme: gradient([(0.62, 0.86, 0.93), (0.48, 0.60, 0.94)]), profile: "default",
                  pinned: [
                      tab("p1", "https://docs.google.com/spreadsheets/d/demo", "Budget 2027 – Google Sheets"),
                      folder("f1", "Lisbon, March", [
                          tab("p2", "https://www.google.com/travel/flights", "Flights – compare dates"),
                          tab("p3", "https://www.airbnb.com/rooms/demo", "Alfama loft · Airbnb"),
                      ]),
                      tab("p4", "https://en.wikipedia.org/wiki/Lisbon", "Lisbon – Wikipedia"),
                      tab("p5", "https://www.youtube.com/watch?v=demo", "Lo-fi beats to focus to"),
                  ],
                  today: [plain("t1", "https://en.wikipedia.org/wiki/Calm_technology", "Calm technology – Wikipedia")]),
            space("demo-studio", "Studio", "🎨", theme: gradient([(0.73, 0.64, 0.95), (0.94, 0.64, 0.77)]), profile: "default",
                  pinned: [tab("p6", "https://www.figma.com/files/demo", "Press kit – Figma"),
                           tab("p7", "https://en.wikipedia.org/wiki/Color_theory", "Color theory – Wikipedia")],
                  today: []),
            space("demo-work", "Work", "💼", theme: gradient([(0.97, 0.69, 0.52), (0.94, 0.54, 0.60)]), profile: "Profile 1",
                  pinned: [
                      tab("p8", "https://www.notion.so/demo-roadmap", "Q4 roadmap"),
                      folder("f2", "Launch", [
                          tab("p9", "https://linear.app/demo/launch", "Launch checklist"),
                          tab("p10", "https://www.figma.com/files/demo-press", "Press kit – Figma"),
                      ]),
                      tab("p11", "https://github.com/acme/web", "acme/web"),
                  ],
                  today: [plain("t2", "https://linear.app/demo/issue/AIR-412", "AIR-412 Sidebar springs")]),
            space("demo-launch", "Launch", "🚀", theme: gradient([(0.96, 0.85, 0.43), (0.61, 0.86, 0.54)]), profile: "Profile 2",
                  pinned: [tab("p12", "https://www.producthunt.com/", "Product Hunt"),
                           tab("p13", "https://news.ycombinator.com/", "Hacker News")],
                  today: []),
        ]
        let favorites = """
        "default":[\(plain("v1", "https://mail.google.com/mail/u/0/", "Inbox – Gmail")),\(plain("v2", "https://calendar.google.com/", "Calendar")),\(plain("v3", "https://www.google.com/maps", "Google Maps")),\(plain("v4", "https://www.youtube.com/", "YouTube"))],
        "Profile 1":[\(plain("v5", "https://mail.google.com/mail/u/1/", "Inbox – Gmail")),\(plain("v6", "https://calendar.google.com/calendar/u/1/", "Calendar")),\(plain("v7", "https://app.slack.com/", "Slack")),\(plain("v8", "https://linear.app/", "Linear"))],
        "Profile 2":[\(plain("v9", "https://www.figma.com/", "Figma")),\(plain("v10", "https://www.notion.so/", "Notion"))]
        """
        return """
        {"profiles":[
          {"id":"default","directory":"Default","name":"Personal","isAvailable":true},
          {"id":"Profile 1","directory":"Profile 1","name":"Acme","color":-12088065,"isAvailable":true},
          {"id":"Profile 2","directory":"Profile 2","name":"Launch","color":-756480,"isAvailable":true}],
         "spaces":[\(spaces.joined(separator: ","))],
         "favorites":{\(favorites)},
         "warnings":[{"code":"splitView","message":"Flattened a split view into individual tabs."}]}
        """
    }()
}
#endif
