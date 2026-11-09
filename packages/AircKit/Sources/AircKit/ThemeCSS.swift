// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Arc's page palette as CSS (P07, P05; research §4.2): the theme of a page's Space as custom properties on the page's
/// root, under Arc's own names, so a Boost or a page written for Arc reads the same values in Airc
/// (`var(--arc-palette-background)`). AircDesign's `ResolvedTheme.pagePalette` says what each colour is.
///
/// How a page gets them: the "theme" part of the engine's page script carries every Space's palette by a short key
/// (`key(_:)`: lowercase letters only, the engine's per-tab page data allows nothing else). A document whose tab's key
/// reaches it at document start (`install(post, data)`: the engine's per-tab page data, when the engine passes it)
/// adopts its palette before the page's own scripts run and before it paints. Every top-frame web document says `ready`
/// with a token of its own and the key it shows; the app sends `palette {t, k, c}` when the tab's Space has another
/// (no key at document start, a theme or appearance change, the tab moved to another Space or window). A document
/// with no Space (a private window, Little Arc) has none at all: nothing of a Space leaks into it.
///
/// The variables sit in a constructed style sheet under `:where(:root)`: nothing in the DOM for the page to see or
/// remove, untouched by its Content Security Policy, and a page's own `:root` value of the same name wins.
public enum ThemeCSS {
    /// The page script part's name (its messages: "theme.ready", "theme.palette").
    public static let part = "theme"

    /// One Space's palette as CSS values.
    public struct Palette: Equatable, Sendable {
        /// Arc's `--arc-palette-*` names with their values, in Arc's order.
        public var palette: [(name: String, value: String)]
        public var simple: String
        public var gradient: [String]
        public var overlay: [String]

        public init(palette: [(name: String, value: String)], simple: String, gradient: [String], overlay: [String]) {
            self.palette = palette
            self.simple = simple
            self.gradient = gradient
            self.overlay = overlay
        }

        public static func == (a: Palette, b: Palette) -> Bool {
            a.palette.map(\.name) == b.palette.map(\.name) && a.palette.map(\.value) == b.palette.map(\.value)
                && a.simple == b.simple && a.gradient == b.gradient && a.overlay == b.overlay
        }

        /// Every custom property, name → value, in the order they're written.
        public var variables: [(name: String, value: String)] {
            palette.map { ("--arc-palette-" + $0.name, $0.value) }
                + [("--arc-background-simple-color", simple)]
                + gradient.enumerated().map { ("--arc-background-gradient-color\($0.offset)", $0.element) }
                + overlay.enumerated().map { ("--arc-background-gradient-overlay-color\($0.offset)", $0.element) }
        }

        /// `:where(:root) { --arc-palette-background: #f4efe9; … }`
        public var css: String {
            ":where(:root) { " + variables.map { "\($0.name): \($0.value);" }.joined(separator: " ") + " }"
        }
    }

    /// A colour as CSS: `#rrggbb` when opaque, `rgba(r, g, b, a)` otherwise. Components are 0…1 (clamped).
    public static func color(red: Double, green: Double, blue: Double, alpha: Double = 1) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        if alpha >= 0.9995 { return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue)) }
        let a = (min(max(alpha, 0), 1) * 1000).rounded() / 1000
        return "rgba(\(byte(red)), \(byte(green)), \(byte(blue)), \(fmt(a)))"
    }

    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The key of the `n`th palette: lowercase letters only, at most 16 ("pa", "pb", … "pz", "pba", …).
    public static func key(_ n: Int) -> String {
        var n = max(0, n), s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(97 + n % 26))) + s
            n /= 26
        } while n > 0
        return "p" + s
    }

    /// A key the engine's per-tab page data can carry.
    public static func isKey(_ s: String) -> Bool {
        (1...16).contains(s.utf8.count) && s.utf8.allSatisfy { (97...122).contains($0) }
    }

    /// The page script part: `function install(post, data)`, with every Space's palette by key.
    public static func source(palettes: [String: Palette]) -> String {
        var map: [String: String] = [:]
        for (k, p) in palettes where isKey(k) { map[k] = p.css }
        return runtime.replacingOccurrences(of: "%MAP%", with: json(map))
    }

    /// The `palette` message for one document: `key` "" with `css` "" takes the palette away.
    public static func message(token: String, key: String, css: String) -> String {
        json(["t": token, "k": key, "c": css])
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // Builtins are taken at install, before the page's scripts run (BoostPageScript does the same).
    static let runtime = #"""
    (function () {
      'use strict';
      var MAP = %MAP%;
      return function install(post, data) {
        if (window.top !== window) return undefined;
        var protocol = location.protocol;
        if (protocol !== 'http:' && protocol !== 'https:') return undefined;
        var uncurry = Function.prototype.bind.bind(Function.prototype.call);
        var own = uncurry(Object.prototype.hasOwnProperty);
        var parse = JSON.parse, stringify = JSON.stringify;
        var sliceA = uncurry(Array.prototype.slice), indexOf = uncurry(Array.prototype.indexOf);
        var concat = uncurry(Array.prototype.concat), splice = uncurry(Array.prototype.splice);
        var listen = uncurry(EventTarget.prototype.addEventListener);
        var Sheet = window.CSSStyleSheet;
        var replaceSync = Sheet && uncurry(Sheet.prototype.replaceSync);
        var desc = Object.getOwnPropertyDescriptor(Document.prototype, 'adoptedStyleSheets');
        var getAdopted = desc && uncurry(desc.get), setAdopted = desc && uncurry(desc.set);
        var doc = document;
        function field(m, k) { return m !== null && typeof m === 'object' && own(m, k) ? m[k] : undefined; }
        var TOKEN = '';
        try {
          var bits = new Uint32Array(4);
          crypto.getRandomValues(bits);
          for (var b = 0; b < 4; b++) TOKEN += bits[b].toString(36);
        } catch (e) {}
        if (!TOKEN) TOKEN = String(Math.random()).slice(2) + String(Date.now());

        var sheet = null, shown = '';
        function show(key, css) {
          if (!getAdopted || !Sheet) return;
          if (!css) {
            if (sheet) {
              var list = sliceA(getAdopted(doc)), i = indexOf(list, sheet);
              if (i >= 0) { splice(list, i, 1); setAdopted(doc, list); }
              try { replaceSync(sheet, ''); } catch (e) {}
            }
            shown = '';
            return;
          }
          if (!sheet) sheet = new Sheet();
          try { replaceSync(sheet, css); } catch (e) { return; }
          var now = sliceA(getAdopted(doc));
          if (indexOf(now, sheet) < 0) setAdopted(doc, concat(now, [sheet]));
          shown = key;
        }
        // The engine's per-tab page data: this tab's key, at document start.
        var given = typeof data === 'string' && own(MAP, data) ? data : '';
        if (given) show(given, MAP[given]);
        function ready(restored) {
          return '{"t":' + stringify(TOKEN) + ',"k":' + stringify(shown) + ',"d":' + (typeof data === 'string' ? 'true' : 'false')
            + (restored ? ',"restored":true' : '') + '}';
        }
        post('ready', ready(false));
        // Back from the back-forward cache: its tab may be in another Space by now.
        listen(window, 'pageshow', function (e) { if (e.persisted) post('ready', ready(true)); }, true);
        return function receive(kind, json) {
          var m = null;
          try { m = parse(json); } catch (e) {}
          if (field(m, 't') !== TOKEN || kind !== 'palette') return;
          var k = field(m, 'k'), c = field(m, 'c');
          show(typeof k === 'string' ? k : '', typeof c === 'string' ? c : '');
        };
      };
    })()
    """#
}
