# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Produce an unapplied diff without writing into the app agent's files.
from pathlib import Path
import difflib
root = Path(__file__).resolve().parents[2]
out = root / 'engine/tests/pass11-adapter'
out.mkdir(exist_ok=True)
changes = {}
p = root / 'apps/browser/Sources/Airc/Engine/BrowserEngine.swift'
s = p.read_text()
s = s.replace('protocol BrowserEngine: AnyObject {', '''struct EngineLinkRequest {
    let url: URL
    let source: String
    let disposition: String
    let sourceBundleID: String?
    let userGesture: Bool
    let opener: EngineTab?
}
enum EngineHostingError: Error { case rejected(String) }

protocol BrowserEngine: AnyObject {
    /// Main-thread policy; true consumes the link. Defer tab mutation to the next turn.
    var linkRouter: ((EngineLinkRequest) -> Bool)? { get set }
    /// Call inside application(_:open:) while its Apple event is current.
    func routeExternalURL(_ url: URL) -> Bool''')
s = s.replace('extension BrowserEngine {', '''extension BrowserEngine {
    var linkRouter: ((EngineLinkRequest) -> Bool)? { get { nil } set {} }
    func routeExternalURL(_ url: URL) -> Bool { false }''',1)
s = s.replace('protocol EngineWindow: AnyObject {', '''protocol EngineWindow: AnyObject {
    /// 1–4 distinct live tabs, each in an app-owned view belonging to this window.
    /// Reuse views and resize their frames; don't call this for every divider tick.
    func presentPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws
    func focusPane(_ tab: EngineTab)
    /// Same-profile transfer; wrapper, WebContents, media and delegate identity survive.
    func moveTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws
    func openPeek(url: URL, opener: EngineTab, in host: NSView) throws -> EngineTab''')
s += '''
// WebKit remains buildable; it must explicitly implement live hosting before using these UI paths.
extension EngineWindow {
    func presentPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws {
        throw EngineHostingError.rejected("multiPaneUnsupported")
    }
    func focusPane(_ tab: EngineTab) { tab.focus() }
    func moveTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws {
        throw EngineHostingError.rejected("liveMoveUnsupported")
    }
    func openPeek(url: URL, opener: EngineTab, in host: NSView) throws -> EngineTab {
        throw EngineHostingError.rejected("peekUnsupported")
    }
}
'''
changes[p] = s
p = root / 'apps/browser/Sources/Airc/Engine/ChromiumEngine.swift'
s = p.read_text().replace('    let core: AircEngine', '''    var linkRouter: ((EngineLinkRequest) -> Bool)? {
        get { ChromiumRuntime.linkRouter }
        set { ChromiumRuntime.linkRouter = newValue }
    }
    func routeExternalURL(_ url: URL) -> Bool { core.routeExternalURL(url.absoluteString) }
    let core: AircEngine''',1)
s = s.replace('    func activateTab(_ tab: EngineTab) {', '''    func presentPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws {
        let tabs = panes.compactMap { $0.tab as? ChromiumTab }
        guard (1...4).contains(panes.count), tabs.count == panes.count,
              Set(tabs.map { ObjectIdentifier($0) }).count == panes.count,
              Set(panes.map { ObjectIdentifier($0.host) }).count == panes.count,
              tabs.allSatisfy({ $0.owner === self && !$0.isClosed }),
              panes.allSatisfy({ $0.host.window === window }),
              tabs.contains(where: { $0 === focused }) else {
            throw EngineHostingError.rejected("invalidPanes")
        }
        for tab in wrappedTabs.values where !tabs.contains(where: { $0 === tab }) {
            tab.core.setPageVisible(false)
        }
        for (index, pane) in panes.enumerated() {
            tabs[index].core.independentZoom = true
            tabs[index].core.attach(to: pane.host)
        }
        focusPane(focused)
    }
    func focusPane(_ tab: EngineTab) {
        guard let tab = tab as? ChromiumTab, tab.owner === self, tab.core.pageVisible else { return }
        selected = tab
        core.activate(tab.core)
        tab.core.focus()
    }
    func moveTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws {
        guard let tab = tab as? ChromiumTab, let profile = profile as? ChromiumProfile else {
            throw EngineHostingError.rejected("wrongEngine")
        }
        if let error = core.moveTab(tab.core, profile: profile.core, to: host) {
            throw EngineHostingError.rejected(error)
        }
        let key = ObjectIdentifier(tab.core)
        if let old = tab.owner, old !== self {
            old.wrappedTabs.removeValue(forKey: key)
            if old.selected === tab { old.selected = nil }
        }
        tab.owner = self
        wrappedTabs[key] = tab
    }
    func openPeek(url: URL, opener: EngineTab, in host: NSView) throws -> EngineTab {
        guard let opener = opener as? ChromiumTab,
              let tab = core.openPeek(url: url.absoluteString, opener: opener.core, in: host) else {
            throw EngineHostingError.rejected("invalidPeek")
        }
        return wrap(tab)
    }
    func activateTab(_ tab: EngineTab) {''',1)
s = s.replace('        if selected !== tab { selected?.core.setPageVisible(false) }','''        // Returning to normal presentation hides every other pane/overlay.
        wrappedTabs.values.filter { $0 !== tab }.forEach { $0.core.setPageVisible(false) }''',1)
# A tab can move out and back before this callback's deferred cleanup executes.
s = s.replace('            if self.selected?.core === tab { self.selected = nil }', '''            if let profile = tab.profile, self.core.tabs(for: profile).contains(where: { $0 === tab }) { return }
            if self.selected?.core === tab { self.selected = nil }''',1)
s = s.replace('    private let started: () -> Void', '''    static var linkRouter: ((EngineLinkRequest) -> Bool)?
    func engine(_ engine: AircEngine, routeLink request: [String: Any], opener: AircTab?) -> Bool {
        guard let raw = request["url"] as? String, let url = URL(string: raw) else { return false }
        return Self.linkRouter?(EngineLinkRequest(url: url,
            source: request["source"] as? String ?? "page",
            disposition: request["disposition"] as? String ?? "foreground_tab",
            sourceBundleID: request["sourceBundleID"] as? String,
            userGesture: request["userGesture"] as? Bool ?? false,
            opener: opener?.delegate as? ChromiumTab)) ?? false
    }
    private let started: () -> Void''',1)
s = s.replace('        owner?.engine.pictureInPictureRequestsTab?(self)', '\n'.join([
    '        if reason == "page", core.pageVisible { owner?.focusPane(self) }',
    '        else { owner?.engine.pictureInPictureRequestsTab?(self) }']))
changes[p] = s
patch = ''
for p, s in changes.items():
    name = str(p.relative_to(root))
    patch += ''.join(difflib.unified_diff(p.read_text().splitlines(True), s.splitlines(True), fromfile='a/'+name, tofile='b/'+name))
    (out / p.name).write_text(s)
(root / 'engine/app-pass11.patch').write_text(patch)
# Extract the tiny real app host class for isolated adapter compilation.
views = (root / 'apps/browser/Sources/Airc/UI/WindowViews.swift').read_text()
a = views.index('final class PageHostView:')
b = views.index('\n}', a) + 2
(out / 'PageHostView.swift').write_text('import AppKit\n' + views[a:b] + '\n')
