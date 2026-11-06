// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The engine's page script, composed from the app's named parts (the app's PageScripts; BoostPageScript is the
/// "boost" part): each part's install gets a `post` that prefixes its messages with the part's name ("boost.ready"),
/// and `receive("boost.apply", …)` reaches only that part. A script the engine had before the app set its own is kept
/// as the base and gets every other message unprefixed.
public enum PageScriptComposer {
    /// One install function that installs every part with its own prefixed `post` and routes `receive` by prefix. A
    /// part that throws doesn't stop the others. The receivers are in a map with no prototype, and `receive` routes with
    /// plain syntax (no method of a builtin): a page that replaces Object.prototype.hasOwnProperty or adds
    /// Object.prototype.boost can't make a part's message reach its own function. A part's message never goes to the
    /// base, even in a document where that part took nothing.
    public static func compose(parts: [(name: String, source: String)], base: String?) -> String? {
        guard !parts.isEmpty || base != nil else { return nil }
        let list = parts.map { "[\"\($0.name)\", (\($0.source))]" }.joined(separator: ",\n")
        return """
        (function () {
          var parts = [\(list)];
          var base = \(base.map { "(\($0))" } ?? "null");
          return function (post) {
            var receivers = { __proto__: null }, names = { __proto__: null }, baseReceive = null;
            function prefixed(name) { return function (kind, json) { return post(name + '.' + kind, json); }; }
            for (var i = 0; i < parts.length; i++) {
              var p = parts[i];
              names[p[0]] = true;
              try {
                var r = typeof p[1] === 'function' ? p[1](prefixed(p[0])) : null;
                if (typeof r === 'function') receivers[p[0]] = r;
              } catch (e) {}
            }
            if (typeof base === 'function') { try { var b = base(post); if (typeof b === 'function') baseReceive = b; } catch (e) {} }
            return function (kind, json) {
              if (typeof kind !== 'string') return;
              var name = '', rest = null;
              for (var k = 0; k < kind.length; k++) {
                if (rest !== null) rest += kind[k];
                else if (kind[k] === '.') rest = '';
                else name += kind[k];
              }
              try {
                if (rest !== null && name && names[name] === true) {
                  var r = receivers[name];
                  if (typeof r === 'function') r(rest, json);
                } else if (baseReceive) {
                  baseReceive(kind, json);
                }
              } catch (e) {}
            };
          };
        })()
        """
    }
}
