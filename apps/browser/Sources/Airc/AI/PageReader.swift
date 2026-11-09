// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// Reads a page's visible text for the AI features (docs/user/ai.md), in the page through `EngineTab.evaluate`, on both
/// engines: the text nodes a person can see (not hidden, not in scripts, styles, forms or frames), grouped by the
/// nearest block (a paragraph, a heading, a list item, a cell), whitespace collapsed, in reading order, up to a cap.
/// The same walk finds a quote again (`jump`): its block by index and its range by offsets in that block's text,
/// scrolls to it and highlights it. Nothing is kept in the page between calls, and nothing leaves the Mac.
enum PageReader {
    /// Visible text on a page, at most `cap` characters (AircKit's PageText). Nil when the page can't be read: no body,
    /// an engine that can't evaluate, a script that failed or took more than 10 seconds.
    static func read(_ tab: EngineTab, cap: Int, completion: @escaping (PageText?) -> Void) {
        let started = CACurrentMediaTime()
        tab.evaluate(script(mode: "read", cap: cap, target: nil)) { value in
            lastReadSeconds = CACurrentMediaTime() - started
            completion(PageText(script: value))
        }
    }

    /// How long the last read took (the scripted checks log it).
    private(set) static var lastReadSeconds: Double = 0

    struct Jump {
        var ok: Bool
        /// The quote's top in the viewport after the scroll, and the viewport's height (CSS pixels).
        var top: Double
        var viewport: Double
        var highlighted: Bool
        var text: String
    }

    /// Scrolls the page to a quote and highlights it (the CSS Custom Highlight API; the selection where a page lacks
    /// it). Its block is found by index, or by its text if the page changed since it was read.
    static func jump(_ tab: EngineTab, to quote: PageQuote, completion: ((Jump?) -> Void)? = nil) {
        let target: [String: Any] = ["b": quote.block, "s": quote.start, "e": quote.end, "t": quote.text]
        tab.evaluate(script(mode: "jump", cap: AskPageLimits.readCap, target: target)) { value in
            guard let d = value as? [String: Any] else { completion?(nil); return }
            completion?(Jump(ok: (d["ok"] as? Bool) ?? false, top: (d["top"] as? NSNumber)?.doubleValue ?? -1,
                             viewport: (d["vh"] as? NSNumber)?.doubleValue ?? 0, highlighted: (d["hl"] as? Bool) ?? false,
                             text: d["text"] as? String ?? ""))
        }
    }

    /// Takes the highlight away (the card closed).
    static func clearHighlight(_ tab: EngineTab) {
        tab.evaluate("(function(){try{if(window.CSS&&CSS.highlights)CSS.highlights.delete('airc-ask');}catch(e){}return true})()", completion: nil)
    }

    static func script(mode: String, cap: Int, target: [String: Any]?) -> String {
        let t = target.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return "(\(walker))(\(max(1000, cap)), '\(mode)', \(t))"
    }

    /// The walk. `read` returns {title, url, total, truncated, blocks: [[text, heading]]}; `jump` returns {ok, top, vh,
    /// hl, text}. The two must number blocks the same way, so they share every step. It's bounded every way a page could
    /// make it long: text read (`cap`, inside one huge block too), text walked (five times that), text nodes and time;
    /// past any of them the page counts as truncated (Ask on Page calls it too large).
    static let walker = """
    function (cap, mode, target) {
      var body = document.body;
      if (!body) return null;
      var MAX_NODES = 100000, MAX_MS = 1500, began = Date.now(), seen = 0;
      var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, CANVAS: 1, IFRAME: 1, OBJECT: 1, EMBED: 1,
                   SELECT: 1, OPTION: 1, TEXTAREA: 1, INPUT: 1, HEAD: 1, VIDEO: 1, AUDIO: 1, MATH: 1 };
      var shown = new Map(), owner = new Map();
      function visible(el) {
        var v = shown.get(el);
        if (v !== undefined) return v;
        v = true;
        for (var a = el; a && a !== body; a = a.parentElement) {
          if (SKIP[a.tagName] || SKIP[String(a.tagName).toUpperCase()]) { v = false; break; }
        }
        if (v) {
          if (el.checkVisibility) v = el.checkVisibility({ checkVisibilityCSS: true, visibilityProperty: true });
          else { var cs = getComputedStyle(el); v = cs.display !== 'none' && cs.visibility !== 'hidden'; }
        }
        shown.set(el, v);
        return v;
      }
      function blockOf(el) {
        var chain = [];
        for (var a = el; a && a !== body; a = a.parentElement) {
          var known = owner.get(a);
          if (known) { chain.forEach(function (c) { owner.set(c, known); }); return known; }
          chain.push(a);
          var d = getComputedStyle(a).display || '';
          if (d.indexOf('inline') !== 0 && d !== 'contents') { chain.forEach(function (c) { owner.set(c, a); }); return a; }
        }
        chain.forEach(function (c) { owner.set(c, body); });
        return body;
      }
      var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, { acceptNode: function (n) {
        var p = n.parentElement;
        if (!p || !/\\S/.test(n.data)) return NodeFilter.FILTER_SKIP;
        return visible(p) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      } });
      // Whitespace runs as one space, trimmed; `map` gives each kept UTF-16 unit's node and offset. At most `limit`
      // units (a block's text is never collapsed past what the read can still take), not cutting a surrogate pair.
      function collapse(nodes, map, limit) {
        var out = '', space = true;
        if (limit === undefined) limit = Infinity;
        for (var i = 0; i < nodes.length && out.length < limit; i++) {
          var s = nodes[i].data;
          for (var j = 0; j < s.length && out.length < limit; j++) {
            var c = s.charAt(j);
            if (/\\s/.test(c)) {
              if (!space) { out += ' '; if (map) map.push([nodes[i], j]); space = true; }
            } else { out += c; if (map) map.push([nodes[i], j]); space = false; }
          }
        }
        if (out.length > limit) { out = out.slice(0, limit); if (map) map.length = limit; }
        var last = out.charCodeAt(out.length - 1);
        if (last >= 0xD800 && last <= 0xDBFF) { out = out.slice(0, -1); if (map) map.pop(); }
        if (out.charAt(out.length - 1) === ' ') { out = out.slice(0, -1); if (map) map.pop(); }
        return out;
      }
      var blocks = [], current = null, nodes = [], total = 0, truncated = false, read = 0;
      var wanted = mode === 'jump' ? target.b : -1, found = null, all = [];
      function flush() {
        if (!current) return;
        var i = blocks.length;
        if (mode === 'read') {
          var text = read < cap ? collapse(nodes, null, cap - read) : '';
          if (read + text.length >= cap) truncated = true;
          read += text.length;
          blocks.push([text, /^H[1-6]$/.test(current.tagName) ? 1 : 0]);
        } else {
          blocks.push(0);
          if (i === wanted) found = nodes;
          all.push(nodes);
        }
        current = null;
        nodes = [];
      }
      for (var n = walker.nextNode(); n; n = walker.nextNode()) {
        total += n.data.length;
        if (total > cap * 5) { truncated = true; break; }
        if (++seen > MAX_NODES || (seen % 256 === 0 && Date.now() - began > MAX_MS)) { truncated = true; break; }
        if (mode === 'read' && read >= cap) { truncated = true; continue; }
        var b = blockOf(n.parentElement);
        if (b !== current) { flush(); current = b; }
        nodes.push(n);
      }
      flush();
      if (mode === 'read') {
        if (total > cap) truncated = true;
        return { title: document.title || '', url: location.href, total: total, truncated: truncated, blocks: blocks };
      }
      function norm(s) { return String(s).replace(/\\s+/g, ' ').trim(); }
      // The quote at its offsets in its block; or, if the page changed since it was read, its text anywhere.
      function locate(list) {
        var map = [], text = collapse(list, map);
        var s = target.s, e = target.e;
        if (s >= 0 && e <= text.length && e > s && norm(text.slice(s, e)) === norm(target.t)) return { map: map, s: s, e: e };
        var at = text.indexOf(target.t);
        return at < 0 ? null : { map: map, s: at, e: at + target.t.length };
      }
      var hit = found ? locate(found) : null;
      for (var k = 0; !hit && k < all.length; k++) hit = locate(all[k]);
      if (!hit) return { ok: false, top: -1, vh: innerHeight, hl: false, text: '' };
      var a = hit.map[hit.s], z = hit.map[hit.e - 1];
      var range = document.createRange();
      range.setStart(a[0], a[1]);
      range.setEnd(z[0], z[1] + 1);
      var el = a[0].parentElement;
      var smooth = document.visibilityState === 'visible' && !matchMedia('(prefers-reduced-motion: reduce)').matches;
      el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: smooth ? 'smooth' : 'auto' });
      var hl = false;
      try {
        if (window.CSS && CSS.highlights && window.Highlight) {
          CSS.highlights.set('airc-ask', new Highlight(range));
          if (!document.getElementById('__airc-ask-style')) {
            var st = document.createElement('style');
            st.id = '__airc-ask-style';
            st.textContent = '::highlight(airc-ask){background-color:rgba(255,196,0,.42);color:inherit}';
            (document.head || document.documentElement).appendChild(st);
          }
          hl = true;
        }
      } catch (err) {}
      if (!hl) { var sel = getSelection(); sel.removeAllRanges(); sel.addRange(range); }
      var r = range.getBoundingClientRect();
      return { ok: true, top: r.top, vh: innerHeight, hl: hl, text: range.toString() };
    }
    """
}

/// Loads a page nobody sees, in a given profile, reads its text and closes it: link previews (LinkPreviewCard.swift).
/// One never-shown engine window holds at most two such pages at a time (at most four more wait; a fifth pushes out the
/// oldest waiting); it goes after a minute without work. Each page has a hard deadline past its load timeout, so a page
/// whose read never answers can't hold its place. A read no longer wanted (`cancel`) leaves the queue, or its page
/// closes. A page that tries to open others gets them closed, and its sound is muted. A page counts as a visit of that
/// site in the engine's own history and keeps the cookies it sets, as opening it would; Airc's own history, sidebar
/// and session never hold it.
final class HiddenPageReader: NSObject, EngineWindowDelegate, EngineTabDelegate {
    static let shared = HiddenPageReader()
    /// How long a page may load before what it has is read anyway (scripted checks shorten it).
    static var loadTimeout: TimeInterval = 8
    /// How long past `loadTimeout` its read may take before the page is given up.
    static let readTimeout: TimeInterval = 4
    static let concurrent = 2
    static let maxWaiting = 4

    private struct Job {
        let id: Int
        let url: URL
        let profile: EngineProfile
        let profileID: String
        let cap: Int
        let done: (PageText?) -> Void
    }
    private final class Load {
        let tab: EngineTab
        let job: Job
        let deadline: Date
        let hardDeadline: Date
        var reading = false
        var finished = false
        var settledAt: Date?
        init(tab: EngineTab, job: Job, deadline: Date) {
            self.tab = tab
            self.job = job
            self.deadline = deadline
            hardDeadline = deadline.addingTimeInterval(HiddenPageReader.readTimeout)
        }
    }
    private var queue: [Job] = []
    private var loads: [Load] = []
    private var window: EngineWindow?
    private var timer: Timer?
    private var idleClose: DispatchWorkItem?
    private var nextID = 0
    /// Pages loaded since launch, for the scripted checks (a count: no addresses kept).
    private(set) var loadCount = 0

    var isWorking: Bool { !loads.isEmpty || !queue.isEmpty }

    /// Reads `url` in a profile; `completion` gets its text, or nil, once. Returns the read's ID for `cancel`.
    @discardableResult
    func read(_ url: URL, profile: EngineProfile, profileID: String = "", cap: Int, completion: @escaping (PageText?) -> Void) -> Int {
        nextID += 1
        queue.append(Job(id: nextID, url: url, profile: profile, profileID: profileID, cap: cap, done: completion))
        while queue.count > Self.maxWaiting + max(0, Self.concurrent - loads.count) { queue.removeFirst().done(nil) }
        pump()
        return nextID
    }

    /// A read no longer wanted: out of the queue, or its page closed. Its completion gets nil (if it hasn't answered).
    func cancel(_ id: Int) {
        if let i = queue.firstIndex(where: { $0.id == id }) { return queue.remove(at: i).done(nil) }
        if let l = loads.first(where: { $0.job.id == id }) { finish(l, nil) }
    }

    /// A profile's data cleared or the profile deleted: its reads stop.
    func cancel(profileID: String) {
        let gone = queue.filter { $0.profileID == profileID }
        queue.removeAll { $0.profileID == profileID }
        gone.forEach { $0.done(nil) }
        for l in loads where l.job.profileID == profileID { finish(l, nil) }
    }

    /// Stops everything (the setting turned off): pending reads answer nil, the pages close.
    func cancelAll() {
        let pending = queue
        queue = []
        pending.forEach { $0.done(nil) }
        for l in loads { finish(l, nil) }
        closeWindow()
    }

    private func pump() {
        idleClose?.cancel()
        while loads.count < Self.concurrent, !queue.isEmpty {
            let job = queue.removeFirst()
            guard let w = engineWindow() else { job.done(nil); continue }
            let tab = w.openTab(url: job.url, profile: job.profile, foreground: false)
            tab.isMuted = true
            tab.delegate = self
            loadCount += 1
            loads.append(Load(tab: tab, job: job, deadline: Date().addingTimeInterval(Self.loadTimeout)))
        }
        guard !loads.isEmpty else { return scheduleIdleClose() }
        // Loading callbacks for a page nobody shows aren't guaranteed on every engine: look every quarter second too.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func engineWindow() -> EngineWindow? {
        if let window { return window }
        guard let engine = (NSApp.delegate as? AppDelegate)?.engine else { return nil }
        // Never shown: nothing is drawn and nothing takes focus.
        let w = engine.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768))
        w.delegate = self
        window = w
        return w
    }

    private func tick() {
        let now = Date()
        for l in loads where !l.finished {
            // A read that never answered (an engine without its own script timeout): the page is given up.
            if now > l.hardDeadline { finish(l, nil); continue }
            check(l)
        }
    }

    private func check(_ l: Load) {
        guard !l.reading, !l.finished else { return }
        let now = Date()
        let late = now > l.deadline
        let url = l.tab.url?.absoluteString ?? ""
        guard late || (!l.tab.isLoading && !url.isEmpty && url != "about:blank") else { return }
        // A moment after loading ends, for the page's own scripts to put in their text.
        if !late {
            if l.settledAt == nil { l.settledAt = now; return }
            if now.timeIntervalSince(l.settledAt!) < 0.4 { return }
        }
        l.reading = true
        PageReader.read(l.tab, cap: l.job.cap) { [weak self] page in
            guard let self else { return }
            if page == nil, !late {
                l.reading = false   // not ready yet: look again until the deadline
                return
            }
            self.finish(l, page)
        }
    }

    private func finish(_ l: Load, _ page: PageText?) {
        guard !l.finished else { return }
        l.finished = true
        loads.removeAll { $0 === l }
        l.tab.delegate = nil
        l.tab.close()
        l.job.done(page)
        if loads.isEmpty { timer?.invalidate(); timer = nil }
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }

    private func scheduleIdleClose() {
        idleClose?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isWorking else { return }
            self.closeWindow()
        }
        idleClose = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    private func closeWindow() {
        timer?.invalidate()
        timer = nil
        window?.window.orderOut(nil)
        window = nil
    }

    // MARK: Engine callbacks

    func tabDidChangeLoading(_ t: EngineTab) {
        if let l = loads.first(where: { $0.tab === t }) { check(l) }
    }
    func tabDidChangeURL(_ tab: EngineTab) {}
    func tabDidChangeTitle(_ tab: EngineTab) {}
    func tabDidChangeFavicon(_ tab: EngineTab) {}
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}

    // The page opens nothing; anything it tries is closed.
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) { tab.close() }
    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        if let l = loads.first(where: { $0.tab === tab }) { finish(l, nil) }
    }
    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}
}
