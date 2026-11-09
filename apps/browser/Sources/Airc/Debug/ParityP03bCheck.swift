// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script parityp03b` (both engines): P03b's keyboard leftovers (docs/user/parity-p03b.md).
///   - K06, Arc's Cycle Tab: ⌃⌘→ and ⌃⌘← go through all six tabs of a Space in the order they were last used (past
///     ⌃Tab's five), on with the keys let go in between, wrapping; only the stop counts as used; a new tab starts the
///     next cycle with it, a closed tab drops out, another Space cycles its own tabs, and a private window's keys and
///     pages never touch the main window's order. The Tabs menu has both items with Arc's keys.
///   - Esc's order, innermost first and one surface per press: Command Bar, Peek, find, full screen, the sidebar's
///     keyboard. Full screen is the controller's state with no window going full screen (exit only counts its requests):
///     a check never takes the owner's display to a new Space.
///   - C02: ⌥⌘⌫ is a row in Settings › Shortcuts › Command Bar; moved to ⌃⌥⌘D, the old key removes nothing and the new
///     one removes the highlighted page; a history row shows a ✕ under the pointer that removes it (VoiceOver's press),
///     a search row none.
///   - K03: bracket keys on layouts that type [ ] { } only with ⌥: on this Mac's layout the keys ⌘[ ⌘] ⌘{ ⌘} have
///     (Back, Forward, Previous and Next Tab) run from the US key positions and from the ⌥ brackets, by real key events;
///     German, French, Swiss and Norwegian layouts' tables (read from macOS, not selected), each driven once; a US layout
///     gets none; ⌘+ stays Zoom In.
/// Keys go through the app's own event path (NSApp.sendEvent: the app's key monitor), then the shortcuts check's key
/// window stand-in; never HID events.
extension SnapshotRunner {
    func parityP03bScenario() {
        let store = c.store
        var server: LocalPageServer?
        var base = ""
        var sid = "", otherSid = ""
        var tabs: [String] = []          // T1 … T6, used in that order
        var closing: String?
        var names: [String: String] = [:]
        var otherTabs: [String] = []
        let one = "https://history.example.org/p03b-one"
        let two = "https://history.example.org/p03b-two"
        let removeID = ShortcutCenter.removeSuggestion.id
        var bar: CommandBarView? { c.commandBar }
        func name(_ id: String?) -> String { id.flatMap { names[$0] } ?? "other" }
        func shown() -> String { name(c.shownTabID) }
        func arrow(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }

        /// A key down and up through the app's event path, in `window` (the main window by default).
        func send(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = [], ignoring: String? = nil, window: NSWindow? = nil) {
            let w = window ?? c.window
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                               context: nil, characters: chars, charactersIgnoringModifiers: ignoring ?? chars,
                                               isARepeat: false, keyCode: code) else { continue }
                NSApp.sendEvent(e)
            }
        }
        func cycle(_ forward: Bool, window: NSWindow? = nil) {
            send(arrow(forward ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey), forward ? 124 : 123,
                 [.control, .command, .function, .numericPad], window: window)
            p03Flags([])   // the keys let go: the cycle goes on all the same
        }
        /// Esc through the app's event path; when AppKit didn't deliver it to our window (another app's window in front
        /// keeps it from being key, so `arrived` isn't true), the window's own `sendEvent` hands it to the first
        /// responder, as P07's keys do. The key monitor has had it either way.
        func escape(arrived: (() -> Bool)? = nil) {
            send("\u{1b}", 53)
            guard let arrived, !arrived() else { return }
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: c.window.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                note("parityp03b: Esc handed to the window (\(inputBlocked ?? "not key"))")
                c.window.sendEvent(e)
            }
        }
        func waitFor(_ condition: @escaping () -> Bool, timeout: Double = 3) {
            step { [self] done in waitUntil(condition, timeout: timeout, then: done) }
        }

        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = { path in
                let n = path.split(separator: "/").last.map(String.init) ?? "page"
                return .init(body: "<!doctype html><meta charset=utf-8><title>\(n)</title><h1>\(n)</h1><input id=f>")
            }
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityp03b: a loopback server") }
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return }
            note("parityp03b: engine \(app?.engine.name ?? "?"), window on active Space \(c.window.isOnActiveSpace), "
                 + "screen locked \(Self.screenLocked), layout \(Self.layoutName)")
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            app?.settings.values.suggestionsEnabled = false
            do {
                sid = try store.createSpace(name: "Cycle", profileID: store.defaultProfile.id, after: c.currentSpaceID).id
                otherSid = try store.createSpace(name: "Other", profileID: store.defaultProfile.id, after: sid).id
                for i in 1...6 {
                    let t = try store.openTab(url: "\(base)/T\(i)", inSpace: sid, activate: false, title: "T\(i)")
                    tabs.append(t.id); names[t.id] = "T\(i)"
                }
                for n in ["X", "Y"] {
                    let t = try store.openTab(url: "\(base)/\(n)", inSpace: otherSid, activate: false, title: n)
                    otherTabs.append(t.id); names[t.id] = n
                }
            } catch {
                check(false, "parityp03b: Spaces and tabs (\(error))")
            }
            c.reloadAll(animated: false)
            c.switchToSpace(otherSid, animated: false)
        }
        // Each tab used in turn: Y then X in Other; T1 … T6 in Cycle (T6 last).
        for i in [1, 0] { run { [self] in if otherTabs.indices.contains(i) { c.show(otherTabs[i]) } }; wait(0.05) }
        run { [self] in c.switchToSpace(sid, animated: false) }
        for i in 0..<6 { run { [self] in if tabs.indices.contains(i) { c.show(tabs[i]) } }; wait(0.05) }
        waitForPage()

        // MARK: K06 Cycle Tab

        uiCase(window: { self.c.window }) {
            run { [self] in
                let recent = store.recentTabs(inSpace: sid).map { name($0) }
                check(recent == ["T6", "T5", "T4", "T3", "T2", "T1"], "parityp03b cycle: the Space's order of use (\(recent))")
                c.focusShownPage()
                var seen: [String] = []
                for _ in 0..<6 { cycle(true); seen.append(shown()) }
                check(seen == ["T5", "T4", "T3", "T2", "T1", "T6"],
                      "parityp03b cycle: ⌃⌘→ six times goes through all six tabs back in time and wraps, keys let go between (\(seen))")
                cycle(false)
                let back = shown()
                cycle(false)
                let back2 = shown()
                check([back, back2] == ["T1", "T2"], "parityp03b cycle: ⌃⌘← goes the other way, wrapping (\([back, back2]))")
                let after = store.recentTabs(inSpace: sid).map { name($0) }
                check(after == ["T2", "T6", "T5", "T4", "T3", "T1"],
                      "parityp03b cycle: only the stop counts as used, the tabs passed keep their place (\(after))")
            }
            // Open: a new tab is shown; the next cycle starts with it, then the tab shown before it.
            run { [self] in
                do {
                    let t = try store.openTab(url: "\(base)/T7", inSpace: sid, activate: false, title: "T7")
                    names[t.id] = "T7"
                    c.reloadAll(animated: false)
                    c.show(t.id)
                } catch { check(false, "parityp03b cycle: a new tab (\(error))") }
            }
            wait(0.1)
            run { [self] in
                cycle(true)
                let first = shown()
                let order = TabCycler.cycle(of: c)?.order.map { name($0) } ?? []
                check(first == "T2" && order.first == "T7",
                      "parityp03b cycle: after a new tab, ⌃⌘→ goes from it to the tab used before it (\(first), cycle \(order.prefix(3)))")
                // Close: the next tab of the cycle closes meanwhile and drops out.
                closing = TabCycler.cycle(of: c)?.order.dropFirst(2).first
                if let next = closing { c.closeTab(next) }
            }
            // The engine closes the page after its unload handlers (Chromium answers a moment later).
            waitFor({ closing.map { store.tab($0) == nil } ?? true })
            run { [self] in
                let next = closing
                cycle(true)
                let skipped = shown()
                check(next != nil && names[next!] == "T6" && skipped == "T5" && !(TabCycler.cycle(of: c)?.order.contains(next!) ?? true),
                      "parityp03b cycle: a tab closed mid-cycle drops out (closed \(name(next)), shown \(skipped))")
            }
            // Space switch: Other's keys cycle Other's two tabs, and coming back Cycle goes on from its own order.
            run { [self] in c.switchToSpace(otherSid, animated: false) }
            wait(0.2)
            run { [self] in
                let start = shown()
                cycle(true)
                let a = shown()
                cycle(true)
                let b = shown()
                check(start == "X" && a == "Y" && b == "X" && c.currentSpaceID == otherSid,
                      "parityp03b cycle: in another Space, its own two tabs (\([start, a, b]))")
            }
            run { [self] in c.switchToSpace(sid, animated: false) }
            wait(0.2)
            run { [self] in
                let start = shown()
                let recent = store.recentTabs(inSpace: sid).map { name($0) }
                cycle(true)
                check(start == "T5" && shown() == recent.dropFirst().first && c.currentSpaceID == sid,
                      "parityp03b cycle: back in Cycle, a new cycle from its own order (\(start) → \(shown()), order \(recent.prefix(3)))")
                let items = NSApp.mainMenu.map { Self.p03bItems($0) } ?? []
                let fwd = items.first { $0.title == "Cycle Tab Forward" }, bwd = items.first { $0.title == "Cycle Tab Backward" }
                check(fwd?.keyEquivalent == arrow(NSRightArrowFunctionKey) && fwd?.keyEquivalentModifierMask == [.control, .command]
                      && bwd?.keyEquivalent == arrow(NSLeftArrowFunctionKey) && bwd?.keyEquivalentModifierMask == [.control, .command],
                      "parityp03b cycle: the Tabs menu has Cycle Tab Forward ⌃⌘→ and Cycle Tab Backward ⌃⌘←")
            }
        }

        // Private window: its keys and pages never touch the main window's order.
        var priv: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { p in
                priv = p
                p?.navigate(URL(string: "\(base)/Private")!)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done)
            }
        }
        run { [self] in
            guard let p = priv else { return skip("parityp03b cycle: no private window on this engine") }
            let before = store.recentTabs(inSpace: sid), shownBefore = c.shownTabID
            // The private window is the key window now (AppKit's menus and keys follow it).
            Self.emulateKeyWindow(p.window) { [weak self] in self?.note($0) }
            cycle(true, window: p.window)
            cycle(true, window: p.window)
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            let after = store.recentTabs(inSpace: sid)
            check(after == before && c.shownTabID == shownBefore,
                  "parityp03b cycle: ⌃⌘→ in a private window leaves the main window and its order alone "
                  + "(shown \(name(shownBefore)) → \(shown()), order \(before.prefix(3).map { name($0) }) → \(after.prefix(3).map { name($0) }))")
            var stops = Set<String>()
            for _ in 0..<8 { cycle(true); stops.insert(c.shownTabID ?? "") }
            check(stops.isSubset(of: Set(before)) && !stops.contains { store.tab($0) == nil },
                  "parityp03b cycle: the main window's cycle never lands on a private page (\(stops.count) stops)")
            p.closeWindow()
        }
        wait(0.6)

        // MARK: Esc, innermost first

        var exits = 0
        uiCase(window: { self.c.window }) {
            run { [self] in
                c.isFullscreen = true   // full screen's Esc rules, with the window where it is
                exits = c.fullScreen.exitRequests
                if let opener = c.shownTabID.flatMap({ c.engineTab(for: $0) }) { c.openPeek(URL(string: "\(base)/Peeked")!, from: opener) }
            }
            waitFor({ self.c.peek != nil })
            wait(0.3)
            run { [self] in
                c.openCommandBar(mode: .newTab)
                let open = bar != nil && c.peek != nil
                escape()
                check(open && c.commandBar == nil && c.peek != nil && c.fullScreen.exitRequests == exits,
                      "parityp03b Esc: over a Peek in full screen, Esc closes only the Command Bar")
                escape()
                check(c.peek == nil || c.peek?.closing == true, "parityp03b Esc: the next Esc closes the Peek")
                check(c.fullScreen.exitRequests == exits, "parityp03b Esc: … and full screen stays")
            }
            wait(0.7)
            // Find: Peek first, then find, then full screen.
            run { [self] in c.showFind() }
            run { [self] in if let opener = c.shownTabID.flatMap({ c.engineTab(for: $0) }) { c.openPeek(URL(string: "\(base)/Peeked2")!, from: opener) } }
            waitFor({ self.c.peek != nil && self.c.peek?.closing == false })
            wait(0.3)
            run { [self] in
                escape()
                check((c.peek == nil || c.peek?.closing == true) && c.findBar != nil && c.fullScreen.exitRequests == exits,
                      "parityp03b Esc: with find open under a Peek, Esc closes the Peek, find stays")
            }
            wait(0.3)
            run { [self] in
                if let f = c.findBar?.field { c.window.makeFirstResponder(f) }
                escape { self.c.findBar == nil }
                check(c.findBar == nil && c.fullScreen.exitRequests == exits, "parityp03b Esc: then Esc closes find, full screen stays")
            }
            wait(0.7)
            // The sidebar's keyboard comes last: find, then the sidebar, and never full screen on the same press.
            run { [self] in
                c.showFind()
                c.revealCurrentTab()
                let onRow = c.window.firstResponder is SidebarRowView
                escape { self.c.findBar == nil }
                check(onRow && c.findBar == nil && c.window.firstResponder is SidebarRowView && c.fullScreen.exitRequests == exits,
                      "parityp03b Esc: sidebar keyboard and find, Esc closes find and the sidebar keeps the keyboard")
            }
            wait(0.7)
            run { [self] in
                escape { !(self.c.window.firstResponder is SidebarRowView) }
                check(!(c.window.firstResponder is SidebarRowView) && c.fullScreen.exitRequests == exits,
                      "parityp03b Esc: the next Esc gives the page the keyboard, full screen stays")
                // Only now does a second press leave full screen.
                escape()
                check(c.fullScreen.exitRequests == exits + 1, "parityp03b Esc: with nothing else open, Esc twice leaves full screen")
            }
        }
        run { [self] in c.isFullscreen = false }
        wait(0.7)

        // MARK: C02, the Command Bar's remove key and ✕

        uiCase(window: { self.c.window }) {
            run { [self] in
                let p = store.profile(ofSpace: sid).id
                app?.history.recordVisit(profileID: p, url: one, title: "P03b first quokka page", typed: true)
                app?.history.recordVisit(profileID: p, url: two, title: "P03b second quokka page", typed: true)
                let row = ShortcutCenter.groups.first { $0.title == "Command Bar" }?.commands.first
                check(row?.id == removeID && ShortcutCenter.shared.map.isRemappable(removeID)
                      && ShortcutCenter.shared.map.key(removeID)?.display == "⌥⌘⌫",
                      "parityp03b C02: Settings › Shortcuts › Command Bar lists ⌥⌘⌫, remappable (\(row?.title ?? "none"))")
                let outcome = ShortcutCenter.shared.update { $0.assign(KeyCombo("d", [.control, .option, .command]), to: removeID) }
                check(outcome == .done && ShortcutCenter.shared.map.key(removeID)?.display == "⌃⌥⌘D", "parityp03b C02: moved to ⌃⌥⌘D (\(outcome))")
                c.openCommandBar(mode: .newTab)
                bar?.type("P03b first quokka")
            }
            waitFor({ bar?.results.first?.historyURL == one })
            run { [self] in
                let p = store.profile(ofSpace: sid).id
                send("\u{7f}", 51, [.option, .command])
                check(app?.history.entry(profileID: p, url: one) != nil, "parityp03b C02: ⌥⌘⌫ no longer removes once moved")
                send("\u{4}", 2, [.control, .option, .command], ignoring: "d")
                check(app?.history.entry(profileID: p, url: one) == nil && !(bar?.results.contains { $0.historyURL == one } ?? true)
                      && bar != nil, "parityp03b C02: ⌃⌥⌘D removes the highlighted page, the bar stays open")
                ShortcutCenter.shared.update { $0.reset(removeID) }
                check(ShortcutCenter.shared.map.key(removeID)?.display == "⌥⌘⌫", "parityp03b C02: reset to ⌥⌘⌫")
                bar?.type("P03b second quokka")
            }
            waitFor({ bar?.results.contains { $0.historyURL == two } == true })
            run { [self] in
                guard let b = bar, let i = b.results.firstIndex(where: { $0.historyURL == two }), b.visibleRows.indices.contains(i) else {
                    return check(false, "parityp03b C02: the history row")
                }
                let p = store.profile(ofSpace: sid).id
                let row = b.visibleRows[i]
                row.setHoveredForTesting(true)
                let x = row.removeButton
                check(!x.isHidden && row.bounds.contains(x.frame) && x.frame.width == CommandRowRemoveButton.size
                      && x.toolTip == "Remove from History (⌥⌘⌫)",
                      "parityp03b C02: a history row under the pointer shows its ✕ (\(x.frame), \(x.toolTip ?? "-"))")
                if let img = render(b) {
                    try? img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("p03b-hover-remove.png"))
                    note("wrote p03b-hover-remove.png")
                }
                if let s = b.visibleRows.indices.first(where: { b.results[$0].historyURL == nil }) {
                    let search = b.visibleRows[s]
                    search.setHoveredForTesting(true)
                    check(search.removeButton.isHidden, "parityp03b C02: a search row has no ✕")
                    search.setHoveredForTesting(false)
                }
                row.setHoveredForTesting(true)
                check(x.accessibilityRole() == .button && x.accessibilityLabel() == "Remove from History",
                      "parityp03b C02: VoiceOver reads the ✕ as a Remove from History button")
                _ = x.accessibilityPerformPress()
                check(app?.history.entry(profileID: p, url: two) == nil && !b.results.contains { $0.historyURL == two } && c.commandBar === b
                      && c.window.firstResponder === b.fieldEditor && b.query == "P03b second quokka",
                      "parityp03b C02: the ✕ removes the page, the bar and its text stay")
                c.closeCommandBar()
            }
        }

        // MARK: K03, brackets on other layouts

        var forwardKey: (String, NSEvent.ModifierFlags)?
        var startPage = ""
        func pageName() -> String { c.shownTabID.flatMap { c.engineTab(for: $0)?.url?.lastPathComponent } ?? "-" }
        run { [self] in
            let aliases = ShortcutCenter.shared.layoutAliases
            let list = aliases.map { "\($0.id)=\(ShortcutCenter.combo($0.key, $0.modifiers)?.display ?? "?")" }
            note("parityp03b K03: \(Self.layoutName): \(list.joined(separator: ", "))")
            let typesBrackets = ShortcutCenter.currentLayout().map { l in
                (0...50).contains { l(UInt16($0), false, false) == "[" || l(UInt16($0), true, false) == "[" }
            } ?? true
            if typesBrackets {
                check(aliases.isEmpty, "parityp03b K03: this layout types [ itself: no extra keys")
            } else {
                let ids = Set(aliases.map(\.id))
                check(ids.isSuperset(of: ["tabs.back", "tabs.forward", "tabs.previous.brace", "tabs.next.brace"]),
                      "parityp03b K03: ⌘[ ⌘] ⌘{ ⌘} all have keys on \(Self.layoutName) (\(ids.sorted()))")
            }
            let zoom = ShortcutCenter.shared.commands.first { $0.key == "=" && $0.modifiers == .command }
            check(zoom?.id == "view.zoomIn", "parityp03b K03: ⌘+ stays Zoom In (\(zoom?.id ?? "none"))")
            forwardKey = aliases.first { $0.id == "tabs.forward" }.map { ($0.key, $0.modifiers) }
            // A page with somewhere to go back to.
            startPage = pageName()
            c.navigate(to: URL(string: "\(base)/Second")!, newTab: false)
        }
        wait(1.0)
        uiCase(window: { self.c.window }) {
            run { [self] in
                c.window.makeFirstResponder(nil)
                guard let back = ShortcutCenter.shared.layoutAliases.first(where: { $0.id == "tabs.back" && !$0.modifiers.contains(.option) }) else {
                    return skip("parityp03b K03: \(Self.layoutName) types [ itself (US position keys not needed)")
                }
                // The US position key: key code 33 types what the alias says on this layout.
                send(back.key, 33, back.modifiers)
            }
            waitFor({ pageName() == startPage }, timeout: 4)
            wait(0.8)   // the Back load settles before Forward
            run { [self] in
                guard ShortcutCenter.shared.layoutAliases.contains(where: { $0.id == "tabs.back" }) else { return }
                let url = pageName()
                check(url == startPage, "parityp03b K03: ⌘ with the key at US [ (\(Self.layoutName)) goes Back (\(url), from Second to \(startPage))")
                c.window.makeFirstResponder(nil)
                guard let (k, m) = forwardKey, let code = Self.p03bCode(typing: k, shift: m.contains(.shift)) else {
                    return check(false, "parityp03b K03: ⌘] has no key here")
                }
                let typed = ShortcutCenter.currentLayout()?(code, m.contains(.shift), m.contains(.option)) ?? k
                send(typed, code, m, ignoring: k)
            }
            waitFor({ pageName() == "Second" }, timeout: 4)
            run { [self] in
                guard let (k, m) = forwardKey else { return }
                let url = pageName()
                check(url == "Second", "parityp03b K03: \(ShortcutCenter.combo(k, m)?.display ?? "?") (⌘] typed with ⌥) goes Forward (\(url))")
                // ⇧⌘{ ⇧⌘} by the US positions: Previous and Next Tab.
                c.window.makeFirstResponder(nil)
                let start = c.shownTabID
                let prev = ShortcutCenter.shared.layoutAliases.first { $0.id == "tabs.previous.brace" && !$0.modifiers.contains(.option) }
                let next = ShortcutCenter.shared.layoutAliases.first { $0.id == "tabs.next.brace" && !$0.modifiers.contains(.option) }
                if let next { send(next.key, 30, next.modifiers) }
                let moved = c.shownTabID
                if let prev { send(prev.key, 33, prev.modifiers) }
                check(next != nil && prev != nil && moved != start && c.shownTabID == start,
                      "parityp03b K03: \(next.flatMap { ShortcutCenter.combo($0.key, $0.modifiers)?.display } ?? "-") Next Tab and "
                      + "\(prev.flatMap { ShortcutCenter.combo($0.key, $0.modifiers)?.display } ?? "-") Previous Tab (⌘} ⌘{)")
            }
        }
        // Other layouts' tables, as macOS has them (none is selected): one key each, through the app's key monitor.
        let layouts = [("com.apple.keylayout.German", "German"), ("com.apple.keylayout.French", "French"),
                       ("com.apple.keylayout.SwissGerman", "Swiss German"), ("com.apple.keylayout.Norwegian", "Norwegian"),
                       ("com.apple.keylayout.US", "U.S.")]
        for (id, label) in layouts {
            run { [self] in
                guard let layout = ShortcutCenter.layout(id: id) else { return skip("parityp03b K03: no \(label) layout on this Mac") }
                ShortcutCenter.shared.layoutForTesting = layout
                let aliases = ShortcutCenter.shared.layoutAliases
                note("parityp03b K03: \(label): " + aliases.map { "\($0.id)=\(ShortcutCenter.combo($0.key, $0.modifiers)?.display ?? "?")" }.joined(separator: ", "))
                if id.hasSuffix(".US") { return check(aliases.isEmpty, "parityp03b K03: U.S. types the brackets: no extra keys") }
                c.window.makeFirstResponder(nil)
                let start = c.shownTabID
                guard let next = aliases.first(where: { $0.id == "tabs.next.brace" && !$0.modifiers.contains(.option) }),
                      let prev = aliases.first(where: { $0.id == "tabs.previous.brace" && !$0.modifiers.contains(.option) }) else {
                    return check(false, "parityp03b K03: \(label): ⌘{ ⌘} have keys")
                }
                send(next.key, 30, next.modifiers)
                let moved = c.shownTabID
                send(prev.key, 33, prev.modifiers)
                let zoom = ShortcutCenter.shared.commands.first { $0.key == "=" && $0.modifiers == .command }?.id
                check(moved != start && c.shownTabID == start && zoom == "view.zoomIn" && aliases.contains { $0.id == "tabs.back" },
                      "parityp03b K03: \(label): \(ShortcutCenter.combo(next.key, next.modifiers)?.display ?? "?") and "
                      + "\(ShortcutCenter.combo(prev.key, prev.modifiers)?.display ?? "?") switch tabs, ⌘[ has a key, Zoom In kept")
            }
        }
        run { [self] in
            ShortcutCenter.shared.layoutForTesting = nil
            server?.stop()
        }
    }

    /// Every item of a menu and its submenus.
    static func p03bItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(p03bItems) ?? []) }
    }

    /// The key code that types `chars` on this Mac's layout (with ⇧ or not).
    static func p03bCode(typing chars: String, shift: Bool) -> UInt16? {
        guard let l = ShortcutCenter.currentLayout() else { return nil }
        return (0...50).map(UInt16.init).first { l($0, shift, false)?.lowercased() == chars.lowercased() }
    }
}
#endif
