// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// S03: a Favorite's unread dot and sound badge on synthetic loopback pages, both engines. `--script s03badges` makes a
/// Favorite whose title counts "(N)", turns its Show Unread Badge off, plays a near-silent tone and checks the
/// badge's motion with Reduce Motion off and on, and a private window. `--script s03badges-relaunch`, on the same data
/// directory, checks the switch came back off after the relaunch and can be turned on again.
/// Nothing leaves the Mac: 127.0.0.1 only. The tone is a 20 Hz wave at −58 dBFS: below what the Mac's speakers play,
/// but above Chromium's −72 dBFS silence floor, which a page of zeros never crosses (so Chromium would never call
/// it audible).
/// A sound badge as drawn, read on the main thread (AudioBadge is main-actor).
struct S03Sound: CustomStringConvertible {
    var state = AudioBadge.State.none, isHidden = true, isAnimating = false, frame = CGRect.zero
    var description: String { "\(state)\(isHidden ? " hidden" : "")\(isAnimating ? " moving" : "")" }
}

extension SnapshotRunner {
    static let s03Marker = "s03badges-favorite.txt"

    private static func s03Server() -> LocalPageServer? {
        let page = """
        <!doctype html><meta charset=utf-8><title>Inbox (3) - Fixture Mail</title>
        <body style="font:14px -apple-system;padding:24px">Synthetic inbox
        <audio id=a src="/tone.wav" loop></audio>
        <script>
        function setCount(n){document.title=(n>0?'Inbox ('+n+') - ':'Inbox - ')+'Fixture Mail';return document.title}
        </script>
        """
        return LocalPageServer(responses: [
            "/inbox": .init(headers: ["Content-Type": "text/html; charset=utf-8"], body: page),
            "/tone.wav": .init(headers: ["Content-Type": "audio/wav"], body: "", data: s03Tone(seconds: 4)),
        ])
    }

    /// 16 kHz mono 16-bit, a 20 Hz square wave of ±40 (−58 dBFS).
    private static func s03Tone(seconds: Int) -> Data {
        let rate = 16_000, samples = rate * seconds
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        for i in 0..<samples { u16(UInt16(bitPattern: (i / (rate / 40)) % 2 == 0 ? 40 : -40)) }
        return d
    }

    private func s03Tile(_ itemID: String) -> FavoriteTileView? {
        guard let p = c.pageView(for: c.currentSpaceID) else { return nil }
        p.layoutSubtreeIfNeeded()
        return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == itemID }
    }

    private func s03BadgeItem(_ itemID: String) -> NSMenuItem? {
        guard let item = c.store.item(itemID) else { return nil }
        let m = c.menu(for: .favorite(item, c.store.liveTab(forItem: itemID)))
        m.update()
        return m.items.first { $0.title == "Show Unread Badge" }
    }

    private func s03Toggle(_ itemID: String) {
        guard let item = c.store.item(itemID) else { return }
        let m = c.menu(for: .favorite(item, c.store.liveTab(forItem: itemID)))
        m.update()
        if let i = m.items.firstIndex(where: { $0.title == "Show Unread Badge" }) { m.performActionForItem(at: i) }
    }

    private func s03Eval(_ tab: @escaping () -> EngineTab?, _ js: String, _ label: String) {
        step { [self] done in
            guard let t = tab() else { check(false, "s03: \(label): the page exists"); return done() }
            t.evaluate(js) { v in self.note("s03: \(label) → \(v.map { "\($0)" } ?? "nil")"); done() }
        }
    }

    func s03BadgesScenario() {
        let engine = (app?.engine is WebKitEngine) ? "webkit" : "chromium"
        var server: LocalPageServer?, base = "", fav = "", tabID = ""
        let page = { [unowned self] () -> EngineTab? in self.c.engineTab(for: tabID) }
        let tile = { [unowned self] () -> FavoriteTileView? in self.s03Tile(fav) }
        let sound = { () -> S03Sound? in
            MainActor.assumeIsolated {
                tile()?.audioBadge.map { S03Sound(state: $0.state, isHidden: $0.layer.isHidden, isAnimating: $0.isAnimating, frame: $0.layer.frame) }
            }
        }
        let motion = { (v: Bool?) in
            MainActor.assumeIsolated {
                AircMotion.reduceMotionOverride = v
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            }
        }
        run { URLRules.extraUnreadBadgeHosts = ["127.0.0.1"] }
        step { done in
            server = Self.s03Server()
            server?.start { port in base = port.map { "http://127.0.0.1:\($0)" } ?? ""; done() }
        }
        run { [self] in
            guard !base.isEmpty else { return check(false, "s03: the loopback server listens") }
            do {
                let pid = c.store.profile(ofSpace: c.currentSpaceID).id
                let t = try c.store.openTab(url: base + "/inbox", inSpace: c.currentSpaceID, activate: false, title: "Inbox")
                try c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 0))
                tabID = t.id
                fav = c.store.tab(t.id)?.itemID ?? ""
                try? fav.write(to: AppPaths.dataDirectory.appendingPathComponent(Self.s03Marker), atomically: true, encoding: .utf8)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            } catch { check(false, "s03: setup (\(error))") }
        }
        step { [self] done in waitUntil({ page()?.title.hasPrefix("Inbox (3)") == true && page()?.isLoading == false }, timeout: 15) { done() } }

        // 1. The title's count draws the dot; no count, no dot; a count again, the dot again.
        step { [self] done in waitUntil({ tile()?.showsUnreadDot == true }, timeout: 3) { done() } }
        run { [self] in
            check(tile()?.showsUnreadDot == true, "s03 \(engine): \"Inbox (3)\" in the title draws the Favorite's unread dot")
            check(s03BadgeItem(fav)?.state == .on, "s03 \(engine): the Favorite's menu offers Show Unread Badge, on")
            check(sound().map { $0.state == .none } ?? true, "s03 \(engine): a silent page has no sound badge")
        }
        capture("s03-\(engine)-unread")
        s03Eval(page, "setCount(0)", "title count 0")
        step { [self] done in waitUntil({ tile()?.showsUnreadDot == false }, timeout: 3) { done() } }
        run { [self] in check(tile()?.showsUnreadDot == false, "s03 \(engine): the title without a count takes the dot away (\(page()?.title ?? "-"))") }
        s03Eval(page, "setCount(7)", "title count 7")
        step { [self] done in waitUntil({ tile()?.showsUnreadDot == true }, timeout: 3) { done() } }
        run { [self] in check(tile()?.showsUnreadDot == true, "s03 \(engine): a count again brings the dot back (\(page()?.title ?? "-"))") }

        // 2. Show Unread Badge off: no dot while the count stays; the switch is saved.
        run { [self] in s03Toggle(fav) }
        wait(0.3)
        run { [self] in
            let saved = AppSettings(directory: AppPaths.dataDirectory).values.sidebarItems.noUnreadBadge.contains(fav)
            check(tile()?.showsUnreadDot == false && page()?.title.hasPrefix("Inbox (7)") == true && s03BadgeItem(fav)?.state == .off && saved,
                  "s03 \(engine): Show Unread Badge off hides the dot while the title still counts 7, and is saved (\(saved))")
        }
        s03Eval(page, "setCount(9)", "title count 9 with the switch off")
        wait(0.5)
        run { [self] in check(tile()?.showsUnreadDot == false, "s03 \(engine): with the switch off a new count draws no dot") }

        // 3. Sound: the badge plays its note while the page is audible; Reduce Motion stills it.
        run { motion(false) }
        s03Eval(page, "document.getElementById('a').play().then(()=>'playing',e=>String(e))", "play the tone")
        step { [self] done in waitUntil({ sound()?.state == .playing }, timeout: 8) { done() } }
        run { [self] in
            let b = sound()
            check(page()?.isAudible == true && b?.state == .playing && b?.isHidden == false && b?.isAnimating == true,
                  "s03 \(engine): an audible Favorite shows its sound badge, note moving (audible \(page()?.isAudible == true), badge \(b.map { "\($0)" } ?? "none"), moving \(b?.isAnimating == true))")
            if let b, let t = tile() {
                let f = b.frame, d = AudioBadge.diameter
                check(abs(f.width - d) < 0.5 && t.bounds.maxX - f.maxX >= 4 && f.minY >= 4 && f.maxY < t.bounds.midY,
                      "s03 \(engine): the sound badge is \(d) pt on the tile's top-right corner, 4 pt clear of its edges (\(f), tile \(t.bounds.size))")
            }
        }
        capture("s03-\(engine)-audio")
        run { motion(true) }
        wait(0.2)
        run { [self] in
            let b = sound()
            check(b?.state == .playing && b?.isHidden == false && b?.isAnimating == false,
                  "s03 \(engine): Reduce Motion: the sound badge stays, its note still (moving \(b?.isAnimating == true))")
        }
        run { [self] in c.reloadAll(animated: false) }
        wait(0.2)
        run { [self] in check(sound()?.isAnimating == false, "s03 \(engine): Reduce Motion: a redrawn tile's note stays still") }
        run { motion(false) }
        wait(0.2)
        run { [self] in check(sound()?.isAnimating == true, "s03 \(engine): Reduce Motion off again: the note moves again") }
        run { [self] in c.toggleMute(tabID) }
        step { [self] done in waitUntil({ sound()?.state == .muted }, timeout: 3) { done() } }
        run { [self] in
            let b = sound()
            check(b?.state == .muted && b?.isAnimating == false, "s03 \(engine): muted: a still crossed-out speaker (\(b.map { "\($0)" } ?? "none"))")
            c.toggleMute(tabID)
        }
        s03Eval(page, "var a=document.getElementById('a');a.pause();a.currentTime=0;'paused'", "pause the tone")
        step { [self] done in waitUntil({ sound().map { $0.state == .none } ?? true }, timeout: 10) { done() } }
        run { [self] in
            let b = sound()
            check(page()?.isAudible == false && (b == nil || (b!.state == .none && b!.isHidden && !b!.isAnimating)),
                  "s03 \(engine): the tone stops, the sound badge goes (audible \(page()?.isAudible == true))")
            motion(nil)
        }

        // 4. A private window has no Favorites, so no unread dot or sound badge (as Arc's).
        var priv: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                priv = w
                _ = w?.openPage(URL(string: base + "/inbox"))
                done()
            }
        }
        wait(2)
        run { [self] in
            guard let w = priv?.window else { return check(false, "s03 \(engine): the private window opens") }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let views = w.contentView.map(all) ?? []
            check(!views.contains { $0 is FavoriteTileView }, "s03 \(engine): a private window draws no Favorites, so no unread dot or sound badge (\(views.count) views)")
            priv?.closeWindow()
        }
        wait(0.5)
        run { [self] in
            URLRules.extraUnreadBadgeHosts = []
            server = nil
            try? c.store.flush()
        }
    }

    /// The second launch on the first one's data directory: the Favorite's switch is still off.
    func s03BadgesRelaunchScenario() {
        let engine = (app?.engine is WebKitEngine) ? "webkit" : "chromium"
        var server: LocalPageServer?, base = "", fav = ""
        run { URLRules.extraUnreadBadgeHosts = ["127.0.0.1"] }
        step { done in
            server = Self.s03Server()
            server?.start { port in base = port.map { "http://127.0.0.1:\($0)" } ?? ""; done() }
        }
        run { [self] in
            let marker = AppPaths.dataDirectory.appendingPathComponent(Self.s03Marker)
            fav = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            check(!fav.isEmpty && c.store.item(fav) != nil, "s03 relaunch \(engine): the first launch's Favorite is back (\(fav))")
            check(s03BadgeItem(fav)?.state == .off && !c.showsUnreadBadge(c.store.item(fav)!),
                  "s03 relaunch \(engine): its Show Unread Badge is still off after the relaunch")
            // The saved page's port was the first launch's: open the Favorite, then load the page from this launch's server.
            if let item = c.store.item(fav) { c.activate(entry: .favorite(item, c.store.liveTab(forItem: fav))) }
        }
        let page = { [unowned self] () -> EngineTab? in self.c.store.liveTab(forItem: fav).flatMap { self.c.engineTab(for: $0.id) } }
        step { [self] done in waitUntil({ page() != nil }, timeout: 10) { done() } }
        run { if let u = URL(string: base + "/inbox") { page()?.load(u) } }
        step { [self] done in waitUntil({ page()?.title.hasPrefix("Inbox (3)") == true && page()?.isLoading == false }, timeout: 15) { done() } }
        wait(0.3)
        run { [self] in
            check(s03Tile(fav)?.showsUnreadDot == false, "s03 relaunch \(engine): the title counts 3 and the dot stays hidden (\(page()?.title ?? "-"))")
            s03Toggle(fav)
        }
        wait(0.3)
        run { [self] in
            check(s03Tile(fav)?.showsUnreadDot == true && s03BadgeItem(fav)?.state == .on,
                  "s03 relaunch \(engine): Show Unread Badge on again draws the dot")
        }
        capture("s03-\(engine)-relaunch")
        run { URLRules.extraUnreadBadgeHosts = []; server = nil }
    }
}
#endif
