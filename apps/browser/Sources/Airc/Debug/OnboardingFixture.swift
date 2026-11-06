// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircImport
import Foundation

/// A synthetic Arc import for automated runs (`--script onboarding`): neutral demo profiles, Spaces, themes, pinned
/// trees, Favorites and one warning. Never the owner's data. Decoded through AircImport's own Codable types, so it is
/// exactly what `ArcImporter.plan` returns.
enum OnboardingFixture {
    static func plan() -> ImportPlan? {
        do {
            return try JSONDecoder().decode(ImportPlan.self, from: Data(json.utf8))
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
