// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// What a page does with the location, and which devices it asked for (SB-2), from the page script's "siteuse" part
/// (EnginePageScripts.swift). Neither engine says when a page reads the location (Chromium 156 keeps only "accessed" for
/// geolocation, WebKit nothing), so the part wraps navigator.geolocation in the page's main world, before the page's own
/// scripts, and reports:
/// - "doc": a new top document (its state starts clean);
/// - "watch" {n}: how many of the frame's watchPosition watches have had a position (0 once cleared, or the frame left);
/// - "read": a getCurrentPosition answer;
/// - "ask" {k}: the page asked for its location, the camera, the microphone or the screen.
/// The location is in use while a watch runs and for 15 s after a one-shot read (Chrome holds its device indicators as
/// long after a use ends). Site Controls also uses the asks: a site that wants something macOS doesn't let Airc have
/// says so (SystemPrivacy). Nothing polls; a change posts SiteControlsCenter.didChange for the tab.
final class SiteUse {
    static let shared = SiteUse()
    /// After a one-shot read, the location shows as used this long (a check shortens it).
    static var readHold: TimeInterval = 15

    enum Ask: String, CaseIterable { case location, camera, microphone, screen }

    private final class Entry {
        weak var tab: EngineTab?
        /// Frame → its watches that have had a position.
        var watching: [String: Int] = [:]
        var lastRead: Date?
        var asked: Set<Ask> = []
        var hold: DispatchWorkItem?
        init(_ tab: EngineTab) { self.tab = tab }
        var isEmpty: Bool { watching.isEmpty && lastRead == nil && asked.isEmpty }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    #if AIRC_TESTING
    /// Scripted checks: the part answers geolocation with a made-up position and never calls the real one (no
    /// CoreLocation, no macOS prompt); getUserMedia and getDisplayMedia reject without reaching the engine.
    private(set) static var fake = false
    #endif

    /// After BoostCenter.start (which made the engine's page script ours), before the first page opens.
    static func start() {
        guard let scripts = PageScripts.shared else { return }
        var fake = false
        #if AIRC_TESTING
        fake = LaunchOptions.current.snapshotDir != nil && LaunchOptions.current.script == "followups3"
        Self.fake = fake
        #endif
        scripts.set("siteuse", source: source(fake: fake)) { tab, message in shared.received(tab, message) }
        scripts.pushNow()
    }

    // MARK: State

    /// A watch runs, or the page read the location in the last 15 s.
    func locationInUse(_ tab: EngineTab) -> Bool {
        guard let e = existing(tab) else { return false }
        if e.watching.values.contains(where: { $0 > 0 }) { return true }
        return e.lastRead.map { Date().timeIntervalSince($0) < Self.readHold } ?? false
    }

    /// What the page's top document asked for.
    func asked(_ tab: EngineTab) -> Set<Ask> { existing(tab)?.asked ?? [] }

    private func existing(_ tab: EngineTab) -> Entry? {
        entries[ObjectIdentifier(tab)].flatMap { $0.tab === tab ? $0 : nil }
    }

    private func entry(_ tab: EngineTab) -> Entry {
        if let e = existing(tab) { return e }
        entries = entries.filter { $0.value.tab != nil }
        let e = Entry(tab)
        entries[ObjectIdentifier(tab)] = e
        return e
    }

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        let body = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        switch m.kind {
        case "doc":
            guard m.isMainFrame, let e = existing(tab), !e.isEmpty else { return }
            e.hold?.cancel()
            entries[ObjectIdentifier(tab)] = nil
        case "watch":
            let n = (body["n"] as? NSNumber)?.intValue ?? 0
            let e = entry(tab)
            guard (e.watching[m.frame] ?? 0) != n else { return }
            e.watching[m.frame] = n > 0 ? n : nil
        case "read":
            let e = entry(tab)
            let was = locationInUse(tab)
            e.lastRead = Date()
            e.hold?.cancel()
            let hold = DispatchWorkItem { [weak self, weak tab] in
                guard let self, let tab, !tab.isClosed, !self.locationInUse(tab) else { return }
                SiteControlsCenter.shared?.pageChanged(tab)
            }
            e.hold = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.readHold + 0.05, execute: hold)
            if was { return }
        case "ask":
            guard let k = (body["k"] as? String).flatMap(Ask.init(rawValue:)), entry(tab).asked.insert(k).inserted else { return }
        default:
            return
        }
        SiteControlsCenter.shared?.pageChanged(tab)
    }

    #if AIRC_TESTING
    /// For checks that can't make a page ask (no getDisplayMedia in tests): as if the page had asked for `k`.
    func noteAsk(_ k: Ask, in tab: EngineTab) {
        guard entry(tab).asked.insert(k).inserted else { return }
        SiteControlsCenter.shared?.pageChanged(tab)
    }
    #endif

    // MARK: The part

    /// The wrappers keep the page's `this`, arguments and results, and their `toString` reads as the originals'.
    static func source(fake: Bool) -> String {
        """
        function (post) {
          var FAKE = \(fake ? "true" : "false");
          function like(f, original) {
            try { Object.defineProperty(f, 'toString', { value: function () { return Function.prototype.toString.call(original); } }); } catch (e) {}
            return f;
          }
          function ask(k) { post('ask', '{"k":"' + k + '"}'); }
          var top = false;
          try { top = window.top === window; } catch (e) {}
          var geo = navigator.geolocation, G = geo && Object.getPrototypeOf(geo), active = 0;
          function report() { post('watch', '{"n":' + active + '}'); }
          function position() {
            return { coords: { latitude: 48.2082, longitude: 16.3738, accuracy: 25, altitude: null, altitudeAccuracy: null,
                               heading: null, speed: null }, timestamp: Date.now() };
          }
          if (G && typeof G.getCurrentPosition === 'function' && typeof G.watchPosition === 'function') {
            var get = G.getCurrentPosition, watch = G.watchPosition, clear = G.clearWatch, live = Object.create(null), timers = {}, next = 1;
            G.getCurrentPosition = like(function getCurrentPosition(ok, fail, options) {
              ask('location');
              var answer = typeof ok === 'function' ? function () { post('read', '{}'); return ok.apply(this, arguments); } : ok;
              if (FAKE) { if (typeof ok === 'function') setTimeout(function () { answer(position()); }, 30); return; }
              return get.call(this, answer, fail, options);
            }, get);
            G.watchPosition = like(function watchPosition(ok, fail, options) {
              ask('location');
              var id, started = false;
              var answer = typeof ok === 'function' ? function () {
                if (!started && id !== undefined) { started = true; live[id] = true; active++; report(); }
                return ok.apply(this, arguments);
              } : ok;
              if (FAKE) {
                id = 900000 + next++;
                if (typeof ok === 'function') {
                  setTimeout(function () { if (timers[id]) answer(position()); }, 30);
                  timers[id] = setInterval(function () { answer(position()); }, 1000);
                }
                return id;
              }
              id = watch.call(this, answer, fail, options);
              return id;
            }, watch);
            G.clearWatch = like(function clearWatch(id) {
              if (live[id]) { delete live[id]; active--; report(); }
              if (FAKE) { if (timers[id]) { clearInterval(timers[id]); delete timers[id]; } return; }
              return clear.apply(this, arguments);
            }, clear);
          }
          var md = navigator.mediaDevices, M = md && Object.getPrototypeOf(md);
          if (M && typeof M.getUserMedia === 'function') {
            var gum = M.getUserMedia;
            M.getUserMedia = like(function getUserMedia(c) {
              if (c && c.video) ask('camera');
              if (c && c.audio) ask('microphone');
              if (FAKE) return Promise.reject(new DOMException('Not in an Airc check', 'NotAllowedError'));
              return gum.apply(this, arguments);
            }, gum);
          }
          if (M && typeof M.getDisplayMedia === 'function') {
            var gdm = M.getDisplayMedia;
            M.getDisplayMedia = like(function getDisplayMedia() {
              ask('screen');
              if (FAKE) return Promise.reject(new DOMException('Not in an Airc check', 'NotAllowedError'));
              return gdm.apply(this, arguments);
            }, gdm);
          }
          addEventListener('pagehide', function () { if (active) post('watch', '{"n":0}'); }, true);
          addEventListener('pageshow', function (e) { if (e.persisted) { if (top) post('doc', '{}'); if (active) report(); } }, true);
          if (top) post('doc', '{}');
          return null;
        }
        """
    }
}
