// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import Carbon.HIToolbox
import ObjectiveC

/// `--script shortcuts` (owner, 2026-11-06: "cmd+shift+v doesn't work … any shortcut like cmd+b"). Editors' and pages'
/// shortcuts on a loopback editor page, the editing keys in the page's fields and in ours, and the page-first rule for
/// the shortcuts Airc also binds (CB-3), through real key events (NSApp.postEvent). Docs/qa/shortcuts.md has the table.
///
/// Scripted runs never activate the app, so the window is never key. AppKit then routes ⌘ keys differently: the page
/// never sees them as key equivalents (Chromium's page view takes those only in a key window), and the Edit menu's
/// Copy, Paste and Undo find no target (nil-targeted actions go to the key window). A person's window is key: its views
/// get a ⌘ key first (`performKeyEquivalent:`), then the main menu, then the focused view's keyDown. So this check makes
/// the test window report itself key (`isKeyWindow`, `NSApp.keyWindow`) and replays that order after the app's own key
/// monitor (`KeyMonitor.testKeyWindowDispatch`). Everything from there on (the page, the engine's unhandled-key path,
/// WebKit's resend, the menus and their targets) is the app's and the engines' real code.
///
/// The general pasteboard is saved first and put back at the end, unless someone copied in between.
extension SnapshotRunner {
    /// One key as AppKit delivers it, on this Mac's keyboard layout. Chromium rebuilds a key event from its key code
    /// (its event serialization), so a posted event must be one the layout really makes: ⌘Z is key code 16 on a German
    /// layout, and the US code 6 arrives there as ⌘Y. A key is given by its character (`chars`/`ignoring`, with the US
    /// code as a hint) and gets the layout's code; `physical` keys (Docs' ⌘⇧7) keep their code and get its characters.
    /// `page` is how the test page's logger names it (`event.code`, a physical name).
    struct Key {
        let name: String, code: UInt16, chars: String, ignoring: String, mods: NSEvent.ModifierFlags, page: String
        /// This layout can't type it (⌘[ on a German layout needs ⌥): Chromium runs SKIP it.
        let unavailable: Bool
        /// Chromium runs only post keys their layout makes (WebKit takes an event as posted).
        static var strict = false

        init(_ name: String, _ code: UInt16, _ chars: String, _ ignoring: String? = nil, _ mods: NSEvent.ModifierFlags, physical: Bool = false) {
            var code = code, mods = mods, chars = chars, ignoring = ignoring ?? chars, missing = false
            let special = ignoring.unicodeScalars.first.map { $0.value >= 0xF700 || $0.value < 0x20 || $0.value == 0x7f } ?? true
            if !special {
                if !physical {
                    // Letters are looked up unshifted (⇧ stays in `mods`); other characters as they are (⇧ added if needed).
                    let letter = ignoring.lowercased() != ignoring.uppercased()
                    if let hit = Layout.code(typing: letter ? ignoring.lowercased() : ignoring, near: code) {
                        code = hit.code
                        if hit.shift { mods.insert(.shift) }
                    } else {
                        missing = true
                    }
                }
                let shift = mods.contains(.shift)
                if !missing {
                    ignoring = Layout.typed(code, shift: shift) ?? ignoring
                    if !mods.contains(.control) { chars = mods.contains(.option) ? (Layout.typed(code, shift: shift, option: true) ?? chars) : ignoring }
                }
            }
            self.name = name; self.code = code; self.chars = chars; self.ignoring = ignoring; self.mods = mods
            unavailable = missing && Self.strict
            page = (mods.contains(.command) ? "cmd+" : "") + (mods.contains(.control) ? "ctrl+" : "") + (mods.contains(.option) ? "alt+" : "")
                + (mods.contains(.shift) ? "shift+" : "") + (Layout.domCode[code] ?? "?")
        }
        static func cmd(_ name: String, _ code: UInt16, _ c: String) -> Key { Key(name, code, c, nil, .command) }
        static func cmdShift(_ name: String, _ code: UInt16, _ c: String) -> Key { Key(name, code, c, nil, [.command, .shift]) }
        static func arrow(_ name: String, _ code: UInt16, _ k: Int, _ mods: NSEvent.ModifierFlags) -> Key {
            let c = String(Character(UnicodeScalar(k)!))
            return Key(name, code, c, c, mods.union([.function, .numericPad]))
        }
    }

    /// This Mac's keyboard layout (UCKeyTranslate), and the physical DOM code names of the ANSI key codes.
    enum Layout {
        static let domCode: [UInt16: String] = {
            let names = ["KeyA", "KeyS", "KeyD", "KeyF", "KeyH", "KeyG", "KeyZ", "KeyX", "KeyC", "KeyV", "IntlBackslash", "KeyB", "KeyQ", "KeyW",
                         "KeyE", "KeyR", "KeyY", "KeyT", "Digit1", "Digit2", "Digit3", "Digit4", "Digit6", "Digit5", "Equal", "Digit9", "Digit7",
                         "Minus", "Digit8", "Digit0", "BracketRight", "KeyO", "KeyU", "BracketLeft", "KeyI", "KeyP", "Enter", "KeyL", "KeyJ",
                         "Quote", "KeyK", "Semicolon", "Backslash", "Comma", "Slash", "KeyN", "KeyM", "Period", "Tab", "Space", "Backquote", "Backspace"]
            var d: [UInt16: String] = [:]
            for (i, n) in names.enumerated() { d[UInt16(i)] = n }
            d[117] = "Delete"; d[123] = "ArrowLeft"; d[124] = "ArrowRight"; d[125] = "ArrowDown"; d[126] = "ArrowUp"
            d[116] = "PageUp"; d[121] = "PageDown"; d[53] = "Escape"
            return d
        }()

        /// What the key with `code` types on this layout, with ⇧ and ⌥ or not.
        static func typed(_ code: UInt16, shift: Bool, option: Bool = false) -> String? {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            return data.withUnsafeBytes { bytes -> String? in
                guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var dead: UInt32 = 0, length = 0
                var out = [UniChar](repeating: 0, count: 4)
                let mods = UInt32(((shift ? shiftKey : 0) | (option ? optionKey : 0)) >> 8) & 0xFF
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, out.count, &length, &out)
                return status == noErr && length > 0 ? String(utf16CodeUnits: out, count: length) : nil
            }
        }

        /// The key that types `c` (⇧ when it needs it), `near` first (the US code).
        static func code(typing c: String, near: UInt16) -> (code: UInt16, shift: Bool)? {
            for shift in [false, true] {
                if typed(near, shift: shift) == c { return (near, shift) }
                for code in UInt16(0)..<51 where typed(code, shift: shift) == c { return (code, shift) }
            }
            return nil
        }
    }

    private static let editorPage = """
        <!doctype html><meta charset=utf-8><title>keys</title>
        <style>body{margin:0;font:15px -apple-system,sans-serif}#ed{position:absolute;left:40px;top:40px;width:420px;height:110px;border:1px solid #999}
        #ta{position:absolute;left:40px;top:170px;width:420px;height:70px}#in{position:absolute;left:40px;top:260px;width:420px}</style>
        <div id=ed contenteditable>Hello world</div>
        <textarea id=ta>alpha beta
        gamma delta</textarea>
        <input id=in value="one two three" autocomplete=off>
        <script>
        var ed=document.getElementById('ed'),ta=document.getElementById('ta'),inp=document.getElementById('in');
        var log=[],prevent={},loadID=Math.random().toString(36).slice(2);
        function combo(e){return (e.metaKey?'cmd+':'')+(e.ctrlKey?'ctrl+':'')+(e.altKey?'alt+':'')+(e.shiftKey?'shift+':'')+e.code}
        addEventListener('keydown',function(e){var c=combo(e);if(prevent[c])e.preventDefault();log.push('kd '+c+(e.defaultPrevented?' prevented':''))},true);
        addEventListener('keyup',function(e){log.push('ku '+combo(e))},true);
        addEventListener('beforeinput',function(e){log.push('bi '+e.inputType)},true);
        addEventListener('paste',function(e){var d=e.clipboardData;log.push('paste '+(d?Array.prototype.join.call(d.types,'|'):'-'))},true);
        addEventListener('copy',function(){log.push('copy')},true);
        addEventListener('cut',function(){log.push('cut')},true);
        function reset(){ed.innerHTML='Hello world';ta.value='alpha beta\\ngamma delta';inp.value='one two three';prevent={};log=[]}
        function selectText(el,a,b){el.focus();var t=el.firstChild,r=document.createRange();r.setStart(t,a);r.setEnd(t,b);var s=getSelection();s.removeAllRanges();s.addRange(r)}
        function caret(el,a,b){el.focus();el.setSelectionRange(a,b===undefined?a:b)}
        function state(){var l=log;log=[];return JSON.stringify({ed:ed.innerHTML,edText:ed.innerText,ta:ta.value,tas:ta.selectionStart,tae:ta.selectionEnd,
          iv:inp.value,is:inp.selectionStart,ie:inp.selectionEnd,active:(document.activeElement||{}).id||'',loadID:loadID,href:location.href,log:l})}
        </script>
        """

    func shortcutsScenario() {
        Key.strict = app?.engine.name.hasPrefix("Chromium") == true
        var server: LocalPageServer?
        var tabID = "", base = ""
        var savedPasteboard: [[NSPasteboard.PasteboardType: Data]] = []
        let page = { self.c.engineTab(for: tabID) }
        let blur = "reset();inp.blur();ta.blur();ed.blur();getSelection().removeAllRanges()"
        // AIRC_SHORTCUTS_ONLY=fields,own: just those parts (format paste fields bound focus own boost quit).
        let only = ProcessInfo.processInfo.environment["AIRC_SHORTCUTS_ONLY"]?.split(separator: ",").map(String.init)
        let want = { (part: String) in only == nil || only!.contains(part) }

        run { [self] in
            note("shortcuts: window key \(c.window.isKeyWindow), app active \(NSApp.isActive), on the active Space \(c.window.isOnActiveSpace), "
                 + "screen locked \(Self.screenLocked), keyboard layout \(Self.layoutName)")
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            savedPasteboard = Self.pasteboardItems()
        }
        step { [self] done in
            guard let s = LocalPageServer(pages: ["/editor": Self.editorPage, "/editor2": Self.editorPage, "/editor3": Self.editorPage]) else {
                check(false, "shortcuts: the loopback server starts"); return done()
            }
            server = s
            s.start { port in
                guard let port, let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/editor", inSpace: self.c.currentSpaceID,
                                                                  title: "Shortcuts") else {
                    self.check(false, "shortcuts: the loopback server starts"); return done()
                }
                base = "http://127.0.0.1:\(port)"
                tabID = t.id
                self.c.reloadAll(animated: false)
                self.c.show(t.id, focus: true)
                done()
            }
        }
        waitForPage()
        step { [self] done in clickIntoPage(done) }
        run { [self] in
            note("shortcuts: page focused \(c.focusedPage != nil), first responder \(Self.describe(c.window.firstResponder)), "
                 + "pasteAndMatchStyle: on the responder \(c.window.firstResponder?.responds(to: PasteAndMatchStyle.selector) ?? false)")
        }

        // MARK: Formatting and editors' own shortcuts
        if want("format") {
            // ⌘B ⌘I ⌘U: the engine's own editing (Chrome bolds a contenteditable selection itself).
            for (k, tag, kind) in [(Key.cmd("⌘B", 11, "b"), "<b>", "formatBold"),
                                   (Key.cmd("⌘I", 34, "i"), "<i>", "formatItalic"),
                                   (Key.cmd("⌘U", 32, "u"), "<u>", "formatUnderline")] {
                keyCase(k, page: page, setup: "reset();selectText(ed,0,5)") { s, log in
                    let html = s["ed"] as? String ?? ""
                    _ = kind   // Chromium also fires beforeinput \(kind); WebKit's stand-in (keysScript) runs execCommand, which doesn't
                    self.check(log.contains("kd \(k.page)") && html.contains(tag),
                               "shortcuts: \(k.name) in a contenteditable formats the selection (\(html), log \(log.joined(separator: ", ")))")
                }
            }
            // Keys editors (Docs, Notion, Slack, Linear, GitHub) handle themselves: the page gets each one once, and the
            // browser's command for it (⇧⌘L ⇧⌘R ⇧⌘C ⇧⌘K) doesn't run when the page used it.
            var editorKeys: [Key] = [
                .cmd("⌘K", 40, "k"), .cmdShift("⇧⌘X", 7, "X"),
                Key("⇧⌘7", 26, "7", nil, [.command, .shift], physical: true), Key("⇧⌘8", 28, "8", nil, [.command, .shift], physical: true),
                .cmd("⌘/", 44, "/"), .cmd("⌘↩", 36, "\r"),
                .cmdShift("⇧⌘↩", 36, "\r"), .cmdShift("⇧⌘E", 14, "E"),
                .cmdShift("⇧⌘L", 37, "L"), .cmdShift("⇧⌘R", 15, "R"),
                .cmdShift("⇧⌘C", 8, "C"), .cmdShift("⇧⌘K", 40, "K"),
                .cmdShift("⇧⌘S", 1, "S"),
            ]
            let optionDigits = ["¡", "™", "£", "¢", "∞", "§"], digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22]
            for n in 1...6 {
                editorKeys.append(Key("⌥⌘\(n)", digitCodes[n - 1], optionDigits[n - 1], "\(n)", [.command, .option], physical: true))
            }
            var pasteboardBefore = 0, libraryBefore = false, todayBefore = 0, sidebarBefore = false
            for k in editorKeys {
                run { [self] in
                    pasteboardBefore = NSPasteboard.general.changeCount
                    libraryBefore = c.library != nil
                    todayBefore = c.store.todayRowTabs(ofSpace: c.currentSpaceID).count
                    sidebarBefore = c.sidebarHidden
                }
                keyCase(k, page: page, setup: "reset();prevent[\(Self.js(k.page))]=1;selectText(ed,0,5)", settle: KeyMonitor.pageAnswerTimeout + 0.15) { s, log in
                    let downs = log.filter { $0.hasPrefix("kd \(k.page)") }
                    var browser: [String] = []
                    if NSPasteboard.general.changeCount != (self.uiAttempt?.pasteboardBefore ?? pasteboardBefore) { browser.append("the pasteboard changed") }
                    if (self.c.library != nil) != libraryBefore { browser.append("the Library toggled") }
                    if s["loadID"] as? String != Self.lastLoadID { browser.append("the page reloaded") }
                    if self.c.store.todayRowTabs(ofSpace: self.c.currentSpaceID).count != todayBefore { browser.append("Today was cleared") }
                    if self.c.shownTabID != tabID { browser.append("another tab shows") }
                    if self.c.sidebarHidden != sidebarBefore { browser.append("the sidebar toggled") }
                    // No keyup: macOS sends none for a key pressed with ⌘ (to any app; pages in Chrome get none either).
                    self.check(downs == ["kd \(k.page) prevented"] && browser.isEmpty,
                               "shortcuts: \(k.name) reaches the page once and the page keeps it (\(log.joined(separator: ", "))"
                               + (browser.isEmpty ? "" : "; " + browser.joined(separator: ", ")) + ")")
                }
            }
            // CB-3: a second press within a second runs the browser's command (⇧⌘C copies the URL), and a page that doesn't
            // use the key leaves it to the browser at once, which runs its command once.
            let copyURL = Key.cmdShift("⇧⌘C", 8, "C")
            keyCase(copyURL, page: page, setup: "reset();prevent[\(Self.js(copyURL.page))]=1;selectText(ed,0,5)") { _, _ in }
            keyCase(copyURL, page: page, setup: "1", settle: 0.3) { _, log in
                let url = NSPasteboard.general.string(forType: .string) ?? ""
                self.check(url.hasSuffix("/editor") && !log.contains { $0.hasPrefix("kd \(copyURL.page)") },
                           "shortcuts: ⇧⌘C again within a second copies the URL (pasteboard \(url), page log \(log.joined(separator: ", ")))")
            }
            wait(1.1)
            run { Self.putPlain("") }
            keyCase(copyURL, page: page, setup: "reset();selectText(ed,0,5)", settle: 0.3) { _, log in
                let url = NSPasteboard.general.string(forType: .string) ?? ""
                self.check(url.hasSuffix("/editor") && log.filter({ $0.hasPrefix("kd \(copyURL.page)") }) == ["kd \(copyURL.page)"],
                           "shortcuts: ⇧⌘C the page doesn't use copies the URL (pasteboard \(url), page log \(log.joined(separator: ", ")))")
            }

        }

        // MARK: Paste and Match Style
        if want("paste") {

            let rich = "<meta charset=utf-8><b>Bold</b> and <i>rich</i>"
            for k in [Key.cmdShift("⇧⌘V", 9, "V"), Key("⌥⇧⌘V", 9, "◊", "V", [.command, .option, .shift])] {
                run { Self.putRichText(html: rich, plain: "Bold and rich") }
                keyCase(k, page: page, setup: "reset();ed.innerHTML='x';selectText(ed,1,1)") { s, log in
                    let html = s["ed"] as? String ?? ""
                    self.check(log.contains("kd \(k.page)") && log.contains { $0.hasPrefix("paste") } && html.contains("Bold and rich")
                               && !html.contains("<b>") && !html.contains("<i>"),
                               "shortcuts: \(k.name) pastes plain text into a contenteditable (\(html), log \(log.joined(separator: ", ")))")
                }
            }
            run { Self.putRichText(html: rich, plain: "Bold and rich") }
            let paste = Key.cmd("⌘V", 9, "v")
            keyCase(paste, page: page, setup: "reset();ed.innerHTML='x';selectText(ed,1,1)") { s, log in
                let html = s["ed"] as? String ?? ""
                self.check(log.contains("kd \(paste.page)") && html.contains("<b>Bold</b>"),
                           "shortcuts: ⌘V keeps the clipboard's formatting (\(html), log \(log.joined(separator: ", ")))")
            }

        }

        // MARK: Editing keys in the page's fields
        if want("fields") {

            let tabsBefore = { self.c.store.state.tabs.count }
            var tabCount = 0
            run { tabCount = tabsBefore() }
            let fieldKeys: [(Key, String, (([String: Any]) -> Bool), String)] = [
                (.cmd("⌘A", 0, "a"), "reset();caret(inp,3)", { $0["is"] as? Int == 0 && $0["ie"] as? Int == 13 }, "selects the field's text"),
                (.cmd("⌘C", 8, "c"), "reset();caret(inp,0,3)", { s in NSPasteboard.general.string(forType: .string) == "one" && Self.logged(s, "copy") }, "copies the selection"),
                (.cmd("⌘X", 7, "x"), "reset();caret(inp,0,4)", { s in s["iv"] as? String == "two three" && NSPasteboard.general.string(forType: .string) == "one " }, "cuts the selection"),
                (.cmd("⌘V", 9, "v"), "caret(inp,0)", { s in s["iv"] as? String == "one two three" && Self.logged(s, "paste") }, "pastes"),
                (.cmd("⌘Z", 6, "z"), "caret(inp,4)", { s in s["iv"] as? String == "two three" && Self.logged(s, "bi historyUndo") }, "undoes the paste"),
                (.cmdShift("⇧⌘Z", 6, "Z"), "caret(inp,0)", { s in s["iv"] as? String == "one two three" && Self.logged(s, "bi historyRedo") }, "redoes it"),
                (.arrow("⌘←", 123, NSLeftArrowFunctionKey, .command), "reset();caret(ta,8)", { $0["tas"] as? Int == 0 }, "goes to the line's start"),
                (.arrow("⌘→", 124, NSRightArrowFunctionKey, .command), "reset();caret(ta,2)", { $0["tas"] as? Int == 10 }, "goes to the line's end"),
                (.arrow("⌘↓", 125, NSDownArrowFunctionKey, .command), "reset();caret(ta,2)", { $0["tas"] as? Int == 22 }, "goes to the end"),
                (.arrow("⌘↑", 126, NSUpArrowFunctionKey, .command), "reset();caret(ta,15)", { $0["tas"] as? Int == 0 }, "goes to the start"),
                (.arrow("⌥→", 124, NSRightArrowFunctionKey, .option), "reset();caret(ta,0)", { $0["tas"] as? Int == 5 }, "moves a word right"),
                (.arrow("⌥←", 123, NSLeftArrowFunctionKey, .option), "reset();caret(ta,10)", { $0["tas"] as? Int == 6 }, "moves a word left"),
                (Key("⌃A", 0, "\u{01}", "a", .control), "reset();caret(ta,8)", { $0["tas"] as? Int == 0 }, "goes to the line's start"),
                (Key("⌃E", 14, "\u{05}", "e", .control), "reset();caret(ta,2)", { $0["tas"] as? Int == 10 }, "goes to the line's end"),
                (Key("⌃K", 40, "\u{0b}", "k", .control), "reset();caret(ta,6)", { ($0["ta"] as? String)?.hasPrefix("alpha \n") == true }, "deletes to the line's end"),
                (Key("⌘⌫", 51, "\u{7f}", nil, .command), "reset();caret(ta,10)", { ($0["ta"] as? String)?.hasPrefix("\ngamma") == true }, "deletes to the line's start"),
                (Key("⌦", 117, String(Character(UnicodeScalar(NSDeleteFunctionKey)!)), nil, .function), "reset();caret(ta,0)",
                 { ($0["ta"] as? String)?.hasPrefix("lpha") == true }, "deletes forward"),
            ]
            func fieldKey(_ item: (Key, String, ([String: Any]) -> Bool, String)) {
                let (k, setup, ok, what) = item
                keyCase(k, page: page, setup: setup) { s, log in
                    let moved = (s["href"] as? String)?.hasSuffix("/editor") != true || self.c.shownTabID != tabID || tabsBefore() != tabCount
                    self.check(ok(s) && log.filter({ $0.hasPrefix("kd \(k.page)") }).count == 1 && !moved,
                               "shortcuts: \(k.name) in a page field \(what) (\(Self.fieldState(s)), log \(log.joined(separator: ", "))"
                               + (moved ? "; the browser acted: \(s["href"] ?? "-"), tabs \(tabCount) → \(tabsBefore()) (shown \(self.c.shownTabID.flatMap { self.c.store.tab($0)?.url } ?? "-"))" : "") + ")")
                }
            }

            fieldKeys.prefix(2).forEach(fieldKey)
            // Cut supplies the paste fixture; undo and redo depend on that exact paste. Replaying only paste
            // duplicated its text and made the next undo/redo falsely fail under clipboard contention.
            uiCase(window: { self.c.window }) {
                fieldKeys[2...5].forEach(fieldKey)
            }
            fieldKeys.dropFirst(6).forEach(fieldKey)

            // ⌘Z on a page whose keyboard isn't in a field: a page that uses it keeps it (a canvas app's own undo); one
            // that doesn't leaves it to Reopen Closed Tab (SB-23, SB-40).
            var scratch = ""
            run { [self] in
                guard let t = try? c.store.openTab(url: "data:text/html,%3Ctitle%3EScratch%3C/title%3Escratch", inSpace: c.currentSpaceID, title: "Scratch") else { return }
                scratch = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            wait(0.8)
            run { [self] in if c.shownTabID == scratch { c.closeCurrentTab() } }
            wait(0.8)
            run { [self] in c.show(tabID, focus: true) }
            wait(0.4)
            let reopened = { self.c.store.todayRowTabs(ofSpace: self.c.currentSpaceID).contains { $0.url.contains("Scratch") } }
            let undo = Key.cmd("⌘Z", 6, "z")
            keyCase(undo, page: page, setup: blur + ";prevent[\(Self.js(undo.page))]=1", pause: 0.3, settle: KeyMonitor.pageAnswerTimeout + 0.15) { _, log in
                self.check(!scratch.isEmpty && !reopened() && log.contains("kd \(undo.page) prevented"),
                           "shortcuts: ⌘Z a page uses outside a field stays the page's (closed tab reopened \(reopened()), log \(log.joined(separator: ", ")))")
            }
            wait(1.05)
            keyCase(undo, page: page, setup: blur, pause: 0.3, settle: 0.6) { _, log in
                self.check(!scratch.isEmpty && reopened() && log.filter({ $0.hasPrefix("kd \(undo.page)") }) == ["kd \(undo.page)"],
                           "shortcuts: ⌘Z outside a field reopens the closed tab (reopened \(reopened()), log \(log.joined(separator: ", ")))")
            }
            run { [self] in c.show(tabID, focus: true) }
            wait(0.4)

        }

        // MARK: Shortcuts Airc also binds: the page first (CB-3)
        if want("bound") {

            // Each: the page uses it (its command must not run, even after the page's answer timeout), then a page that
            // doesn't (its command runs, once). ⌘O and ⌘P only the first way (a beep, a print sheet).
            struct Bound { let key: Key; let state: (WindowController) -> String; let undo: (WindowController) -> Void; let unused: Bool }
            let bound: [Bound] = [
                Bound(key: .cmd("⌘D", 2, "d"), state: { c in c.store.tab(c.shownTabID ?? "")?.itemID == nil ? "unpinned" : "pinned" },
                      undo: { $0.togglePin() }, unused: true),
                Bound(key: .cmd("⌘E", 14, "e"), state: { $0.extensionsPopover?.isShown == true ? "extensions" : "-" },
                      undo: { $0.extensionsPopover?.close() }, unused: true),
                Bound(key: .cmd("⌘L", 37, "l"), state: { $0.commandBar.map { "command bar \($0.mode)" } ?? "-" },
                      undo: { $0.closeCommandBar() }, unused: true),
                Bound(key: .cmd("⌘S", 1, "s"), state: { $0.sidebarHidden ? "sidebar hidden" : "sidebar" },
                      undo: { $0.toggleSidebar() }, unused: true),
                Bound(key: .cmd("⌘Y", 16, "y"), state: { c in c.commandBar != nil ? "history" : c.shownTabID != tabID ? "history tab" : "-" },
                      undo: { c in c.closeCommandBar(); if c.shownTabID != tabID { c.closeCurrentTab(); c.show(tabID) } }, unused: true),
                Bound(key: .cmd("⌘F", 3, "f"), state: { $0.findBar != nil ? "find bar" : "-" },
                      undo: { $0.closeFind(refocusPage: true) }, unused: true),
                Bound(key: .cmd("⌘G", 5, "g"), state: { $0.findBar != nil ? "find bar" : "-" },
                      undo: { $0.closeFind(refocusPage: true) }, unused: true),
                Bound(key: .cmd("⌘O", 31, "o"), state: { _ in "-" }, undo: { _ in }, unused: false),
                Bound(key: .cmd("⌘P", 35, "p"), state: { _ in "-" }, undo: { _ in }, unused: false),
            ]
            run { [self] in if c.sidebarHidden { c.toggleSidebar() } }   // ⌘E's list hangs off the URL field
            for b in bound {
                var before = ""
                run { before = b.state(self.c) }
                keyCase(b.key, page: page, setup: "reset();prevent[\(Self.js(b.key.page))]=1;caret(inp,3)", settle: KeyMonitor.pageAnswerTimeout + 0.15) { s, log in
                    let after = b.state(self.c)
                    self.check(log.filter({ $0.hasPrefix("kd \(b.key.page)") }) == ["kd \(b.key.page) prevented"] && after == before,
                               "shortcuts: \(b.key.name) a page uses stays the page's (browser: \(before) → \(after), log \(log.joined(separator: ", ")))")
                }
                guard b.unused else { continue }
                wait(1.05)   // past the second-press window
                keyCase(b.key, page: page, setup: "reset();caret(inp,3)", settle: 0.4) { s, log in
                    let after = b.state(self.c)
                    self.check(log.filter({ $0.hasPrefix("kd \(b.key.page)") }) == ["kd \(b.key.page)"] && after != before,
                               "shortcuts: \(b.key.name) a page doesn't use runs the browser's command once (browser: \(before) → \(after), "
                               + "log \(log.joined(separator: ", ")))")
                    b.undo(self.c)
                }
                wait(0.3)
                step { [self] done in refocus(page, done) }
            }
            // ⌘[ / ⌘]: one step back and forward through /editor → /editor2 → /editor3; a page that uses them keeps them.
            for path in ["/editor2", "/editor3"] {
                run { page()?.load(URL(string: base + path)!) }
                waitForPage()
            }
            step { [self] done in refocus(page, done) }
            let back = Key.cmd("⌘[", 33, "[")
            keyCase(back, page: page, setup: "reset();prevent[\(Self.js(back.page))]=1;caret(inp,3)", settle: KeyMonitor.pageAnswerTimeout + 0.15) { s, log in
                self.check((s["href"] as? String)?.hasSuffix("/editor3") == true && log.contains("kd \(back.page) prevented"),
                           "shortcuts: ⌘[ a page uses stays the page's (at \(s["href"] ?? "-"), log \(log.joined(separator: ", ")))")
            }
            if !back.unavailable {
                wait(1.05)
                run { [self] in _ = page()?.evaluate("reset();caret(inp,3);1") { _ in } }
                postKeyStep(.cmd("⌘[", 33, "["))
                waitForPage()
                step { [self] done in
                    page()?.evaluate("location.pathname") { v in
                        self.check(v as? String == "/editor2", "shortcuts: ⌘[ a page doesn't use goes back one page (at \(v ?? "-"))")
                        done()
                    }
                }
                step { [self] done in refocus(page, done) }
                postKeyStep(.cmd("⌘]", 30, "]"))
                waitForPage()
                step { [self] done in
                    page()?.evaluate("location.pathname") { v in
                        self.check(v as? String == "/editor3", "shortcuts: ⌘] a page doesn't use goes forward one page (at \(v ?? "-"))")
                        done()
                    }
                }
            }

            // ⌘← ⌘→ outside a field: Chrome's Back and Forward (in a field they moved the caret, above).
            step { [self] done in refocus(page, done) }
            run { [self] in _ = page()?.evaluate("inp.blur();ta.blur();ed.blur();1") { _ in } }
            wait(0.3)
            postKeyStep(.arrow("⌘←", 123, NSLeftArrowFunctionKey, .command))
            waitForPage()
            step { [self] done in
                page()?.evaluate("location.pathname") { v in
                    self.check(v as? String == "/editor2", "shortcuts: ⌘← outside a field goes back one page (at \(v ?? "-"))")
                    done()
                }
            }
            step { [self] done in refocus(page, done) }
            run { [self] in _ = page()?.evaluate("inp.blur();ta.blur();ed.blur();1") { _ in } }
            wait(0.3)
            postKeyStep(.arrow("⌘→", 124, NSRightArrowFunctionKey, .command))
            waitForPage()
            step { [self] done in
                page()?.evaluate("location.pathname") { v in
                    self.check(v as? String == "/editor3", "shortcuts: ⌘→ outside a field goes forward one page (at \(v ?? "-"))")
                    done()
                }
            }

            // ⌥⌘V (Arc): the clipboard's URL in a new tab; a page that uses the key (Docs' Paste Formatting) keeps it.
            let pasteGo = Key("⌥⌘V", 9, "√", "v", [.command, .option])
            var tabsBeforePaste = 0
            run { [self] in Self.putPlain(base + "/editor2")
                tabsBeforePaste = c.store.todayRowTabs(ofSpace: c.currentSpaceID).count }
            keyCase(pasteGo, page: page, setup: "reset();prevent[\(Self.js(pasteGo.page))]=1;caret(inp,3)", settle: KeyMonitor.pageAnswerTimeout + 0.15) { _, log in
                let n = self.c.store.todayRowTabs(ofSpace: self.c.currentSpaceID).count
                self.check(n == tabsBeforePaste && self.c.shownTabID == tabID && log.contains("kd \(pasteGo.page) prevented"),
                           "shortcuts: ⌥⌘V a page uses stays the page's (Today tabs \(tabsBeforePaste) → \(n), log \(log.joined(separator: ", ")))")
            }
            wait(1.05)
            uiCase(window: { self.c.window }) {
                run { [self] in
                    if uiAttempt?.retry == true, c.shownTabID != tabID {
                        c.closeCurrentTab()
                        c.show(tabID, focus: true)
                    }
                    Self.putPlain(base + "/editor2")
                }
                keyCase(pasteGo, page: page, setup: "reset();caret(inp,3)", settle: 0.6) { _, log in
                    let shown = self.c.shownTabID.flatMap { self.c.store.tab($0) }
                    self.check(self.c.shownTabID != tabID && shown?.url.hasSuffix("/editor2") == true,
                               "shortcuts: ⌥⌘V opens the clipboard's URL in a new tab (shown \(shown?.url ?? "-"), log \(log.joined(separator: ", ")))")
                }
            }
            waitForPage()
            // Tab switching: ⌘{ ⌘} (⇧⌘[ ⇧⌘]) and ⌃⇞ ⌃⇟ move through the sidebar's tabs, whoever has the keyboard.
            var pasted = ""
            run { [self] in pasted = c.shownTabID ?? "" }
            for (k, what) in [(Key("⌘{", 33, "{", nil, [.command, .shift]), "previous"), (Key("⌘}", 30, "}", nil, [.command, .shift]), "next"),
                              (Key("⌃⇞", 116, String(Character(UnicodeScalar(NSPageUpFunctionKey)!)), nil, [.control, .function]), "previous"),
                              (Key("⌃⇟", 121, String(Character(UnicodeScalar(NSPageDownFunctionKey)!)), nil, [.control, .function]), "next")] {
                if k.unavailable { postKeyStep(k); continue }
                var from = ""
                run { [self] in from = c.shownTabID ?? "" }
                postKeyStep(k)
                wait(0.4)
                run { [self] in
                    let want = c.store.adjacentEntry(to: from, offset: what == "next" ? 1 : -1, inSpace: c.currentSpaceID)?.liveTab?.id
                    check(c.shownTabID != from && (want == nil || c.shownTabID == want), "shortcuts: \(k.name) shows the \(what) tab (\(from) → \(c.shownTabID ?? "-"))")
                }
            }
            run { [self] in
                if c.store.tab(pasted) != nil, pasted != tabID { c.show(pasted, focus: false); c.closeCurrentTab() }
            }
            wait(0.6)
            run { [self] in c.show(tabID, focus: true) }
            wait(0.3)
            // ⇧⌘A (Chrome's tab search): the Command Bar, which lists the open tabs.
            keyCase(.cmdShift("⇧⌘A", 0, "A"), page: page, setup: "reset();caret(inp,3)", settle: 0.3) { _, log in
                self.check(self.c.commandBar != nil, "shortcuts: ⇧⌘A a page doesn't use opens the Command Bar (log \(log.joined(separator: ", ")))")
                self.c.closeCommandBar()
            }
            // ⇧⌘W (Close Window) closes the window, so only its menu item is checked.
            run { [self] in
                let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Close Window" }
                // Menus spell ⇧ letters in upper case (ShortcutCenter.menuEquivalent).
                let key = item.flatMap { ShortcutCenter.combo($0.keyEquivalent, $0.keyEquivalentModifierMask) }
                check(key?.display == "⇧⌘W", "shortcuts: File › Close Window is ⇧⌘W (\(key?.display ?? "no item"))")
            }

        }

        // MARK: Focus where a person comes back to a page from
        if want("focus") {

            // A Space switch away and back (⌃n), and a click on the page's sidebar row: the page has the keyboard again.
            step { [self] done in refocus(page, done) }
            run { [self] in
                // A second Space to switch to (same profile), with a page of its own.
                guard c.store.orderedSpaces.count < 2, let other = try? c.store.createSpace(name: "Elsewhere", theme: c.store.selectedSpace.theme,
                                                                                            profileID: c.store.selectedSpace.profileID, after: c.currentSpaceID) else { return }
                _ = try? c.store.openTab(url: "data:text/html,%3Ctitle%3EElsewhere%3C/title%3E", inSpace: other.id)
                c.reloadAll(animated: false)
            }
            var switched = false
            step { [self] done in
                let spaces = c.store.orderedSpaces
                guard spaces.count >= 2, let i = spaces.firstIndex(where: { $0.id == c.currentSpaceID }) else {
                    skip("shortcuts: focus after a Space switch: one Space only"); return done()
                }
                let other = i == 0 ? 1 : 0, codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
                guard other < 9, i < 9 else { return done() }
                postKey("\(other + 1)", keyCode: codes[other], modifiers: .control)
                waitUntil({ self.c.currentSpaceID == spaces[other].id }, timeout: 3) {
                    self.postKey("\(i + 1)", keyCode: codes[i], modifiers: .control)
                    self.waitUntil({ self.c.currentSpaceID == spaces[i].id && self.c.shownTabID == tabID }, timeout: 3) {
                        switched = self.c.currentSpaceID == spaces[i].id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                    }
                }
            }
            keyCase(.cmd("⌘B", 11, "b"), page: page, setup: "reset();selectText(ed,0,5)", focusFirst: false) { s, log in
                self.check(switched && self.c.focusedPage != nil && log.contains("kd \(Key.cmd("⌘B", 11, "b").page)"),
                           "shortcuts: after a Space switch (⌃n away and back: \(switched)) the page has the keyboard (focused \(self.c.focusedPage != nil), "
                           + "first responder \(Self.describe(self.c.window.firstResponder)), log \(log.joined(separator: ", ")))")
            }
            step { [self] done in
                guard let p = c.pageView(for: c.currentSpaceID), let row = todayRow(tabID, in: p) else { skip("shortcuts: no sidebar row for the page"); return done() }
                c.window.makeFirstResponder(nil)
                click(at: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil), in: c.window) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
            keyCase(.cmd("⌘B", 11, "b"), page: page, setup: "reset();selectText(ed,0,5)", focusFirst: false) { s, log in
                self.check(self.c.focusedPage != nil && log.contains("kd \(Key.cmd("⌘B", 11, "b").page)"),
                           "shortcuts: after a click on its sidebar row the page has the keyboard (focused \(self.c.focusedPage != nil), "
                           + "first responder \(Self.describe(self.c.window.firstResponder)), log \(log.joined(separator: ", ")))")
            }

        }

        // MARK: Our own fields: the Command Bar (⌘T, ⌘L)
        if want("own") {

            postKeyStep(.cmd("⌘T", 17, "t"))
            step { [self] done in waitUntil({ self.c.window.firstResponder is NSTextView }, timeout: 3) { done() } }
            run { [self] in typeText("qxqxq wvwvw") }
            wait(0.3)
            let ownKeys: [(Key, (NSTextView) -> Void, (NSTextView) -> Bool, String)] = [
                (.cmd("⌘A", 0, "a"), { $0.setSelectedRange(NSRange(location: 3, length: 0)) }, { $0.selectedRange() == NSRange(location: 0, length: 11) }, "selects all"),
                (.cmd("⌘C", 8, "c"), { Self.putPlain(""); $0.setSelectedRange(NSRange(location: 0, length: 5)) },
                 { _ in NSPasteboard.general.string(forType: .string) == "qxqxq" }, "copies"),
                (.cmd("⌘X", 7, "x"), { $0.setSelectedRange(NSRange(location: 0, length: 6)) }, { $0.string == "wvwvw" && NSPasteboard.general.string(forType: .string) == "qxqxq " }, "cuts"),
                (.cmd("⌘V", 9, "v"), { tv in Self.putPlain("qxqxq "); tv.setSelectedRange(NSRange(location: 0, length: 0)) },
                 { $0.string == "qxqxq wvwvw" }, "pastes"),
                (.cmd("⌘Z", 6, "z"), { _ in }, { $0.string == "wvwvw" }, "undoes the paste"),
                (.cmdShift("⇧⌘Z", 6, "Z"), { tv in if tv.string != "wvwvw" { tv.string = "(⌘Z didn't undo)" } }, { $0.string == "qxqxq wvwvw" }, "redoes it"),
                (.arrow("⌘←", 123, NSLeftArrowFunctionKey, .command), { $0.setSelectedRange(NSRange(location: 8, length: 0)) }, { $0.selectedRange().location == 0 }, "goes to the start"),
                (.arrow("⌘→", 124, NSRightArrowFunctionKey, .command), { $0.setSelectedRange(NSRange(location: 2, length: 0)) }, { $0.selectedRange().location == 11 }, "goes to the end"),
                (.arrow("⌥←", 123, NSLeftArrowFunctionKey, .option), { $0.setSelectedRange(NSRange(location: 11, length: 0)) }, { $0.selectedRange().location == 6 }, "moves a word left"),
                (.arrow("⌥→", 124, NSRightArrowFunctionKey, .option), { $0.setSelectedRange(NSRange(location: 0, length: 0)) }, { $0.selectedRange().location == 5 }, "moves a word right"),
                (Key("⌃A", 0, "\u{01}", "a", .control), { $0.setSelectedRange(NSRange(location: 8, length: 0)) }, { $0.selectedRange().location == 0 }, "goes to the start"),
                (Key("⌃E", 14, "\u{05}", "e", .control), { $0.setSelectedRange(NSRange(location: 2, length: 0)) }, { $0.selectedRange().location == 11 }, "goes to the end"),
                (Key("⌃K", 40, "\u{0b}", "k", .control), { $0.setSelectedRange(NSRange(location: 5, length: 0)) }, { $0.string == "qxqxq" }, "deletes to the end"),
                (Key("⌘⌫", 51, "\u{7f}", nil, .command), { $0.string = "qxqxq wvwvw"; $0.setSelectedRange(NSRange(location: 6, length: 0)) }, { $0.string == "wvwvw" }, "deletes to the start"),
            ]
            func ownKey(_ item: (Key, (NSTextView) -> Void, (NSTextView) -> Bool, String)) {
                let (k, setup, ok, what) = item
                fieldCase("the Command Bar", k, setup: setup, ok: ok, what: what)
            }
            ownKeys.prefix(2).forEach(ownKey)
            uiCase(window: { self.c.window }) {
                run { [self] in
                    if uiAttempt?.retry == true { (c.window.firstResponder as? NSTextView)?.string = "qxqxq wvwvw" }
                }
                ownKeys[2...5].forEach(ownKey)
            }
            // Navigation has its own fixture even if the editing transaction was externally interrupted.
            run { [self] in (c.window.firstResponder as? NSTextView)?.string = "qxqxq wvwvw" }
            ownKeys.dropFirst(6).forEach(ownKey)
            run { Self.putRichText(html: "<b>Bold</b> and <i>rich</i>", plain: "Bold and rich") }
            fieldCase("the Command Bar", .cmdShift("⇧⌘V", 9, "V"), setup: { $0.string = ""; $0.setSelectedRange(NSRange(location: 0, length: 0)) },
                      ok: { $0.string == "Bold and rich" }, what: "pastes plain text")
            run { [self] in check(c.commandBar != nil, "shortcuts: the Command Bar stays open through its editing keys"); c.closeCommandBar() }
            // ⌘L: the URL, selected, copies with ⌘C.
            postKeyStep(.cmd("⌘L", 37, "l"))
            step { [self] done in waitUntil({ self.c.window.firstResponder is NSTextView }, timeout: 3) { done() } }
            fieldCase("the URL field (⌘L)", .cmd("⌘C", 8, "c"), setup: { $0.selectAll(nil) },
                      ok: { _ in NSPasteboard.general.string(forType: .string) == page()?.url?.absoluteString }, what: "copies the URL")
            run { [self] in c.closeCommandBar() }

        }

        // MARK: Our own fields: the Boost code editor
        if want("boost") {

            run { [self] in c.showBoostEditor(section: .code) }
            wait(0.6)
            step { [self] done in
                guard let tv = Self.shortcutViews(BoostCodeTextView.self, in: c.root).first else { skip("shortcuts: the Boost code editor (no code view)"); return done() }
                c.window.makeFirstResponder(tv)
                tv.string = ""
                typeText("abc def")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
            }
            fieldCase("the Boost code editor", .cmd("⌘A", 0, "a"), setup: { $0.setSelectedRange(NSRange(location: 1, length: 0)) },
                      ok: { $0.selectedRange() == NSRange(location: 0, length: 7) }, what: "selects all", needs: BoostCodeTextView.self)
            uiCase(window: { self.c.window }) {
                run { [self] in
                    if uiAttempt?.retry == true { (c.window.firstResponder as? BoostCodeTextView)?.string = "abc def" }
                }
                fieldCase("the Boost code editor", .cmd("⌘X", 7, "x"), setup: { $0.setSelectedRange(NSRange(location: 0, length: 4)) },
                          ok: { $0.string == "def" }, what: "cuts", needs: BoostCodeTextView.self)
                fieldCase("the Boost code editor", .cmd("⌘Z", 6, "z"), setup: { tv in if tv.string != "def" { tv.string = "(⌘X didn't cut)" } },
                          ok: { $0.string == "abc def" }, what: "undoes the cut", needs: BoostCodeTextView.self)
                fieldCase("the Boost code editor", .cmd("⌘V", 9, "v"), setup: { tv in Self.putPlain("abc "); tv.setSelectedRange(NSRange(location: 7, length: 0)) },
                          ok: { $0.string == "abc defabc " }, what: "pastes", needs: BoostCodeTextView.self)
            }
            run { [self] in c.closeBoostEditor(animated: false) }
        }

        // MARK: Hold ⌘Q to quit (Arc)
        if want("quit") {
            // A tap shows the hint and doesn't quit; a hold of 0.7 s quits. On Chromium the key-up never reaches the app's
            // monitor (Chromium's application class sends ⌘ key-ups to the window), so the key's own state decides.
            // Posted keys don't move the hardware's key state, so it is a stand-in here, and the quit is counted, not run.
            var quits = 0, held = false
            let realHeld = KeyMonitor.quitIsHeld, realQuit = KeyMonitor.quit
            run {
                KeyMonitor.testQuitHold = true
                KeyMonitor.quitIsHeld = { _ in held }
                KeyMonitor.quit = { quits += 1 }
            }
            let q = Key.cmd("⌘Q", 12, "q")
            postKeyStep(q)   // down and up
            wait(0.3)
            run { [self] in
                check(c.toast.shownText == "Hold ⌘Q to Quit", "shortcuts: a ⌘Q tap shows “Hold ⌘Q to Quit” (toast \(c.toast.shownText ?? "none"))")
            }
            wait(0.6)
            run { [self] in check(quits == 0, "shortcuts: a ⌘Q tap doesn't quit (quits \(quits))") }
            // As on Chromium: no key-up comes, and the key is up at 0.7 s.
            run { [self] in postKey(q, up: false) }
            wait(0.9)
            run { [self] in check(quits == 0, "shortcuts: ⌘Q released without a key-up the app sees doesn't quit (quits \(quits))") }
            run { [self] in held = true; postKey(q, up: false) }
            wait(0.9)
            run { [self] in check(quits == 1, "shortcuts: ⌘Q held for 0.7 s quits (quits \(quits))") }
            run {
                KeyMonitor.testQuitHold = false
                KeyMonitor.quitIsHeld = realHeld
                KeyMonitor.quit = realQuit
            }
        }

        // MARK: Close Other Tabs (Arc's ⌥⌘W)
        if want("bound") {
            run { [self] in
                for n in 1...2 { _ = try? c.store.openTab(url: "data:text/html,%3Ctitle%3EOther\(n)%3C/title%3E", inSpace: c.currentSpaceID) }
                c.reloadAll(animated: false)
                c.show(tabID, focus: true)
            }
            wait(0.8)
            var before = 0
            run { [self] in before = c.store.todayRowTabs(ofSpace: c.currentSpaceID).count }
            postKeyStep(Key("⌥⌘W", 13, "∑", "w", [.command, .option]))
            wait(1.2)
            run { [self] in
                let left = c.store.todayRowTabs(ofSpace: c.currentSpaceID).map(\.id)
                check(before >= 3 && left == [tabID] && c.shownTabID == tabID,
                      "shortcuts: ⌥⌘W closes the other Today tabs (\(before) → \(left.count), the page's tab \(left.contains(tabID) ? "kept" : "gone"))")
            }
        }

        run { [self] in
            server?.stop()
            KeyMonitor.testKeyWindowDispatch = nil
            // The owner's clipboard back, unless they copied something of their own meanwhile.
            if UICheckAttempt.mayRestorePasteboard { Self.restorePasteboard(savedPasteboard) }
            else { note("shortcuts: the pasteboard changed outside the check; left as it is") }
            note("shortcuts: done")
        }
    }

    /// The page load the last case's setup ran in (a reload changes it).
    private static var lastLoadID: String?

    /// Sets up the page with `setup` (its helpers: reset, selectText, caret, prevent), presses `k`, waits for the
    /// page's answer and `settle` seconds, then hands the page's state and event log to `verdict`.
    func keyCase(_ k: Key, page: @escaping () -> EngineTab?, setup: String, pause: Double = 0, settle: Double = 0.35, focusFirst: Bool = true,
                 verdict: @escaping ([String: Any], [String]) -> Void) {
        uiCase(window: { self.c.window }) {
            if k.unavailable { return run { [self] in skip("shortcuts: \(k.name): this keyboard layout can't type it (\(Self.layoutName))") } }
            run { [self] in
                uiAttempt?.monitorsPasteboard = ["c", "x", "v"].contains(k.ignoring.lowercased()) || setup.contains("prevent[")
                uiAttempt?.pasteboardReadOnly = k.ignoring.lowercased() == "v"
            }
            if focusFirst { step { [self] done in refocus(page, done) } }
            step { [self] done in
                guard uiAttempt?.retry == true, setup == "1", let p = page() else { return done() }
                // Retry the double-press sequence, including its first, page-consumed press.
                p.evaluate("reset();prevent[\(Self.js(k.page))]=1;selectText(ed,0,5)") { _ in
                    self.postKey(k)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { p.evaluate("state()") { _ in done() } }
                }
            }
            step { [self] done in
                guard let p = page() else { check(false, "shortcuts: \(k.name): no page"); return done() }
                p.evaluate("(function(){\(setup);return loadID})()") { v in
                    Self.lastLoadID = v as? String
                    DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: done)
                }
            }
            step { [self] done in
                if ProcessInfo.processInfo.environment["AIRC_SHORTCUTS_TRACE"] == "1" {
                    let r = c.window.firstResponder as? NSView
                    note("trace: \(k.name): first responder \(Self.describe(r)), text input context \(r?.inputContext != nil), "
                         + "editing per the app \(KeyMonitor.pageIsEditingText(c))")
                }
                postKey(k)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.waitUntil({ !KeyMonitor.isWaitingForPage }, timeout: 3) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: done)
                    }
                }
            }
            step { [self] done in
                guard let p = page() else { return done() }
                p.evaluate("state()") { v in
                    let s = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    self.uiAttempt?.recordInputDelivery(setup == "1" || (s["log"] as? [String] ?? []).contains { $0.hasPrefix("kd \(k.page)") })
                    self.uiAttempt?.sample()
                    verdict(s, s["log"] as? [String] ?? ["(no answer: \(String(describing: v)))"])
                    done()
                }
            }
        }
    }

    /// The same for one of our own fields (the first responder, an NSTextView).
    func fieldCase(_ field: String, _ k: Key, setup: @escaping (NSTextView) -> Void, ok: @escaping (NSTextView) -> Bool, what: String,
                   needs: NSTextView.Type = NSTextView.self) {
        let standalone = !collectingUICase
        var originalText: String?
        uiCase(window: { self.c.window }) {
            if k.unavailable { return run { [self] in skip("shortcuts: \(k.name) in \(field): this keyboard layout can't type it") } }
            step { [self] done in
                guard let tv = c.window.firstResponder as? NSTextView, type(of: tv) == needs || needs == NSTextView.self else {
                    check(false, "shortcuts: \(k.name) in \(field): not focused (\(Self.describe(c.window.firstResponder)))"); return done()
                }
                if standalone, self.uiAttempt?.retry == true, let originalText { tv.string = originalText }
                else { originalText = tv.string }
                setup(tv)
                // What the key finds: if neither the field nor the clipboard changes, it never reached the field.
                let before = (tv.string, tv.selectedRange(), NSPasteboard.general.changeCount)
                self.uiAttempt?.monitorsPasteboard = ["c", "x", "v"].contains(k.ignoring.lowercased())
                self.uiAttempt?.pasteboardReadOnly = k.ignoring.lowercased() == "v"
                if ProcessInfo.processInfo.environment["AIRC_SHORTCUTS_TRACE"] == "1" {
                    note("trace: \(k.name) in \(field): can undo \(tv.undoManager?.canUndo ?? false), can redo \(tv.undoManager?.canRedo ?? false)")
                }
                postKey(k)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let now = self.c.window.firstResponder as? NSTextView
                    // Delivered: the field still has the keyboard and the key did something there, or nothing else could
                    // have kept it. With another app's window over ours (someone working at the Mac), a key that changed
                    // nothing never reached the field: environmental, as the page fields' cases are. Uncovered, a key
                    // that does nothing stays a real failure.
                    let changed = tv.string != before.0 || tv.selectedRange() != before.1 || NSPasteboard.general.changeCount != before.2
                    let w = self.c.window
                    let centre = w.convertPoint(toScreen: NSPoint(x: w.contentView?.bounds.midX ?? 0, y: w.contentView?.bounds.midY ?? 0))
                    let top = NSWindow.windowNumber(at: centre, belowWindowWithWindowNumber: 0)
                    let covered = top != 0 && top != w.windowNumber && SnapshotRunner.windowInfo(top).pid != getpid()
                    self.uiAttempt?.recordInputDelivery(now === tv && (changed || !covered))
                    self.uiAttempt?.sample()
                    self.check(now === tv && ok(tv), "shortcuts: \(k.name) in \(field) \(what) (“\(tv.string)”, selection \(NSStringFromRange(tv.selectedRange()))"
                               + (now === tv ? "" : ", the field lost the keyboard to \(Self.describe(self.c.window.firstResponder))") + ")")
                    done()
                }
            }
        }
    }

    /// The page has the keyboard: a click into it when it hasn't.
    func refocus(_ page: () -> EngineTab?, _ done: @escaping () -> Void) {
        if c.focusedPage != nil { return done() }
        clickIntoPage(done)
    }

    func postKeyStep(_ k: Key) {
        if k.unavailable { return run { [self] in skip("shortcuts: \(k.name): this keyboard layout can't type it (\(Self.layoutName))") } }
        step { [self] done in postKey(k); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done) }
    }

    static var layoutName: String {
        guard let s = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(), let n = TISGetInputSourceProperty(s, kTISPropertyLocalizedName) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(n).takeUnretainedValue() as String
    }

    func postKey(_ k: Key, up: Bool = true) {
        for type in up ? [NSEvent.EventType.keyDown, .keyUp] : [.keyDown] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: k.mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: c.window.windowNumber, context: nil, characters: k.chars,
                                           charactersIgnoringModifiers: k.ignoring, isARepeat: false, keyCode: k.code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// The window this run treats as key (see the type's note).
    private static weak var keyWindowForTest: NSWindow?

    /// A key window's dispatch for a window that can't be key (see the type's note). AIRC_KEYWINDOW picks the parts
    /// (diagnosis): window (NSWindow.isKeyWindow), app (NSApp.keyWindow), notify (didBecomeKey), rwhv (Chromium's page
    /// view only), menu (the main menu with the window's responder chain as nil-targeted items' targets).
    static func emulateKeyWindow(_ c: WindowController, note: @escaping (String) -> Void) {
        emulateKeyWindow(c.window, note: note)
    }

    /// The same for any of the app's windows (a private window: PrivateWindowExtrasCheck.swift).
    static func emulateKeyWindow(_ window: NSWindow, note: @escaping (String) -> Void) {
        let parts = Set((ProcessInfo.processInfo.environment["AIRC_KEYWINDOW"] ?? "rwhv,app,menu").split(separator: ",").map(String.init))
        let trace = ProcessInfo.processInfo.environment["AIRC_SHORTCUTS_TRACE"] == "1"
        note("shortcuts: key window stand-in: " + parts.sorted().joined(separator: ", "))
        keyWindowForTest = window
        if parts.contains("window"), let m = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow)) {
            typealias Getter = @convention(c) (NSWindow, Selector) -> ObjCBool
            let original = unsafeBitCast(method_getImplementation(m), to: Getter.self)
            let key: @convention(block) (NSWindow) -> ObjCBool = { w in w === keyWindowForTest ? true : original(w, #selector(getter: NSWindow.isKeyWindow)) }
            method_setImplementation(m, imp_implementationWithBlock(key))
        }
        if parts.contains("app"), let m = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow)) {
            typealias Getter = @convention(c) (NSApplication, Selector) -> NSWindow?
            let original = unsafeBitCast(method_getImplementation(m), to: Getter.self)
            let key: @convention(block) (NSApplication) -> NSWindow? = { app in keyWindowForTest ?? original(app, #selector(getter: NSApplication.keyWindow)) }
            method_setImplementation(m, imp_implementationWithBlock(key))
        }
        if parts.contains("rwhv"), let cls = NSClassFromString("RenderWidgetHostViewCocoa"),
           let m = class_getInstanceMethod(cls, NSSelectorFromString("isKeyTrackingWindowKey")) {
            let key: @convention(block) (AnyObject) -> ObjCBool = { _ in true }
            method_setImplementation(m, imp_implementationWithBlock(key))
        }
        // The engines' pages take the keyboard (Chromium's page focus, its text input state) only in a key window.
        if parts.contains("notify") { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window) }
        let ownMenu = parts.contains("menu")
        // After the app's monitor: the window's views, then the main menu (AppKit's keyDown comes after, as ever).
        KeyMonitor.testKeyWindowDispatch = { [weak window] event in
            guard let window, event.window === window else { return false }
            guard event.modifierFlags.contains(.command) else {
                if trace { note("trace: \(Self.name(event)) → keyDown (\(Self.describe(window.firstResponder)))") }
                return false
            }
            if window.performKeyEquivalent(with: event) {
                if trace { note("trace: \(Self.name(event)) → a view took it (\(Self.describe(window.firstResponder)))") }
                return true
            }
            let menu = ownMenu ? performMenuKey(event, in: window) : NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            if trace { note("trace: \(Self.name(event)) → " + (menu ? "the main menu took it" : "keyDown (\(Self.describe(window.firstResponder)))")) }
            return menu
        }
    }

    static func name(_ e: NSEvent) -> String {
        let m = e.modifierFlags
        return (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
            + (e.charactersIgnoringModifiers ?? "?") + (e.isARepeat ? " (repeat)" : "") + (e.type == .keyUp ? " up" : "")
    }

    /// NSMenu's key equivalent lookup and dispatch, with the window's responder chain for nil targets (an inactive app
    /// has no key window to send them to).
    static func performMenuKey(_ event: NSEvent, in w: NSWindow) -> Bool {
        guard let menu = NSApp.mainMenu, let item = menuItem(for: event, in: menu), let action = item.action else { return false }
        var target: AnyObject? = item.target
        if target == nil {
            var r: NSResponder? = w.firstResponder
            while let x = r, !x.responds(to: action) { r = x.nextResponder }
            target = r
            if target == nil, let d = w.delegate as AnyObject?, d.responds(to: action) { target = d }
            if target == nil, NSApp.responds(to: action) { target = NSApp }
            if target == nil, let d = NSApp.delegate as AnyObject?, d.responds(to: action) { target = d }
        }
        guard let t = target else { return false }
        if let v = t as? NSMenuItemValidation, !v.validateMenuItem(item) { return false }
        if !(t is NSMenuItemValidation), let v = t as? NSUserInterfaceValidations, !v.validateUserInterfaceItem(item) { return false }
        return NSApp.sendAction(action, to: t, from: item)
    }

    static func menuItem(for e: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = e.modifierFlags.intersection(mask), chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        for item in menu.items {
            if let sub = item.submenu {
                if let hit = menuItem(for: e, in: sub) { return hit }
                continue
            }
            guard !item.keyEquivalent.isEmpty, !item.isHidden || item.allowsKeyEquivalentWhenHidden else { continue }
            var itemFlags = item.keyEquivalentModifierMask.intersection(mask)
            if item.keyEquivalent != item.keyEquivalent.lowercased() { itemFlags.insert(.shift) }
            if itemFlags == flags, item.keyEquivalent.lowercased() == chars { return item }
        }
        return nil
    }

    static func logged(_ s: [String: Any], _ prefix: String) -> Bool { (s["log"] as? [String])?.contains { $0.hasPrefix(prefix) } == true }

    static func js(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "\\'") + "'" }

    static func fieldState(_ s: [String: Any]) -> String {
        "input “\(s["iv"] ?? "-")” \(s["is"] ?? "-")–\(s["ie"] ?? "-"), textarea “\((s["ta"] as? String ?? "-").replacingOccurrences(of: "\n", with: "⏎"))” "
            + "\(s["tas"] ?? "-")–\(s["tae"] ?? "-"), active \(s["active"] ?? "-")"
    }

    static func putPlain(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        UICheckAttempt.markFixture()
    }

    static func putRichText(html: String, plain: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(plain, forType: .string)
        UICheckAttempt.markFixture()
    }

    static func pasteboardItems() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    static func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { d in
            let item = NSPasteboardItem()
            for (t, v) in d { item.setData(v, forType: t) }
            return item
        })
    }

    static func shortcutViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        func walk(_ v: NSView) { if let t = v as? T { found.append(t) }; v.subviews.forEach(walk) }
        walk(root)
        return found
    }
}
#endif
