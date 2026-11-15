// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Compression
import Foundation

/// P17a (H01–H03, B02): a Space's pinned tree, a folder or a Boost as a link that carries the snapshot itself, in the
/// URL's fragment (docs/dev/share-links.md): `https://aircbrowser.com/s#v1.<payload>`. Nothing is stored on a server;
/// the site only serves a static viewer. Arc made server permalinks of the same things ("Viewers won't receive future
/// updates and this permalink cannot be deleted"); a link here is the same promise, since it is the content.
///
/// Reading is all or nothing and hostile-input-proof: the payload's length is checked before it's decoded, inflating
/// stops at a cap, brackets are counted before JSON is parsed, the schema is exact (an unknown key is an error), every
/// address must be http(s) with a host and no credentials, and counts and depth are capped. Any failure refuses the
/// whole link.
public struct ShareSnapshot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A Space's pinned tree, in sidebar order.
        case space(name: String, icon: String?, items: [ShareNode])
        /// A folder's contents.
        case folder(name: String, icon: String?, items: [ShareNode])
        /// A Boost (its file without the picture), for the usual review before it's installed.
        case boost(BoostFile)
    }

    public var kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public var name: String {
        switch kind {
        case .space(let n, _, _), .folder(let n, _, _): return n
        case .boost(let f): return f.name
        }
    }

    public var items: [ShareNode] {
        switch kind {
        case .space(_, _, let i), .folder(_, _, let i): return i
        case .boost: return []
        }
    }

    /// Tabs, folders and splits in the tree, for the preview ("12 tabs in 3 folders").
    public var counts: (tabs: Int, folders: Int, splits: Int) {
        var t = 0, f = 0, s = 0
        func walk(_ nodes: [ShareNode]) {
            for n in nodes {
                switch n {
                case .tab: t += 1
                case .folder(_, let items): f += 1; walk(items)
                case .split(_, let tabs): s += 1; t += tabs.count
                }
            }
        }
        walk(items)
        return (t, f, s)
    }
}

public struct ShareTab: Equatable, Sendable {
    public var url: String
    /// The tab's custom name, else its page's last title.
    public var title: String?
    public init(url: String, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

public indirect enum ShareNode: Equatable, Sendable {
    case tab(ShareTab)
    case folder(name: String, items: [ShareNode])
    /// A pinned split: 2 to 4 tabs.
    case split(axis: SplitAxis, tabs: [ShareTab])
}

public enum ShareLink {
    public static let host = "aircbrowser.com"
    public static let path = "/s"
    /// The viewer's "Open in Airc": `airc://share#v1.<payload>`.
    public static let appScheme = "airc"
    public static let appHost = "share"
    public static let version = 1

    /// Characters after `v1.`, at most; checked before anything is decoded.
    public static let maximumPayload = 32_000
    /// Bytes of JSON, at most: inflating stops there.
    public static let maximumJSON = 524_288
    public static let maximumTabs = 2_000
    public static let maximumNodes = 4_000
    /// Folders below the top level, at most.
    public static let maximumDepth = 10
    /// Longer links may be cut by chat apps: the share preview says so.
    public static let longLink = 8_000

    static let nameLimit = 200, titleLimit = 500, urlLimit = 4_096, iconLimit = 16

    public enum Failure: String, Error, LocalizedError {
        case damaged, newerVersion, tooLarge, unsafeAddress
        public var errorDescription: String? {
            switch self {
            case .damaged: "This link is damaged or incomplete."
            case .newerVersion: "This link was made by a newer version of Airc. Update Airc to open it."
            case .tooLarge: "This link is too large to open."
            case .unsafeAddress: "This link contains an address Airc doesn’t open (only web addresses can be shared)."
            }
        }
    }

    // MARK: Links

    /// A share link: the website's (`www.` too, `/s` or `/s/`) or the app's `airc://share`, with a `v…` fragment.
    public static func isLink(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), let fragment = url.fragment, fragment.hasPrefix("v") else { return false }
        if scheme == appScheme { return url.host?.lowercased() == appHost }
        guard scheme == "https", let h = url.host?.lowercased(), h == host || h == "www." + host else { return false }
        return url.path == path || url.path == path + "/"
    }

    /// The link for `snapshot`; it's read back before it's returned, so a link Airc makes always opens.
    public static func url(for snapshot: ShareSnapshot) throws -> URL {
        let json = try encode(snapshot)
        guard json.count <= maximumJSON, let packed = BoostLink.deflate(json) else { throw Failure.tooLarge }
        let payload = BoostLink.base64url(packed)
        guard payload.count <= maximumPayload, let url = URL(string: "https://\(host)\(path)#v\(version).\(payload)") else {
            throw Failure.tooLarge
        }
        _ = try self.snapshot(from: url)
        return url
    }

    /// The same link for the viewer's "Open in Airc".
    public static func appURL(for link: URL) -> URL? {
        guard isLink(link), let fragment = link.fragment else { return nil }
        return URL(string: "\(appScheme)://\(appHost)#\(fragment)")
    }

    /// The snapshot in `url`, fully checked; any problem refuses the whole link.
    public static func snapshot(from url: URL) throws -> ShareSnapshot {
        guard isLink(url), let fragment = url.fragment, let dot = fragment.firstIndex(of: ".") else { throw Failure.damaged }
        let tag = fragment[fragment.index(after: fragment.startIndex)..<dot]
        guard !tag.isEmpty, tag.count <= 9, tag.allSatisfy({ $0.isASCII && $0.isNumber }), tag.first != "0", let v = Int(tag) else {
            throw Failure.damaged
        }
        guard v == version else { throw v > version ? Failure.newerVersion : Failure.damaged }
        let payload = fragment[fragment.index(after: dot)...]
        guard payload.utf8.count <= maximumPayload else { throw Failure.tooLarge }
        guard !payload.isEmpty, let packed = BoostLink.unbase64url(String(payload)) else { throw Failure.damaged }
        // A payload that would grow past the cap stops inflating there (BoostLink.inflate's buffer is cap + 1).
        guard let json = BoostLink.inflate(packed, limit: maximumJSON) else {
            throw inflatesPastLimit(packed) ? Failure.tooLarge : Failure.damaged
        }
        return try decode(json)
    }

    /// Whether `packed` is a valid stream that grows past the cap (a "zip bomb"), not a damaged one: it fills a buffer
    /// of the cap + 1 bytes.
    static func inflatesPastLimit(_ packed: Data) -> Bool {
        var out = Data(count: maximumJSON + 1)
        let n = out.withUnsafeMutableBytes { dst in
            packed.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > maximumJSON
    }

    // MARK: Addresses and text

    /// An address a link may carry: absolute http(s) with a host, no user name or password, no whitespace or control
    /// characters, at most 4,096 UTF-16 units.
    public static func isSafeAddress(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf16.count <= urlLimit,
              !s.unicodeScalars.contains(where: { $0.properties.isWhitespace || isControl($0) }),
              let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let h = c.host, !h.isEmpty, c.user == nil, c.password == nil else { return false }
        return true
    }

    /// `s` without a user name or password, or nil when it can't be shared (not http(s), or no host).
    public static func shareable(_ s: String) -> String? {
        guard var c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        c.user = nil
        c.password = nil
        guard let out = c.string, isSafeAddress(out) else { return nil }
        return out
    }

    static func isControl(_ u: Unicode.Scalar) -> Bool { u.value < 0x20 || (0x7F...0x9F).contains(u.value) }

    /// Text for a link: control characters dropped, whitespace collapsed, at most `limit` UTF-16 units (on a character
    /// boundary). nil when nothing is left.
    static func clean(_ s: String?, limit: Int) -> String? {
        guard let s else { return nil }
        let flat = String(String.UnicodeScalarView(s.unicodeScalars.map { isControl($0) ? " " : $0 }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = ""
        for ch in flat {
            if out.utf16.count + String(ch).utf16.count > limit { break }
            out.append(ch)
        }
        return out.isEmpty ? nil : out
    }

    static func isEmojiText(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf16.count <= iconLimit else { return false }
        return s.allSatisfy { ch in
            !ch.isASCII && ch.unicodeScalars.contains { $0.properties.isEmoji } && !ch.unicodeScalars.contains(where: isControl)
        }
    }

    // MARK: JSON

    static func encode(_ snapshot: ShareSnapshot) throws -> Data {
        func tab(_ t: ShareTab) -> [String: Any] {
            var o: [String: Any] = ["type": "tab", "url": t.url]
            if let title = t.title { o["title"] = title }
            return o
        }
        func node(_ n: ShareNode) -> [String: Any] {
            switch n {
            case .tab(let t): return tab(t)
            case .folder(let name, let items): return ["type": "folder", "name": name, "items": items.map(node)]
            case .split(let axis, let tabs): return ["type": "split", "axis": axis.rawValue, "items": tabs.map(tab)]
            }
        }
        var top: [String: Any]
        switch snapshot.kind {
        case .space(let name, let icon, let items), .folder(let name, let icon, let items):
            var isSpace = false
            if case .space = snapshot.kind { isSpace = true }
            top = ["kind": isSpace ? "space" : "folder", "name": name, "items": items.map(node)]
            if let icon { top["icon"] = icon }
        case .boost(let file):
            let data = try file.withoutPreview.encoded()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.damaged }
            top = ["kind": "boost", "boost": object]
        }
        return try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Bracket nesting outside strings, counted before parsing: deep `[[[[…` can't reach the parser.
    static func nestingDepth(_ data: Data, stopAt limit: Int) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for b in data {
            if inString {
                if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch b {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > limit { return deepest }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return deepest
    }

    static func decode(_ data: Data) throws -> ShareSnapshot {
        // Top object, items, a folder's object and items per level, a split and its tabs: 3 + 2 × depth + 3.
        let allowedNesting = 3 + 2 * (maximumDepth + 1) + 3
        guard nestingDepth(data, stopAt: allowedNesting) <= allowedNesting else { throw Failure.tooLarge }
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.damaged }
        guard let kind = top["kind"] as? String else { throw Failure.damaged }
        if kind == "boost" {
            try exact(top, required: ["kind", "boost"])
            guard let object = top["boost"] as? [String: Any], object["preview"] == nil,
                  let raw = try? JSONSerialization.data(withJSONObject: object),
                  let file = try? BoostFile.decode(raw) else { throw Failure.damaged }
            return ShareSnapshot(.boost(file))
        }
        guard kind == "space" || kind == "folder" else { throw Failure.damaged }
        try exact(top, required: ["kind", "name", "items"], optional: ["icon"])
        let name = try text(top["name"], limit: nameLimit)
        var icon: String?
        if let i = top["icon"] {
            guard let s = i as? String, isEmojiText(s) else { throw Failure.damaged }
            icon = s
        }
        var tabs = 0, nodes = 0
        func tab(_ value: Any?) throws -> ShareTab {
            guard let o = value as? [String: Any], o["type"] as? String == "tab" else { throw Failure.damaged }
            try exact(o, required: ["type", "url"], optional: ["title"])
            guard let url = o["url"] as? String else { throw Failure.damaged }
            guard isSafeAddress(url) else { throw Failure.unsafeAddress }
            tabs += 1
            guard tabs <= maximumTabs else { throw Failure.tooLarge }
            return ShareTab(url: url, title: try o["title"].map { try text($0, limit: titleLimit) })
        }
        func list(_ value: Any?, depth: Int) throws -> [ShareNode] {
            guard let a = value as? [Any] else { throw Failure.damaged }
            return try a.map { v in
                nodes += 1
                guard nodes <= maximumNodes else { throw Failure.tooLarge }
                guard let o = v as? [String: Any], let type = o["type"] as? String else { throw Failure.damaged }
                switch type {
                case "tab":
                    return .tab(try tab(o))
                case "folder":
                    guard depth < maximumDepth else { throw Failure.tooLarge }
                    try exact(o, required: ["type", "name", "items"])
                    return .folder(name: try text(o["name"], limit: nameLimit), items: try list(o["items"], depth: depth + 1))
                case "split":
                    try exact(o, required: ["type", "items"], optional: ["axis"])
                    var axis = SplitAxis.horizontal
                    if let a = o["axis"] {
                        guard let s = a as? String, let parsed = SplitAxis(rawValue: s) else { throw Failure.damaged }
                        axis = parsed
                    }
                    guard let panes = o["items"] as? [Any], (2...4).contains(panes.count) else { throw Failure.damaged }
                    return .split(axis: axis, tabs: try panes.map(tab))
                default:
                    throw Failure.damaged
                }
            }
        }
        let items = try list(top["items"], depth: 0)
        guard tabs >= 1 else { throw Failure.damaged }
        return ShareSnapshot(kind == "space" ? .space(name: name, icon: icon, items: items) : .folder(name: name, icon: icon, items: items))
    }

    /// `o` has exactly these keys, none of them null.
    static func exact(_ o: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(o.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)), !o.values.contains(where: { $0 is NSNull }) else {
            throw Failure.damaged
        }
    }

    /// A required string: 1 to `limit` UTF-16 units, not only whitespace, no control characters.
    static func text(_ value: Any?, limit: Int) throws -> String {
        guard let s = value as? String, s.utf16.count <= limit, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !s.unicodeScalars.contains(where: isControl) else { throw Failure.damaged }
        return s
    }
}

// MARK: - From and into the sidebar

/// What a Share Space… or Share Folder… preview shows: the snapshot, and what stays out of it.
public struct ShareDraft: Equatable, Sendable {
    public var snapshot: ShareSnapshot
    /// Pinned items that aren't web pages (notes, local files) or splits without two of them: not in the link.
    public var leftOut: Int
    /// A Space's Today tabs, which a Space link doesn't carry (only its pinned tree).
    public var todayTabs: Int
}

extension SpacesStore {
    /// Share Space…: the Space's name, emoji and pinned tree. Not its Today tabs, its profile's Favorites, its theme or
    /// anything from its pages; addresses lose any user name and password. nil when nothing in it can be shared.
    public func shareDraft(ofSpace spaceID: String) -> ShareDraft? {
        guard let s = space(spaceID) else { return nil }
        var leftOut = 0
        let items = shareNodes(children(of: .pinned(spaceID: spaceID), parent: nil), leftOut: &leftOut)
        let name = ShareLink.clean(s.name, limit: ShareLink.nameLimit) ?? "Space"
        var icon: String?
        if case .emoji(let e)? = s.icon, ShareLink.isEmojiText(e) { icon = e }
        let draft = ShareDraft(snapshot: ShareSnapshot(.space(name: name, icon: icon, items: items)), leftOut: leftOut,
                               todayTabs: todayTabs(ofSpace: spaceID).count)
        return draft.snapshot.counts.tabs > 0 ? draft : nil
    }

    /// Share Folder…: the folder's name, emoji and contents. nil when nothing in it can be shared.
    public func shareDraft(ofFolder folderID: String) -> ShareDraft? {
        guard let f = item(folderID), f.kind == .folder else { return nil }
        var leftOut = 0
        let items = shareNodes(children(of: f.container, parent: f.id), leftOut: &leftOut)
        let icon = f.icon.flatMap { ShareLink.isEmojiText($0) ? $0 : nil }
        let name = ShareLink.clean(f.displayTitle, limit: ShareLink.nameLimit) ?? "Folder"
        let draft = ShareDraft(snapshot: ShareSnapshot(.folder(name: name, icon: icon, items: items)), leftOut: leftOut, todayTabs: 0)
        return draft.snapshot.counts.tabs > 0 ? draft : nil
    }

    private func shareTab(_ i: Item) -> ShareTab? {
        guard let url = i.savedURL.flatMap(ShareLink.shareable) else { return nil }
        return ShareTab(url: url, title: ShareLink.clean(i.title ?? i.pageTitle, limit: ShareLink.titleLimit))
    }

    private func shareNodes(_ items: [Item], leftOut: inout Int) -> [ShareNode] {
        var out: [ShareNode] = []
        for i in items {
            switch i.kind {
            case .tab:
                if let t = shareTab(i) { out.append(.tab(t)) } else { leftOut += 1 }
            case .folder:
                out.append(.folder(name: ShareLink.clean(i.displayTitle, limit: ShareLink.nameLimit) ?? "Folder",
                                   items: shareNodes(children(of: i.container, parent: i.id), leftOut: &leftOut)))
            case .split:
                let panes = panes(ofSplitItem: i.id)
                let tabs = panes.compactMap(shareTab)
                leftOut += panes.count - tabs.count
                if tabs.count >= 2 { out.append(.split(axis: i.splitLayout?.axis ?? .horizontal, tabs: Array(tabs.prefix(4)))) }
                else if let t = tabs.first { out.append(.tab(t)) }
            }
        }
        return out
    }

    /// Add as New Space: a Space with the link's name, emoji and pinned tree, in `profileID`, after `after`. One undoable
    /// step; nothing is added if anything fails. The tabs aren't opened.
    @discardableResult
    public func addSharedSpace(_ snapshot: ShareSnapshot, profileID: String?, after: String?) throws -> Space {
        guard case .space(let name, let icon, let items) = snapshot.kind else { throw StoreError.invalidMove }
        let spaces = orderedSpaces
        let order: Double
        if let after, let i = spaces.firstIndex(where: { $0.id == after }) {
            order = Ordering.between(spaces[i].order, i + 1 < spaces.count ? spaces[i + 1].order : nil)
        } else {
            order = Ordering.between(spaces.last?.order, nil)
        }
        let s = Space(name: name, icon: icon.map(SpaceIcon.emoji), theme: .neutral, profileID: profile(profileID)?.id ?? defaultProfile.id,
                      order: order, createdAt: now())
        try perform("Add Shared Space", undoable: true) {
            put(s)
            addShared(items, to: .pinned(spaceID: s.id), parent: nil)
        }
        return s
    }

    /// Add to This Space: the link's folder at the end of the Space's pinned tabs. One undoable step.
    @discardableResult
    public func addSharedFolder(_ snapshot: ShareSnapshot, toSpace spaceID: String) throws -> Item {
        guard case .folder(let name, let icon, let items) = snapshot.kind, space(spaceID) != nil else { throw StoreError.invalidMove }
        let container = ItemContainer.pinned(spaceID: spaceID)
        let siblings = children(of: container, parent: nil)
        let folder = Item(kind: .folder, container: container, order: Ordering.insertion(at: siblings.count, in: siblings.map(\.order)),
                          title: name, icon: icon, createdAt: now())
        try perform("Add Shared Folder", undoable: true) {
            put(folder)
            addShared(items, to: container, parent: folder.id)
        }
        return item(folder.id)!
    }

    private func addShared(_ nodes: [ShareNode], to container: ItemContainer, parent: String?) {
        func tab(_ t: ShareTab, parent: String?, order: Double) -> Item {
            Item(kind: .tab, container: container, parentID: parent, order: order, savedURL: t.url, pageTitle: t.title, createdAt: now())
        }
        for (k, n) in nodes.enumerated() {
            let order = Double(k + 1)
            switch n {
            case .tab(let t):
                put(tab(t, parent: parent, order: order))
            case .folder(let name, let items):
                let f = Item(kind: .folder, container: container, parentID: parent, order: order, title: name, createdAt: now())
                put(f)
                addShared(items, to: container, parent: f.id)
            case .split(let axis, let tabs):
                var s = Item(kind: .split, container: container, parentID: parent, order: order, createdAt: now())
                var layout = SplitLayout(axis: axis)
                for (j, t) in tabs.enumerated() {
                    let p = tab(t, parent: s.id, order: Double(j))
                    put(p)
                    if j == 0 { layout.focusedItemID = p.id }
                }
                s.splitLayout = layout
                put(s)
            }
        }
    }
}
