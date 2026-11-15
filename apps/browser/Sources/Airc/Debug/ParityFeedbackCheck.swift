// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `--script parityfeedback` (both engines): Help › Send Feedback… (docs/user/feedback.md) against a local sharing
/// server (apps/marketing/scripts/sharing-dev.mjs: the same functions as aircbrowser.com, in-memory store) or a
/// Preview: AIRC_SHARING_BASE (+ AIRC_SHARING_BYPASS, AIRC_SHARING_ADMIN). Never Production.
/// Real input (AIRC_REAL_KEYS=1, the stable UI driver, a dedicated session under the UI lock): ⌘T and typing, the
/// message typed with real keys, the boxes ticked and the buttons clicked with real clicks. Each result says which. The
/// private-window case opens it from the Help menu item itself (performActionForItem, labelled [menu item]).
///   - Help has Send Feedback… after Release Notes, without a key (Arc's Contact the Team); ⌘T "Send Feedback" opens it;
///   - both boxes start off and "What will be sent" says so; ticking the screenshot pictures this window only (its size,
///     not the screen's), with a preview Remove takes away; ticking app info lists its rows;
///   - Send: the confirmation, and the service has exactly the message, the address, the picture and the details;
///   - offline (a closed port): Send keeps it, says so plainly, and the outbox sends it once the network is back;
///   - a private window: no screenshot offered.
/// feedback2 (each real input unless it says otherwise):
///   - ⌘T "feedback", "feed", "bug", "report" (typed) put Send Feedback first; Return opens it;
///   - pictures: "Add Screenshot…" › This Window (real click + ↓ Return), Remove (real click), ⌘V of a JPEG with a
///     location in it (real ⌘V), a HEIC file dropped from a drag source (a real driver drag), five at most; the service
///     stores all of them without metadata, and the admin page shows each;
///   - the sidebar footer's Feedback button: a real click opens the sheet; ⌃-click › Hide hides it in every window and
///     Settings' value brings it back; at the 164 pt minimum it gives way to Space icons; Little Airc has no footer;
///   - a tab row's copy button (real hover and click): Today and pinned rows copy the clean link (as ⇧⌘C), the "Copied"
///     toast shows, the row isn't selected or shown; the title ends before both buttons; VoiceOver has "Copy Link".
extension SnapshotRunner {
    func parityFeedbackScenario() {
        let center = FeedbackCenter.shared
        let base = center.service.base
        guard base.host != "aircbrowser.com", base.host != "www.aircbrowser.com" else {
            run { [self] in check(false, "parityfeedback: set AIRC_SHARING_BASE to a local server or a Preview (never Production)") }
            return
        }
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL-ENV parityfeedback: real input needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1") }
            return
        }
        let admin = ProcessInfo.processInfo.environment["AIRC_SHARING_ADMIN"] ?? "local-admin-secret-for-checks-only"
        let message = "The sidebar flickers when I switch Spaces"
        let email = "qa@example.com"
        var firstID = "", windowPixels = CGSize.zero

        func sheet() -> FeedbackSheet? { FeedbackSheet.active }
        func host() -> NSView? { sheet()?.sheet.contentView }
        /// The admin page of the test server, as text.
        func adminPage(_ done: @escaping (String) -> Void) {
            var r = URLRequest(url: base.appendingPathComponent("admin/feedback"))
            r.setValue("Basic " + Data("owner:\(admin)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            center.service.extraHeaders.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            URLSession.shared.dataTask(with: r) { d, _, _ in
                let text = d.map { String(decoding: $0, as: UTF8.self) } ?? ""
                DispatchQueue.main.async { done(text) }
            }.resume()
        }
        func activate() {
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { done() }
            }
        }
        /// A real key (a ⌘ combo through the HID stream: Airc must be in front).
        func key(_ combo: String, _ what: String) {
            step { [self] done in
                UIDriverClient.run(["--key", combo, "--pid", "\(getpid())"]) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real key] \(what): \(out)") }
                    done()
                }
            }
        }
        /// Text typed with real keys, as the current layout types it; characters it can't type are noted.
        func type(_ text: String, _ what: String) {
            step { [self] done in
                guard let keys = UIDriverClient.keys(typing: text) else {
                    note("FAIL-ENV parityfeedback [real keys] \(what): \(UIDriverClient.layoutName) can't type “\(text)” with plain or ⇧ keys")
                    return done()
                }
                UIDriverClient.press(keys, pid: getpid()) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real keys] \(what): \(out)") }
                    done()
                }
            }
        }
        /// A real click on one of the sheet's controls.
        func click(_ anchor: String, _ what: String) {
            step { [self] done in
                guard let h = host(), let w = h.window, let p = anchorPoint(anchor, in: h), let primary = NSScreen.screens.first else {
                    check(false, "parityfeedback [real click] \(what): \(anchor) is on screen")
                    return done()
                }
                // Quartz global coordinates (top-left origin), as the driver takes them; no --mods for a plain click.
                let g = w.convertPoint(toScreen: p)
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real click] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }
        func shot(_ name: String) {
            step { [self] done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let v = host(), let image = self.render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: self.dir.appendingPathComponent(name + ".png"))
                        self.note("wrote \(name).png")
                    }
                    done()
                }
            }
        }
        /// A real click on Cancel when the sheet is open (the Help-search case may not have opened it).
        func clickIfOpen(_ anchor: String, _ what: String) {
            step { [self] done in
                guard let h = host(), let w = h.window, let p = anchorPoint(anchor, in: h), let primary = NSScreen.screens.first else { return done() }
                let g = w.convertPoint(toScreen: p)
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real click] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
        }
        /// The real pointer off the Command Bar's rows (they select on hover): the sidebar footer's empty middle.
        func parkPointer() {
            step { [self] done in
                let f = c.sidebar.footer
                let p = f.convert(NSPoint(x: f.bounds.midX + 30, y: f.bounds.midY), to: nil)
                UIDriverClient.move(p, in: c.window) { _, _ in done() }
            }
        }
        /// ⌘T, "send feedback", Return: all real keys.
        func openFromCommandBar(_ tag: String) {
            activate()
            parkPointer()
            key("cmd+t", "⌘T (\(tag))")
            wait(0.6)
            // Tab on the empty field: actions only, so a search suggestion can't come first.
            key("tab", "Tab (\(tag))")
            wait(0.3)
            type("send feedback", "the command (\(tag))")
            wait(0.6)
            key("return", "Return (\(tag))")
            step { [self] done in waitUntil({ sheet() != nil && sheet()?.sheet.isVisible == true }, timeout: 4) { done() } }
            wait(0.5)
        }

        // The menu: Help › Send Feedback…, Arc's place for Contact the Team.
        run { [self] in
            let help = NSApp.helpMenu
            let titles = help?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
            let item = help?.items.first { $0.title == "Send Feedback…" }
            check(titles.firstIndex(of: "Send Feedback…") == titles.firstIndex(of: "Release Notes").map { $0 + 1 }
                  && item?.keyEquivalent == "" && item?.isEnabled == true,
                  "parityfeedback: Help › Send Feedback… after Release Notes, no key, enabled (\(titles))")
            let bar = c.commandActions().map(\.title)
            check(bar.contains("Send Feedback") && !c.menuCommandActions(excluding: []).map(\.title).contains("Send Feedback…"),
                  "parityfeedback: the Command Bar offers Send Feedback once")
        }


        // ⌘T → the sheet, empty, both boxes off.
        openFromCommandBar("first")
        run { [self] in
            guard let s = sheet() else { return check(false, "parityfeedback [real keys] ⌘T “send feedback” Return opens the sheet") }
            check(s.parent === c.window && s.offersScreenshot && s.attachments.isEmpty && !s.includeAppInfo && s.report.images == nil
                  && s.report.app == nil && !s.canSend,
                  "parityfeedback [real keys]: ⌘T “send feedback” opens the sheet on this window; no pictures, app info off, Send off until there's a message")
            windowPixels = CGSize(width: c.root.bounds.width * c.window.backingScaleFactor, height: c.root.bounds.height * c.window.backingScaleFactor)
        }
        // Under the open sheet, a page on the card: red above, blue below, so the picture's page part and its orientation can be read back.
        run { [self] in
            let html = "<html><body style='margin:0'><div style='height:50vh;background:rgb(230,40,40)'></div><div style='height:50vh;background:rgb(40,80,230)'></div></body></html>"
            c.navigate(to: URL(string: "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!, newTab: true)
        }
        wait(2.5)
        run { [self] in check(sheet() != nil, "parityfeedback: the sheet stays while the page underneath loads") }
        type(message, "the message")
        wait(0.4)
        click("feedback.email", "the reply field")
        step { [self] done in
            // "@" isn't a plain or ⇧ key on every layout (⌥L on German ones): the rest is typed, "@" pasted if need be.
            if UIDriverClient.keys(typing: email) == nil {
                note("parityfeedback: “@” has no plain/⇧ key in \(UIDriverClient.layoutName); the address is set directly")
                sheet()?.email = email
                return done()
            }
            UIDriverClient.press(UIDriverClient.keys(typing: email) ?? [], pid: getpid()) { ok, out in
                if !ok { self.note("FAIL-ENV parityfeedback [real keys] the address: \(out)") }
                done()
            }
        }
        wait(0.3)
        shot("feedback-empty-options")
        run { [self] in
            let r = sheet()?.report
            check(r?.message == message && r?.email == email && r?.images == nil && r?.app == nil && sheet()?.canSend == true,
                  "parityfeedback [real keys]: the message and address as typed (\(r?.message ?? "-"), \(r?.email ?? "-")); nothing else until ticked")
        }

        // Pictures. "Add Screenshot…" › Screenshot of This Window: a real click on the menu button, ↓ and Return.
        func addWindowPicture(_ what: String) {
            let before = { sheet()?.attachments.count ?? 0 }
            var n = 0
            run { n = before() }
            click("feedback.addScreenshot", "Add Screenshot… (\(what))")
            wait(0.5)
            key("down", "↓ to Screenshot of This Window (\(what))")
            wait(0.2)
            key("return", "Return on Screenshot of This Window (\(what))")
            step { [self] done in waitUntil({ before() > n && sheet()?.preparing == 0 }, timeout: 8) { done() } }
            run { [self] in
                if before() == n {
                    note("FAIL-ENV parityfeedback [real click] \(what): the Add Screenshot… menu didn't take ↓ Return here; added directly")
                    sheet()?.addWindowPicture()
                }
            }
            step { [self] done in waitUntil({ before() > n && sheet()?.preparing == 0 }, timeout: 8) { done() } }
        }
        addWindowPicture("first")
        run { [self] in
            let s = sheet()
            let a = s?.attachments.first
            let px = CGSize(width: a?.picture.width ?? 0, height: a?.picture.height ?? 0)
            let screen = (NSScreen.main?.frame.size).map { CGSize(width: $0.width * (NSScreen.main?.backingScaleFactor ?? 1), height: $0.height * (NSScreen.main?.backingScaleFactor ?? 1)) } ?? .zero
            // The JPEG is this window at most 1920 across: the window's shape, not the screen's.
            let ratio = windowPixels.height > 0 ? windowPixels.width / windowPixels.height : 0
            let got = px.height > 0 ? px.width / px.height : -1
            check(a?.source == .window && px.width > 0 && abs(ratio - got) < 0.02 && px.width <= 1920
                  && TestAnchors.view("feedback.thumb.0", in: host() ?? c.root) != nil
                  && (a?.picture.data.count ?? Int.max) <= FeedbackReport.maximumImage,
                  "parityfeedback [real click]: Add Screenshot… › This Window takes Airc's picture of this window (\(Int(px.width))×\(Int(px.height)), window \(Int(windowPixels.width))×\(Int(windowPixels.height)), screen \(Int(screen.width))×\(Int(screen.height))), shown as a thumbnail")
        }
        shot("feedback-screenshot-preview")
        run { [self] in
            // The picture exactly as it would be sent.
            try? sheet()?.attachments.first?.picture.data.write(to: dir.appendingPathComponent("feedback-window-picture.jpg"))
            note("wrote feedback-window-picture.jpg")
            // The page is in it, upright: red in the card's upper part, blue in its lower part.
            guard let jpeg = sheet()?.attachments.first?.picture.data, let rep = NSBitmapImageRep(data: jpeg), c.root.bounds.width > 0 else {
                return check(false, "parityfeedback: the picture can be read back")
            }
            let k = CGFloat(rep.pixelsWide) / c.root.bounds.width
            let card = c.card.frame   // root coordinates, flipped (top-down)
            func color(_ fx: CGFloat, _ fy: CGFloat) -> (r: CGFloat, b: CGFloat) {
                let x = Int((card.minX + card.width * fx) * k), y = Int((card.minY + card.height * fy) * k)   // rep: top-left origin
                let cl = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                return (cl?.redComponent ?? 0, cl?.blueComponent ?? 0)
            }
            let top = color(0.5, 0.2), bottom = color(0.5, 0.8)
            check(top.r > 0.6 && top.b < 0.45 && bottom.b > 0.6 && bottom.r < 0.45,
                  String(format: "parityfeedback: the picture has the page, upright (top r %.2f b %.2f, bottom r %.2f b %.2f)", top.r, top.b, bottom.r, bottom.b))
        }
        click("feedback.remove.0", "the thumbnail's remove button")
        run { [self] in
            check(sheet()?.attachments.isEmpty == true && sheet()?.report.images == nil && TestAnchors.view("feedback.thumb.0", in: host() ?? c.root) == nil,
                  "parityfeedback [real click]: the thumbnail's × takes the picture away (not sent)")
        }
        addWindowPicture("again")

        // ⌘V: a JPEG with a location and a camera in it, as a phone's photo copied from Photos.
        run { [self] in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(Self.feedbackTestPicture(.jpeg, color: (0.1, 0.7, 0.2), gps: true), forType: .init(UTType.jpeg.identifier))
            check(FeedbackSheet.hasPictures(pb), "parityfeedback: a copied photo counts as a picture to paste")
        }
        activate()
        step { [self] done in
            // The sheet's own window has the keys (the message field).
            sheet()?.sheet.makeKeyAndOrderFront(nil)
            done()
        }
        key("cmd+v", "⌘V with a photo on the pasteboard")
        step { [self] done in waitUntil({ (sheet()?.attachments.count ?? 0) >= 2 && sheet()?.preparing == 0 }, timeout: 6) { done() } }
        run { [self] in
            let a = sheet()?.attachments.dropFirst().first
            let props = a.flatMap { CGImageSourceCreateWithData($0.picture.data as CFData, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            check(a?.source == .pasted && a?.picture.type == "image/jpeg" && props?[kCGImagePropertyGPSDictionary] == nil
                  && props?[kCGImagePropertyTIFFDictionary] == nil && sheet()?.message == message,
                  "parityfeedback [real keys]: ⌘V adds the copied photo as a picture, without its location or camera (\(a?.picture.width ?? 0)×\(a?.picture.height ?? 0)); the message is unchanged")
        }

        // A HEIC file dropped on the message from a drag source window (a real driver drag): it joins as a JPEG.
        var dragSource: NSWindow?
        step { [self] done in
            let file = dir.appendingPathComponent("dropped-photo.heic")
            try? Self.feedbackTestPicture(.heic, color: (0.95, 0.75, 0.1), gps: true).write(to: file)
            guard let h = host(), let target = anchorPoint("feedback.message", in: h), let sw = h.window, let primary = NSScreen.screens.first else {
                check(false, "parityfeedback: the message field is on screen for a drop")
                return done()
            }
            // Over the browser window's sidebar, beside the sheet (normal level, our own window).
            let wf = c.window.frame
            let w = NSWindow(contentRect: NSRect(x: wf.minX + 24, y: wf.midY - 60, width: 120, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Drag source"
            w.isReleasedWhenClosed = false
            let v = FeedbackDragSource(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
            v.url = file
            w.contentView = v
            w.orderFront(nil)
            dragSource = w
            let from = w.convertPoint(toScreen: NSPoint(x: 60, y: 60))
            let to = sw.convertPoint(toScreen: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                UIDriverClient.run(["--drag", String(Double(from.x.rounded())), String(Double((primary.frame.maxY - from.y).rounded())),
                                    String(Double(to.x.rounded())), String(Double((primary.frame.maxY - to.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real drag] the HEIC file: \(out)") }
                    self.waitUntil({ (sheet()?.attachments.count ?? 0) >= 3 && sheet()?.preparing == 0 }, timeout: 6) { done() }
                }
            }
        }
        run { [self] in
            dragSource?.orderOut(nil)
            dragSource = nil
            let a = sheet()?.attachments.dropFirst(2).first
            let props = a.flatMap { CGImageSourceCreateWithData($0.picture.data as CFData, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            check(a?.source == .dropped && a?.picture.type == "image/jpeg" && a?.picture.data.prefix(3) == Data([0xff, 0xd8, 0xff])
                  && props?[kCGImagePropertyGPSDictionary] == nil && sheet()?.message == message,
                  "parityfeedback [real drag]: a dropped HEIC file joins as a JPEG without its location; the message keeps no file path (\(sheet()?.attachments.count ?? 0) pictures)")
        }
        activate()
        step { [self] done in sheet()?.sheet.makeKeyAndOrderFront(nil); done() }
        click("feedback.appInfo", "Include app info")
        shot("feedback-thumbnails")
        run { [self] in
            let a = sheet()?.report.app
            let info = Bundle.main.infoDictionary ?? [:]
            check(a?.version == info["CFBundleShortVersionString"] as? String && a?.engine == (app?.options.engine == "chromium" ? "chromium" : "webkit")
                  && a?.macOS != nil && a?.model != nil && a?.locale != nil,
                  "parityfeedback [real click]: app info lists version \(a?.version ?? "-") (\(a?.build ?? "-")), \(a?.engine ?? "-"), macOS \(a?.macOS ?? "-"), \(a?.model ?? "-"), \(a?.locale ?? "-")")
            let rows = sheet()?.report.app?.rows.map(\.label) ?? []
            check(rows.contains("Airc") && rows.contains("Engine") && rows.contains("macOS") && rows.contains("Mac") && sheet()?.report.images?.count == 3,
                  "parityfeedback: “What will be sent” lists the message, reply address, the 3 pictures and each app detail (\(rows))")
        }
        // Five at most: two more of the window, then a sixth is refused.
        addWindowPicture("fourth")
        addWindowPicture("fifth")
        run { [self] in
            let s = sheet()
            s?.addWindowPicture()
            check(s?.attachments.count == 5 && s?.canAddPictures == false && s?.problem?.contains("At most 5") == true,
                  "parityfeedback: five pictures at most; a sixth is refused with a reason (\(s?.problem ?? "-"))")
        }
        click("feedback.remove.4", "remove the fifth")
        click("feedback.remove.3", "remove the fourth")
        run { [self] in check(sheet()?.attachments.count == 3, "parityfeedback [real click]: back to 3 pictures") }

        // Send (a real click), the confirmation, and exactly that on the service.
        click("feedback.send", "Send")
        step { [self] done in waitUntil({ sheet()?.phase == .sent }, timeout: 10) { done() } }
        shot("feedback-sent")
        step { [self] done in
            check(sheet()?.phase == .sent && TestAnchors.view("feedback.doneTitle", in: host() ?? c.root) != nil,
                  "parityfeedback [real click]: Send shows “Thanks, it’s sent” (\(sheet()?.problem ?? "no problem"))")
            adminPage { page in
                let m = page.range(of: #"id="f-([A-Za-z0-9]{12})""#, options: .regularExpression).map { String(page[$0].dropFirst(6).dropLast()) } ?? ""
                firstID = m
                self.check(!m.isEmpty && page.contains(message) && page.contains("mailto:\(email)") && page.contains("shot=\(m)\"")
                           && page.contains("shot=\(m)&amp;n=1") && page.contains("shot=\(m)&amp;n=2") && !page.contains("shot=\(m)&amp;n=3")
                           && page.contains("Airc \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"),
                           "parityfeedback: the service has the message, the address, the 3 pictures and the app details (entry \(m))")
                // Each stored picture, as the owner's page serves it, against the one shown and sent: the same pixels, no metadata.
                let sent = sheet()?.attachments.map(\.picture) ?? []
                let group = DispatchGroup()
                var results: [String] = Array(repeating: "missing", count: sent.count)
                for (n, p) in sent.enumerated() {
                    group.enter()
                    var pic = URLRequest(url: URL(string: base.appendingPathComponent("admin/feedback").absoluteString + "?shot=\(m)" + (n > 0 ? "&n=\(n)" : ""))!)
                    pic.setValue("Basic " + Data("owner:\(admin)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                    URLSession.shared.dataTask(with: pic) { d, r, _ in
                        let src = d.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
                        let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
                        let same = (r as? HTTPURLResponse)?.statusCode == 200 && w == p.width && h == p.height
                            && (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == p.type
                            && props[kCGImagePropertyGPSDictionary] == nil && d?.range(of: Data("Exif".utf8)) == nil
                        try? d?.write(to: self.dir.appendingPathComponent("feedback-stored-picture-\(n).\(p.type == "image/png" ? "png" : "jpg")"))
                        DispatchQueue.main.async { results[n] = same ? "ok" : "\(w ?? 0)×\(h ?? 0) \(d?.count ?? 0) bytes"; group.leave() }
                    }.resume()
                }
                group.notify(queue: .main) {
                    self.check(!sent.isEmpty && results.allSatisfy { $0 == "ok" },
                               "parityfeedback: each stored picture has the size and type sent, and no Exif or location (\(results))")
                    done()
                }
            }
        }
        click("feedback.done", "Done")
        run { [self] in check(sheet() == nil, "parityfeedback [real click]: Done closes it") }

        // Offline: a closed port. Send keeps it and says so; the network back sends it.
        // ⌘T again with a page shown (the runner's window capture hides the Command Bar, so none is taken mid-bar).
        openFromCommandBar("with-page")
        run { [self] in
            check(sheet() != nil && sheet()?.parent === c.window, "parityfeedback [real keys]: ⌘T “send feedback” Return opens the sheet with a page shown too")
        }
        clickIfOpen("feedback.cancel", "Cancel (with page)")
        run { [self] in c.closeCurrentTab() }
        wait(0.8)
        run { center.serviceOverride = SharingService(base: URL(string: "http://127.0.0.1:9")!) }
        openFromCommandBar("offline")
        type("Sent while offline", "the offline message")
        click("feedback.send", "Send (offline)")
        step { [self] done in waitUntil({ sheet()?.phase == .queued }, timeout: 10) { done() } }
        shot("feedback-queued")
        run { [self] in
            check(sheet()?.phase == .queued && center.waitingCount == 1,
                  "parityfeedback [real click]: offline, Send says “Saved to send later” and keeps it in the outbox (\(center.waitingCount))")
        }
        click("feedback.done", "Done (offline)")
        step { [self] done in
            center.serviceOverride = nil
            // What NetworkWatch posts when the path comes back (it can't be made to report it in a check).
            NotificationCenter.default.post(name: NetworkWatch.restored, object: nil)
            waitUntil({ center.waitingCount == 0 }, timeout: 10) {
                adminPage { page in
                    self.check(center.waitingCount == 0 && page.contains("Sent while offline") && page.contains("f-\(firstID)"),
                               "parityfeedback: back online, the saved message is sent (outbox \(center.waitingCount))")
                    done()
                }
            }
        }

        // A private window: no screenshot.
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { p in
                guard let p else { self.check(false, "parityfeedback: a private window opens"); return done() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    p.window.makeKeyAndOrderFront(nil)
                    let help = NSApp.helpMenu
                    if let i = help?.items.firstIndex(where: { $0.title == "Send Feedback…" }) { help?.performActionForItem(at: i) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let s = sheet()
                        self.check(s?.parent === p.window && s?.isPrivate == true && s?.offersScreenshot == false
                                   && TestAnchors.view("feedback.screenshot", in: s?.sheet.contentView ?? self.c.root) == nil
                                   && TestAnchors.view("feedback.privateNote", in: s?.sheet.contentView ?? self.c.root) != nil,
                                   "parityfeedback [menu item]: in a private window the sheet offers no screenshot and says so")
                        done()
                    }
                }
            }
        }
        shot("feedback-private")
        run { sheet()?.close() }

        // feedback2 ⌘T: "feedback", "feed", "bug", "report" typed (real keys, no Tab): Send Feedback is the first row,
        // selected, so Return opens it.
        for word in ["feedback", "feed", "bug", "report"] {
            activate()
            parkPointer()
            key("cmd+t", "⌘T (\(word))")
            wait(0.6)
            type(word, "“\(word)” in the Command Bar")
            wait(0.8)
            run { [self] in
                let rows = c.commandBar?.results.map(\.title) ?? []
                check(rows.first == "Send Feedback" && c.commandBar?.selected == 0,
                      "parityfeedback [real keys]: ⌘T “\(word)”: Send Feedback is the top row, selected (\(rows.prefix(4)))")
            }
            if word == "feedback" {
                key("return", "Return on Send Feedback")
                step { [self] done in waitUntil({ sheet() != nil }, timeout: 4) { done() } }
                run { [self] in check(sheet()?.parent === c.window, "parityfeedback [real keys]: ⌘T “feedback” Return opens the sheet") }
                clickIfOpen("feedback.cancel", "Cancel (⌘T feedback)")
            } else {
                // Esc clears a completion first, then closes the bar.
                key("esc", "Esc (\(word))")
                wait(0.3)
                step { [self] done in
                    guard c.commandBar != nil else { return done() }
                    UIDriverClient.run(["--key", "esc", "--pid", "\(getpid())"]) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done) }
                }
            }
        }

        // Command Bar: a resting pointer never picks a row (eventsmode's finding). The real pointer is parked where the bar's
        // third row will be; ⌘T, typing and Return open the top match. Then a real move picks the row under it.
        var restAt: NSPoint?
        func closeBar(_ what: String) {
            key("esc", "Esc (\(what))")
            wait(0.3)
            step { [self] done in
                guard c.commandBar != nil else { return done() }
                UIDriverClient.run(["--key", "esc", "--pid", "\(getpid())"]) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done) }
            }
        }
        activate()
        parkPointer()
        key("cmd+t", "⌘T (find the rows)")
        wait(0.6)
        type("feedback", "“feedback” (find the rows)")
        wait(0.8)
        run { [self] in
            let rows = c.commandBar?.rowViewsForTesting ?? []
            guard rows.count >= 3 else { return check(false, "command bar resting pointer: at least 3 rows for “feedback” (\(rows.count))") }
            let r = rows[2]
            restAt = r.convert(NSPoint(x: r.bounds.midX, y: r.bounds.midY), to: nil)
        }
        closeBar("find the rows")
        step { [self] done in
            guard let p = restAt else { return done() }
            UIDriverClient.move(p, in: c.window) { ok, out in
                if !ok { self.note("FAIL-ENV command bar [real move] park over row 3: \(out)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        }
        key("cmd+t", "⌘T over a resting pointer")
        wait(0.6)
        type("feedback", "“feedback” over a resting pointer")
        wait(0.8)
        run { [self] in
            let bar = c.commandBar
            let rows = bar?.rowViewsForTesting ?? []
            let under = rows.firstIndex { $0.isHovered }
            check(bar?.selected == 0 && bar?.results.first?.title == "Send Feedback" && under != nil && under != 0,
                  "Command Bar [real keys, resting pointer]: the top match stays selected (selected \(bar?.selected ?? -1), pointer on row \(under ?? -1))")
        }
        key("return", "Return over a resting pointer")
        step { [self] done in waitUntil({ sheet() != nil }, timeout: 4) { done() } }
        run { [self] in check(sheet() != nil, "Command Bar [real keys, resting pointer]: Return opens the top match (Send Feedback), not the row under the pointer") }
        clickIfOpen("feedback.cancel", "Cancel (resting pointer)")
        // The same pointer, moved a little within that row: now it picks it.
        step { [self] done in
            guard let p = restAt else { return done() }
            UIDriverClient.move(p, in: c.window) { _, _ in done() }
        }
        key("cmd+t", "⌘T (then move)")
        wait(0.6)
        type("feedback", "“feedback” (then move)")
        wait(0.8)
        run { [self] in check(c.commandBar?.selected == 0, "Command Bar [real keys]: still the top match before the pointer moves (\(c.commandBar?.selected ?? -1))") }
        step { [self] done in
            guard let p = restAt else { return done() }
            UIDriverClient.move(NSPoint(x: p.x + 12, y: p.y + 1), in: c.window, steps: 6, duration: 120) { ok, out in
                if !ok { self.note("FAIL-ENV command bar [real move] within row 3: \(out)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        }
        run { [self] in
            let bar = c.commandBar
            let under = bar?.rowViewsForTesting.firstIndex { $0.isHovered }
            check(under != nil && bar?.selected == under,
                  "Command Bar [real move]: moving the pointer picks the row under it (selected \(bar?.selected ?? -1), pointer on row \(under ?? -1))")
        }
        // Typing again puts the top match first, with the pointer resting on that row.
        type("x", "one more key")
        wait(0.6)
        run { [self] in check(c.commandBar?.selected == 0, "Command Bar [real keys]: typing puts the top match first again (\(c.commandBar?.selected ?? -1))") }
        closeBar("resting pointer case")
        parkPointer()

        // feedback2: the sidebar footer's Feedback button.
        let footer = { self.c.sidebar.footer }
        func realClick(_ v: NSView?, mods: String? = nil, _ what: String) {
            step { [self] done in
                guard let v, let w = v.window, let primary = NSScreen.screens.first, !v.isHidden else {
                    check(false, "parityfeedback [real click] \(what): on screen")
                    return done()
                }
                let g = w.convertPoint(toScreen: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil))
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]
                                   + (mods.map { ["--mods", $0] } ?? [])) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real click] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
        }
        func renderFooter(_ name: String) {
            run { [self] in
                let v = c.sidebar
                v.layoutSubtreeIfNeeded()
                let f = footer().frame
                if let image = render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    // The footer's band (a little above it too): the sidebar's own picture, cropped.
                    let k = CGFloat(rep.pixelsWide) / max(1, v.bounds.width)
                    let band = CGRect(x: 0, y: (f.minY - 30) * k, width: v.bounds.width * k, height: (f.height + 30) * k)
                    if let cg = rep.cgImage?.cropping(to: band.integral) {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                        note("wrote \(name).png")
                    }
                }
            }
        }
        var widthBefore: CGFloat = 0
        var addedSpaces: [String] = []
        activate()
        run { [self] in
            widthBefore = c.sidebarWidth
            c.setSidebarWidth(260)
            c.sidebar.layoutSubtreeIfNeeded()
            let b = footer().feedbackButton
            check(footer().showsFeedback && b.toolTip == "Send Feedback" && b.accessibilityLabel() == "Send Feedback"
                  && b.frame.minX > footer().libraryButton.frame.maxX - 0.5 && b.frame.maxX <= (footer().cellViews.first?.frame.minX ?? .infinity) + 0.5,
                  "parityfeedback: the footer has the Feedback button after Library, before the Space icons (\(b.frame), tooltip \(b.toolTip ?? "-"))")
        }
        renderFooter("feedback-footer-button")
        realClick(footer().feedbackButton, "the footer's Feedback button")
        step { [self] done in waitUntil({ sheet() != nil }, timeout: 4) { done() } }
        run { [self] in check(sheet()?.parent === c.window && sheet()?.sheet.isVisible == true, "parityfeedback [real click]: the footer's Feedback button opens the sheet on this window") }
        clickIfOpen("feedback.cancel", "Cancel (footer)")
        // Narrow: at the 164 pt minimum with three Spaces the Space icons keep their room and the button gives way.
        run { [self] in
            let home = c.currentSpaceID
            let profile = c.store.profile(ofSpace: home).id
            for (name, icon) in [("Work", "💼"), ("Home", "🏠")] {
                if let sp = try? c.store.createSpace(name: name, icon: .emoji(icon), profileID: profile, after: home) { addedSpaces.append(sp.id) }
            }
            c.reloadAll(animated: false)
            c.setSidebarWidth(AircMetrics.Sidebar.minWidth)
            c.sidebar.layoutSubtreeIfNeeded()
            let cells = footer().cellViews.map(\.frame.width)
            check(!footer().showsFeedback && cells.count == 3 && cells.allSatisfy { $0 >= 22 },
                  "parityfeedback: at the \(Int(AircMetrics.Sidebar.minWidth)) pt minimum with 3 Spaces the button gives way; the icons keep \(cells.map { Int($0) }) pt")
        }
        renderFooter("feedback-footer-min-3spaces")
        run { [self] in
            c.setSidebarWidth(228)
            c.sidebar.layoutSubtreeIfNeeded()
            let cells = footer().cellViews.map(\.frame.width)
            let b = footer().feedbackButton.frame
            check(footer().showsFeedback && cells.allSatisfy { $0 >= 24 } && b.maxX <= (footer().cellViews.first?.frame.minX ?? 0) + 0.5,
                  "parityfeedback: at 228 pt with 3 Spaces it shows, the icons keep \(cells.map { Int($0) }) pt and don't overlap it")
        }
        renderFooter("feedback-footer-228-3spaces")
        run { [self] in
            for id in addedSpaces { try? c.store.deleteSpace(id) }
            c.reloadAll(animated: false)
            c.setSidebarWidth(AircMetrics.Sidebar.minWidth)
            c.sidebar.layoutSubtreeIfNeeded()
            check(footer().showsFeedback && footer().cellViews.isEmpty, "parityfeedback: with one Space it shows at the minimum width too")
        }
        renderFooter("feedback-footer-min-1space")
        run { [self] in c.setSidebarWidth(260) }
        // ⌃-click › Hide Feedback Button (real ⌃-click, ↓ ↓ Return in its menu).
        realClick(footer().feedbackButton, mods: "ctrl", "⌃-click on the Feedback button")
        wait(0.4)
        key("down", "↓ (Send Feedback…)")
        key("down", "↓ (Hide Feedback Button)")
        key("return", "Return on Hide Feedback Button")
        wait(0.4)
        run { [self] in
            check(!footer().showsFeedback && app?.settings.values.sidebarFeedbackButton == false && c.toast.shownText?.contains("Settings") == true,
                  "parityfeedback [real click+keys]: ⌃-click › Hide Feedback Button hides it and says where it comes back (\(c.toast.shownText ?? "no toast"))")
            // Settings › Appearance › Sidebar › Show Feedback button: the same value.
            app?.settings.values.sidebarFeedbackButton = true
        }
        wait(0.3)
        run { [self] in check(footer().showsFeedback, "parityfeedback: Settings' Show Feedback button brings it back") }
        // Little Airc: a window with no sidebar, so no footer and no button.
        step { [self] done in
            guard let l = app?.openLittleArc(url: nil) else { check(false, "parityfeedback: Little Airc opens"); return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                let views = l.window.contentView.map(all) ?? []
                self.check(!views.isEmpty && !views.contains { $0 is SpaceBarView },
                           "parityfeedback: Little Airc has no footer, so no Feedback button (\(views.count) views)")
                l.window.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done)
            }
        }
        run { [self] in c.setSidebarWidth(widthBefore) }

        // feedback2: the copy button on tab rows (real hover and click).
        var server: LocalPageServer?
        var pageBase = ""
        var tabA = "", tabB = ""
        step { [self] done in
            server = LocalPageServer(responses: ["/a.html": .init(body: "<title>Article A</title><h1>A</h1>"),
                                                 "/b.html": .init(body: "<title>Article B</title><h1>B</h1>")])
            server?.start { port in
                pageBase = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !pageBase.isEmpty else { return check(false, "parityfeedback: a loopback server for the copy button") }
            let home = c.currentSpaceID
            tabA = (try? c.store.openTab(url: pageBase + "/a.html?utm_source=newsletter&utm_medium=email&id=7&fbclid=XYZ", inSpace: home, title: "Article A"))?.id ?? ""
            tabB = (try? c.store.openTab(url: pageBase + "/b.html", inSpace: home, title: "Article B"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabB, focus: false)
        }
        wait(1.5)
        func row(_ id: String) -> TabRowView? {
            guard let p = c.pageView(for: c.currentSpaceID) else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.tabID == id } ?? p.subviews.flatMap { $0.subviews }.compactMap { $0 as? TabRowView }.first { $0.tabID == id }
        }
        func copyCase(_ tag: String) {
            var changeCount = 0
            var toastSeen: String?
            activate()
            // Off the rows first (the card's middle), then onto row A's title (a real pointer move), then the copy button.
            step { [self] done in
                UIDriverClient.move(c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil), in: c.window) { _, _ in done() }
            }
            step { [self] done in
                guard let r = row(tabA) else { check(false, "parityfeedback (\(tag)): row A is in the sidebar"); return done() }
                UIDriverClient.hover(r.convert(NSPoint(x: 60, y: r.bounds.midY), to: nil), in: c.window, dwell: 300) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real hover] \(tag): \(out)") }
                    done()
                }
            }
            run { [self] in
                let r = row(tabA)
                let copy = r?.copyButton
                let title = r?.titleField.frame ?? .zero
                check(r?.isHovered == true && copy?.isHidden == false && copy?.toolTip == "Copy Link" && copy?.accessibilityLabel() == "Copy Link"
                      && copy?.accessibilityRole() == .button && title.maxX <= (copy?.frame.minX ?? 0) + 0.5,
                      "parityfeedback [real hover] (\(tag)): the hovered row shows the copy button left of ×, and its title ends before both (title to \(Int(title.maxX)), copy at \(Int(copy?.frame.minX ?? -1)))")
                let actions = r?.accessibilityCustomActions()?.map(\.name) ?? []
                check(actions.contains("Copy Link"), "parityfeedback (\(tag)): VoiceOver's actions on the row have Copy Link (\(actions))")
                changeCount = NSPasteboard.general.changeCount
            }
            run { [self] in
                if let v = c.sidebar as NSView?, let image = render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let r = row(tabA) {
                    let k = CGFloat(rep.pixelsWide) / max(1, v.bounds.width)
                    let f = r.convert(r.bounds, to: v)
                    let y = v.isFlipped ? f.minY : v.bounds.height - f.maxY
                    if let cg = rep.cgImage?.cropping(to: CGRect(x: 0, y: (y - 8) * k, width: v.bounds.width * k, height: (f.height + 16) * k).integral) {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("copy-link-row-\(tag).png"))
                        note("wrote copy-link-row-\(tag).png")
                    }
                }
            }
            step { [self] done in
                guard let b = row(tabA)?.copyButton, !b.isHidden, let primary = NSScreen.screens.first else {
                    check(false, "parityfeedback [real click] (\(tag)): the copy button is on screen")
                    return done()
                }
                let g = c.window.convertPoint(toScreen: b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil))
                c.toast.isHidden = true
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV parityfeedback [real click] (\(tag)) copy: \(out)") }
                    self.waitUntil({ self.c.toast.shownText?.hasPrefix("Copied") == true }, timeout: 1.5) {
                        toastSeen = self.c.toast.shownText
                        done()
                    }
                }
            }
            run { [self] in
                let url = c.store.tab(tabA)?.url ?? ""
                let want = LinkCopyPolicy.cleaned(url).url
                let got = NSPasteboard.general.string(forType: .string) ?? ""
                check(NSPasteboard.general.changeCount != changeCount && got == want && !got.contains("utm_") && !got.contains("fbclid") && got.contains("id=7"),
                      "parityfeedback [real click] (\(tag)): the copy button puts the clean link on the pasteboard (\(got)), as ⇧⌘C would")
                check(toastSeen?.hasPrefix("Copied") == true, "parityfeedback (\(tag)): the “Copied” toast shows (\(toastSeen ?? "none"))")
                check(c.shownTabID == tabB && row(tabA)?.isSelected == false && (c.pageView(for: c.currentSpaceID)?.selection.isEmpty ?? true),
                      "parityfeedback [real click] (\(tag)): the row isn't selected or shown (shown \(c.shownTabID == tabB ? "B" : c.shownTabID ?? "-"))")
            }
        }
        copyCase("today")
        run { [self] in
            try? c.store.togglePin(tabA, inSpace: c.currentSpaceID)
            c.reloadAll(animated: false)
            c.show(tabB, focus: false)
            NSPasteboard.general.clearContents()
        }
        wait(0.8)
        copyCase("pinned")
        // VoiceOver's Copy Link (the row's action) does the same.
        run { [self] in
            NSPasteboard.general.clearContents()
            let action = row(tabA)?.accessibilityCustomActions()?.first { $0.name == "Copy Link" }
            _ = action?.handler?()
            let got = NSPasteboard.general.string(forType: .string) ?? ""
            check(got == LinkCopyPolicy.cleaned(c.store.tab(tabA)?.url ?? "").url && c.shownTabID == tabB,
                  "parityfeedback [VoiceOver action]: the row's Copy Link copies the clean link (\(got))")
        }
        run { [self] in
            for id in [tabA, tabB] where !id.isEmpty { c.closeTab(id) }
            server?.stop()
        }
        parkPointer()
        wait(0.5)

        // Last, so it can't disturb the rest:
        // The real menu, by keyboard: ⌘? (Help's search), "send feedback", ↓, Return. The search field is macOS's; when it
        // doesn't take the keys here that's FAIL-ENV, and ⌘T below still opens the sheet with real keys.
        activate()
        key("cmd+?", "⌘? (Help's search)")
        wait(1.0)
        type("send feedback", "Help's search")
        wait(1.2)
        key("down", "↓ to the menu item")
        wait(0.4)
        key("return", "Return on Send Feedback…")
        step { [self] done in waitUntil({ sheet() != nil && sheet()?.sheet.isVisible == true }, timeout: 3) { done() } }
        run { [self] in
            if let s = sheet() {
                check(s.parent === c.window, "parityfeedback [real keys]: Help › Send Feedback… found with Help's search (⌘?) opens the sheet on this window")
            } else {
                note("FAIL-ENV parityfeedback [real keys]: Help's search (⌘?) didn't open Send Feedback… on \(UIDriverClient.layoutName); ⌘T opened it above")
            }
        }
        step { [self] done in
            guard sheet() != nil else {
                // Close whatever menu is open.
                return UIDriverClient.run(["--key", "esc", "--repeat", "2", "--pid", "\(getpid())"]) { _, _ in done() }
            }
            done()
        }
        clickIfOpen("feedback.cancel", "Cancel")
        run { [self] in check(sheet() == nil, "parityfeedback: nothing is left open at the end") }

    }

    /// A small picture of `type` in one colour, optionally with a phone's location and camera details in it.
    static func feedbackTestPicture(_ type: UTType, color: (CGFloat, CGFloat, CGFloat), gps: Bool) -> Data {
        let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 40, y: 300, width: 200, height: 120))
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil), let image = ctx.makeImage() else { return Data() }
        let meta: [CFString: Any] = gps ? [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.2082, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 16.3738, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Phone", kCGImagePropertyTIFFModel: "Model 9"],
        ] : [:]
        CGImageDestinationAddImage(dest, image, meta as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : Data()
    }
}

/// A file to drag from (parityfeedback's drop case): a real driver drag that starts here carries `url`.
final class FeedbackDragSource: NSView, NSDraggingSource {
    var url: URL?
    private var started = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setFill()
        bounds.fill()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDown(with event: NSEvent) { started = false }
    override func mouseDragged(with event: NSEvent) {
        guard !started, let url else { return }
        started = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 30, dy: 30), contents: NSImage(systemSymbolName: "photo", accessibilityDescription: nil))
        beginDraggingSession(with: [item], event: event, source: self)
    }
}
#endif
