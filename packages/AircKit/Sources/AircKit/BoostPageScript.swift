// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Boosts part of the engine's page script (BST-1). The engine runs it at document start in the main world of every
/// frame, before the page's own scripts. It carries the site → CSS map, so a Boost's style is there for the page's
/// first paint: no flash of the unboosted page. The style goes in constructed style sheets (`adoptedStyleSheets`): no
/// element for the page to remove, and a page's Content Security Policy doesn't block it.
///
/// The page never decides a site with a list of its own. The app keys each entry by its site (BoostDomain, the whole
/// public suffix list) and adds what the page needs to find it: `e` for a site that is one exact host, and `x`, the
/// list's rules under a site that make some of its subdomains other sites (usually none). The page takes its host, or
/// the longest entry its host ends in that neither rules out.
///
/// Frames (BST-3): a document in a frame takes its site's Boost only when the page around it is on the same site (the
/// page's origin from `location.ancestorOrigins`, which a page can't change), and then only what a frame adds itself
/// (`gf`: the font, letter case, zaps, custom CSS, and the invert its page takes back for frames; the page's filter and
/// tint already cover it). A frame of another site keeps its own look, whatever Boost its own site has: it's a part of
/// someone else's page. Custom JavaScript stays in the top frame.
///
/// Zap in frames (boosts3): Zap mode runs in the frames of the page's own site too (the app turns it on in each), and an
/// element zapped there is the frames' (`BoostZap.frame`: its selector was made in the frame's document). Any other
/// frame (another site's, or one with no web address) can only be zapped whole: while zapping it takes no pointer, and
/// the page picks it by where the pointer is.
///
/// Private windows (boosts3): the engine calls install with a third argument, `true`, in a private profile's
/// documents (PageScriptComposer); the part installs nothing there, as Arc's Boosts were off in Incognito. A private
/// window's top-frame web document says only `ready {private: true}` (no token, so nothing can be sent to it): Chromium's
/// private profile copies the regular profile's zoom per host, so the app puts back a Boost's size there.
///
/// `@import` in custom CSS (constructed sheets drop it): the runtime takes the leading `@import` rules out and loads
/// each into a sheet of its own, in order, before the rest of the CSS, with its media, `supports()` and `layer` around
/// it. Only `data:text/css` URLs and URLs of the document's own origin are loaded (fetched by the page itself, its
/// own credentials, no redirect to another origin, `text/css` only, 512 KB at most, 24 per document, 4 deep); any
/// other origin or scheme is refused unfetched and reported (`importFailed`). BoostCSSImports is the app's copy of the
/// same rule, for the editor.
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
///               d: its site or null, restored: back from the back-forward cache}` · `zap {s: selector, l: label, t}` ·
///               `zapEnd {t}` · `zapFailed {t}` (from frames too: `t` names the document) ·
///               `importFailed {u: the URL as written, w: why}` (top frame only)
///   app → page  `apply {t, v, d: site, g: generated CSS (the frame's, for a frame), c: custom CSS, f: has a filter}` ·
///               `zap {t, on: Bool}`
public enum BoostPageScript {
    /// The page script part: an expression whose value is `function install(post, data, isPrivate)`, which returns
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
            let gf = BoostStyle.generated(for: b, frame: true)
            let c = b.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : b.css
            var entry: [String: Any] = ["g": g, "c": c, "f": b.colors.hasFilter]
            if gf != g { entry["gf"] = gf }
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

    /// The `apply` message for one document of a site after an edit (an off, held or missing Boost restores the page);
    /// `frame`: for a document in a frame of a page on the same site.
    public static func applyMessage(for boost: Boost?, domain: String, token: String, version: Int, frame: Bool = false) -> String {
        var m: [String: Any] = ["t": token, "v": version, "d": domain, "g": "", "c": "", "f": false]
        if let boost, boost.isLive {
            m["g"] = BoostStyle.generated(for: boost, frame: frame)
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
      return function install(post, data, isPrivate) {
        // A private window's document: no style, no token, nothing to receive. Its top frame says it's there, so the app
        // can put back a Boost's size that Chromium's private profile copied (the zoom is per host).
        if (isPrivate === true) {
          var p = location.protocol;
          if (window.top === window && (p === 'http:' || p === 'https:')) post('ready', '{"private":true}');
          return undefined;
        }
        var TOP = window.top === window;
        var uncurry = Function.prototype.bind.bind(Function.prototype.call);
        var own = uncurry(Object.prototype.hasOwnProperty);
        var parse = JSON.parse, stringify = JSON.stringify;
        var sliceA = uncurry(Array.prototype.slice), indexOf = uncurry(Array.prototype.indexOf);
        var concat = uncurry(Array.prototype.concat), splice = uncurry(Array.prototype.splice);
        var listen = uncurry(EventTarget.prototype.addEventListener), unlisten = uncurry(EventTarget.prototype.removeEventListener);
        var strSlice = uncurry(String.prototype.slice), lower = uncurry(String.prototype.toLowerCase);
        var charAt = uncurry(String.prototype.charAt), strIndexOf = uncurry(String.prototype.indexOf);
        var trim = uncurry(String.prototype.trim), test = uncurry(RegExp.prototype.test), exec = uncurry(RegExp.prototype.exec);
        var URLc = typeof URL === 'function' ? URL : null;
        var fetchF = typeof fetch === 'function' ? fetch : null;
        var resText = typeof Response === 'function' ? uncurry(Response.prototype.text) : null;
        var getHeader = typeof Headers === 'function' ? uncurry(Headers.prototype.get) : null;
        var then = typeof Promise === 'function' ? uncurry(Promise.prototype.then) : null;
        var atobF = typeof atob === 'function' ? atob : null;
        var Decoder = typeof TextDecoder === 'function' ? TextDecoder : null;
        var decodeURI = decodeURIComponent;
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
        var origin = String(location.origin);
        var site = web ? siteOf(location.hostname) : null;
        if (!TOP) {
          // A frame: only a website whose page (the outermost origin in ancestorOrigins) is on its site. A frame of the
          // page's own origin says ready even without a Boost yet, so one made while it's open reaches it.
          if (!web) return undefined;
          var anc = location.ancestorOrigins, pageOrigin = anc && anc.length ? String(anc[anc.length - 1]) : '';
          var hm = /^https?:\/\/(\[[^\]]+\]|[^:\/\[\]]+)(?::\d+)?$/.exec(pageOrigin);
          var pageSite = hm ? siteOf(hm[1]) : null;
          if (site !== null ? pageSite !== site : !hm || pageOrigin !== origin) return undefined;
        }
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
        var srcDesc = win.HTMLIFrameElement && Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src');
        var frameSrc = srcDesc && srcDesc.get ? uncurry(srcDesc.get) : function (f) { return f.src; };
        var byTag = uncurry(Document.prototype.getElementsByTagName);
        var every = win.setInterval, stopEvery = win.clearInterval;
        var generated = null, custom = null, zapped = null, cursor = null, hasFilter = false;
        // Every sheet this part made, and the imports' tree: each node's own sheet comes after the sheets it imports.
        var made = [], imports = { kids: [], sheet: null }, customText = null, importCount = 0, reported = { __proto__: null };
        // What the imports reported before this document said ready (the app knows no document until then).
        var readySaid = false, held = [];

        function sheet(text, base) {
          var s = null;
          if (base) { try { s = new Sheet({ baseURL: base }); } catch (e) { s = null; } }
          if (!s) s = new Sheet();
          try { replaceSync(s, text || ''); } catch (e) {}
          made[made.length] = s;
          return s;
        }
        function setText(s, text) { try { replaceSync(s, text || ''); } catch (e) {} }
        function flatten(node, out) {
          for (var i = 0; i < node.kids.length; i++) flatten(node.kids[i], out);
          if (node.sheet) out[out.length] = node.sheet;
        }
        // The page's own adopted sheets first, then this part's, in their order: the generated style, the imports, the
        // custom CSS, the zaps, Zap's cursor.
        function adopt() {
          if (!getAdopted || !Sheet || !generated) return;
          var list = sliceA(getAdopted(doc)), next = [], i;
          for (i = 0; i < list.length; i++) if (indexOf(made, list[i]) < 0) next[next.length] = list[i];
          var mine = [generated];
          flatten(imports, mine);
          mine[mine.length] = custom;
          if (zapped) mine[mine.length] = zapped;
          if (cursor) mine[mine.length] = cursor;
          next = concat(next, mine);
          if (next.length === list.length) {
            var same = true;
            for (i = 0; i < next.length && same; i++) same = next[i] === list[i];
            if (same) return;
          }
          setAdopted(doc, next);
        }

        // MARK: @import (see the header): the leading rules, as the CSS syntax has them.
        function skipSpace(t, i) {
          for (;;) {
            var ch = charAt(t, i);
            if (ch === ' ' || ch === '\n' || ch === '\t' || ch === '\r' || ch === '\f') { i++; continue; }
            if (ch === '/' && charAt(t, i + 1) === '*') { var e = strIndexOf(t, '*/', i + 2); i = e < 0 ? t.length : e + 2; continue; }
            return i;
          }
        }
        // A quoted string from `i` (its quote): [value, index after it].
        function quoted(t, i) {
          var q = charAt(t, i), v = '';
          for (i++; i < t.length; i++) {
            var ch = charAt(t, i);
            if (ch === '\\') { i++; v += charAt(t, i); continue; }
            if (ch === q) return [v, i + 1];
            if (ch === '\n') return null;
            v += ch;
          }
          return null;
        }
        // The text up to the bracket that closes the one before `i`: [inside, index after it].
        function balanced(t, i) {
          var depth = 1, start = i;
          for (; i < t.length; i++) {
            var ch = charAt(t, i);
            if (ch === '"' || ch === "'") { var q = quoted(t, i); if (!q) return null; i = q[1] - 1; continue; }
            if (ch === '(') depth++;
            else if (ch === ')' && --depth === 0) return [strSlice(t, start, i), i + 1];
          }
          return null;
        }
        // {list: [{u, l: layer (null, '' or a name), s: supports or null, m: media or null}], rest}
        function splitImports(t) {
          var list = [], i = 0, ch;
          for (;;) {
            i = skipSpace(t, i);
            var head = lower(strSlice(t, i, i + 8));
            if (head === '@charset') {
              var sc = strIndexOf(t, ';', i);
              if (sc < 0) break;
              i = sc + 1;
              continue;
            }
            if (strSlice(head, 0, 7) !== '@import') break;
            var j = skipSpace(t, i + 7), url = null, at;
            ch = charAt(t, j);
            if (ch === '"' || ch === "'") {
              at = quoted(t, j);
              if (!at) break;
              url = at[0]; j = at[1];
            } else if (lower(strSlice(t, j, j + 4)) === 'url(') {
              var k = skipSpace(t, j + 4);
              ch = charAt(t, k);
              if (ch === '"' || ch === "'") {
                at = quoted(t, k);
                if (!at) break;
                url = at[0]; k = skipSpace(t, at[1]);
                if (charAt(t, k) !== ')') break;
                j = k + 1;
              } else {
                var close = strIndexOf(t, ')', k);
                if (close < 0) break;
                url = trim(strSlice(t, k, close)); j = close + 1;
              }
            } else break;
            // The rest of the rule, to its semicolon.
            var end = j, depth = 0;
            for (; end < t.length; end++) {
              ch = charAt(t, end);
              if (ch === '"' || ch === "'") { var qq = quoted(t, end); if (!qq) { end = t.length; break; } end = qq[1] - 1; continue; }
              if (ch === '(') depth++;
              else if (ch === ')') depth--;
              else if ((ch === ';' && depth <= 0) || ch === '{') break;
            }
            if (charAt(t, end) === '{') break;
            var pre = trim(strSlice(t, j, end)), layer = null, supports = null, b;
            if (test(/^layer\s*\(/i, pre)) {
              b = balanced(pre, strIndexOf(pre, '(') + 1);
              if (!b) break;
              layer = trim(b[0]); pre = trim(strSlice(pre, b[1]));
            } else if (test(/^layer(?![\w-])/i, pre)) { layer = ''; pre = trim(strSlice(pre, 5)); }
            if (test(/^supports\s*\(/i, pre)) {
              b = balanced(pre, strIndexOf(pre, '(') + 1);
              if (!b) break;
              supports = trim(b[0]); pre = trim(strSlice(pre, b[1]));
            }
            list[list.length] = { u: url, l: layer, s: supports, m: pre || null };
            i = end + 1;
          }
          return { list: list, rest: strSlice(t, i) };
        }
        function wrap(text, imp) {
          if (imp.m !== null) text = '@media ' + imp.m + ' {\n' + text + '\n}';
          if (imp.s !== null) text = '@supports (' + imp.s + ') {\n' + text + '\n}';
          if (imp.l !== null) text = '@layer' + (imp.l ? ' ' + imp.l : '') + ' {\n' + text + '\n}';
          return text;
        }
        function refuse(u, why) {
          if (!TOP || reported[u]) return;
          reported[u] = true;
          var m = '{"u":' + stringify(String(u).slice(0, 300)) + ',"w":' + stringify(why) + '}';
          if (readySaid) post('importFailed', m); else held[held.length] = m;
        }
        // data:text/css (plain or base64), as text; null when it isn't one.
        function dataCSS(u) {
          var comma = strIndexOf(u, ',');
          if (comma < 0) return null;
          var meta = lower(trim(strSlice(u, 5, comma))), body = strSlice(u, comma + 1);
          var base64 = test(/;\s*base64$/, meta);
          if (base64) meta = strSlice(meta, 0, meta.lastIndexOf(';'));
          if (!test(/^text\/css(\s*;\s*charset\s*=\s*"?utf-8"?)?$/, trim(meta))) return null;
          try {
            if (!base64) return decodeURI(body);
            var bin = atobF(body), bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            return Decoder ? new Decoder('utf-8').decode(bytes) : decodeURI(escape(bin));
          } catch (e) { return null; }
        }
        var LIMIT = 512 * 1024;
        // Loads `text`'s imports (relative to `base`) under `node`, then the text itself; `wrappers` are the outer imports'.
        function load(node, text, base, depth, wrappers) {
          var split = splitImports(text);
          for (var i = 0; i < split.list.length; i++) {
            var imp = split.list[i], kid = { kids: [], sheet: null };
            node.kids[node.kids.length] = kid;
            fetchImport(kid, imp, base, depth + 1, concat([imp], wrappers));
          }
          return split.rest;
        }
        function place(node, text, base, wrappers) {
          for (var w = 0; w < wrappers.length; w++) text = wrap(text, wrappers[w]);
          node.sheet = sheet(text, base);
          adopt();
        }
        function fetchImport(node, imp, base, depth, wrappers) {
          var u = String(imp.u || '');
          if (depth > 4 || ++importCount > 24) return refuse(u, 'limit');
          if (lower(strSlice(trim(u), 0, 5)) === 'data:') {
            var css = dataCSS(trim(u));
            if (css === null) return refuse(u, 'data');
            if (css.length > LIMIT) return refuse(u, 'size');
            // A data: sheet has no address of its own: what it imports is resolved against the document's.
            var restD = load(node, css, base, depth, wrappers);
            return place(node, restD, null, wrappers);
          }
          var target = null;
          try { target = URLc ? new URLc(u, base) : null; } catch (e) { target = null; }
          if (!target) return refuse(u, 'address');
          if (target.protocol !== 'http:' && target.protocol !== 'https:') return refuse(u, 'scheme');
          if (target.origin !== origin) return refuse(u, 'origin');
          if (!fetchF || !then || !resText) return refuse(u, 'blocked');
          var href = target.href;
          var request;
          try { request = fetchF(href, { credentials: 'same-origin', mode: 'same-origin', redirect: 'follow', cache: 'default' }); }
          catch (e) { return refuse(u, 'blocked'); }
          then(request, function (res) {
            var type = getHeader && res.headers ? lower(String(getHeader(res.headers, 'content-type') || '')) : '';
            if (!res.ok) return refuse(u, 'status');
            if (strIndexOf(type, 'text/css') !== 0) return refuse(u, 'type');
            then(resText(res), function (body) {
              if (body.length > LIMIT) return refuse(u, 'size');
              var restU = load(node, body, href, depth, wrappers);
              place(node, restU, href, wrappers);
            }, function () { refuse(u, 'blocked'); });
          }, function () { refuse(u, 'blocked'); });
        }
        function setCustom(c) {
          if (c === customText) return;
          customText = c;
          imports = { kids: [], sheet: null };
          importCount = 0;
          var rest = c ? load(imports, c, String(location.href), 0, []) : '';
          setText(custom, rest);
        }

        function setStyle(entry, fromMap) {
          var g = field(entry, 'g') || '', c = field(entry, 'c') || '';
          if (fromMap && !TOP && field(entry, 'gf') !== undefined) g = field(entry, 'gf') || '';
          hasFilter = field(entry, 'f') === true;
          if (!generated) {
            if (!g && !c) return;
            generated = sheet(''); custom = sheet('');
          }
          setText(generated, g);
          setCustom(c);
          adopt();
        }
        // A filtered page whose background is only on <body>: the root's white (BoostStyle) takes the body's colour.
        function settle() {
          adopt();
          if (!TOP || !hasFilter || !generated || !doc.body || !doc.documentElement) return;
          try {
            var root = getStyle(win, doc.documentElement).backgroundColor;
            var body = getStyle(win, doc.body).backgroundColor;
            if (root === 'rgb(255, 255, 255)' && body && body !== 'rgba(0, 0, 0, 0)' && body !== 'transparent' && body !== root) {
              insertRule(generated, ':where(html) { background-color: ' + body + '; }', generated.cssRules.length);
            }
          } catch (e) {}
        }

        setStyle(site ? MAP[site] : null, true);
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
        // Arc's "Zap all related elements" (⌥-click): the element's kind by its tag and stable classes or test
        // attribute, without its place; only when that finds more than it (and not half the page).
        function relatedFor(el) {
          var tag = el.localName, s = esc(tag), base = s;
          var attrs = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-component'];
          for (var i = 0; i < attrs.length; i++) {
            var v = el.getAttribute(attrs[i]);
            if (v && v.length <= 60 && !looksGenerated(v)) { s += '[' + attrs[i] + '="' + v.replace(/["\\]/g, '\\$&') + '"]'; break; }
          }
          var classes = String(el.getAttribute('class') || '').split(/\s+/).filter(function (c) { return c && !looksGenerated(c); });
          for (var k = 0; k < classes.length && k < 2; k++) s += '.' + esc(classes[k]);
          if (s === base) return null;
          var n = count(s);
          return n > 1 && n <= 400 ? { s: s, n: n } : null;
        }
        function labelFor(el) {
          var t = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || el.innerText || el.textContent || '';
          t = String(t).replace(/\s+/g, ' ').trim();
          return t.length > 60 ? t.slice(0, 59) + '\u2026' : t;
        }
        // A frame the page leaves to Zap inside it: a web address of the page's own origin or site (the app turns Zap on
        // in its document). Any other frame is zapped whole from here.
        function zapsInside(f) {
          var src = '';
          try { src = String(frameSrc(f) || ''); } catch (e) {}
          var hm = exec(/^https?:\/\/(\[[^\]]+\]|[^:\/?#\[\]]+)(?::\d+)?(?:[\/?#]|$)/i, src);
          if (!hm) return false;
          var u = null;
          if (URLc) { try { u = new URLc(src); } catch (e) {} }
          if (u && String(u.origin) === origin) return true;
          return site !== null && siteOf(hm[1]) === site;
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
          if (!generated) { generated = sheet(''); custom = sheet(''); }
          cursor = sheet('* { cursor: crosshair !important; }');
          // The page's frames (top frame only): those of its own site keep the pointer (Zap runs inside them); every
          // other one takes none while zapping, and is found by where the pointer is. Looked at again every second,
          // for frames that come later.
          var outside = [];
          function framesNow() {
            if (!TOP || !cursor) return;
            var list = byTag(doc, 'iframe'), rules = '* { cursor: crosshair !important; }\niframe { pointer-events: none !important; }', next = [];
            for (var fi = 0; fi < list.length; fi++) {
              var f = list[fi], sel = zapsInside(f) ? selectorFor(f) : null;
              if (sel) rules += '\n' + sel + ' { pointer-events: auto !important; }';
              else next[next.length] = f;
            }
            outside = next;
            setText(cursor, rules);
          }
          framesNow();
          adopt();
          var timer = TOP ? every(framesNow, 1000) : null;
          var current = null;
          function outsideAt(x, y) {
            for (var oi = outside.length - 1; oi >= 0; oi--) {
              var f = outside[oi];
              if (!f.isConnected) continue;
              var r = f.getBoundingClientRect();
              if (r.width > 0 && r.height > 0 && x >= r.left && x < r.right && y >= r.top && y < r.bottom) return f;
            }
            return null;
          }
          function target(e) {
            if (TOP && typeof e.clientX === 'number') {
              var whole = outsideAt(e.clientX, e.clientY);
              if (whole) return whole;
            }
            var t = e.target;
            while (t && t.nodeType !== 1) t = t.parentNode;
            return !t || t === host || t === doc.documentElement || t === doc.body ? null : t;
          }
          var related = false;
          function show(el) {
            current = el;
            if (!el) { box.style.display = 'none'; return; }
            var kin = related ? relatedFor(el) : null;
            var r = el.getBoundingClientRect();
            box.style.display = 'block';
            box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
            box.style.width = Math.max(4, r.width) + 'px'; box.style.height = Math.max(4, r.height) + 'px';
            chip.style.top = r.top < 24 ? '2px' : '-22px';
            chip.textContent = kin ? el.localName + ' \u00b7 all ' + kin.n + ' like it'
              : el.localName + ' \u00b7 ' + Math.round(r.width) + ' \u00d7 ' + Math.round(r.height);
          }
          function move(e) { if (trusted(e)) { related = !!e.altKey; show(target(e)); } }
          function block(e) {
            if (!trusted(e) || (typeof e.button === 'number' && e.button !== 0 && e.type !== 'contextmenu')) return;
            e.preventDefault(); e.stopImmediatePropagation();
          }
          function click(e) {
            if (!trusted(e) || e.button !== 0) return;
            e.preventDefault(); e.stopImmediatePropagation();
            var el = target(e);
            if (el) hide(el, !!e.altKey);
          }
          function key(e) {
            if (trusted(e) && e.key === 'Alt') { related = e.type === 'keydown'; if (current) show(current); return; }
            if (!trusted(e) || e.key !== 'Escape' || e.type !== 'keydown') return;
            e.preventDefault(); e.stopImmediatePropagation();
            zapStop();
            post('zapEnd', '{"t":' + stringify(TOKEN) + '}');
          }
          function scrolled() { if (current) show(current); }
          // Into a frame that zaps itself: its own box shows there, this one goes.
          function left(e) {
            var r = e.relatedTarget;
            if (trusted(e) && r && r.localName === 'iframe' && indexOf(outside, r) < 0) show(null);
          }
          var on = [['mousemove', move], ['mouseover', move], ['mouseout', left], ['pointerdown', block], ['mousedown', block],
                    ['pointerup', block], ['mouseup', block], ['click', click], ['auxclick', block], ['dblclick', block],
                    ['keydown', key], ['keyup', key], ['scroll', scrolled]];
          for (var i = 0; i < on.length; i++) listen(win, on[i][0], on[i][1], true);
          zap = { host: host, on: on, show: show, timer: timer };
        }
        function zapStop() {
          if (!zap) return;
          if (zap.timer !== null) stopEvery(zap.timer);
          for (var i = 0; i < zap.on.length; i++) unlisten(win, zap.on[i][0], zap.on[i][1], true);
          if (zap.host.parentNode) zap.host.parentNode.removeChild(zap.host);
          cursor = null;
          adopt();
          zap = null;
        }
        function hide(el, all) {
          var kin = all ? relatedFor(el) : null;
          var s = kin ? kin.s : selectorFor(el);
          var failed = '{"t":' + stringify(TOKEN) + '}';
          if (!s) { post('zapFailed', failed); return; }
          if (!zapped) zapped = sheet('');
          try { insertRule(zapped, s + ' { display: none !important; }', zapped.cssRules.length); } catch (e) { post('zapFailed', failed); return; }
          adopt();
          if (zap) zap.show(null);
          var label = labelFor(el);
          // A frame zapped whole: where it comes from ("Frame from ads.example"), not its text, which isn't the page's.
          if (el.localName === 'iframe') {
            var fm = null;
            try { fm = exec(/^https?:\/\/([^\/?#]+)/i, String(frameSrc(el) || '')); } catch (e) {}
            label = fm ? 'Frame from ' + fm[1] : 'Frame';
          }
          if (kin) label = 'All ' + kin.n + ' like \u201c' + (label.length > 40 ? label.slice(0, 39) + '\u2026' : label || el.localName) + '\u201d';
          post('zap', '{"s":' + stringify(s) + ',"l":' + stringify(label) + ',"t":' + stringify(TOKEN) + '}');
        }

        post('ready', ready(false));
        readySaid = true;
        for (var hi = 0; hi < held.length; hi++) post('importFailed', held[hi]);
        held = [];
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
            setStyle(m, false);
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
