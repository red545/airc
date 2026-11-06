// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

#if canImport(AircCore)
/// `--script prompts` (Chromium, SB-3): the engine's prompts drawn by the app, from pages on a loopback server, with
/// fake camera and microphone (`--use-fake-device-for-media-stream`; macOS's own camera prompt never shows) and only
/// synthetic form values. Every answer is a real click on the card's button, through the window.
///   - camera + microphone: the card hangs under the URL field, follows it when the window resizes, hides on another
///     tab and comes back with its tab; "Allow while visiting the site" gives the page its stream;
///   - location: "Never allow" denies it; notifications: the × dismisses it;
///   - a password: Save, then the form fills on the next visit, and not in another profile; Update; and Never, after
///     which the same site doesn't ask again;
///   - an address (Save) and a card (No thanks).
extension SnapshotRunner {
    func promptsScenario() {
        guard let engine = app?.engine as? ChromiumEngine else { return note("prompts: Chromium only") }
        var base = "", otherBase = ""
        var server: LocalPageServer?
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        let login = """
            <title>login</title><form action="/submitted" method="post">
            <label>User <input id="username" name="username" autocomplete="username"></label>
            <label>Password <input id="password" name="password" type="password" autocomplete="current-password"></label>
            <button id="submit">Sign in</button></form>
            """
        func form(_ title: String, _ fields: [(String, String)]) -> String {
            "<title>\(title)</title><form action=\"/submitted\" method=\"post\">"
                + fields.map { "<label>\($0.1) <input id=\"\($0.0)\" name=\"\($0.0)\" autocomplete=\"\($0.0)\"></label>" }.joined()
                + "<button id=\"submit\">Submit</button></form>"
        }
        let address = [("given-name", "First name"), ("family-name", "Last name"), ("street-address", "Address"),
                       ("address-level2", "City"), ("address-level1", "State"), ("postal-code", "ZIP"), ("country", "Country")]
        let card = [("cc-name", "Name"), ("cc-number", "Card number"), ("cc-exp-month", "Month"), ("cc-exp-year", "Year")]

        step { [self] done in
            server = LocalPageServer(responses: [
                "/media": .init(body: "<title>media</title><p>Camera and microphone</p>"),
                "/location": .init(body: "<title>location</title><p>Where am I</p>"),
                "/notify": .init(body: "<title>notify</title><p>Notifications</p>"),
                "/login": .init(body: login),
                "/address": .init(body: form("address", address)),
                "/card": .init(body: form("card", card)),
                "/submitted": .init(body: "<title>submitted</title><p>Thanks</p>"),
            ])
            guard let server else { check(false, "prompts: the loopback server starts"); return done() }
            server.start { port in
                guard let port else { self.check(false, "prompts: the loopback server starts"); return done() }
                // Two origins on one server: localhost and 127.0.0.1 are different sites to the password manager.
                base = "http://localhost:\(port)"
                otherBase = "http://127.0.0.1:\(port)"
                done()
            }
        }

        func open(_ url: @escaping () -> String, title: String, inSpace space: @escaping () -> String? = { nil }) {
            run { [self] in
                let sid = space() ?? c.currentSpaceID
                if sid != c.currentSpaceID { c.switchToSpace(sid, animated: false) }
                guard !base.isEmpty, let t = try? c.store.openTab(url: url(), inSpace: sid, title: title) else { return }
                tabID = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            step { [self] done in
                waitUntil({ page()?.title == title && page()?.isLoading == false }, timeout: 8) {
                    if page()?.title != title { self.check(false, "prompts: \(title) loads (\(page()?.title ?? "-"))") }
                    done()
                }
            }
        }
        /// Runs `js` in the page as a user gesture (the page's own request, as after a click).
        func gesture(_ js: String, then: (() -> Void)? = nil) {
            step { [self] done in
                guard let p = page() else { return done() }
                engine.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true, "returnByValue": true], in: p) { _, error in
                    if let error { self.note("prompts: gesture failed (\(error))") }
                    then?()
                    done()
                }
            }
        }
        /// Types into a field: focus by a gesture, then trusted text input (DevTools Input.insertText).
        func typeInto(_ field: String, _ text: String) {
            // Selected first, so a value the password manager filled in is replaced, not added to.
            gesture("var e=document.getElementById('\(field)');e.focus();e.select()")
            step { [self] done in
                guard let p = page() else { return done() }
                engine.devToolsCall("Input.insertText", params: ["text": text], in: p) { _, _ in done() }
            }
        }
        func waitTitle(_ what: String, _ expected: String, timeout: Double = 6) {
            step { [self] done in
                waitUntil({ page()?.title == expected }, timeout: timeout) {
                    self.check(page()?.title == expected, "prompts: \(what) (page says \"\(page()?.title ?? "-")\")")
                    done()
                }
            }
        }
        /// The card for `name` is on screen, in our window, hanging from the URL field.
        func expectCard(_ name: String, timeout: Double = 8, _ match: @escaping (PagePrompt) -> Bool) {
            step { [self] done in
                waitUntil({ self.c.prompts.shown.map { match($0.prompt) } == true && self.c.prompts.bubble != nil }, timeout: timeout) {
                    guard let b = self.c.prompts.bubble, let shown = self.c.prompts.shown, match(shown.prompt) else {
                        self.check(false, "prompts: \(name): the card shows (shown: \(self.c.prompts.shown?.prompt.label ?? "none"), "
                                   + "waiting \(self.c.prompts.pendingCount))")
                        return done()
                    }
                    b.layoutSubtreeIfNeeded()
                    self.check(b.superview === self.c.root && b.frame.height > 40 && self.c.root.bounds.contains(b.frame),
                               "prompts: \(name): the card shows in our window (\(NSStringFromRect(b.frame)))")
                    self.checkAnchored(name)
                    done()
                }
            }
        }
        func click(_ anchor: String) {
            run { [self] in c.prompts.bubble?.layoutSubtreeIfNeeded() }
            clickIn({ self.c.prompts.bubble?.hostingView }, anchor)
            run { [self] in
                note("prompts: clicked \(anchor) at \(TestAnchors.frames[anchor].map { NSStringFromRect($0) } ?? "-"): \(TestAnchors.lastHit[anchor] ?? "-")")
            }
        }
        func expectAnswered(_ name: String, _ answer: PromptAnswer) {
            step { [self] done in
                waitUntil({ self.app?.promptCenter?.answered.last?.answer == answer }, timeout: 3) {
                    let last = self.app?.promptCenter?.answered.last
                    self.check(last?.answer == answer && self.c.prompts.shown == nil,
                               "prompts: \(name): the click answers it (\(last.map { "\($0.label): \($0.answer)" } ?? "no answer"), "
                               + "card \(self.c.prompts.bubble == nil ? "gone" : "still up"))")
                    done()
                }
            }
        }

        // MARK: Permissions

        // Chromium asks macOS for the camera and microphone once the page's request is allowed, even with fake devices,
        // which puts a system prompt on the owner's screen (2026-11-06). Off unless AIRC_MEDIA_PROMPT_CHECKS=1.
        if ProcessInfo.processInfo.environment["AIRC_MEDIA_PROMPT_CHECKS"] == "1" {
        open({ base + "/media" }, title: "media")
        gesture("navigator.mediaDevices.getUserMedia({video:true,audio:true}).then(function(s){document.title='granted '+"
                + "s.getTracks().map(function(t){return t.kind}).sort().join(',')},function(e){document.title='rejected '+e.name})")
        expectCard("camera and microphone") { if case .permission(let p) = $0 { Set(p.kinds) == ["camera", "microphone"] } else { false } }
        capture("prompt-camera")
        // The card follows the URL field when the window gets narrower and back.
        var frame = NSRect.zero
        run { [self] in
            frame = c.window.frame
            c.window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width - 160, height: frame.height - 80), display: true)
            c.root.layoutSubtreeIfNeeded()
            checkAnchored("camera and microphone, after a resize")
            c.window.setFrame(frame, display: true)
            c.root.layoutSubtreeIfNeeded()
            // With the sidebar hidden it hangs from the page's top-left corner.
            c.sidebarFraction = 0
            c.layoutRoot()
            let b = c.prompts.bubble?.frame ?? .zero
            check(abs(b.minX - (c.card.frame.minX + 10)) <= 1 && abs(b.minY - (c.card.frame.minY + 4 + PromptPresenter.gap)) <= 1,
                  "prompts: camera: with the sidebar hidden it hangs from the page's corner (\(NSStringFromRect(b)), page \(NSStringFromRect(c.card.frame)))")
            c.sidebarFraction = 1
            c.layoutRoot()
        }
        // Another tab hides it; the page that asked brings the same request back.
        var mediaTab = "", requestID = ""
        run { [self] in
            mediaTab = tabID
            if case .permission(let p)? = c.prompts.shown?.prompt { requestID = p.id }
            guard let t = try? c.store.openTab(url: "about:blank", inSpace: c.currentSpaceID, title: "Other") else { return }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            let hidden = c.prompts.bubble == nil
            c.show(mediaTab, focus: false)
            var back = false
            if case .permission(let p)? = c.prompts.shown?.prompt { back = p.id == requestID }
            check(hidden && back, "prompts: camera: hides on another tab (\(hidden)) and comes back with its tab (\(back))")
            c.closeTab(t.id)
            c.show(mediaTab, focus: false)
        }
        click("prompt.allow")
        expectAnswered("camera and microphone", .allow(remember: true))
        waitTitle("Allow while visiting the site gives the page its camera and microphone", "granted audio,video")
        } else {
            run { [self] in skip("prompts: camera and microphone: off by default, as they prompt the owner (AIRC_MEDIA_PROMPT_CHECKS=1 runs them)") }
        }

        open({ base + "/location" }, title: "location")
        gesture("navigator.geolocation.getCurrentPosition(function(){document.title='located'},function(e){document.title='denied '+e.code})")
        expectCard("location") { if case .permission(let p) = $0 { p.kinds == ["location"] } else { false } }
        capture("prompt-location")
        click("prompt.block")
        expectAnswered("location", .block)
        waitTitle("Never allow denies the location", "denied 1")

        open({ base + "/notify" }, title: "notify")
        gesture("Notification.requestPermission().then(function(r){document.title='notify '+r})")
        expectCard("notifications") { if case .permission(let p) = $0 { p.kinds == ["notifications"] } else { false } }
        // The × is an AppKit button on the card: a real click at its centre.
        step { [self] done in
            guard let b = c.prompts.bubble else { return done() }
            let x = b.closeButton
            self.click(at: x.convert(NSPoint(x: x.bounds.midX, y: x.bounds.midY), to: nil), in: c.window, done)
        }
        expectAnswered("notifications", .dismiss)
        waitTitle("the × dismisses notifications (the site may ask again)", "notify default")

        // MARK: Passwords

        func submitLogin(_ origin: @escaping () -> String, password: String) {
            open({ origin() + "/login" }, title: "login")
            typeInto("username", "airc-synthetic")
            typeInto("password", password)
            gesture("document.getElementById('submit').click()")
        }
        func isPassword(_ state: String) -> (PagePrompt) -> Bool {
            { if case .password(let p) = $0 { p.state == state && p.username == "airc-synthetic" } else { false } }
        }
        func expectFilled(_ name: String, filled: Bool) {
            step { [self] done in
                var tries = 0
                func poll() {
                    guard let p = page() else { return done() }
                    // A trusted gesture lets page script read a filled password; only equality is read, never a value.
                    engine.devToolsCall("Runtime.evaluate", params: [
                        "expression": "document.body.click();[document.getElementById('username').value==='airc-synthetic',"
                            + "document.getElementById('password').value==='Only-A-Fixture-42!']",
                        "userGesture": true, "returnByValue": true], in: p) { reply, _ in
                        let v = ((reply?["result"] as? [String: Any])?["value"] as? [Bool]) ?? []
                        let got = v == [true, true]
                        tries += 1
                        if got == filled && (filled || tries >= 12) || tries >= 24 {
                            self.check(got == filled, "prompts: \(name) (username, password filled: \(v))")
                            return done()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                    }
                }
                poll()
            }
        }

        submitLogin({ base }, password: "Only-A-Fixture-42!")
        expectCard("save password", isPassword("save"))
        capture("prompt-password-save")
        // The username can be edited before saving: a real click into it, a key, then put back.
        click("prompt.username")
        step { [self] done in
            let model = c.prompts.bubble?.model
            let focused = c.window.firstResponder is NSTextView
            check(focused, "prompts: save password: a click puts the cursor in the username field (first responder \(String(describing: c.window.firstResponder.map { Swift.type(of: $0) })))")
            model?.username = "airc-synthetic"
            done()
        }
        click("prompt.save")
        expectAnswered("save password", .save(username: nil))
        step { [self] done in
            waitUntil({ page().map { engine.passwordPrompt(for: $0)?["state"] as? String != "save" } ?? true }, timeout: 3) {
                let state = page().flatMap { engine.passwordPrompt(for: $0)?["state"] as? String } ?? "none"
                self.check(state != "save", "prompts: save password: the engine took it (state now \(state))")
                done()
            }
        }
        open({ base + "/login" }, title: "login")
        expectFilled("a saved password fills the form on the next visit", filled: true)

        // Another profile doesn't have it.
        var second = ""
        step { [self] done in
            do {
                let p = try c.profiles.createProfile(name: "Prompt Check", emoji: "", color: nil)
                second = try c.store.createSpace(name: "Second", profileID: p.id).id
                c.reloadAll(animated: false)
                c.profiles.whenLoaded(p.id, { _ in done() }, failed: { self.check(false, "prompts: the second profile loads"); done() })
            } catch {
                check(false, "prompts: a second profile and Space (\(error))")
                done()
            }
        }
        open({ base + "/login" }, title: "login", inSpace: { second.isEmpty ? nil : second })
        expectFilled("another profile's form stays empty", filled: false)
        run { [self] in if let home = c.store.orderedSpaces.first?.id { c.switchToSpace(home, animated: false) } }

        // Update: the same username with a new password.
        submitLogin({ base }, password: "Only-A-Fixture-43!")
        expectCard("update password", isPassword("update"))
        capture("prompt-password-update")
        click("prompt.save")
        expectAnswered("update password", .save(username: nil))

        // Never on another site: it doesn't ask again there.
        submitLogin({ otherBase }, password: "Only-A-Fixture-42!")
        expectCard("save password (other site)", isPassword("save"))
        click("prompt.never")
        expectAnswered("Never", .never)
        submitLogin({ otherBase }, password: "Only-A-Fixture-44!")
        step { [self] done in
            waitUntil({ self.c.prompts.bubble != nil }, timeout: 4) {
                // The engine still keeps the login pending (Chrome's key icon can save it by hand); it just doesn't offer.
                let state = page().flatMap { engine.passwordPrompt(for: $0)?["state"] as? String } ?? "none"
                self.check(self.c.prompts.bubble == nil,
                           "prompts: after Never the site doesn't ask again (card \(self.c.prompts.bubble == nil ? "none" : "shown"), engine state \(state))")
                done()
            }
        }

        // MARK: Choosing between saved logins (the app's list, engine pass 12)

        // Two logins for a site of its own, saved through the engine (this part checks the list, not the save card).
        for (user, password) in [("airc-synthetic", "Only-A-Fixture-42!"), ("airc-second", "Only-A-Fixture-45!")] {
            open({ otherBase + "/login" }, title: "login")
            typeInto("username", user)
            typeInto("password", password)
            gesture("document.getElementById('submit').click()")
            step { [self] done in
                waitUntil({ page().map { ["save", "update"].contains(engine.passwordPrompt(for: $0)?["state"] as? String ?? "") } ?? false }, timeout: 6) {
                    guard let p = page(), let state = engine.passwordPrompt(for: p)?["state"] as? String else {
                        self.check(false, "prompts: the engine offers to save \(user)'s login")
                        return done()
                    }
                    engine.resolvePasswordPrompt(in: p, action: state)
                    done()
                }
            }
        }
        passwordPickerChecks(engine, page: page, open: { open({ otherBase + "/login" }, title: "login") })

        // MARK: Address and card

        open({ base + "/address" }, title: "address")
        for (field, value) in zip(address.map(\.0), ["Airc", "Fixture", "123 Example Street", "Mountain View", "CA", "94043", "US"]) {
            typeInto(field, value)
        }
        gesture("document.getElementById('submit').click()")
        expectCard("save address") { if case .autofill(let a) = $0 { a.kind == "saveAddress" } else { false } }
        capture("prompt-address")
        click("prompt.accept")
        expectAnswered("save address", .accept)

        open({ base + "/card" }, title: "card")
        for (field, value) in zip(card.map(\.0), ["Airc Fixture", "4111111111111111", "12", "2030"]) { typeInto(field, value) }
        gesture("document.getElementById('submit').click()")
        expectCard("save card") { if case .autofill(let a) = $0 { a.kind == "saveCard" } else { false } }
        capture("prompt-card")
        click("prompt.decline")
        expectAnswered("save card", .never)
        run { server?.stop() }
    }

    /// Two saved logins on one site: a trusted click in the username field brings the app's list under the field (not
    /// Chromium's popup); a real click on a row after the engine's 500 ms guard fills that login; ↓ ↓ Return fills the
    /// second row from the keyboard while the page keeps it; Esc closes the list and the engine forgets its rows.
    private func passwordPickerChecks(_ engine: ChromiumEngine, page: @escaping () -> EngineTab?, open: () -> Void) {
        let picker = { self.c.prompts.passwords }
        /// A trusted click at the field's centre (DevTools input), which is what makes Chromium offer the logins.
        func clickField(_ id: String) {
            step { [self] done in
                guard let p = page() else { return done() }
                engine.devToolsCall("Runtime.evaluate", params: [
                    "expression": "(function(){var r=document.getElementById('\(id)').getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()",
                    "returnByValue": true], in: p) { reply, _ in
                    let v = ((reply?["result"] as? [String: Any])?["value"] as? [Double]) ?? [20, 20]
                    var sent = 0
                    for type in ["mousePressed", "mouseReleased"] {
                        engine.devToolsCall("Input.dispatchMouseEvent", params: ["type": type, "x": v[0], "y": v[1], "button": "left",
                                                                                 "clickCount": 1], in: p) { _, _ in
                            sent += 1
                            if sent == 2 { done() }
                        }
                    }
                }
            }
        }
        func expectList(_ name: String) {
            step { [self] done in
                waitUntil({ picker().view != nil && picker().choices.count >= 2 }, timeout: 4) {
                    if picker().view == nil, let p = page() {
                        // Some runs (a locked screen: the page counts as hidden) never offer; the engine's manual trigger
                        // asks again, as the key icon would.
                        self.note("prompts: \(name): no list after the click; asking the engine (showAutofillSuggestions)")
                        engine.showAutofillSuggestions(in: p, passwords: true)
                    }
                    self.waitUntil({ picker().view != nil && picker().choices.count >= 2 }, timeout: 3) {
                        let names = picker().choices.map(\.username).sorted()
                        self.check(names == ["airc-second", "airc-synthetic"],
                                   "prompts: \(name): the list shows both saved logins (\(names))")
                        done()
                    }
                }
            }
        }
        func expectFilledWith(_ name: String, _ user: String, _ password: String) {
            step { [self] done in
                var tries = 0
                func poll() {
                    guard let p = page() else { return done() }
                    engine.devToolsCall("Runtime.evaluate", params: [
                        "expression": "[document.getElementById('username').value==='\(user)',"
                            + "document.getElementById('password').value==='\(password)']",
                        "userGesture": true, "returnByValue": true], in: p) { reply, _ in
                        let v = ((reply?["result"] as? [String: Any])?["value"] as? [Bool]) ?? []
                        tries += 1
                        if v == [true, true] || tries >= 16 {
                            self.check(v == [true, true], "prompts: \(name): \(user)'s login is filled (username, password: \(v))")
                            return done()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                    }
                }
                poll()
            }
        }

        open()
        run { [self] in c.engineTab(for: c.shownTabID ?? "")?.focus() }
        // Whatever the page filled at load goes, so the field shows what the list fills.
        step { [self] done in
            guard let p = page() else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: [
                "expression": "document.getElementById('username').value='';document.getElementById('password').value='';1",
                "returnByValue": true], in: p) { _, _ in done() }
        }
        clickField("username")
        expectList("two saved logins")
        wait(0.2)
        run { [self] in
            guard let v = picker().view, let p = page() else { return check(false, "prompts: the password list is up") }
            v.layoutSubtreeIfNeeded()
            // Under the field: the field's rectangle from the page, in the window.
            let field = picker().fieldRect.map { r -> NSRect in
                let origin = p.view.isFlipped ? r.origin : NSPoint(x: r.minX, y: p.view.bounds.height - r.maxY)
                return c.root.convert(NSRect(origin: origin, size: r.size), from: p.view)
            } ?? .zero
            check(v.superview === c.root && field.width > 0 && abs(v.frame.minY - (field.maxY + PasswordPicker.gap)) <= 1.5
                  && abs(v.frame.minX - max(c.card.frame.minX + 8, field.minX)) <= 1.5,
                  "prompts: the list hangs under the username field (list \(NSStringFromRect(v.frame)), field \(NSStringFromRect(field)), "
                  + "from \(picker().anchorSource))")
            check(c.window.firstResponder.map { r in (r as? NSView).map { $0 === p.view || $0.isDescendant(of: p.view) } ?? false } ?? false,
                  "prompts: the page keeps the keyboard while the list is up")
        }
        capture("password-picker")
        // A real click on the second login, once the engine's 500 ms guard is over.
        wait(0.6)
        step { [self] done in
            guard let v = picker().view, let i = picker().choices.firstIndex(where: { $0.username == "airc-second" }), i < v.rows.count else {
                check(false, "prompts: the list has airc-second's row")
                return done()
            }
            let r = v.rows[i]
            let before = picker().filled.count
            self.click(at: r.convert(NSPoint(x: r.bounds.midX, y: r.bounds.midY), to: nil), in: c.window) {
                if picker().filled.count == before, picker().view != nil {
                    // A window that takes no posted clicks (another app or the lock screen in front): the row's own press.
                    self.skip("prompts: a real click on a row: the window took no posted click (owner's session); pressed the row directly")
                    _ = r.accessibilityPerformPress()
                }
                done()
            }
        }
        expectFilledWith("a click on a row", "airc-second", "Only-A-Fixture-45!")
        run { [self] in
            check(picker().view == nil && picker().filled.last == "airc-second",
                  "prompts: the list goes once a login is filled (\(picker().view == nil ? "gone" : "still up"))")
        }

        // The keyboard: ↓ ↓ Return fills the second row.
        step { [self] done in
            guard let p = page() else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: [
                "expression": "document.getElementById('username').value='';document.getElementById('password').value='';document.body.focus();1",
                "returnByValue": true], in: p) { _, _ in done() }
        }
        clickField("username")
        expectList("the list again")
        wait(0.6)
        var second = ""
        run { [self] in
            let rows = picker().choices
            second = rows.count >= 2 ? rows[1].username : ""
            c.engineTab(for: c.shownTabID ?? "")?.focus()
        }
        key("\u{F701}", 125)
        key("\u{F701}", 125)
        run { [self] in
            check(picker().view?.selected == 1, "prompts: ↓ ↓ selects the second row (selected \(picker().view?.selected.map(String.init) ?? "none"))")
        }
        key("\r", 36)
        step { [self] done in
            let user = second
            let password = user == "airc-second" ? "Only-A-Fixture-45!" : "Only-A-Fixture-42!"
            var tries = 0
            func poll() {
                guard let p = page() else { return done() }
                engine.devToolsCall("Runtime.evaluate", params: [
                    "expression": "[document.getElementById('username').value==='\(user)',document.getElementById('password').value==='\(password)']",
                    "userGesture": true, "returnByValue": true], in: p) { reply, _ in
                    let v = ((reply?["result"] as? [String: Any])?["value"] as? [Bool]) ?? []
                    tries += 1
                    if v == [true, true] || tries >= 16 {
                        self.check(v == [true, true] && self.c.prompts.passwords.view == nil,
                                   "prompts: Return fills the selected login (\(user): \(v)) and the list goes")
                        return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                }
            }
            poll()
        }

        // Esc closes it; the engine's rows go with it (a stale choice fails).
        clickField("password")
        clickField("username")
        expectList("the list for Esc")
        var stale = -1
        run { [self] in
            stale = picker().choices.first?.index ?? -1
            c.engineTab(for: c.shownTabID ?? "")?.focus()
        }
        key("\u{1b}", 53)
        run { [self] in
            let accepted = page().map { engine.acceptAutofillSuggestion(in: $0, index: stale) } ?? true
            check(picker().view == nil && !accepted,
                  "prompts: Esc closes the list (\(picker().view == nil ? "gone" : "still up")) and its rows are gone (stale choice accepted: \(accepted))")
        }
    }

    /// The card's top edge is the URL field's bottom edge plus the gap, its leading edge the field's (kept inside the
    /// window), and the engine's UI anchor is that field.
    func checkAnchored(_ name: String) {
        guard let b = c.prompts.bubble else { return check(false, "prompts: \(name): anchored (no card)") }
        let anchor = c.prompts.anchorRectInRoot()
        let top = abs(b.frame.minY - (anchor.maxY + PromptPresenter.gap)) <= 1
        let lead = abs(b.frame.minX - min(max(8, anchor.minX), c.root.bounds.width - b.frame.width - 8)) <= 1
        let field = c.pageView(for: c.currentSpaceID)?.urlField
        #if canImport(AircCore)
        let engineRect = (app?.engine as? ChromiumEngine)?.uiAnchorRectInScreen(window: c.engineWindow) ?? .zero
        let fieldScreen = field.flatMap { f in f.window.map { $0.convertToScreen(f.convert(f.bounds, to: nil)) } } ?? .zero
        let engineAgrees = abs(engineRect.minX - fieldScreen.minX) <= 1 && abs(engineRect.maxY - fieldScreen.maxY) <= 1
        #else
        let engineAgrees = true
        #endif
        check(top && lead && engineAgrees, "prompts: \(name): hangs from the URL field (card \(NSStringFromRect(b.frame)), "
              + "field \(NSStringFromRect(anchor)), engine anchor is the field \(engineAgrees))")
    }
}
#endif
#endif
