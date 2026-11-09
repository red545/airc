// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityk07` (both engines): Airc's AppleScript dictionary against Arc's (K07, Scripting/). Scripts are
/// AppleScript text, compiled with the terms of this very app bundle (`using terms from`) and sent to
/// `current application`: the events stay in this process, so no other app is scripted and macOS asks no Automation
/// question. Pages are on loopback.
///   - the dictionary: every class, property and command Arc's had, with Arc's four-letter codes, loaded by Cocoa;
///   - windows: count, name, id, index, active tab, active space; spaces: title, profile, focus;
///   - tabs: every tab of a window and of a space with Arc's locations (topApp, pinned, unpinned), whose-id lookups,
///     select, set URL, reload, go back and forward, close; `make new tab` in a window and in a space, and Arc's
///     error without a URL; `make new tab` at the application opens a Little Arc;
///   - a script shaped like Raycast's Arc extension (properties of every tab, as JSON);
///   - `execute … javascript`: refused while View › Allow JavaScript from Apple Events is off (the default), and the
///     menu item's checkmark; with it on, the page's answer as text;
///   - private windows: `make new window with properties {incognito:true}`, its mode and tabs, `execute` refused there
///     even with the switch on, `close`.
extension SnapshotRunner {
    func parityK07Scenario() {
        var server: LocalPageServer?, port: UInt16 = 0
        var base: String { "http://127.0.0.1:\(port)" }
        var sid = "", workID = "", todayID = "", pinnedItem = "", favoriteItem = ""
        var wrap: ((String) -> String)?
        func page(_ title: String, _ extra: String = "") -> String {
            "<title>\(title)</title><body style='font:18px -apple-system;margin:40px'><h1>\(title)</h1>\(extra)</body>"
        }
        step { done in
            server = LocalPageServer(pages: ["/a": page("Alpha", "<script>window.k07 = {answer: 42}</script>"), "/b": page("Beta"),
                                             "/c": page("Gamma"), "/p": page("Pinned page"), "/f": page("Favorite page")])
            server?.start { port = $0 ?? 0; done() }
            if server == nil { done() }
        }

        // The dictionary: Arc's names and codes, as Cocoa loaded them.
        run { [self] in
            let registry = NSScriptSuiteRegistry.shared()
            func cls(_ code: String) -> NSScriptClassDescription? { registry.classDescription(withAppleEventCode: k07Code(code)) }
            let classes = [("window", "WiND"), ("tab", "tAbB"), ("space", "sPaC")]
            let missingClasses = classes.filter { cls($0.1)?.className != $0.0 }
            let properties: [(String, String, String)] = [
                ("WiND", "ID  ", "uniqueID"), ("WiND", "pnam", "title"), ("WiND", "pidx", "orderedIndex"), ("WiND", "hclb", "hasCloseBox"),
                ("WiND", "ismn", "isMiniaturizable"), ("WiND", "pmnd", "isMiniaturized"), ("WiND", "prsz", "isResizable"),
                ("WiND", "pvis", "isVisible"), ("WiND", "iszm", "isZoomable"), ("WiND", "pzum", "isZoomed"), ("WiND", "acTa", "activeTab"),
                ("WiND", "acSp", "activeSpace"), ("WiND", "inco", "isIncognito"), ("WiND", "mode", "mode"),
                ("tAbB", "ID  ", "uniqueID"), ("tAbB", "pnam", "title"), ("tAbB", "URL ", "URL"), ("tAbB", "ldng", "loading"),
                ("tAbB", "loca", "location"), ("sPaC", "ID  ", "uniqueID"), ("sPaC", "pnam", "title"),
            ]
            let missingProperties = properties.filter { cls($0.0)?.key(withAppleEventCode: k07Code($0.1)) != $0.2 }
            let commands: [(String, String, String)] = [("core", "crel", "make"), ("core", "cnte", "count"), ("core", "clos", "close"),
                ("CrSe", "lect", "select"), ("CrSu", "Back", "go back"), ("CrSu", "Fwd ", "go forward"), ("CrSu", "Rlod", "reload"),
                ("CrSu", "stop", "stop"), ("CrSu", "ExJa", "execute"), ("SpaF", "ocus", "focus")]
            let missingCommands = commands.filter {
                registry.commandDescription(withAppleEventClass: k07Code($0.0), andAppleEventCode: k07Code($0.1))?.commandName != $0.2
            }
            check(missingClasses.isEmpty && missingProperties.isEmpty && missingCommands.isEmpty,
                  "parityk07: Arc's classes, properties and commands with Arc's codes (missing \(missingClasses.map(\.0) + missingProperties.map { "\($0.0).\($0.2)" } + missingCommands.map(\.2)))")
            check(Bundle.main.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true
                  && Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String == "Airc.sdef",
                  "parityk07: Info.plist turns scripting on with Airc.sdef")
        }

        // A Space with a Favorite, a pinned tab and a Today tab, and a second Space.
        run { [self] in
            sid = c.currentSpaceID
            let profile = c.store.profile(ofSpace: sid)
            workID = (try? c.store.createSpace(name: "K07 Work", profileID: profile.id, after: sid))?.id ?? ""
            if let t = try? c.store.openTab(url: base + "/f", inSpace: sid), (try? c.store.move(.tab(t.id), to: .favorites(profileID: profile.id, index: 0))) != nil {
                favoriteItem = c.store.favorites(ofProfile: profile.id).first { $0.savedURL == base + "/f" }?.id ?? ""
            }
            if let t = try? c.store.openTab(url: base + "/p", inSpace: sid), (try? c.store.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))) != nil {
                pinnedItem = c.store.children(of: .pinned(spaceID: sid), parent: nil).first { $0.savedURL == base + "/p" }?.id ?? ""
            }
            todayID = (try? c.store.openTab(url: base + "/a", inSpace: sid))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(todayID)
            check(!workID.isEmpty && !favoriteItem.isEmpty && !pinnedItem.isEmpty && !todayID.isEmpty,
                  "parityk07: a Space with a Favorite, a pinned tab and a Today tab, and a second Space")
        }
        waitForPage()

        // How scripts reach the app: this bundle's terms, sent to the current application.
        run { [self] in
            let bundle = Bundle.main.bundleURL as CFURL
            let hfs = CFURLPathStyle(rawValue: 1).map { CFURLCopyFileSystemPath(bundle, $0) as String } ?? ""   // kCFURLHFSPathStyle
            let candidates: [(String, (String) -> String)] = [
                ("using terms from this bundle", { "with timeout of 40 seconds\nusing terms from application \"\(hfs)\"\ntell current application\n\($0)\nend tell\nend using terms from\nend timeout" }),
                ("current application", { "with timeout of 40 seconds\ntell current application\n\($0)\nend tell\nend timeout" }),
            ]
            for (name, w) in candidates {
                let r = k07Run(w("count windows"))
                if r.error == nil, (r.int ?? 0) >= 1 { wrap = w; note("parityk07: scripts compile with \(name)"); break }
                note("parityk07: \(name) didn't work: \(r.error ?? 0) \(r.message ?? "")")
            }
            check(wrap != nil, "parityk07: an Arc-style script compiles and runs in Airc (count windows)")
        }
        func script(_ body: String) -> K07Result { wrap.map { k07Run($0(body)) } ?? K07Result(error: -1, message: "no way to run scripts") }

        // Windows, spaces, tabs.
        run { [self] in
            guard wrap != nil else { return }
            let name = script("name of front window"), id = script("id of front window"), index = script("index of front window")
            check(name.text == c.window.title && id.text == String(c.window.windowNumber) && index.int == 1,
                  "parityk07: name, id and index of front window (\(name.text ?? "-"), \(id.text ?? "-"), \(index.int.map(String.init) ?? "-"))")
            let version = script("version"), closeable = script("closeable of front window")
            check(version.text?.isEmpty == false && closeable.bool == true, "parityk07: version (\(version.text ?? "-")) and closeable of front window")
            let active = script("URL of active tab of front window"), title = script("title of active tab of front window")
            check(active.text == base + "/a" && title.text == "Alpha" && script("id of active tab of front window").text == todayID,
                  "parityk07: active tab of front window: its URL, title and id (\(active.text ?? active.message ?? "-"), \(title.text ?? "-"))")
            let space = script("id of active space of front window"), titles = script("title of every space of front window")
            let profile = script("profile of active space of front window")
            check(space.text == sid && titles.list.contains("K07 Work") && titles.list.count == c.windowSpaces.count
                  && profile.text == c.store.profile(ofSpace: sid).name,
                  "parityk07: active space and every space's title, the space's profile (\(titles.list), \(profile.text ?? "-"))")
            let ids = script("id of every tab of front window").list, locations = script("location of every tab of active space of front window").list
            let spaceIDs = script("id of every tab of active space of front window").list
            let expected = ScriptWindow(c).scriptTabs.map(\.uniqueID)
            check(ids == expected && ids.contains(favoriteItem) && ids.contains(pinnedItem) && ids.contains(todayID),
                  "parityk07: every tab of the window in sidebar order, Favorites, pinned and Today (\(ids.count) tabs)")
            let byID = Dictionary(zip(spaceIDs, locations), uniquingKeysWith: { a, _ in a })
            check(byID[favoriteItem] == "topApp" && byID[pinnedItem] == "pinned" && byID[todayID] == "unpinned",
                  "parityk07: Arc's locations: a Favorite is topApp, a pinned tab pinned, a Today tab unpinned (\(byID[favoriteItem] ?? "-"), \(byID[pinnedItem] ?? "-"), \(byID[todayID] ?? "-"))")
            let count = script("count tabs of front window"), whose = script("title of (first tab of front window whose id is \"\(todayID)\")")
            check(count.int == expected.count && whose.text == "Alpha", "parityk07: count tabs, and a tab found by whose id (\(whose.text ?? whose.message ?? "-"))")
        }

        // A Raycast-shaped script (its Arc extension's tab list): properties of every tab, as JSON text.
        run { [self] in
            guard wrap != nil else { return }
            let r = script("""
            set _output to ""
            set allTabs to properties of every tab of first window
            repeat with i from 1 to count of allTabs
              set _tab to item i of allTabs
              set _output to _output & "{\\"title\\":\\"" & (title of _tab) & "\\",\\"url\\":\\"" & (URL of _tab) & "\\",\\"id\\":\\"" & (id of _tab) & "\\",\\"location\\":\\"" & (location of _tab) & "\\"}"
              if i < (count of allTabs) then set _output to _output & ","
            end repeat
            return "[" & _output & "]"
            """)
            let tabs = r.text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: String]] } ?? []
            check(tabs.count == ScriptWindow(c).scriptTabs.count && tabs.contains { $0["id"] == pinnedItem && $0["location"] == "pinned" && $0["url"] == base + "/p" },
                  "parityk07: a Raycast-shaped script reads properties of every tab (\(tabs.count) tabs\(r.message.map { ", \($0)" } ?? ""))")
        }

        // select, make new tab in a window and in a space, focus.
        run { [self] in
            guard wrap != nil else { return }
            _ = script("tell (first tab of front window whose id is \"\(pinnedItem)\") to select")
            check(c.store.tab(c.shownTabID)?.itemID == pinnedItem, "parityk07: select shows a pinned tab, loading it")
            let made = script("tell front window to make new tab with properties {URL:\"\(base)/b\"}")
            let shown = c.store.tab(c.shownTabID)
            check(made.error == nil && shown?.url == base + "/b" && shown?.isToday == true && shown?.spaceID == sid,
                  "parityk07: make new tab in a window opens a Today tab there, shown (\(made.message ?? shown?.url ?? "-"))")
            let inSpace = script("tell space 2 of front window to make new tab with properties {URL:\"\(base)/c\"}")
            let space2 = c.windowSpaces.count > 1 ? c.windowSpaces[1].id : ""
            check(inSpace.error == nil && c.currentSpaceID == space2 && c.store.tab(c.shownTabID)?.url == base + "/c",
                  "parityk07: make new tab in space 2 opens it there, on screen (\(inSpace.message ?? "ok"))")
            let missing = script("tell front window to make new tab")
            check(missing.message?.contains("Please provide a valid URL property") == true, "parityk07: make new tab without a URL gives Arc's answer (\(missing.message ?? "none"))")
            _ = script("tell (first space of front window whose id is \"\(sid)\") to focus")
            check(c.currentSpaceID == sid, "parityk07: focus a space")
            _ = script("tell (first tab of front window whose id is \"\(todayID)\") to select")
        }
        waitForPage()
        // set URL, reload, go back and forward.
        run { [self] in
            guard wrap != nil else { return }
            _ = script("set URL of active tab of front window to \"\(base)/b\"")
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: todayID)?.url?.path == "/b" && self.c.engineTab(for: todayID)?.isLoading == false }, timeout: 6) { done() } }
        run { [self] in
            check(c.engineTab(for: todayID)?.url?.absoluteString == base + "/b" && script("loading of active tab of front window").bool == false,
                  "parityk07: set URL of the active tab loads it in place")
            _ = script("go back active tab of front window")
        }
        // Back done loading before forward (WebKit ignores a forward while the back is still under way).
        step { [self] done in waitUntil({ self.c.engineTab(for: todayID)?.url?.path == "/a" && self.c.engineTab(for: todayID)?.isLoading == false }, timeout: 6) { done() } }
        run { [self] in
            check(c.engineTab(for: todayID)?.url?.path == "/a", "parityk07: go back")
            _ = script("go forward active tab of front window")
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: todayID)?.url?.path == "/b" }, timeout: 6) { done() } }
        run { [self] in
            check(c.engineTab(for: todayID)?.url?.path == "/b", "parityk07: go forward")
            _ = script("set URL of active tab of front window to \"\(base)/a\"")
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: todayID)?.title == "Alpha" && self.c.engineTab(for: todayID)?.isLoading == false }, timeout: 6) { done() } }

        // execute javascript: off by default, the menu's checkmark, then on.
        run { [self] in
            guard wrap != nil, let app else { return }
            let item = k07MenuItem("Allow JavaScript from Apple Events")
            item?.menu?.update()
            check(app.settings.values.appleEventsJavaScript == false && item != nil && item?.state == .off,
                  "parityk07: Allow JavaScript from Apple Events is off by default, unchecked in the View menu")
            let off = script("execute active tab of front window javascript \"document.title\"")
            check(off.error == -10004 && off.message?.contains("Allow JavaScript from Apple Events") == true,
                  "parityk07: execute is refused while it's off (\(off.error.map(String.init) ?? "-"): \(off.message ?? "-"))")
            if let item, let target = item.target, let action = item.action { NSApp.sendAction(action, to: target, from: item) }
            item?.menu?.update()
            check(app.settings.values.appleEventsJavaScript && item?.state == .on, "parityk07: the menu item turns it on, checked")
        }
        run { [self] in
            guard wrap != nil else { return }
            let title = script("execute active tab of front window javascript \"document.title\"")
            let sum = script("tell active tab of front window to execute javascript \"6 * 7\"")
            let object = script("execute active tab of front window javascript \"window.k07\"")
            check(title.text == "Alpha" && sum.text == "42" && object.text == "{\"answer\":42}",
                  "parityk07: execute returns the page's answer as text (\(title.text ?? title.message ?? "-"), \(sum.text ?? "-"), \(object.text ?? "-"))")
            let unloaded = script("execute (first tab of front window whose id is \"\(favoriteItem)\") javascript \"1\"")
            check(unloaded.error == -1728, "parityk07: execute in a tab that isn't loaded says to select it (\(unloaded.message ?? "-"))")
        }

        // Private windows: made by script, scriptable, never running JavaScript.
        var privateID = ""
        run { [self] in
            guard wrap != nil else { return }
            let before = PrivateBrowsing.shared.windows.count
            let made = script("make new window with properties {incognito:true}")
            privateID = PrivateBrowsing.shared.windows.last.map { String($0.window.windowNumber) } ?? ""
            check(made.error == nil && PrivateBrowsing.shared.windows.count == before + 1 && !privateID.isEmpty,
                  "parityk07: make new window with properties {incognito:true} opens a private window (\(made.message ?? "ok"))")
            let mode = script("mode of window id \"\(privateID)\""), incognito = script("incognito of window id \"\(privateID)\"")
            let normal = script("mode of window id \"\(c.window.windowNumber)\"")
            check(mode.text == "incognito" && incognito.bool == true && normal.text == "normal",
                  "parityk07: a private window's mode is incognito, a browser window's normal (\(mode.text ?? mode.message ?? "-"))")
            let tab = script("tell window id \"\(privateID)\" to make new tab with properties {URL:\"\(base)/c\"}")
            check(tab.error == nil, "parityk07: make new tab in a private window (\(tab.message ?? "ok"))")
        }
        step { [self] done in
            waitUntil({ PrivateBrowsing.shared.windows.last?.shownPage.map { $0.title == "Gamma" && !$0.isLoading } ?? false }, timeout: 8) { done() }
        }
        run { [self] in
            guard wrap != nil else { return }
            let url = script("URL of active tab of window id \"\(privateID)\""), count = script("count tabs of window id \"\(privateID)\"")
            let spaces = script("count spaces of window id \"\(privateID)\"")
            check(url.text == base + "/c" && (count.int ?? 0) >= 1 && spaces.int == 0,
                  "parityk07: a private window's tabs (\(url.text ?? url.message ?? "-")), no spaces")
            let js = script("execute active tab of window id \"\(privateID)\" javascript \"document.title\"")
            check(js.error == -10004 && js.message?.contains("private windows") == true,
                  "parityk07: execute is refused in a private window even with the switch on (\(js.message ?? "-"))")
            _ = script("close window id \"\(privateID)\"")
        }
        step { [self] done in waitUntil({ PrivateBrowsing.shared.windows.isEmpty }, timeout: 6) {
            self.check(PrivateBrowsing.shared.windows.isEmpty, "parityk07: close a private window")
            done()
        } }

        // A Little Arc from `make new tab` at the application; closing a Today tab.
        var extra = ""
        run { [self] in
            guard wrap != nil, let app else { return }
            let before = app.littleArcs.count
            let made = script("make new tab with properties {URL:\"\(base)/b\"}")
            check(made.error == nil && app.littleArcs.count == before + 1, "parityk07: make new tab at the application opens a Little Arc (\(made.message ?? "ok"))")
            app.littleArcs.last?.closeWindow()
            extra = c.store.todayTabs(ofSpace: sid).first { $0.url == base + "/b" && $0.id != todayID }?.id ?? ""
            _ = script("close (first tab of front window whose id is \"\(extra)\")")
        }
        // Chromium closes a page asynchronously; the tab leaves the sidebar once it has.
        step { [self] done in waitUntil({ !extra.isEmpty && self.c.store.tab(extra) == nil }, timeout: 5) {
            self.check(!extra.isEmpty && self.c.store.tab(extra) == nil, "parityk07: close a Today tab")
            done()
        } }
        // The switch back off, as it was.
        run { [self] in
            app?.settings.values.appleEventsJavaScript = false
            if c.store.space(workID) != nil { try? c.store.deleteSpace(workID) }
            server?.stop()
        }
    }

    private func k07MenuItem(_ title: String) -> NSMenuItem? {
        func find(_ m: NSMenu?) -> NSMenuItem? {
            guard let m else { return nil }
            for i in m.items {
                if i.title == title { return i }
                if let hit = find(i.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    fileprivate func k07Run(_ source: String) -> K07Result {
        guard let s = NSAppleScript(source: source) else { return K07Result(error: -1, message: "no script") }
        var info: NSDictionary?
        let r = s.executeAndReturnError(&info)
        if let info {
            return K07Result(error: info[NSAppleScript.errorNumber] as? Int ?? -1, message: info[NSAppleScript.errorMessage] as? String)
        }
        return K07Result(value: r)
    }
}

fileprivate func k07Code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

fileprivate struct K07Result {
    var value: NSAppleEventDescriptor?
    var error: Int?
    var message: String?
    init(value: NSAppleEventDescriptor?) { self.value = value }
    init(error: Int, message: String?) { self.error = error; self.message = message }
    var text: String? { value?.stringValue }
    var int: Int? { value.map { Int($0.int32Value) } }
    var bool: Bool? { value.map { $0.booleanValue } }
    var list: [String] {
        guard let v = value, v.numberOfItems > 0 else { return [] }
        return (1...v.numberOfItems).map { v.atIndex($0)?.stringValue ?? "" }
    }
}
#endif
