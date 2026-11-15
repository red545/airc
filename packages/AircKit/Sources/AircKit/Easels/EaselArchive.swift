// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// easelall (parity N08, Arc's Library card "Your Easels are yours to keep" › Export All Easels): every Easel as a web
// page, in one ZIP named as Arc named it ("Airc Easels - 2026-11-14 21.55"):
//
//     <archive>/index.html                 the list of the Easels, each a link to its page
//     <archive>/README.md                  how to open the archive and put it online, and the export log
//     <archive>/<Easel>/index.html         one Easel, exactly as Export as Web Page… writes it (EaselHTML)
//     <archive>/<Easel>/easel.json
//     <archive>/<Easel>/assets/<sha256>.<ext>
//
// Each Easel's folder is self-contained (its own pictures), so it can be copied out on its own. Folder names are
// EaselExport.fileName's, made unique the way a Mac compares names (case and Unicode form ignored): "Trip", "Trip 2".
// The ZIP is written to the file as it goes (ZipFileWriter), so a thousand Easels never sit in memory at once.

public enum EaselArchive {
    /// Arc's archive name ("Arc Easels - %@", the date as yyyy-MM-dd HH.mm), with Airc's name.
    public static func name(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "Airc Easels - " + f.string(from: date)
    }

    /// What happened to one Easel (the export log, the list page, the finished toast).
    public struct Entry: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            /// In the archive; `missing` pictures and `leftOut` items couldn't go (EaselPublic.Report).
            case saved(missing: Int, leftOut: Int)
            /// Nothing on it: not in the archive.
            case empty
            /// Couldn't be read or written: not in the archive.
            case failed
        }
        public var title: String
        /// Its folder in the archive (nil when it isn't in it).
        public var folder: String?
        public var items: Int
        public var pictures: Int
        public var shared: Bool
        public var outcome: Outcome
        public var isSaved: Bool { if case .saved = outcome { true } else { false } }
    }

    /// Unique folder names for one archive.
    public struct Names {
        private var taken: Set<String>
        public init() { taken = [Self.key("index.html"), Self.key("README.md")] }

        static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

        /// `title`'s folder name: EaselExport.fileName, then " 2", " 3"… while it's taken.
        public mutating func take(_ title: String) -> String {
            let base = EaselExport.fileName(title)
            var name = base, n = 1
            while taken.contains(Self.key(name)) {
                n += 1
                name = "\(base) \(n)"
            }
            taken.insert(Self.key(name))
            return name
        }
    }

    /// Writes one archive: `add` each Easel (or `skip` it), then `finish`.
    public final class Writer {
        public let root: String
        public private(set) var entries: [Entry] = []
        private let zip: ZipFileWriter
        private var names = Names()
        private let date: Date

        /// A new archive at `url` whose entries are under `root` (the archive's name).
        public init(url: URL, root: String, date: Date = Date()) throws {
            self.root = EaselExport.fileName(root)
            self.date = date
            zip = try ZipFileWriter(url: url, date: date)
        }

        public var size: UInt64 { zip.size }

        /// One Easel's folder: index.html, easel.json and its pictures (`pictures` holds every name in `easel.assets`).
        /// An Easel with no blocks is logged as empty and gets no folder.
        @discardableResult
        public func add(_ easel: EaselPublic, pictures: [String: Data], report: EaselPublic.Report = .init(), shared: Bool = false) throws -> Entry {
            var e = Entry(title: easel.displayTitle, folder: nil, items: easel.blocks.count, pictures: easel.assets.count, shared: shared,
                          outcome: .saved(missing: report.picturesMissing, leftOut: report.leftOut))
            guard !easel.blocks.isEmpty else {
                e.outcome = .empty
                entries.append(e)
                return e
            }
            // Every picture first: a missing one fails this Easel before anything of it is written.
            let files = try easel.assets.map { a -> (String, Data) in
                guard let d = pictures[a.name], EaselPublic.pictureName(d) == a.name else { throw EaselExport.ExportError.picture(a.name) }
                return (a.name, d)
            }
            let json = try easel.encoded()
            let folder = names.take(easel.title)
            let dir = "\(root)/\(folder)"
            try zip.add("\(dir)/index.html", Data(EaselHTML.page(easel, asset: { "assets/\($0)" }).utf8))
            try zip.add("\(dir)/easel.json", json)
            for (name, d) in files { try zip.add("\(dir)/assets/\(name)", d) }
            e.folder = folder
            entries.append(e)
            return e
        }

        /// An Easel that couldn't be read (or was empty), for the log.
        public func skip(title: String, outcome: Entry.Outcome = .failed) {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(title: t.isEmpty ? EaselURL.untitled : t, folder: nil, items: 0, pictures: 0, shared: false, outcome: outcome))
        }

        /// The list page and the README, then the ZIP's directory. `dateText` is how the pages say the date.
        public func finish(dateText: String? = nil) throws {
            let when = dateText ?? date.formatted(date: .long, time: .omitted)
            try zip.add("\(root)/index.html", Data(EaselArchive.listPage(entries, dateText: when).utf8))
            try zip.add("\(root)/README.md", Data(EaselArchive.readme(entries, dateText: when).utf8))
            try zip.finish()
        }

        /// Stops without finishing (the caller removes the file).
        public func abandon() { zip.abandon() }
    }

    /// "3 Easels", "1 Easel".
    static func count(_ n: Int) -> String { n == 1 ? "1 Easel" : "\(n) Easels" }

    /// A folder's address from the list page: each character that means something in a URL escaped.
    static func href(_ folder: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;%")
        return (folder.addingPercentEncoding(withAllowedCharacters: allowed) ?? folder) + "/index.html"
    }

    /// The archive's index.html: its Easels, each a card linking to its page; nothing from the web.
    public static func listPage(_ entries: [Entry], dateText: String) -> String {
        let saved = entries.filter(\.isSaved)
        let cards = saved.compactMap { e -> String? in
            guard let folder = e.folder else { return nil }
            var meta = [e.items == 1 ? "1 item" : "\(e.items) items"]
            if e.pictures > 0 { meta.append(e.pictures == 1 ? "1 picture" : "\(e.pictures) pictures") }
            let badge = e.shared ? " <span class=\"badge\">Shared</span>" : ""
            return "<li><a class=\"card\" href=\"\(EaselHTML.esc(href(folder)))\"><span class=\"t\">\(EaselHTML.esc(e.title))\(badge)</span>" +
                "<span class=\"m\">\(meta.joined(separator: " · "))</span></a></li>"
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Airc">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src * file: data:">
        <meta name="referrer" content="no-referrer">
        <title>Your Easels</title>
        <style>
        body { margin: 0; padding: 32px 16px 48px; background: #ebe8e4; color: rgb(20 17 15 / 0.92);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
        main { max-width: 960px; margin: 0 auto; }
        h1 { margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.02em; }
        .note { margin: 6px 0 24px; font-size: 13px; color: rgb(20 17 15 / 0.5); }
        ul { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
        .card { display: flex; flex-direction: column; gap: 4px; padding: 16px; border-radius: 12px; background: #fff; color: inherit;
          text-decoration: none; box-shadow: 0 0 0 1px rgb(20 17 15 / 0.08); }
        .card:hover { box-shadow: 0 0 0 1px rgb(20 17 15 / 0.2), 0 2px 8px rgb(0 0 0 / 0.06); }
        .t { font-size: 15px; font-weight: 600; overflow-wrap: anywhere; }
        .m { font-size: 12px; color: rgb(20 17 15 / 0.5); }
        .badge { margin-left: 6px; padding: 1px 6px; border-radius: 6px; font-size: 11px; font-weight: 500; background: rgb(20 17 15 / 0.07); }
        </style>
        </head>
        <body>
        <main>
        <h1>Your Easels</h1>
        <p class="note">\(count(saved.count)), saved from Airc on \(EaselHTML.esc(dateText)). Open one to see it.</p>
        <ul>
        \(cards.joined(separator: "\n"))
        </ul>
        </main>
        </body>
        </html>

        """
    }

    /// The archive's README.md: opening it, putting it online, what's inside, and the export log.
    public static func readme(_ entries: [Entry], dateText: String) -> String {
        func line(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        let log = entries.map { e -> String in
            switch e.outcome {
            case .saved(let missing, let leftOut):
                var but: [String] = []
                if missing > 0 { but.append(missing == 1 ? "1 picture couldn’t be read and is left out" : "\(missing) pictures couldn’t be read and are left out") }
                if leftOut > 0 { but.append(leftOut == 1 ? "1 item made by a newer Airc is left out" : "\(leftOut) items made by a newer Airc are left out") }
                let folder = e.folder.map { " (`\(line($0))/`)" } ?? ""
                return but.isEmpty ? "- ✅ \(line(e.title)): saved\(folder)" : "- ⚠️ \(line(e.title)): saved\(folder), but \(but.joined(separator: " and "))"
            case .empty: return "- \(line(e.title)): empty, so it isn’t in this archive"
            case .failed: return "- ❌ \(line(e.title)): couldn’t be read, so it isn’t in this archive"
            }
        }
        let saved = entries.filter(\.isSaved).count
        return """
        # Your Easels

        \(count(saved)), saved from Airc on \(line(dateText)).

        ## Opening them

        Open `index.html` to see all your Easels, or the `index.html` in an Easel's folder to see just that one. Everything \
        they show is in this folder, so they open without an internet connection, in any browser. Links on them open the \
        sites they point to.

        ## Putting them online

        Upload this whole folder to anything that hosts plain web pages, such as GitHub Pages, Netlify or Cloudflare Pages. \
        There's nothing to build. To keep them private instead, send the ZIP itself.

        ## What's inside

        - `index.html`: the list of your Easels.
        - `<Easel name>/index.html`: one Easel as a web page.
        - `<Easel name>/easel.json`: the same Easel as data, for anything you want to make with it.
        - `<Easel name>/assets/`: its pictures.

        Nothing private is in it: no cookies, sign-ins, or the pages behind Live Captures (each is its last picture).

        ## Export log

        \(log.joined(separator: "\n"))

        """
    }
}
