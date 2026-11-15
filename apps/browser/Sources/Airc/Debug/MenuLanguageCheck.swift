// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script menulang`: Airc speaks one language, English, until it is localized (Info.plist CFBundleLocalizations
/// = [en] and Resources/en.lproj; docs/localization.md). Run it under a German test locale
/// (`-AppleLanguages '(de)' -AppleLocale de_AT`, as build-app.sh's suite does). Every string the Mac or the engine
/// supplies must then be English as well: AppKit's items in the menu bar (Edit's Start Dictation, Emoji & Symbols and
/// AutoFill; the Window menu; Hide Others), a text field's menu with its Spelling and Substitutions submenus, an
/// alert, the Open panel, and the page's own menu on a page and in a text field (Chromium's strings, or WebKit's).
/// Region formatting stays the Mac's (de_AT's region AT), and sites still get the Mac's preferred languages.
///
/// The menus are drawn from their live items into menulang-*.png: opening a real menu would hold the run in its
/// tracking loop. The alert and the Open panel are shown as sheets and drawn from their windows.
extension SnapshotRunner {
    /// German the Mac supplies when the app's language resolves to German: umlauts, ß, or one of these words.
    static let menuLangGerman = ["Bearbeiten", "Ablage", "Darstellung", "Fenster", "Hilfe", "Dienste", "ausblenden",
        "einblenden", "Beenden", "Diktat", "Symbole", "Ausschneiden", "Kopieren", "Einsetzen", "Rückgängig",
        "Wiederholen", "Abbrechen", "Öffnen", "Sichern", "Speichern", "Zurück", "Vorwärts", "Neu laden", "Untersuchen",
        "Rechtschreibung", "Grammatik", "Ersetzungen", "Sprachausgabe", "Vollbild", "Minimieren", "Schließen",
        "Automatisch", "ausfüllen", "Nicht mehr", "Suchen", "Drucken", "Bild ", "Einfügen", "Auswählen", "Schreibrichtung",
        "Bewegen", "Füllen", "Zentrieren", "Anordnen", "Nachschlagen", "Übersetzen", "Teilen", "Seitenquelltext"]
    static func menuLangIsGerman(_ s: String) -> Bool {
        s.contains { "äöüßÄÖÜ".contains($0) } || menuLangGerman.contains { s.contains($0) }
    }

    func menuLanguageScenario() {
        var server: LocalPageServer?
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        var engineName = "webkit"
        #if canImport(AircCore)
        if app?.engine is ChromiumEngine { engineName = "chromium" }
        #endif
        let tag = { "menulang \(engineName)" }
        func german(_ titles: [String]) -> [String] { titles.filter(Self.menuLangIsGerman) }

        // The app's language, and what the region still controls.
        run { [self] in
            let main = Bundle.main.preferredLocalizations
            let appKit = Bundle(for: NSApplication.self).preferredLocalizations.first ?? "-"
            note("\(tag()): Mac languages \(Locale.preferredLanguages), locale \(Locale.current.identifier); "
                 + "Airc localizations \(Bundle.main.localizations), resolved \(main); AppKit resolves \(appKit)")
            check(main.first == "en", "\(tag()): the app's language resolves to English (\(main))")
            let declared = Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] ?? []
            let strings = Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: "en")
            check(declared == ["en"] && strings != nil && Set(Bundle.main.localizations).subtracting(["Base"]) == ["en"],
                  "\(tag()): the bundle declares English as its only localization (CFBundleLocalizations \(declared), en.lproj \(strings != nil))")
            let germanMac = Locale.preferredLanguages.first?.hasPrefix("de") == true
            if germanMac {
                // Formats keep the Mac's region: de_AT's dates and numbers stay Austrian (day.month., decimal comma).
                let region = Locale.current.region?.identifier ?? "-"
                let number = NumberFormatter.localizedString(from: 1234.5, number: .decimal)
                check(region == "AT" && number.contains(","),
                      "\(tag()): region formatting stays the Mac's (region \(region), 1234.5 → \(number))")
            } else {
                skip("\(tag()): launched without a German test locale (-AppleLanguages '(de)'); the checks below prove nothing")
            }
        }

        // The menu bar, as AppKit has filled it (Dictation, Emoji & Symbols, AutoFill, the Window menu's own items).
        // Services' entries come from each providing app and the Window menu's window list from page titles; neither is ours.
        run { [self] in
            var lines: [String] = []
            var titles: [String] = []
            func walk(_ menu: NSMenu, depth: Int) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                for item in menu.items where !item.isHidden {
                    if item.isSeparatorItem { lines.append(String(repeating: "    ", count: depth) + "—"); continue }
                    if item.action == #selector(NSWindow.makeKeyAndOrderFront(_:)) { continue }
                    let key = item.keyEquivalent.isEmpty ? "" : "   ⌘" + item.keyEquivalent.uppercased()
                    lines.append(String(repeating: "    ", count: depth) + item.title + key)
                    titles.append(item.title)
                    if let sub = item.submenu, sub !== NSApp.servicesMenu { walk(sub, depth: depth + 1) }
                }
            }
            guard let bar = NSApp.mainMenu else { check(false, "\(tag()): the app has a main menu"); return }
            let top = bar.items.dropFirst().map(\.title)
            for item in bar.items { if let sub = item.submenu { lines.append(item.title); walk(sub, depth: 1) } }
            note("\(tag()): menu bar \(top)")
            let bad = german(titles)
            check(bad.isEmpty, "\(tag()): every menu bar item is English (\(titles.count) items; German: \(bad))")
            let edit = bar.items.first { $0.submenu?.items.contains { $0.action == #selector(NSText.copy(_:)) } == true }?.submenu
            let system = (edit?.items ?? []).filter { !$0.isHidden }.filter {
                [#selector(NSApplication.orderFrontCharacterPalette(_:)), NSSelectorFromString("startDictation:")].contains($0.action)
                    || $0.title.contains("AutoFill") || $0.title.contains("ausfüllen")
            }.map(\.title)
            note("\(tag()): Edit's items from the Mac: \(system)")
            check(!system.isEmpty && german(system).isEmpty, "\(tag()): Edit's items from the Mac are English (\(system))")
            let window = NSApp.windowsMenu?.items.filter { !$0.isSeparatorItem && $0.action != #selector(NSWindow.makeKeyAndOrderFront(_:)) }.map(\.title) ?? []
            note("\(tag()): Window menu \(window)")
            drawList("menulang-menubar", header: "Menu bar: " + top.joined(separator: "  "), lines: lines)
            drawList("menulang-edit", header: "Edit", lines: edit.map { menu in
                menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title + ($0.submenu == nil ? "" : "  ›") } } ?? [])
        }

        // A text field's menu (the field editor's, as AppKit builds it for a right-click), with its submenus.
        run { [self] in
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            text.string = "Hello world"
            text.isEditable = true
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = text.menu(for: event) ?? NSTextView.defaultMenu
            var lines: [String] = []
            var titles: [String] = []
            func walk(_ m: NSMenu, _ depth: Int) {
                m.update()
                for item in m.items where !item.isHidden {
                    lines.append(String(repeating: "    ", count: depth) + (item.isSeparatorItem ? "—" : item.title))
                    if item.isSeparatorItem { continue }
                    titles.append(item.title)
                    if let sub = item.submenu, sub !== NSApp.servicesMenu, depth < 1 { walk(sub, depth + 1) }
                }
            }
            if let menu { walk(menu, 0) }
            note("\(tag()): text field menu \(titles)")
            let bad = german(titles)
            check(titles.contains("Cut") && titles.contains("Paste") && bad.isEmpty,
                  "\(tag()): the text field menu is English, with its submenus (\(titles.count) items; German: \(bad))")
            drawList("menulang-textfield", header: "Text field menu", lines: lines)
        }

        // The page's menu on the page and in a text field: Chromium's own strings (or WebKit's).
        step { [self] done in
            server = LocalPageServer(pages: ["/lang": """
                <title>Languages</title><style>body{margin:0;font:16px system-ui}p{height:80px;margin:0;padding:20px}
                input{position:absolute;left:20px;top:140px;width:300px;height:30px}</style>
                <p>Page</p><input id=f value="Text field">
                """])
            server?.start { port in
                guard let port, let tab = try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/lang", inSpace: self.c.currentSpaceID) else {
                    self.check(false, "\(tag()): loopback page"); done(); return
                }
                tabID = tab.id; self.c.reloadAll(animated: false); self.c.show(tab.id, focus: false)
                self.waitUntil({ page()?.title == "Languages" && page()?.isLoading == false }, timeout: 15) { done() }
            }
        }
        wait(0.8)
        step { [self] done in
            guard let tab = page() else { check(false, "\(tag()): the page loaded"); return done() }
            tab.evaluate("JSON.stringify([navigator.language, navigator.languages])") { value in
                let languages = value as? String ?? "-"
                self.note("\(tag()): sites see navigator.languages \(languages)")
                if engineName == "chromium" {
                    // Chromium's Accept-Language is this list: a new profile's comes from the UI locale (en-US,en) and an
                    // existing profile keeps its own; not yet seeded from the Mac's languages (docs/localization.md).
                    self.note("\(tag()): a new Chromium profile's Accept-Language is \(languages) (docs/localization.md)")
                } else if Locale.preferredLanguages.first?.hasPrefix("de") == true {
                    // WebKit gives sites the system's first language.
                    self.check(languages.contains("\"de"), "\(tag()): sites still get the Mac's preferred languages (\(languages))")
                }
                done()
            }
        }
        for (context, x, y) in [("page", 40, 40), ("text field", 60, 155)] {
            step { [self] done in
                guard let tab = page() else { return done() }
                func report(_ titles: [String], lines: [String]) {
                    let bad = german(titles)
                    note("\(tag()): \(context) menu \(titles)")
                    check(!titles.isEmpty && bad.isEmpty, "\(tag()): the \(context) menu is English (\(titles.count) items; German: \(bad))")
                    drawList("menulang-\(engineName)-\(context.replacingOccurrences(of: " ", with: ""))",
                             header: "\(engineName == "chromium" ? "Chromium" : "WebKit") \(context) menu", lines: lines)
                }
                #if canImport(AircCore)
                if let cr = tab as? ChromiumTab, let engine = app?.engine as? ChromiumEngine {
                    var observed = false
                    cr.testPageMenu = { menu in
                        observed = true
                        var titles: [String] = [], lines: [String] = []
                        func walk(_ items: [[String: Any]], _ depth: Int) {
                            for item in items where item["visible"] as? Bool != false {
                                let label = item["label"] as? String ?? ""
                                lines.append(String(repeating: "    ", count: depth) + (label.isEmpty ? "—" : label))
                                if !label.isEmpty { titles.append(label) }
                                if let sub = item["items"] as? [[String: Any]] ?? item["submenu"] as? [[String: Any]] { walk(sub, depth + 1) }
                            }
                        }
                        walk(menu["items"] as? [[String: Any]] ?? [], 0)
                        report(titles, lines: lines)
                        return nil
                    }
                    let params: (String) -> [String: Any] = { ["type": $0, "x": x, "y": y, "button": "right", "clickCount": 1] }
                    engine.devToolsCall("Input.dispatchMouseEvent", params: params("mousePressed"), in: tab) { _, _ in
                        engine.devToolsCall("Input.dispatchMouseEvent", params: params("mouseReleased"), in: tab) { _, _ in
                            self.waitUntil({ observed }, timeout: 5) {
                                if !observed { self.check(false, "\(tag()): the \(context) menu opened") }
                                cr.testPageMenu = nil
                                done()
                            }
                        }
                    }
                    return
                }
                #endif
                guard let wk = tab as? WebKitTab, let view = wk.webView as? PageMenuWebView else {
                    check(false, "\(tag()): a page menu hook for this engine"); return done()
                }
                var observed = false
                view.testMenuOpened = { menu in
                    observed = true
                    let items = menu.items.filter { !$0.isHidden }
                    report(items.filter { !$0.isSeparatorItem }.map(\.title), lines: items.map { $0.isSeparatorItem ? "—" : $0.title })
                    DispatchQueue.main.async { menu.cancelTracking() }
                }
                // As ParityContextMenuCheck: the right-click goes through the window; its menu is cancelled as soon as it tracks.
                let point = view.convert(NSPoint(x: CGFloat(x), y: view.isFlipped ? CGFloat(y) : view.bounds.height - CGFloat(y)), to: nil)
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: c.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                let cancellation = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                    guard let menu = note.object as? NSMenu else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { menu.cancelTracking() }
                }
                DispatchQueue.main.async { self.c.window.sendEvent(event) }
                waitUntil({ observed }, timeout: 5) {
                    NotificationCenter.default.removeObserver(cancellation)
                    view.testMenuOpened = nil
                    if !observed { self.check(false, "\(tag()): the \(context) menu opened") }
                    done()
                }
            }
            wait(0.4)
        }

        // An alert (AppKit's OK and its "Do not show this message again"), shown as a sheet.
        step { [self] done in
            let alert = NSAlert()
            alert.messageText = "Airc speaks English"
            alert.informativeText = "This alert's buttons come from macOS."
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: c.window) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                let titles = alert.buttons.map(\.title) + [alert.suppressionButton?.title ?? ""]
                note("\(tag()): alert \(titles)")
                check(titles.first == "OK" && german(titles).isEmpty, "\(tag()): the alert's buttons are English (\(titles))")
                if let view = alert.window.contentView, let image = render(view) { savePNG(image, "menulang-alert") }
                c.window.endSheet(alert.window)
                done()
            }
        }
        wait(0.5)
        // The Open panel, shown as a sheet: its buttons and sidebar come from macOS.
        step { [self] done in
            let panel = NSOpenPanel()
            panel.directoryURL = FileManager.default.temporaryDirectory
            panel.beginSheetModal(for: c.window) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                var buttons: [String] = []
                func walk(_ v: NSView) {
                    if let b = v as? NSButton, !b.title.isEmpty, !b.isHidden { buttons.append(b.title) }
                    v.subviews.forEach(walk)
                }
                if let root = panel.contentView?.superview ?? panel.contentView { walk(root) }
                // macOS draws the panel in its own service process (a remote view): its buttons and sidebar are read
                // through the accessibility elements the remote view exposes.
                var remote: [String] = []
                func ax(_ element: Any, _ depth: Int) {
                    guard depth < 14, remote.count < 200, let e = element as? NSObject else { return }
                    // The informal NSAccessibility methods, by selector: remote elements are plain NSObjects.
                    func get(_ name: String) -> Any? {
                        let sel = NSSelectorFromString(name)
                        return e.responds(to: sel) ? e.perform(sel)?.takeUnretainedValue() : nil
                    }
                    let role = (get("accessibilityRole") as? String) ?? ""
                    let text = [get("accessibilityTitle"), get("accessibilityLabel")].compactMap { $0 as? String }.first { !$0.isEmpty }
                    if let text, ["AXButton", "AXStaticText", "AXPopUpButton", "AXRow", "AXCell", "AXMenuButton", ""].contains(role) {
                        remote.append(text)
                    }
                    for child in (get("accessibilityChildren") as? [Any]) ?? [] { ax(child, depth + 1) }
                }
                ax(panel, 0)
                note("\(tag()): Open panel buttons \(buttons), remote texts \(remote), prompt \"\(panel.prompt ?? "")\"")
                if buttons.isEmpty && !remote.isEmpty {
                    check(german(remote).isEmpty, "\(tag()): the Open panel (out of process) is English (\(remote.count) texts; German: \(german(remote)))")
                } else if buttons.isEmpty {
                    note("\(tag()): the Open panel draws out of process here; only its prompt is readable")
                    check(german([panel.prompt ?? ""]).isEmpty, "\(tag()): the Open panel's prompt is English (\(panel.prompt ?? ""))")
                } else {
                    check(buttons.contains("Cancel") && german(buttons).isEmpty, "\(tag()): the Open panel's buttons are English (\(buttons))")
                }
                if let view = panel.contentView?.superview ?? panel.contentView, let image = render(view) { savePNG(image, "menulang-openpanel") }
                panel.cancel(nil)
                if c.window.attachedSheet === panel { c.window.endSheet(panel) }
                done()
            }
        }
        wait(0.8)
        run { [self] in
            if let sheet = c.window.attachedSheet { c.window.endSheet(sheet) }
            server?.stop(); finish()
        }
    }

    private func savePNG(_ image: NSImage, _ name: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png")
    }

    /// A menu's items drawn as a menu would show them (title per row, submenus indented).
    private func drawList(_ name: String, header: String, lines: [String]) {
        let font = NSFont.menuFont(ofSize: 13), bold = NSFont.boldSystemFont(ofSize: 13)
        let row: CGFloat = 20, pad: CGFloat = 14
        let shown = Array(lines.prefix(160))
        let columns = shown.count > 80 ? 2 : 1
        let perColumn = Int((Double(shown.count) / Double(columns)).rounded(.up))
        let width = CGFloat(columns) * 420 + pad
        let height = CGFloat(perColumn + 1) * row + pad * 2
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            (header as NSString).draw(at: NSPoint(x: pad, y: pad), withAttributes: [.font: bold, .foregroundColor: NSColor.black])
            for (i, line) in shown.enumerated() {
                let column = i / max(perColumn, 1), r = i % max(perColumn, 1)
                let point = NSPoint(x: pad + CGFloat(column) * 420, y: pad + CGFloat(r + 1) * row)
                let german = Self.menuLangIsGerman(line)
                (line as NSString).draw(at: point, withAttributes: [.font: font,
                    .foregroundColor: german ? NSColor.systemRed : NSColor.black])
            }
            return true
        }
        savePNG(image, name)
    }
}
#endif
