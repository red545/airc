// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import AircDesign
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let aircBoost = UTType(exportedAs: "org.airc.boost", conformingTo: .json)
}

// Sharing Boosts (BST-2, BST-3; Arc's Share and "Add this Boost to Arc?" dialogs, and its gallery):
//   - Share (the editor's menu and footer, Settings): a name, the author's name if they want one, a line about it and a
//     screenshot of the page (theirs to leave out), then Copy Link (small Boosts: BoostLink, nothing leaves the Mac until
//     they paste it somewhere) or Save File…. Their Boost keeps the shared identity, so sharing a change later is a new
//     version of the same Boost.
//   - Review (a file, a link from another app or a page, the gallery): what it is, who says they made it (never
//     checked), its screenshot or a sketch of it, what it changes, every line of its code, and Try It On (style and size
//     on the site's pages, never its code). Nothing is installed until the person confirms; a newer version of a Boost
//     they installed is an update, an older one says so.
//   - The gallery: Airc's starter Boosts (BoostGallery), style only, each reviewed like any other.

/// Where a Boost under review came from.
enum BoostSource {
    case file, link, gallery(BoostGallery.Entry)
    var isGallery: Bool { if case .gallery = self { true } else { false } }
}

/// All entry points use this review. Merely opening or cancelling never changes the store (Try It On shows the Boost on
/// its pages for as long as the sheet is open).
final class BoostImportReview: ObservableObject {
    static var active: [ObjectIdentifier: BoostImportReview] = [:]
    let file: BoostFile
    let source: BoostSource
    let existing: Boost?
    let relation: BoostInstall
    /// A history visit to the site in the last 60 days (Arc: "a site you haven't visited recently").
    let visitedRecently: Bool
    let sheet: NSWindow
    weak var parent: NSWindow?
    /// The browser window that tries it on and shows the site afterwards.
    weak var controller: WindowController?
    private let center: BoostCenter
    @Published private(set) var tryingOn = false

    init(file: BoostFile, source: BoostSource, parent: NSWindow, controller: WindowController?, center: BoostCenter) {
        self.file = file; self.source = source; self.parent = parent; self.controller = controller; self.center = center
        existing = center.store.boost(domain: file.site)
        relation = BoostInstall.relation(of: file, to: existing)
        visitedRecently = controller.map { Self.visited(file.site, app: $0.app) } ?? true
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Review Boost"
        sheet.isReleasedWhenClosed = false
        sheet.contentView = onMain { NSHostingView(rootView: BoostReviewView(review: self)) }
    }

    static func visited(_ site: String, app: AppDelegate?) -> Bool {
        guard let app, let history = app.history, let store = app.store else { return true }
        let since = Date().addingTimeInterval(-60 * 24 * 3600)
        for profile in store.state.profiles.keys {
            for e in history.entries(ofProfile: profile) where e.lastVisit > since {
                if BoostDomain.key(for: URL(string: e.url)) == site { return true }
            }
        }
        return false
    }

    func present() {
        guard let parent, parent.attachedSheet == nil else { NSSound.beep(); return }
        Self.active[ObjectIdentifier(parent)] = self
        parent.beginSheet(sheet)
    }

    /// The site's page to show it on: the gallery's own page, or the site's home.
    var page: URL {
        if case .gallery(let e) = source { return e.page }
        return URL(string: "https://" + (file.scriptHost ?? file.site) + "/") ?? URL(string: "https://" + file.site + "/")!
    }

    /// The browser window shows a page of the site; with `open`, it opens one when it doesn't.
    @discardableResult
    func showSite(open: Bool) -> Bool {
        guard let c = controller else { return false }
        if let id = c.shownTabID, BoostDomain.key(for: c.engineTab(for: id)?.url) == file.site { return true }
        guard open else { return false }
        c.openExternal(page, inSpace: c.currentSpaceID)
        return true
    }

    /// Try It On: the Boost's style and size on the site's pages (never its code) until the sheet closes.
    func setTryOn(_ on: Bool) {
        guard on != tryingOn else { return }
        tryingOn = on
        center.setPreview(on ? file.boost : nil, domain: file.site)
        if on { showSite(open: true) }
    }

    private func close() {
        guard let parent else { return }
        if tryingOn { tryingOn = false; center.setPreview(nil, domain: file.site) }
        parent.endSheet(sheet); sheet.orderOut(nil)
        Self.active[ObjectIdentifier(parent)] = nil
    }

    func cancel() { close() }

    func install() {
        guard let parent else { return }
        // Another window may have edited this site while the sheet was open. Never overwrite unseen work.
        guard center.store.boost(domain: file.site) == existing else {
            close()
            BoostSharing.error("This site's Boost changed while you were reviewing it. Open it again to review the latest version.", on: parent)
            return
        }
        do {
            tryingOn = false
            center.setPreview(nil, domain: file.site)
            try center.store.install(file, replacing: existing != nil, gallery: source.isGallery)
            close()
            // As in Arc, the site opens (unless a page of it is on screen already).
            showSite(open: true)
            let site = file.site
            if center.store.boost(domain: site)?.enabled == false {
                // BST-2: a Boost with code is installed off. The toast offers to turn it on; so do the editor and Settings.
                controller?.showActionToast(relationUpdates ? "Boost updated. It's off until you turn it on." : "Boost installed. It's off until you turn it on.",
                                      action: ("Turn On", { [weak center, weak controller] in
                                          let page = controller?.shownTabID.flatMap { controller?.engineTab(for: $0) }
                                          center?.turnOn(domain: site, page: page)
                                          controller?.showToast("Boost turned on")
                                      }))
            } else {
                controller?.showToast(relationUpdates ? "Boost updated" : "Boost installed!")
            }
        } catch { close(); BoostSharing.error(error.localizedDescription, on: parent) }
    }

    var relationUpdates: Bool { if case .update = relation { true } else { false } }

    var installTitle: String {
        switch relation {
        case .new: "Add Boost"
        case .update: "Update"
        case .reinstall, .older, .replace, .own: "Replace"
        }
    }
}

struct BoostReviewView: View {
    @ObservedObject var review: BoostImportReview
    private var file: BoostFile { review.file }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "paintbrush.pointed.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.purple))
                VStack(alignment: .leading, spacing: 3) {
                    Text(heading).font(.system(size: 20, weight: .semibold))
                    Text("\(file.name) · \(file.site)").font(.headline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // BST-2: code first, where nobody can miss it; the look and the rest follow.
                    if !file.js.isEmpty {
                        Label("This Boost runs code on \(file.scriptHost ?? file.site)\(file.scriptHost == nil ? " and its subdomains" : "").",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange).testAnchor("boost.import.codeWarning")
                        Text("Its JavaScript can read and change those pages, see what you type there, and send it to other websites. Add it only if you trust who made it and understand the code below. Trying it on never runs it.")
                        Text(BoostStore.installsOn(file, replacing: review.existing)
                             ? "It's the same code your Boost runs now, so it stays on."
                             : "It's added turned off. Its code runs only after you turn it on.")
                            .foregroundStyle(.secondary).testAnchor("boost.import.installsOff")
                        code("JavaScript · executable code", file.js, warning: true, language: .javaScript)
                            .testAnchor("boost.import.js")
                    }
                    preview
                    if let author = file.author {
                        Label("By \(author). Names aren't verified: anyone can type any name.", systemImage: "person.crop.circle")
                            .foregroundStyle(.secondary).testAnchor("boost.import.author")
                    }
                    if let about = file.about { Text(about) }
                    if !review.visitedRecently {
                        Label("Heads up! This Boost is for \(file.site), a site you haven't visited recently. Make sure it changes the site you expect.",
                              systemImage: "exclamationmark.circle").foregroundStyle(.orange).testAnchor("boost.import.notVisited")
                    }
                    relationNote
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What it changes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(file.summary)
                        Text("On \(file.site) and its subdomains, in every Space and profile.").foregroundStyle(.secondary)
                    }
                    if !file.zaps.isEmpty {
                        Text(file.zaps.map { "Hide \($0.label.isEmpty ? "an element" : $0.label): \($0.selector)" }.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                    }
                    if !file.css.isEmpty {
                        Text("CSS can load images, fonts and other resources from other websites. Install styles only from sources you trust.")
                            .foregroundStyle(.secondary).testAnchor("boost.import.cssNetworkWarning")
                        code("CSS", file.css, warning: false, language: .css).testAnchor("boost.import.css")
                    }
                    if file.js.isEmpty { Text("No JavaScript in this Boost.").foregroundStyle(.secondary) }
                    if let old = review.existing, !review.relationUpdates {
                        Divider()
                        Text("Your Boost for \(old.domain) now").font(.headline)
                        Text("\(old.name ?? old.domain) · \(old.enabled ? "On" : "Off")\(old.needsSite ? " · paused" : ""). "
                             + BoostFile(boost: old).summary)
                        if !old.css.isEmpty { code("Its CSS", old.css, warning: false, language: .css) }
                        if !old.js.isEmpty {
                            Text("Its JavaScript runs on \(old.scriptHost ?? "all of " + old.domain). Code already run in open pages can't be undone; reload them after replacing.")
                            code("Its JavaScript", old.js, warning: true, language: .javaScript)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.trailing, 8)
            }
            Divider()
            HStack(spacing: 10) {
                if hasStyle {
                    HStack(spacing: 10) {
                        AircSwitch(isOn: Binding(get: { review.tryingOn }, set: { review.setTryOn($0) }))
                            .testAnchor("boost.import.tryOn")
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Try It On")
                            Text(file.js.isEmpty ? "On \(file.site), until you choose" : "Style only; its code doesn't run")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Cancel", action: review.cancel).keyboardShortcut(.cancelAction).testAnchor("boost.import.cancel")
                Button(review.installTitle, action: review.install)
                    .buttonStyle(.borderedProminent).testAnchor("boost.import.install")
            }
        }.padding(24).frame(width: 580, height: 660).background(.background)
    }

    private var hasStyle: Bool { !(file.colors.isDefault && file.font.isDefault && file.zaps.isEmpty && file.css.isEmpty) }

    private var heading: String {
        switch review.relation {
        case .update: "Update this Boost?"
        case .own: "Your own Boost"
        default: "Add this Boost to Airc?"
        }
    }

    @ViewBuilder private var preview: some View {
        Group {
            if let data = file.previewData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .top).clipped()
                    .testAnchor("boost.import.screenshot")
            } else {
                BoostPreviewCard(file: file, chips: true).frame(height: 160).testAnchor("boost.import.sketch")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private var relationNote: some View {
        switch review.relation {
        case .new, .replace:
            if review.existing != nil {
                Label("It replaces your Boost for \(file.site), shown below.", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        case .update(let from, let to):
            VStack(alignment: .leading, spacing: 4) {
                Label("A newer version of a Boost you added: version \(from) → \(to).", systemImage: "arrow.down.circle")
                    .testAnchor("boost.import.update")
                if let have = review.existing, let o = have.origin, o.edited(have) {
                    Text("You changed your copy since you added it. Updating replaces your changes.").foregroundStyle(.orange)
                        .testAnchor("boost.import.edited")
                }
            }
        case .reinstall(let v):
            Label("You already have version \(v) of this Boost. Replacing puts it back as it was shared.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .older(let have, let file):
            Label("This is an older version (\(file)) than yours (\(have)).", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                .testAnchor("boost.import.older")
        case .own:
            Label("You shared this Boost. Replacing puts your copy back as you shared it.", systemImage: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.secondary)
        }
    }

    private func code(_ title: String, _ source: String, warning: Bool, language: BoostCodeTokens.Language) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(warning ? Color.orange : Color.secondary)
            // Full source, coloured (BoostCodeTokens covers every character once), wrapping rather than clipping or
            // truncating. Never evaluated by the review UI.
            Text(source.isEmpty ? AttributedString("None") : Self.highlighted(source, language)).font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(warning ? Color.orange.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Calm colours that read in light and dark; calls a reviewer should look at first get a tinted background.
    static func highlighted(_ source: String, _ language: BoostCodeTokens.Language) -> AttributedString {
        var out = AttributedString()
        for t in BoostCodeTokens.tokens(source, language) {
            var run = AttributedString(t.text)
            switch t.kind {
            case .plain: break
            case .keyword: run.foregroundColor = Color(nsColor: .systemPurple); run.font = .system(size: 12, weight: .semibold, design: .monospaced)
            case .string: run.foregroundColor = Color(nsColor: .systemRed)
            case .comment: run.foregroundColor = Color(nsColor: .secondaryLabelColor); run.font = .system(size: 12, design: .monospaced).italic()
            case .number: run.foregroundColor = Color(nsColor: .systemBlue)
            case .atRule, .property: run.foregroundColor = Color(nsColor: .systemTeal)
            case .sensitive:
                run.foregroundColor = Color(nsColor: .systemOrange); run.font = .system(size: 12, weight: .bold, design: .monospaced)
                run.backgroundColor = Color.orange.opacity(0.16)
            }
            out += run
        }
        return out
    }
}

// MARK: - A sketch of a Boost

/// A small made-up page with the Boost's colours, font and case on it: the gallery's cards, and a review without a
/// screenshot. The real thing is Try It On.
struct BoostPreviewCard: View {
    let file: BoostFile
    /// Small labels for what it changes, along the bottom (the gallery's cards, a review without a screenshot).
    var chips = true

    var body: some View {
        let c = file.colors
        ZStack(alignment: .bottomLeading) {
            ZStack(alignment: .topLeading) {
                page
                    .saturation(c.saturation)
                    .brightness(c.brightness - 1)
                    .contrast(c.contrast)
                if c.tint > 0.005 {
                    Color(hue: c.hue, saturation: 0.75, brightness: 1).opacity(min(0.55, c.tint * 0.7)).blendMode(.multiply)
                        .allowsHitTesting(false)
                }
            }
            .compositingGroup()
            if chips, !labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(labels, id: \.self) { l in
                        Text(l).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
                .padding(10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("A sketch of \(file.name) on \(file.site)")
    }

    /// What it changes, in a word each.
    private var labels: [String] {
        var l: [String] = []
        let c = file.colors
        if c.invert { l.append("Dark") } else if c.tint > 0.005 { l.append("Tint") }
        if abs(c.brightness - 1) > 0.005 || abs(c.contrast - 1) > 0.02 || c.saturation < 0.995 { l.append("Light") }
        if let f = file.font.knownFamily { l.append(f.title) }
        if file.font.size != 0 { l.append("\(Int((file.font.scale * 100).rounded())) %") }
        if let t = file.font.knownCase { l.append(t.sample) }
        if !file.zaps.isEmpty || file.css.contains("display: none") { l.append("Hides parts") }
        if !file.css.isEmpty { l.append("CSS") }
        if !file.js.isEmpty { l.append("Code") }
        return Array(l.prefix(4))
    }

    private var dark: Bool { file.colors.invert }
    private var ink: Color { dark ? Color(white: 0.93) : Color(white: 0.1) }
    private var paper: Color { dark ? Color(white: 0.09) : .white }

    private var page: some View {
        GeometryReader { g in
            let scale = file.font.scale
            VStack(alignment: .leading, spacing: 8 * scale) {
                HStack(spacing: 6) {
                    Circle().fill(ink.opacity(0.18)).frame(width: 10, height: 10)
                    Text(file.site).font(.system(size: 9, weight: .medium)).foregroundStyle(ink.opacity(0.5))
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.08)).frame(width: 46, height: 8)
                }
                Text(cased("The quick brown fox")).font(Self.font(file.font.knownFamily, size: 17 * scale, bold: true))
                    .foregroundStyle(ink).lineLimit(1)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        Text(cased("Jumps over the lazy dog, then settles in for a long read about type and color."))
                            .font(Self.font(file.font.knownFamily, size: 10.5 * scale, bold: false))
                            .foregroundStyle(ink.opacity(0.8)).lineLimit(3)
                        ForEach(0..<2, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.12)).frame(height: 5).padding(.trailing, CGFloat(i) * 30)
                        }
                    }
                    LinearGradient(colors: [Color(red: 0.98, green: 0.6, blue: 0.3), Color(red: 0.35, green: 0.55, blue: 0.95)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: g.size.width * 0.28, height: 54 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .background(paper)
        }
    }

    private func cased(_ s: String) -> String {
        switch file.font.knownCase {
        case .uppercase: s.uppercased()
        case .lowercase: s.lowercased()
        case .capitalize: s.capitalized
        case nil: s
        }
    }

    static func font(_ f: BoostFontFamily?, size: CGFloat, bold: Bool) -> Font {
        let family: String? = switch f {
        case nil, .system: nil
        case .helvetica: "Helvetica Neue"
        case .avenir: "Avenir Next"
        case .georgia: "Georgia"
        case .charter: "Charter"
        case .menlo: "Menlo"
        }
        guard let family, let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size)
        else { return .system(size: size, weight: bold ? .bold : .regular) }
        return Font(font as CTFont)
    }
}

// MARK: - Share

/// The share sheet: name, author, a line about it, the screenshot, then a link or a file.
final class BoostShareSheet: ObservableObject {
    static var active: [ObjectIdentifier: BoostShareSheet] = [:]
    /// The name the person signs with, remembered for the next share (on this Mac only).
    static let authorKey = "AircBoostAuthor"
    let domain: String
    let sheet: NSWindow
    weak var parent: NSWindow?
    weak var controller: WindowController?
    private let center: BoostCenter
    @Published var name: String
    @Published var author: String
    @Published var about = ""
    @Published var includeScreenshot = true
    @Published private(set) var screenshot: Data?
    @Published private(set) var message: String?
    let hasScript: Bool
    /// The revision this share will be, and whether it's a new one of a Boost shared before.
    let revision: Int
    let sharedBefore: Bool
    /// The id this share gives a Boost that wasn't shared before (one for the sheet's link and file alike).
    private let newID = UUID().uuidString.lowercased()

    init?(domain: String, parent: NSWindow, controller: WindowController?, center: BoostCenter) {
        guard let b = center.store.boost(domain: domain) else { return nil }
        self.domain = domain; self.parent = parent; self.controller = controller; self.center = center
        name = b.name ?? domain
        author = UserDefaults.standard.string(forKey: Self.authorKey) ?? ""
        hasScript = b.hasScript
        let probe = center.store.shareFile(domain: domain, name: b.name ?? domain, author: nil)
        revision = probe?.revision ?? 1
        sharedBefore = b.origin?.kind == .shared
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Share Boost"
        sheet.isReleasedWhenClosed = false
        sheet.contentView = onMain { NSHostingView(rootView: BoostShareView(share: self)) }
        takeScreenshot()
    }

    func present() {
        guard let parent, parent.attachedSheet == nil else { NSSound.beep(); return }
        Self.active[ObjectIdentifier(parent)] = self
        parent.beginSheet(sheet)
    }

    func close() {
        guard let parent else { return }
        parent.endSheet(sheet); sheet.orderOut(nil)
        Self.active[ObjectIdentifier(parent)] = nil
    }

    /// The page on screen, if it's on the site: a JPEG of at most 1200 pt wide and 300 KB.
    private func takeScreenshot() {
        guard let c = controller, let id = c.shownTabID, let page = c.engineTab(for: id),
              BoostDomain.key(for: page.url) == domain else { includeScreenshot = false; return }
        page.snapshot { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                self.screenshot = image.flatMap(Self.jpeg)
                if self.screenshot == nil { self.includeScreenshot = false }
            }
        }
    }

    static func jpeg(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        for width in [1200, 960, 720] {
            let w = min(width, cg.width), h = Int(Double(cg.height) * Double(w) / Double(cg.width))
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: scaled)
            for quality in [0.72, 0.55, 0.4] {
                if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                   data.count <= BoostFile.maximumPreviewBytes { return data }
            }
        }
        return nil
    }

    var validName: Bool { BoostFile.plainLine(name, max: 120) }

    func file(withPicture: Bool) -> BoostFile? {
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return center.store.shareFile(domain: domain, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                      author: a.isEmpty ? nil : String(a.prefix(60)), about: about.isEmpty ? nil : String(about.prefix(280)),
                                      preview: withPicture && includeScreenshot ? screenshot : nil, newID: newID)
    }

    /// The link for the Boost as it is now, or why there's none.
    var link: Result<URL, Error> {
        guard let f = file(withPicture: false) else { return .failure(BoostFile.Invalid.format) }
        return Result { try BoostLink.url(for: f) }
    }

    private func remember() {
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { UserDefaults.standard.removeObject(forKey: Self.authorKey) } else { UserDefaults.standard.set(a, forKey: Self.authorKey) }
    }

    func copyLink() {
        guard case .success(let url) = link, let f = file(withPicture: false) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        center.store.noteShared(f)
        remember()
        close()
        controller?.showToast("Boost link copied")
    }

    func saveFile() {
        guard let f = file(withPicture: true), let parent else { return }
        do {
            let data = try f.encoded()
            let panel = NSSavePanel()
            panel.title = "Share Boost"; panel.allowedContentTypes = [.aircBoost]
            panel.nameFieldStringValue = (f.name == domain ? domain : f.name.replacingOccurrences(of: "/", with: "-")) + ".airc-boost"
            close()
            panel.beginSheetModal(for: parent) { [center] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    center.store.noteShared(f)
                    self.remember()
                } catch { BoostSharing.error(error.localizedDescription, on: parent) }
            }
        } catch { message = error.localizedDescription }
    }

    /// Submit to the Gallery (B03): the Boost, with its screenshot if it's included, goes to the gallery on
    /// aircbrowser.com. It's checked there, then a person reviews it before it's listed for everyone.
    @Published private(set) var submitting = false
    @Published private(set) var submitted: String?

    func submitToGallery() {
        guard !submitting, submitted == nil, let f = file(withPicture: true) else { return NSSound.beep() }
        submitting = true
        message = nil
        Task { @MainActor in
            defer { submitting = false }
            do {
                submitted = try await SharingCenter.shared.service.submit(f)
                center.store.noteShared(f)
                remember()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    #if AIRC_TESTING
    /// Scripted checks: Save File… without the panel (the encoded file, noted as shared).
    func saveForCheck(to url: URL) throws {
        guard let f = file(withPicture: true) else { throw BoostFile.Invalid.format }
        try f.encoded().write(to: url, options: .atomic)
        center.store.noteShared(f)
        close()
    }
    #endif
}

struct BoostShareView: View {
    @ObservedObject var share: BoostShareSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.purple))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Boost").font(.system(size: 20, weight: .semibold))
                    Text(share.sharedBefore ? "\(share.domain) · version \(share.revision)" : share.domain)
                        .foregroundStyle(.secondary).testAnchor("boost.share.version")
                }
            }
            Group {
                if let data = share.screenshot, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 170, maxHeight: 170, alignment: .top).clipped()
                        .opacity(share.includeScreenshot ? 1 : 0.35)
                } else {
                    RoundedRectangle(cornerRadius: 0).fill(Color.primary.opacity(0.05)).frame(height: 170)
                        .overlay(Text("Open a page of \(share.domain) to include a screenshot").foregroundStyle(.secondary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            if share.screenshot != nil {
                Toggle("Include this screenshot (check it shows nothing private)", isOn: $share.includeScreenshot)
                    .testAnchor("boost.share.screenshot")
            }
            Form {
                TextField("Name", text: $share.name).testAnchor("boost.share.name")
                TextField("Your name (optional)", text: $share.author).testAnchor("boost.share.author")
                TextField("What it does (optional)", text: $share.about)
            }
            .formStyle(.columns)
            Text(share.sharedBefore
                 ? "People who added an earlier version get this one as an update when they open it. Nothing changes for them until then."
                 : "Anyone with the link or file can install it. Changes you make later reach them only when you share again: they'll be offered an update.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if share.hasScript {
                Label("It includes JavaScript. Whoever installs it sees the code and has to allow it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let m = share.message { Text(m).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).testAnchor("boost.share.message") }
            if let sent = share.submitted {
                Label(sent, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green).testAnchor("boost.share.submitted")
            }
            Spacer(minLength: 0)
            HStack {
                Button(share.submitting ? "Sending…" : "Submit to the Gallery", action: share.submitToGallery)
                    .disabled(!share.validName || share.submitting || share.submitted != nil)
                    .help("Sends it to the Boost Gallery on aircbrowser.com. A person reviews it before it’s listed for everyone.")
                    .testAnchor("boost.share.gallery")
                if case .failure = share.link { Text("Too big for a link: save a file.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: share.close).keyboardShortcut(.cancelAction).testAnchor("boost.share.cancel")
                Button("Save File…", action: share.saveFile).disabled(!share.validName).testAnchor("boost.share.file")
                Button("Copy Link", action: share.copyLink).buttonStyle(.borderedProminent)
                    .disabled(!share.validName || { if case .failure = share.link { return true }; return false }())
                    .testAnchor("boost.share.link")
            }
        }.padding(24).frame(width: 560, height: 540).background(.background)
    }
}

// MARK: - Gallery

/// The Boost gallery window: Airc's starter Boosts, each one reviewed in the browser window before it's added.
final class BoostGalleryWindow: NSObject, NSWindowDelegate {
    static private(set) var shared: BoostGalleryWindow?
    let window: NSWindow
    weak var app: AppDelegate?

    private init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Boost Gallery"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 480)
        window.delegate = self
        window.contentView = onMain { NSHostingView(rootView: BoostGalleryView(gallery: self)) }
        window.center()
    }

    static func show(app: AppDelegate) {
        let g = shared ?? BoostGalleryWindow(app: app)
        shared = g
        if app.options.isAutomated { g.window.orderFront(nil) } else { g.window.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }

    /// Get: the review, on the browser window (where Try It On shows it).
    func get(_ entry: BoostGallery.Entry) {
        guard let center = BoostCenter.shared, let app, let c = app.browserWindow() else { return }
        if !app.options.isAutomated { c.window.makeKeyAndOrderFront(nil) }
        BoostImportReview(file: entry.file, source: .gallery(entry), parent: c.window, controller: c, center: center).present()
    }

    /// B03: the community's Boosts from aircbrowser.com, approved by a person before they're listed. Airc's own
    /// are always there too, so the gallery works offline.
    let community = CommunityGallery()

    /// Get for a community Boost: its file is fetched and checked, then the same review as a link's.
    func get(_ entry: SharingService.GalleryEntry) {
        Task { @MainActor in
            do {
                let file = try await SharingCenter.shared.service.galleryFile(id: entry.id)
                guard let center = BoostCenter.shared, let app, let c = app.browserWindow() else { return }
                if !app.options.isAutomated { c.window.makeKeyAndOrderFront(nil) }
                BoostImportReview(file: file, source: .link, parent: c.window, controller: c, center: center).present()
            } catch {
                community.message = error.localizedDescription
            }
        }
    }
}

/// The gallery's community Boosts: loaded once each time the window opens, with their pictures as they arrive.
final class CommunityGallery: ObservableObject {
    enum Phase: Equatable { case loading, loaded, unavailable }
    @Published private(set) var phase = Phase.loading
    @Published private(set) var entries: [SharingService.GalleryEntry] = []
    @Published private(set) var pictures: [String: NSImage] = [:]
    @Published private(set) var reported: Set<String> = []
    @Published var message: String?
    let service: SharingService

    init(service: SharingService = SharingCenter.shared.service) {
        self.service = service
        load()
    }

    func load() {
        phase = .loading
        Task { @MainActor in
            do {
                entries = try await service.galleryEntries()
                phase = .loaded
                for e in entries where e.preview {
                    if let data = await service.galleryPreview(id: e.id), let image = NSImage(data: data) { pictures[e.id] = image }
                }
            } catch {
                phase = .unavailable
            }
        }
    }

    func report(_ e: SharingService.GalleryEntry, _ reason: SharingService.ReportReason) {
        Task { @MainActor in
            do {
                try await service.report(id: e.id, reason: reason, note: nil)
                reported.insert(e.id)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct BoostGalleryView: View {
    let gallery: BoostGalleryWindow
    @ObservedObject var community: CommunityGallery
    @State private var installed: [String: Boost] = Self.installedByID()

    init(gallery: BoostGalleryWindow) {
        self.gallery = gallery
        community = gallery.community
    }

    static func installedByID() -> [String: Boost] {
        var map: [String: Boost] = [:]
        for b in BoostCenter.shared?.store.all ?? [] { if let id = b.origin?.id { map[id] = b } }
        return map
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Boost Gallery").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Boosts made by Airc and by people who use it. Each one is reviewed before it’s listed, and you see what it changes before you add it.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("From Airc").font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)], spacing: 16) {
                    ForEach(BoostGallery.entries) { entry in card(entry) }
                }
                HStack {
                    Text("From the community").font(.title3.weight(.semibold))
                    Spacer()
                    if community.phase == .loading { ProgressView().controlSize(.small) }
                }.padding(.top, 8)
                if let m = community.message { Text(m).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                switch community.phase {
                case .unavailable:
                    HStack {
                        Text("Airc couldn’t reach the gallery on aircbrowser.com. Airc’s own Boosts are above.").foregroundStyle(.secondary)
                        Button("Try Again", action: community.load).controlSize(.small)
                    }.testAnchor("boost.gallery.offline")
                case .loaded where community.entries.isEmpty:
                    Text("Nothing here yet. Share one of yours: File › Share Boost…, then Submit to the Gallery.").foregroundStyle(.secondary)
                default:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)], spacing: 16) {
                        ForEach(community.entries) { entry in communityCard(entry) }
                    }
                }
            }
            .padding(28)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(.background)
        .onReceive(NotificationCenter.default.publisher(for: BoostCenter.didChange)) { _ in installed = Self.installedByID() }
    }

    private func communityCard(_ entry: SharingService.GalleryEntry) -> some View {
        let have = installed[entry.fileID ?? ""]
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = community.pictures[entry.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.primary.opacity(0.05))
                        .overlay(Text(entry.site.prefix(1).uppercased()).font(.system(size: 40, weight: .semibold)).foregroundStyle(.tertiary))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .top).clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.name).font(.headline).lineLimit(1)
                    Spacer()
                    if have != nil {
                        Label("Added", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(entry.code ? "\(entry.site) · includes code" : entry.site).font(.caption).foregroundStyle(.secondary)
                Text(entry.about ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                HStack {
                    Text(entry.author.map { "by \($0) (not verified)" } ?? "").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    if community.reported.contains(entry.id) {
                        Text("Reported").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Menu("Report") {
                            ForEach(SharingService.ReportReason.allCases, id: \.self) { r in
                                Button(r.title) { community.report(entry, r) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                        .testAnchor("boost.gallery.report.\(entry.id)")
                    }
                    // A later revision of one installed from the gallery is an Update, as Airc's own are.
                    Button(entry.action(installed: have).rawValue) { gallery.get(entry) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .testAnchor("boost.gallery.get.\(entry.id)")
                }
            }
            .padding(12)
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func card(_ entry: BoostGallery.Entry) -> some View {
        let have = installed[entry.id]
        let newer = (entry.file.revision ?? 1) > (have?.origin?.revision ?? .max)
        return VStack(alignment: .leading, spacing: 0) {
            BoostPreviewCard(file: entry.file).frame(height: 150).clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.file.name).font(.headline).lineLimit(1)
                    Spacer()
                    if have != nil, !newer {
                        Label("Added", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.file.site).font(.caption).foregroundStyle(.secondary)
                Text(entry.file.about ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                HStack {
                    Text("by \(entry.file.author ?? BoostGallery.author)").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button(newer ? "Update" : have == nil ? "Get" : "Review") { gallery.get(entry) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .testAnchor("boost.gallery.get.\(entry.id)")
                }
            }
            .padding(12)
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Entry points

enum BoostSharing {
    /// A Boost file, a Boost link (BoostLink), or a shared Space's or folder's link (ShareLinkImport, H01/H02).
    static func accepts(_ url: URL) -> Bool {
        (url.isFileURL && url.pathExtension.lowercased() == "airc-boost") || BoostLink.isLink(url) || ShareLinkImport.accepts(url)
    }
    static func error(_ message: String, on window: NSWindow) {
        let alert = NSAlert(); alert.messageText = "Couldn’t open Boost"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    /// A file, or a link from another app: the review on `window`.
    @discardableResult static func open(_ url: URL, on window: NSWindow) -> Bool {
        let app = NSApp.delegate as? AppDelegate
        let controller = app?.controllers.first { $0.window === window } ?? app?.browserWindow()
        if ShareLinkImport.accepts(url) {
            guard let controller else { return false }
            ShareLinkImport.open(url, in: controller)
            return true
        }
        guard let center = BoostCenter.shared else { return false }
        guard window.attachedSheet == nil else { NSSound.beep(); return false }
        do {
            let link = !url.isFileURL
            let file = link ? try BoostLink.file(from: url) : try BoostFile.read(url)
            BoostImportReview(file: file, source: link ? .link : .file, parent: window, controller: controller, center: center).present()
            return true
        } catch { self.error(error.localizedDescription, on: window); return false }
    }
    /// A tab's page is a Boost link: its window reviews it.
    static func openLink(_ url: URL, from tab: EngineTab) {
        guard let app = NSApp.delegate as? AppDelegate, let c = app.controller(owning: tab) else { return }
        open(url, on: c.window)
    }
    static func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first(where: accepts)
    }
}

extension WindowController {
    /// A toast with one action (Turn On after installing a Boost with code; the Library's Undo), up long enough to reach.
    func showActionToast(_ text: String, action: (title: String, run: () -> Void)) {
        toast.show(text, palette: currentPalette, in: card.frame, duration: AircMetrics.Toast.fullScreenDuration, action: action)
    }
    func openBoostFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.aircBoost]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            BoostSharing.open(url, on: self.window)
        }
    }
    func newBoost() {
        if let id = shownTabID, BoostDomain.key(for: engineTab(for: id)?.url) != nil { showBoostEditor(); return }
        let alert = NSAlert(); alert.messageText = "New Boost"; alert.informativeText = "Enter the site you want to customize, such as example.com."
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: input.contains("://") ? input : "https://" + input)
            guard let site = BoostDomain.key(for: url), BoostFile.validSite(site) else {
                BoostSharing.error(BoostFile.Invalid.domain.localizedDescription, on: self.window); return
            }
            self.showBoostEditor(domain: site)
        }
    }
    /// The Boost gallery (File → Boost Gallery…, the Command Bar, Settings).
    func showBoostGallery() {
        guard boostsAvailable, let app else { return showToast("Boosts need the Chromium engine") }
        BoostGalleryWindow.show(app: app)
    }
    /// The share sheet for the editor's Boost, with the editor's unsaved code saved first (what's shared is what runs).
    func shareBoost(_ model: BoostEditorModel) {
        guard let center = BoostCenter.shared else { return }
        if model.codeDirty { model.saveCode() }
        BoostShareSheet(domain: model.domain, parent: window, controller: self, center: center)?.present()
    }
    /// Arc's "Rename this Boost…".
    func renameBoost(_ model: BoostEditorModel) {
        let alert = NSAlert(); alert.messageText = "Rename Boost"; alert.informativeText = "A name for your Boost for \(model.domain)."
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = model.boost.name ?? ""
        field.placeholderString = model.domain
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            model.rename(field.stringValue)
        }
    }
}

struct BoostsSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var boosts: [Boost] = BoostCenter.shared?.store.all ?? []
    private var shownPage: EngineTab? {
        guard let c = model.controller, let id = c.shownTabID else { return nil }
        return c.engineTab(for: id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Customize sites on this Mac. Review shared code before installing it.").foregroundStyle(.secondary)
            HStack {
                Button("Browse Gallery…") { if let app = model.app { BoostGalleryWindow.show(app: app) } }
                    .testAnchor("settings.boosts.gallery")
                Button("Import…") { model.app?.browserWindow()?.openBoostFile() }
                    .help("Review and add a Boost file (.airc-boost)").testAnchor("settings.boosts.import")
                Spacer()
            }
            if boosts.isEmpty { Text("No Boosts yet. Choose New Boost from the sidebar’s + menu, or get one from the gallery.") }
            ForEach(boosts, id: \.domain) { boost in
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(get: { boost.enabled }, set: { on in
                        BoostCenter.shared?.setEnabled(on, domain: boost.domain, page: shownPage)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(boost.name ?? boost.domain).font(.headline)
                            Text(([boost.name == nil ? nil : boost.domain, Self.origin(boost)] as [String?]).compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Edit") {
                            guard let app = model.app, let c = app.browserWindow() else { return }
                            c.showBoostEditor(domain: boost.domain)
                            if !app.options.isAutomated { c.window.makeKeyAndOrderFront(nil) }
                        }
                        Button("Share Boost…") {
                            guard let window = model.app?.settingsWindow?.window, let center = BoostCenter.shared else { return }
                            BoostShareSheet(domain: boost.domain, parent: window, controller: model.app?.browserWindow(), center: center)?.present()
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { BoostCenter.shared?.remove(domain: boost.domain, page: shownPage) }
                    }
                }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(.top, 20)
            .onReceive(NotificationCenter.default.publisher(for: BoostCenter.didChange)) { _ in boosts = BoostCenter.shared?.store.all ?? [] }
    }

    static func origin(_ b: Boost) -> String? {
        guard let o = b.origin else { return nil }
        let edited = o.edited(b) ? ", edited" : ""
        switch o.kind {
        case .shared: return "Shared, version \(o.revision)\(edited)"
        case .installed: return o.gallery ? "From the gallery\(edited)" : "From \(o.author ?? "someone"), version \(o.revision)\(edited)"
        }
    }
}
