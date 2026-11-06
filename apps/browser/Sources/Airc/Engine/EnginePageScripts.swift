// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// The engine's page script (AircEngine.pageScript; a WKUserScript on the dev engine): one script the engine runs in
/// every page at document start, in the page's main world, before the page's own scripts. Its source is an
/// expression whose value is `function install(post)`; `post(kind, json)` reaches the app as an `EnginePageMessage`,
/// and the `function receive(kind, json)` that install returns gets `callPage`.
///
/// The app composes it from named parts (`PageScripts`): each part's messages carry its name as a prefix
/// ("boost.ready"), and `callPage(tab, "boost.apply", …)` reaches only that part. A script the engine already had
/// before the app set its own is kept as the base and still gets the messages without a prefix.
protocol EnginePageScripts: AnyObject {
    /// What the engine had before the app set its own (kept as the base of the composed script).
    var existingPageScript: String? { get }
    /// Replaces the script for documents created from now on (pages already open keep theirs; use `callPage`).
    func setPageScript(_ source: String?)
    /// A page's `post`, on the main thread.
    var pageMessageHandler: ((EngineTab, EnginePageMessage) -> Void)? { get set }
    /// Calls the top frame's `receive(kind, json)`.
    func callPage(_ tab: EngineTab, kind: String, json: String)
    /// Runs code in the page's main world: in `frame` (an EnginePageMessage frame) or the top frame.
    func executeScript(_ code: String, in tab: EngineTab, frame: String?)
}

struct EnginePageMessage {
    var kind: String
    var json: String
    /// The engine's ID of the frame that posted.
    var frame: String
    var isMainFrame: Bool
    /// The frame's origin as the engine committed it ("https://example.com"), not what the page says.
    var origin: String

    /// The origin's host.
    var host: String? { URL(string: origin)?.host }
}

/// The app's parts of the page script, composed into one source for the engine.
final class PageScripts {
    private weak var engine: EnginePageScripts?
    private var parts: [(name: String, source: String)] = []
    private var handlers: [String: (EngineTab, EnginePageMessage) -> Void] = [:]
    /// The engine's own script from before the app set one, kept as the base.
    private var base: String?
    private var pushScheduled = false

    static private(set) var shared: PageScripts?

    /// Takes over the engine's page script; `existing` is what the engine had (kept and composed with).
    static func start(engine: EnginePageScripts, existing: String?) -> PageScripts {
        if let shared { return shared }
        let s = PageScripts(engine: engine, base: existing)
        shared = s
        return s
    }

    private init(engine: EnginePageScripts, base: String?) {
        self.engine = engine
        self.base = base?.isEmpty == false ? base : nil
        engine.pageMessageHandler = { [weak self] tab, message in self?.route(tab, message) }
    }

    /// Adds or replaces the part `name` (letters only) and its message handler. The engine gets the new script a moment
    /// later, so a slider drag pushes a few times a second, not every frame (open pages get their changes directly).
    func set(_ name: String, source: String, handler: @escaping (EngineTab, EnginePageMessage) -> Void) {
        precondition(name.allSatisfy(\.isLetter), "part names are letters")
        handlers[name] = handler
        if let i = parts.firstIndex(where: { $0.name == name }) { parts[i].source = source } else { parts.append((name, source)) }
        schedulePush()
    }

    /// Pushes now (launch: before the first page opens).
    func pushNow() {
        pushScheduled = false
        engine?.setPageScript(Self.compose(parts: parts, base: base))
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.pushScheduled else { return }
            self.pushNow()
        }
    }

    func callPage(_ tab: EngineTab, part: String, kind: String, json: String) {
        engine?.callPage(tab, kind: part + "." + kind, json: json)
    }

    func executeScript(_ code: String, in tab: EngineTab, frame: String?) {
        engine?.executeScript(code, in: tab, frame: frame)
    }

    private func route(_ tab: EngineTab, _ message: EnginePageMessage) {
        guard let dot = message.kind.firstIndex(of: "."), let handler = handlers[String(message.kind[..<dot])] else { return }
        var m = message
        m.kind = String(message.kind[message.kind.index(after: dot)...])
        handler(tab, m)
    }

    /// One install function that installs every part with its own prefixed `post` and routes `receive` by prefix. A
    /// part that throws doesn't stop the others.
    static func compose(parts: [(name: String, source: String)], base: String?) -> String? {
        guard !parts.isEmpty || base != nil else { return nil }
        let list = parts.map { "[\"\($0.name)\", (\($0.source))]" }.joined(separator: ",\n")
        return """
        (function () {
          var parts = [\(list)];
          var base = \(base.map { "(\($0))" } ?? "null");
          return function (post) {
            var receivers = {}, baseReceive = null;
            parts.forEach(function (p) {
              try {
                var r = typeof p[1] === 'function' ? p[1](function (kind, json) { return post(p[0] + '.' + kind, json); }) : null;
                if (typeof r === 'function') receivers[p[0]] = r;
              } catch (e) {}
            });
            if (typeof base === 'function') { try { var b = base(post); if (typeof b === 'function') baseReceive = b; } catch (e) {} }
            return function (kind, json) {
              var dot = kind.indexOf('.'), r = dot > 0 && Object.prototype.hasOwnProperty.call(receivers, kind.slice(0, dot)) ? receivers[kind.slice(0, dot)] : null;
              try { if (r) r(kind.slice(dot + 1), json); else if (baseReceive) baseReceive(kind, json); } catch (e) {}
            };
          };
        })()
        """
    }
}
