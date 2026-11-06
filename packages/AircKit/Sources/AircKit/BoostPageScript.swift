// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Boosts part of the engine's page script (BST-1). The engine runs it at document start in the top frame's main
/// world, before the page's own scripts. It carries the site → CSS map, so a Boost's style is there for the page's
/// first paint: no flash of the unboosted page. The style goes in constructed style sheets (`adoptedStyleSheets`): no
/// element for the page to remove, and a page's Content Security Policy doesn't block it.
///
/// The page never decides a site with a list of its own. The app keys each entry by its site (BoostDomain, the whole
/// public suffix list) and adds what the page needs to find it: `e` for a site that is one exact host, and `x`, the
/// list's rules under a site that make some of its subdomains other sites (usually none). The page takes its host, or
/// the longest entry its host ends in that neither rules out.
///
/// Custom JavaScript is not in the map, so no page ever holds another site's code. Every top-frame document says
/// "ready" with a token of its own; the app takes the site from the engine's committed origin of the frame (never from
/// the page), and sends only to that document (`EnginePageScripts.callDocument`: the same frame, still showing that
/// origin), with the token, which the page checks. The site's code goes to that frame only (`runner`), once per page
/// load, and runs only if the document still has that exact origin. Builtins are taken before the page's own scripts
/// run, so a page that changes prototypes can't intercept a message or see another document's.
///
/// Messages (the composer prefixes them with "boost."):
///   page → app  `ready {t: token (none from a document that isn't a website), v: the version of the style shown,
///               d: its site or null, restored: back from the back-forward cache}` · `zap {s: selector, l: label}` ·
///               `zapEnd {}` · `zapFailed {}`
///   app → page  `apply {t, v, d: site, g: generated CSS, c: custom CSS, f: has a filter}` · `zap {t, on: Bool}`
/// Top frame only for now: iframes are left as they are (docs/user/boosts.md).
public enum BoostPageScript {
    /// The page script part: an expression whose value is `function install(post)`, which returns
    /// `function receive(kind, json)`. `trustSynthetic` (test builds only) lets scripted checks zap with synthetic
    /// clicks; real builds only take the person's own clicks (`isTrusted`).
    public static func source(boosts: [Boost], version: Int, trustSynthetic: Bool = false,
                              suffixes list: PublicSuffixList? = nil) -> String {
        var map: [String: [String: Any]] = [:]
        let carried = boosts.filter { carries($0) }
        // The list is read only when there's a Boost to carry (the app loads it off the main thread at launch).
        let suffixes = carried.isEmpty ? PublicSuffixList(text: "") : list ?? .shared
        for b in carried {
            let g = BoostStyle.generated(for: b)
            let c = b.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : b.css
            var entry: [String: Any] = ["g": g, "c": c, "f": b.colors.hasFilter]
            if BoostDomain.isExactHost(b.domain, suffixes: suffixes) {
                entry["e"] = true
            } else {
                let beneath = BoostDomain.otherSitesBeneath(b.domain, suffixes: suffixes)
                if !beneath.isEmpty { entry["x"] = beneath }
            }
            map[b.domain] = entry
        }
        return runtime
            .replacingOccurrences(of: "%VERSION%", with: String(version))
            .replacingOccurrences(of: "%TRUST%", with: trustSynthetic ? "true" : "false")
            .replacingOccurrences(of: "%MAP%", with: json(map))
    }

    /// The page script carries a style for this Boost: one the page applies at document start.
    public static func carries(_ boost: Boost?) -> Bool {
        guard let boost, boost.isLive else { return false }
        return !BoostStyle.generated(for: boost).isEmpty || !boost.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The `apply` message for one document of a site after an edit (an off, held or missing Boost restores the page).
    public static func applyMessage(for boost: Boost?, domain: String, token: String, version: Int) -> String {
        var m: [String: Any] = ["t": token, "v": version, "d": domain, "g": "", "c": "", "f": false]
        if let boost, boost.isLive {
            m["g"] = BoostStyle.generated(for: boost)
            m["c"] = boost.css
            m["f"] = boost.colors.hasFilter
        }
        return json(m)
    }

    /// The `zap` message: Zap mode on or off in one document.
    public static func zapMessage(_ on: Bool, token: String) -> String { json(["t": token, "on": on]) }

    /// The person's own JavaScript for `domain`, wrapped to run once in the page it was sent to: only if that page is
    /// still the top frame with exactly `origin` (the engine's, as the app saw it: "https://www.example.com"), and after
    /// its document has been parsed. Run by the engine in the page's main world, like a script of the page (outside its
    /// Content Security Policy, as an extension's script would be).
    public static func runner(origin: String, domain: String, code: String, token: String) -> String {
        """
        (function () {
          if (window.top !== window || location.origin !== \(json(origin))) return;
          var key = '__aircBoostRan';
          if (window[key] === \(json(token))) return;
          try { Object.defineProperty(window, key, { value: \(json(token)), configurable: true }); } catch (e) { return; }
          var run = function () {
            try {
        \(code)
            } catch (e) { console.error('Airc Boost (' + \(json(domain)) + '):', e); }
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true });
          else run();
        })();
        """
    }

    /// JSON that is also a safe JavaScript literal (U+2028 and U+2029 escaped).
    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // The runtime. Builtins it uses after install are taken at install, before the page's scripts run, and called
    // uncurried: a page that later replaces Object.prototype.hasOwnProperty, Function.prototype.call or Array methods
    // can't intercept a message from the app (it could only spoil its own Boost anyway).
    static let runtime = #"""
    (function () {
      'use strict';
      var MAP = %MAP%;
      var VERSION = %VERSION%;
      var TRUST_SYNTHETIC = %TRUST%;
      return function install(post) {
        if (window.top !== window) return undefined;
        var uncurry = Function.prototype.bind.bind(Function.prototype.call);
        var own = uncurry(Object.prototype.hasOwnProperty);
        var parse = JSON.parse, stringify = JSON.stringify;
        var sliceA = uncurry(Array.prototype.slice), indexOf = uncurry(Array.prototype.indexOf);
        var concat = uncurry(Array.prototype.concat), splice = uncurry(Array.prototype.splice);
        var listen = uncurry(EventTarget.prototype.addEventListener), unlisten = uncurry(EventTarget.prototype.removeEventListener);
        function field(m, k) { return m !== null && typeof m === 'object' && own(m, k) ? m[k] : undefined; }

        // This document's token: the app sends it back with every message for this document, and nothing else has it.
        var TOKEN = '';
        try {
          var bits = new Uint32Array(4);
          crypto.getRandomValues(bits);
          for (var b = 0; b < 4; b++) TOKEN += bits[b].toString(36);
        } catch (e) {}
        if (!TOKEN) TOKEN = String(Math.random()).slice(2) + String(Date.now());

        // The site among the entries here (BoostDomain.key's answer, as the app built them): the host itself, or the
        // longest entry it ends in that isn't one exact host (`e`) and has no rule of the list beneath it (`x`) that the
        // host falls under.
        function beneath(labels, rules) {
          for (var i = 0; i < rules.length; i++) {
            var r = rules[i].charAt(0) === '!' ? rules[i].slice(1) : rules[i];
            var p = r.split('.');
            if (p.length > labels.length) continue;
            var hit = true;
            for (var j = 1; j <= p.length && hit; j++) hit = p[p.length - j] === '*' || p[p.length - j] === labels[labels.length - j];
            if (hit) return true;
          }
          return false;
        }
        function siteOf(host) {
          var h = String(host || '').toLowerCase();
          if (h.charAt(0) === '[' && h.charAt(h.length - 1) === ']') h = h.slice(1, -1);
          while (h.charAt(h.length - 1) === '.') h = h.slice(0, -1);
          if (!h) return null;
          if (own(MAP, h)) return h;
          if (h.indexOf(':') >= 0 || /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h)) return null;
          var l = h.split('.');
          if (l.indexOf('') >= 0) return null;
          for (var i = 1; i < l.length; i++) {
            var k = l.slice(i).join('.');
            if (!own(MAP, k)) continue;
            var m = MAP[k];
            if (field(m, 'e') === true) continue;
            var x = field(m, 'x');
            if (x && beneath(l, x)) continue;
            return k;
          }
          return null;
        }

        var protocol = location.protocol;
        var web = protocol === 'http:' || protocol === 'https:';
        var site = web ? siteOf(location.hostname) : null;
        var shownVersion = VERSION, shownSite = site;
        function ready(restored) {
          return '{"t":' + stringify(TOKEN) + ',"v":' + stringify(shownVersion) + ',"d":' + stringify(shownSite)
            + (restored ? ',"restored":true' : '') + '}';
        }
        // A document that isn't a website (blob:, data:, about:) says ready too, so the app forgets the one it
        // replaces. It has no token (a blob: document has its creator's origin, but nothing may be sent to it) and
        // takes nothing.
        if (!web) { post('ready', '{"v":' + stringify(VERSION) + ',"d":null}'); return undefined; }

        var doc = document, win = window;
        var Sheet = win.CSSStyleSheet;
        var replaceSync = Sheet && uncurry(Sheet.prototype.replaceSync);
        var insertRule = Sheet && uncurry(Sheet.prototype.insertRule);
        var adoptedDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'adoptedStyleSheets');
        var getAdopted = adoptedDesc && uncurry(adoptedDesc.get), setAdopted = adoptedDesc && uncurry(adoptedDesc.set);
        var getStyle = uncurry(win.getComputedStyle);
        var generated = null, custom = null, zapped = null, cursor = null, hasFilter = false;

        function sheet(text) { var s = new Sheet(); try { replaceSync(s, text || ''); } catch (e) {} return s; }
        function setText(s, text) { try { replaceSync(s, text || ''); } catch (e) {} }
        function adopt() {
          if (!getAdopted || !Sheet) return;
          var list = sliceA(getAdopted(doc)), missing = [], mine = [generated, custom, zapped, cursor];
          for (var i = 0; i < mine.length; i++) if (mine[i] && indexOf(list, mine[i]) < 0) missing[missing.length] = mine[i];
          if (missing.length) setAdopted(doc, concat(list, missing));
        }
        function unadopt(s) {
          if (!getAdopted || !s) return;
          var list = sliceA(getAdopted(doc));
          var i = indexOf(list, s);
          if (i >= 0) { splice(list, i, 1); setAdopted(doc, list); }
        }
        function setStyle(entry) {
          var g = field(entry, 'g') || '', c = field(entry, 'c') || '';
          hasFilter = field(entry, 'f') === true;
          if (!generated) {
            if (!g && !c) return;
            generated = sheet(''); custom = sheet('');
          }
          setText(generated, g);
          setText(custom, c);
          adopt();
        }
        // A filtered page whose background is only on <body>: the root's white (BoostStyle) takes the body's colour.
        function settle() {
          adopt();
          if (!hasFilter || !generated || !doc.body || !doc.documentElement) return;
          try {
            var root = getStyle(win, doc.documentElement).backgroundColor;
            var body = getStyle(win, doc.body).backgroundColor;
            if (root === 'rgb(255, 255, 255)' && body && body !== 'rgba(0, 0, 0, 0)' && body !== 'transparent' && body !== root) {
              insertRule(generated, ':where(html) { background-color: ' + body + '; }', generated.cssRules.length);
            }
          } catch (e) {}
        }

        setStyle(site ? MAP[site] : null);
        listen(doc, 'DOMContentLoaded', settle, true);
        listen(win, 'load', settle, true);

        // Zap: hover highlights an element, a click hides it and tells the app its selector.
        var zap = null;
        function trusted(e) { return e.isTrusted || TRUST_SYNTHETIC; }
        function looksGenerated(t) {
          return t.length > 40 || /\d{4,}/.test(t) || /(?:[a-z]+\d|\d+[a-z])[a-z\d]{2,}/i.test(t) ||
            /^(?:css|sc|jsx|svelte|emotion|styled)-/i.test(t) || /__[\w-]{5,}$/.test(t);
        }
        function esc(s) { return win.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^\w-]/g, '\\$&'); }
        function count(sel) { try { return doc.querySelectorAll(sel).length; } catch (e) { return -1; } }
        function part(el) {
          var id = el.getAttribute('id');
          if (id && !looksGenerated(id) && count('#' + esc(id)) === 1) return { s: '#' + esc(id), anchor: true };
          var tag = el.localName, s = esc(tag);
          var attrs = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-component', 'role'];
          for (var i = 0; i < attrs.length; i++) {
            var v = el.getAttribute(attrs[i]);
            if (v && v.length <= 60 && !looksGenerated(v)) { s += '[' + attrs[i] + '="' + v.replace(/["\\]/g, '\\$&') + '"]'; break; }
          }
          var classes = String(el.getAttribute('class') || '').split(/\s+/).filter(function (c) { return c && !looksGenerated(c); });
          for (var k = 0; k < classes.length && k < 2; k++) s += '.' + esc(classes[k]);
          var parent = el.parentElement;
          if (parent) {
            var same = 0, index = 0, alike = 0;
            for (var c = parent.firstElementChild; c; c = c.nextElementSibling) {
              if (c.localName === tag) { same++; if (c === el) index = same; }
              try { if (c.matches(s)) alike++; } catch (e) {}
            }
            if (same > 1 && alike > 1) s += ':nth-of-type(' + index + ')';
          }
          return { s: s, anchor: false };
        }
        function selectorFor(el) {
          var parts = [], node = el;
          while (node && node.nodeType === 1 && node !== doc.documentElement && parts.length < 12) {
            var p = part(node);
            parts.unshift(p.s);
            var sel = parts.join(' > ');
            if (count(sel) === 1 && doc.querySelector(sel) === el) return sel;
            if (p.anchor || node === doc.body) break;
            node = node.parentElement;
          }
          return null;
        }
        function labelFor(el) {
          var t = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || el.innerText || el.textContent || '';
          t = String(t).replace(/\s+/g, ' ').trim();
          return t.length > 60 ? t.slice(0, 59) + '\u2026' : t;
        }
        function zapStart() {
          if (zap || !doc.documentElement) return;
          var host = doc.createElement('airc-zap');
          host.setAttribute('style', 'all: initial !important; position: fixed !important; inset: 0 !important; pointer-events: none !important; z-index: 2147483647 !important; display: block !important;');
          var root = host.attachShadow({ mode: 'closed' });
          var box = doc.createElement('div');
          box.setAttribute('style', 'position: fixed; display: none; box-sizing: border-box; pointer-events: none; border: 2px solid #ff453a; border-radius: 4px; background: rgba(255, 69, 58, 0.16); transition: left 60ms, top 60ms, width 60ms, height 60ms;');
          var chip = doc.createElement('div');
          chip.setAttribute('style', 'position: absolute; left: -2px; top: -22px; padding: 2px 6px; border-radius: 5px; background: #ff453a; color: #fff; font: 600 11px/14px -apple-system, BlinkMacSystemFont, sans-serif; white-space: nowrap;');
          box.appendChild(chip);
          root.appendChild(box);
          doc.documentElement.appendChild(host);
          cursor = sheet('* { cursor: crosshair !important; }');
          adopt();
          var current = null;
          function target(e) {
            var t = e.target;
            while (t && t.nodeType !== 1) t = t.parentNode;
            return !t || t === host || t === doc.documentElement || t === doc.body ? null : t;
          }
          function show(el) {
            current = el;
            if (!el) { box.style.display = 'none'; return; }
            var r = el.getBoundingClientRect();
            box.style.display = 'block';
            box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
            box.style.width = Math.max(4, r.width) + 'px'; box.style.height = Math.max(4, r.height) + 'px';
            chip.style.top = r.top < 24 ? '2px' : '-22px';
            chip.textContent = el.localName + ' \u00b7 ' + Math.round(r.width) + ' \u00d7 ' + Math.round(r.height);
          }
          function move(e) { if (trusted(e)) show(target(e)); }
          function block(e) {
            if (!trusted(e) || (typeof e.button === 'number' && e.button !== 0 && e.type !== 'contextmenu')) return;
            e.preventDefault(); e.stopImmediatePropagation();
          }
          function click(e) {
            if (!trusted(e) || e.button !== 0) return;
            e.preventDefault(); e.stopImmediatePropagation();
            var el = target(e);
            if (el) hide(el);
          }
          function key(e) {
            if (!trusted(e) || e.key !== 'Escape') return;
            e.preventDefault(); e.stopImmediatePropagation();
            zapStop();
            post('zapEnd', '{}');
          }
          function scrolled() { if (current) show(current); }
          var on = [['mousemove', move], ['mouseover', move], ['pointerdown', block], ['mousedown', block], ['pointerup', block],
                    ['mouseup', block], ['click', click], ['auxclick', block], ['dblclick', block], ['keydown', key], ['scroll', scrolled]];
          for (var i = 0; i < on.length; i++) listen(win, on[i][0], on[i][1], true);
          zap = { host: host, on: on, show: show };
        }
        function zapStop() {
          if (!zap) return;
          for (var i = 0; i < zap.on.length; i++) unlisten(win, zap.on[i][0], zap.on[i][1], true);
          if (zap.host.parentNode) zap.host.parentNode.removeChild(zap.host);
          unadopt(cursor);
          cursor = null;
          zap = null;
        }
        function hide(el) {
          var s = selectorFor(el);
          if (!s) { post('zapFailed', '{}'); return; }
          if (!zapped) zapped = sheet('');
          try { insertRule(zapped, s + ' { display: none !important; }', zapped.cssRules.length); } catch (e) { post('zapFailed', '{}'); return; }
          adopt();
          if (zap) zap.show(null);
          post('zap', '{"s":' + stringify(s) + ',"l":' + stringify(labelFor(el)) + '}');
        }

        post('ready', ready(false));
        // Back from the back-forward cache: the same page load (its code doesn't run again), maybe an older style. A
        // prerendered page shown at last: the app ignored what it said while it was hidden.
        listen(win, 'pageshow', function (e) { if (e.persisted) post('ready', ready(true)); }, true);
        listen(doc, 'prerenderingchange', function () { post('ready', ready(false)); }, true);
        return function receive(kind, json) {
          var m = null;
          try { m = parse(json); } catch (e) {}
          // Only what the app sent this document: another document's token, or none, is dropped unread.
          if (field(m, 't') !== TOKEN) return;
          if (kind === 'apply') {
            // The app's CSS includes every zap it has stored: the local ones are folded into it.
            if (zapped) setText(zapped, '');
            setStyle(m);
            var v = field(m, 'v'), d = field(m, 'd');
            if (typeof v === 'number') shownVersion = v;
            shownSite = typeof d === 'string' && (field(m, 'g') || field(m, 'c')) ? d : null;
            if (doc.readyState !== 'loading') settle();
          } else if (kind === 'zap') {
            if (field(m, 'on') === true) zapStart(); else zapStop();
          }
        };
      };
    })()
    """#
}
