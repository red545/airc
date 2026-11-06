// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Boosts part of the engine's page script (BST-1). The engine runs it at document start in the top frame's main
/// world, before the page's own scripts. It carries the site → CSS map, so a Boost's style is there for the page's
/// first paint: no flash of the unboosted page. The style goes in constructed style sheets (`adoptedStyleSheets`): no
/// element for the page to remove, and a page's Content Security Policy doesn't block it.
///
/// Custom JavaScript is not in the map, so no page ever holds another site's code. The page says "ready" with its site,
/// and the app, which checks the site against the engine's own record of the frame's origin, sends that site's code to
/// that frame only (`runner`), once per page load.
///
/// Messages (the composer prefixes them with "boost."):
///   page → app  `ready {d: site, v: map version, restored: back from the back-forward cache}` · `zap {s: selector,
///               l: label}` · `zapEnd {}` · `zapFailed {}`
///   app → page  `apply {d: site, g: generated CSS, c: custom CSS, f: has a filter}` · `zap {on: Bool}`
/// Top frame only for now: iframes are left as they are (docs/user/boosts.md).
public enum BoostPageScript {
    /// The page script part: an expression whose value is `function install(post)`, which returns
    /// `function receive(kind, json)`. `trustSynthetic` (test builds only) lets scripted checks zap with synthetic
    /// clicks; real builds only take the person's own clicks (`isTrusted`).
    public static func source(boosts: [Boost], version: Int, trustSynthetic: Bool = false) -> String {
        var map: [String: [String: Any]] = [:]
        for b in boosts where b.enabled {
            let g = BoostStyle.generated(for: b)
            let c = b.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : b.css
            guard !g.isEmpty || !c.isEmpty else { continue }
            map[b.domain] = ["g": g, "c": c, "f": b.colors.hasFilter]
        }
        return runtime
            .replacingOccurrences(of: "%REGISTRABLE%", with: registrableFunction)
            .replacingOccurrences(of: "%VERSION%", with: String(version))
            .replacingOccurrences(of: "%TRUST%", with: trustSynthetic ? "true" : "false")
            .replacingOccurrences(of: "%MAP%", with: json(map))
    }

    /// The `apply` message for a site's open pages after an edit (an off or empty Boost restores the page).
    public static func applyMessage(for boost: Boost?, domain: String) -> String {
        guard let boost, boost.enabled else { return json(["d": domain, "g": "", "c": "", "f": false]) }
        return json(["d": domain, "g": BoostStyle.generated(for: boost), "c": boost.css, "f": boost.colors.hasFilter])
    }

    /// The person's own JavaScript for `domain`, wrapped to run once in the page it was sent to: only if that page is
    /// still on the same site, and after its document has been parsed. Run by the engine in the page's main world, like
    /// a script of the page (outside its Content Security Policy, as an extension's script would be).
    public static func runner(domain: String, code: String, token: String) -> String {
        """
        (function () {
          var site = (\(registrableFunction))(location.hostname);
          if (window.top !== window || site !== \(json(domain))) return;
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

    /// `function (host) → site`, the same rule as BoostDomain.key, with the same suffix list.
    public static let registrableFunction: String = """
        function (host) {
          var S = \(json(BoostDomain.multiLabelSuffixes.sorted()));
          var h = String(host || '').toLowerCase();
          if (h.charAt(0) === '[' && h.charAt(h.length - 1) === ']') h = h.slice(1, -1);
          while (h.charAt(h.length - 1) === '.') h = h.slice(0, -1);
          if (!h) return null;
          if (h.indexOf(':') >= 0 || /^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$/.test(h)) return h;
          var l = h.split('.');
          if (l.length < 2 || l.indexOf('') >= 0) return h;
          for (var n = Math.min(l.length, 3); n >= 2; n--) {
            var suffix = l.slice(l.length - n).join('.');
            if (S.indexOf(suffix) < 0) continue;
            return l.length === n ? suffix : l.slice(l.length - n - 1).join('.');
          }
          return l.slice(l.length - 2).join('.');
        }
        """

    /// JSON that is also a safe JavaScript literal (U+2028 and U+2029 escaped).
    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // The runtime. Builtins it uses later are taken at install, before the page's scripts run, so a page that
    // replaces them can't confuse it (it could only spoil its own Boost anyway).
    static let runtime = #"""
    (function () {
      'use strict';
      var MAP = %MAP%;
      var VERSION = %VERSION%;
      var TRUST_SYNTHETIC = %TRUST%;
      var registrable = (%REGISTRABLE%);
      return function install(post) {
        if (window.top !== window) return undefined;
        var protocol = location.protocol;
        if (protocol !== 'http:' && protocol !== 'https:') return undefined;
        var domain = registrable(location.hostname);
        if (!domain) return undefined;
        var doc = document, win = window;
        var Sheet = win.CSSStyleSheet;
        var replaceSync = Sheet && Sheet.prototype.replaceSync;
        var insertRule = Sheet && Sheet.prototype.insertRule;
        var adoptedDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'adoptedStyleSheets');
        var listen = EventTarget.prototype.addEventListener, unlisten = EventTarget.prototype.removeEventListener;
        var getStyle = win.getComputedStyle, stringify = JSON.stringify, parse = JSON.parse;
        var slice = Array.prototype.slice;
        var generated = null, custom = null, zapped = null, cursor = null, hasFilter = false;

        function sheet(text) { var s = new Sheet(); try { replaceSync.call(s, text || ''); } catch (e) {} return s; }
        function setText(s, text) { try { replaceSync.call(s, text || ''); } catch (e) {} }
        function adopt() {
          if (!adoptedDesc || !Sheet) return;
          var mine = [generated, custom, zapped, cursor].filter(function (s) { return !!s; });
          var list = slice.call(adoptedDesc.get.call(doc));
          var missing = mine.filter(function (s) { return list.indexOf(s) < 0; });
          if (missing.length) adoptedDesc.set.call(doc, list.concat(missing));
        }
        function unadopt(s) {
          if (!adoptedDesc || !s) return;
          var list = slice.call(adoptedDesc.get.call(doc));
          var i = list.indexOf(s);
          if (i >= 0) { list.splice(i, 1); adoptedDesc.set.call(doc, list); }
        }
        function setStyle(entry) {
          var g = entry && entry.g || '', c = entry && entry.c || '';
          hasFilter = !!(entry && entry.f);
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
            var root = getStyle.call(win, doc.documentElement).backgroundColor;
            var body = getStyle.call(win, doc.body).backgroundColor;
            if (root === 'rgb(255, 255, 255)' && body && body !== 'rgba(0, 0, 0, 0)' && body !== 'transparent' && body !== root) {
              insertRule.call(generated, ':where(html) { background-color: ' + body + '; }', generated.cssRules.length);
            }
          } catch (e) {}
        }

        setStyle(Object.prototype.hasOwnProperty.call(MAP, domain) ? MAP[domain] : null);
        listen.call(doc, 'DOMContentLoaded', settle, true);
        listen.call(win, 'load', settle, true);

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
          for (var i = 0; i < on.length; i++) listen.call(win, on[i][0], on[i][1], true);
          zap = { host: host, on: on, show: show };
        }
        function zapStop() {
          if (!zap) return;
          for (var i = 0; i < zap.on.length; i++) unlisten.call(win, zap.on[i][0], zap.on[i][1], true);
          if (zap.host.parentNode) zap.host.parentNode.removeChild(zap.host);
          unadopt(cursor);
          cursor = null;
          zap = null;
        }
        function hide(el) {
          var s = selectorFor(el);
          if (!s) { post('zapFailed', '{}'); return; }
          if (!zapped) zapped = sheet('');
          try { insertRule.call(zapped, s + ' { display: none !important; }', zapped.cssRules.length); } catch (e) { post('zapFailed', '{}'); return; }
          adopt();
          if (zap) zap.show(null);
          post('zap', stringify({ s: s, l: labelFor(el) }));
        }

        post('ready', stringify({ d: domain, v: VERSION }));
        // Back from the back-forward cache: the same page load (its code doesn't run again), maybe an older style.
        listen.call(win, 'pageshow', function (e) {
          if (e.persisted) post('ready', stringify({ d: domain, v: VERSION, restored: true }));
        }, true);
        return function receive(kind, json) {
          var m = null;
          try { m = parse(json); } catch (e) {}
          if (!m) return;
          if (kind === 'apply' && m.d === domain) {
            // The app's CSS includes every zap it has stored: the local ones are folded into it.
            if (zapped) setText(zapped, '');
            setStyle(m);
            if (doc.readyState !== 'loading') settle();
          } else if (kind === 'zap') {
            if (m.on) zapStart(); else zapStop();
          }
        };
      };
    })()
    """#
}
