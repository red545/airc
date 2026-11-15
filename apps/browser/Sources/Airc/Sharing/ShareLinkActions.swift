// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// H01, H02's entry points: Share Space… and Share Folder… (the sidebar menus, the Command Bar), and opening a shared
/// link: a hosted one (`https://aircbrowser.com/s/<id>`, its page's `airc://share/<id>`) or a fragment link
/// (`https://aircbrowser.com/s#v1.…`, `airc://share#v1.…`), from another app, a drop, or a tab that goes to one.
/// P19d: a shared Easel's link (`https://aircbrowser.com/e/<id>`, its page's `airc://easel/<id>`) opens the same ways,
/// in EaselImportSheet.
extension WindowController {
    /// Share Space…: its pinned tree (ShareLinkSheet shows exactly what the link holds before it's published).
    func shareSpace(_ spaceID: String) {
        guard let draft = store.shareDraft(ofSpace: spaceID) else {
            return showToast("Pin some web pages in this Space to share it")
        }
        ShareLinkSheet(draft: draft, sourceID: spaceID, controller: self).present()
    }

    /// Share Folder…: its contents.
    func shareFolder(_ folderID: String) {
        guard let draft = store.shareDraft(ofFolder: folderID) else { return showToast("This folder has no web pages to share") }
        ShareLinkSheet(draft: draft, sourceID: folderID, controller: self).present()
    }

    /// The Command Bar's entry.
    func shareCommandActions() -> [CommandAction] {
        [.init(title: "Share This Space…", symbol: "link", hint: "", keywords: ["share", "link", "space", "send", "copy link", "snapshot"]) { [weak self] in
            guard let self else { return }
            self.shareSpace(self.currentSpaceID)
        }]
    }

    /// A tab went to a share link (typed, or a link clicked anywhere): its window shows the import preview, once for
    /// each link in each tab (WindowController.tabDidChangeURL's hook).
    func shareLinkPageShown(_ tab: EngineTab) {
        // Scheme, host and path first (string checks): every other page leaves here.
        guard let url = tab.url, ShareLinkImport.accepts(url) else { return }
        // Never for a private page or an agent's (MCP) window: those keep nothing of this.
        guard !DeveloperMode.isPrivate(tab) else { return }
        guard !AgentCenter.shared.isAgentTab(tab) else { return }
        guard ShareLinkImport.firstTime(url, in: ObjectIdentifier(tab).hashValue) else { return }
        ShareLinkImport.open(url, in: self)
    }
}

enum ShareLinkImport {
    /// The links each tab has shown a preview for.
    static var shown = Set<String>()
    #if AIRC_TESTING
    /// The last refusal, for the checks (its alert is the window's sheet), and the last link dropped unread.
    static var lastError: String?
    static var lastPrecheck: String?
    #endif

    /// Fragments longer than this are refused before anything else (the format's own cap is far lower).
    static let maximumFragment = 256 * 1024

    static var service: URL { SharingCenter.shared.service.base }

    /// A share link of any kind (string checks only): a Space's or folder's, hosted or in the link, or an Easel's.
    static func accepts(_ url: URL) -> Bool {
        ShareLink.isLink(url) || HostedShareLink.isLink(url, service: service) || HostedEaselLink.isLink(url, service: service)
    }

    /// Whether a tab's link is new for that tab (the preview shows once per link and tab).
    static func firstTime(_ url: URL, in tab: Int) -> Bool {
        accepts(url) && shown.insert("\(tab) \(url.absoluteString)").inserted
    }

    /// Before a fragment link is decoded: the fragment's size, the version's form and the payload's alphabet. A link
    /// that fails is only logged (Links.log), never shown.
    static func precheck(_ url: URL) -> String? {
        guard let f = url.fragment else { return "no fragment" }
        guard f.utf8.count <= maximumFragment else { return "a fragment of \(f.utf8.count) bytes" }
        guard let dot = f.firstIndex(of: "."), f.first == "v" else { return "no version" }
        let tag = f[f.index(after: f.startIndex)..<dot]
        guard !tag.isEmpty, tag.count <= 9, tag.first != "0", tag.allSatisfy({ $0.isASCII && $0.isNumber }) else { return "a malformed version" }
        let payload = f[f.index(after: dot)...]
        guard !payload.isEmpty, payload.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return "a payload that isn't base64url"
        }
        return nil
    }

    /// The import preview for `url` in `c` (nothing is added until Add); a Boost goes to the usual Boost review. A
    /// hosted link's snapshot is fetched first; a link that's gone or refused says so, and nothing is added.
    static func open(_ url: URL, in c: WindowController) {
        if let id = HostedEaselLink.id(from: url, service: service) { return EaselImportSheet.open(id: id, in: c) }
        if let id = HostedShareLink.id(from: url, service: service) {
            Task { @MainActor in
                do {
                    let snapshot = try await SharingCenter.shared.service.snapshot(id: id)
                    guard c.window.attachedSheet == nil else { return NSSound.beep() }
                    ShareImportSheet(snapshot: snapshot, controller: c).present()
                } catch {
                    refuse(error, in: c)
                }
            }
            return
        }
        if let why = precheck(url) {
            #if AIRC_TESTING
            lastPrecheck = why
            #endif
            return LinkLog.write("share link \(LinkLog.host(url)): refused before decoding (\(why))")
        }
        guard c.window.attachedSheet == nil else { return NSSound.beep() }
        do {
            let snapshot = try ShareLink.snapshot(from: url)
            if case .boost(let file) = snapshot.kind {
                guard let center = BoostCenter.shared else { return c.showToast("Boosts need the Chromium engine") }
                BoostImportReview(file: file, source: .link, parent: c.window, controller: c, center: center).present()
                return
            }
            ShareImportSheet(snapshot: snapshot, controller: c).present()
        } catch {
            refuse(error, in: c)
        }
    }

    private static func refuse(_ error: Error, in c: WindowController) {
        #if AIRC_TESTING
        lastError = error.localizedDescription
        #endif
        guard c.window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t open this link"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: c.window)
    }
}
