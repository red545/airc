#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Generate integration diff without editing app-owned files."""
from pathlib import Path
import difflib
root = Path(__file__).resolve().parents[2]
changes = {}
def change(name, old, new):
    if name not in changes:
        original = (root / name).read_text()
        changes[name] = [original, original]
    assert old in changes[name][1], (name, old)
    changes[name][1] = changes[name][1].replace(old, new, 1)
c = 'apps/browser/Sources/Airc/Engine/ChromiumEngine.swift'
b = 'apps/browser/Sources/Airc/Engine/BrowserEngine.swift'
w = 'apps/browser/Sources/Airc/Browser/WindowController.swift'
change(b, '    /// The page closed itself (window.close()).', '    /// The page closed itself or completed a host-requested close.')
change(b, '    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab)', '''    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab)
    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab)''')
change(b, 'protocol EngineWindow: AnyObject {', '''extension EngineWindowDelegate {
    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab) {}
}

protocol EngineWindow: AnyObject {''')
change(c, '    var autofillSuggestionsDidChange:', '''    // Opt-in only after installing a picker. Rows contain an opaque "index" string;
    // empty rows dismiss it. Call accept after a deliberate user selection.
    var usesHostPasswordSuggestions = false
    @discardableResult func acceptAutofillSuggestion(in tab: EngineTab, index: Int) -> Bool {
        (tab as? ChromiumTab)?.core.acceptAutofillSuggestion(index) ?? false
    }
    func hideAutofillSuggestions(in tab: EngineTab) {
        (tab as? ChromiumTab)?.core.hideAutofillSuggestions()
    }
    func enterPictureInPictureForHost(_ tab: EngineTab, completion: @escaping (String, Bool) -> Void) {
        guard let tab = tab as? ChromiumTab else { completion("none", false); return }
        tab.core.enterPictureInPicture(forHost: completion)
    }
    var autofillSuggestionsDidChange:''')
change(c, '        let wrapper = wrappedTabs[key]\n', '')
change(c, '''            // A close the app asked for (⌘W, Clear Today) isn't reported through tabWillClose: the engine reports only
            // the page closing itself. Its removal is the sign that its unload handlers let it go ("Leave"). The app
            // ignores a page it has already forgotten.
            if let wrapper, wrapper.owner === self, tab.closed { self.delegate?.engineWindow(self, tabRequestedClose: wrapper) }
''','')
change(c, '    func tabWillClose(_ tab: AircTab) { dismissDevTools(); owner?.pageClosed(self) }', '''    func tabWillClose(_ tab: AircTab) { dismissDevTools(); owner?.pageClosed(self) }
    func tabDidClose(forHost tab: AircTab) { dismissDevTools(); owner?.pageClosed(self) }
    func tabDidCancelClose(_ tab: AircTab) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let owner = self.owner else { return }
            owner.delegate?.engineWindow(owner, tabCancelledClose: self)
        }
    }
    func tabWantsPasswordSuggestions(_ tab: AircTab) -> Bool {
        owner?.engine.usesHostPasswordSuggestions == true
    }''')
# WebKit retains its existing heuristic; Chromium now has explicit lifecycle signals.
change(w, '            watchForStay(id)', '            if !(app?.engine is ChromiumEngine) { watchForStay(id) }')
# engine.id spelling verified/adjusted by adapter typecheck below.
change(w, '    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {', '''    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab) {
        guard let id = tabID(for: tab) else { return }
        closingTabs.remove(id)
        if archiveQueue?.current == id { stopArchiveQueue(stayedOn: id) }
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {''')
change('apps/browser/Sources/Airc/Browser/Peek.swift',
    'return pinned && request.disposition == "foreground_tab" && Self.crossSite(opener.url, request.url)',
    'return pinned && (request.disposition == "current_tab" || (request.disposition == "foreground_tab" && Self.crossSite(opener.url, request.url)))')
out = ''.join(''.join(difflib.unified_diff(a.splitlines(True), b.splitlines(True), fromfile='a/'+name, tofile='b/'+name)) for name,(a,b) in changes.items())
(root / 'engine/app-pass12.patch').write_text(out)

# Optional generated adapter sources are for compilation only (ignored build output).
out = root / 'engine/host/build/pass12-adapter'
out.mkdir(parents=True, exist_ok=True)
for name, (_, text) in changes.items():
    if name in (b, c): (out / Path(name).name).write_text(text)
for name in ('EnginePageCommands.swift', 'EngineProfileServices.swift'):
    path = root / 'apps/browser/Sources/Airc/Engine' / name
    if path.exists(): (out / name).write_text(path.read_text())
views = (root / 'apps/browser/Sources/Airc/UI/WindowViews.swift').read_text()
a = views.index('final class PageHostView:')
z = views.index('\n}', a) + 2
(out / 'PageHostView.swift').write_text('import AppKit\n' + views[a:z] + '\n')
