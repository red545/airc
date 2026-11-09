// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

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
    /// Calls `receive(kind, json)` of one top-frame document: the one that posted from `frame` with `origin`, and only
    /// while the tab still shows a document of that origin in that frame. False when it doesn't (nothing is sent); true
    /// means sent, for that document if it's still there when it arrives (the page checks its token too).
    func callDocument(_ tab: EngineTab, frame: String, origin: String, kind: String, json: String) -> Bool
    /// Calls `receive(kind, json)` of the document in a frame below the top one (an EnginePageMessage `frame` with
    /// `isMainFrame` false), while that frame is still there; the page checks its token. False: nothing was sent.
    func callFrameDocument(_ tab: EngineTab, frame: String, origin: String, kind: String, json: String) -> Bool
    /// The parts that also run in frames below the top one, for an engine whose page script is the top frame's only
    /// (WebKit). Chromium runs its one page script in every frame already, so it ignores this.
    func setFramePageScript(_ source: String?)
    /// Runs code in the page's main world: in `frame` (an EnginePageMessage frame) or the top frame.
    func executeScript(_ code: String, in tab: EngineTab, frame: String?)
}

extension EnginePageScripts {
    func callFrameDocument(_ tab: EngineTab, frame: String, origin: String, kind: String, json: String) -> Bool { false }
    func setFramePageScript(_ source: String?) {}
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
    /// Parts that run in frames below the top one too (on WebKit, a second user script; BST-3: Boosts).
    private var frameParts: Set<String> = []
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
    func set(_ name: String, source: String, frames: Bool = false, handler: @escaping (EngineTab, EnginePageMessage) -> Void) {
        precondition(name.allSatisfy(\.isLetter), "part names are letters")
        handlers[name] = handler
        if frames { frameParts.insert(name) } else { frameParts.remove(name) }
        if let i = parts.firstIndex(where: { $0.name == name }) { parts[i].source = source } else { parts.append((name, source)) }
        schedulePush()
    }

    #if AIRC_TESTING
    func contains(_ name: String) -> Bool { parts.contains { $0.name == name } }
    #endif

    /// Existing documents can still have in-flight messages after their future-document part is removed.
    func remove(_ name: String, onLateMessage: ((EngineTab, EnginePageMessage) -> Void)? = nil) {
        parts.removeAll { $0.name == name }
        handlers[name] = onLateMessage
        schedulePush()
    }

    /// Install an enabled part into an already-open document, without reloading its form state.
    func installNow(_ name: String, in tab: EngineTab) {
        guard let part = parts.first(where: { $0.name == name }) else { return }
        let slot = "__aircInstall_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let code = "window.\(slot) = {name: '\(name)', install: (\(part.source))};"
        engine?.executeScript(Self.ignoreListed(code), in: tab, frame: nil)
        engine?.callPage(tab, kind: "__aircInstall", json: slot)
    }

    /// Ignore browser instrumentation while stepping. Attribution itself uses native Proxy forwarding,
    /// since a source map cannot recover callers omitted by Chromium's pre-inspector one-frame capture.
    /// Keep mapped and generated URLs distinct. Only browser instrumentation is mapped.
    static func ignoreListed(_ source: String) -> String {
        let map: [String: Any] = ["version": 3, "sources": ["airc://devmode/instrumentation.js"],
            "sourcesContent": [source], "names": [],
            "mappings": Array(repeating: "AAAA", count: source.components(separatedBy: "\n").count + 2).joined(separator: ";"),
            "x_google_ignoreList": [0], "ignoreList": [0]]
        let data = try! JSONSerialization.data(withJSONObject: map)
        return source + "\n//# sourceURL=airc-devmode.js\n//# sourceMappingURL=data:application/json;base64," + data.base64EncodedString() + "\n"
    }

    /// Pushes now (launch: before the first page opens).
    func pushNow() {
        pushScheduled = false
        let source = Self.compose(parts: parts, base: base)
        engine?.setPageScript(parts.contains { $0.name == "devmode" } ? source.map(Self.ignoreListed) : source)
        let inFrames = parts.filter { frameParts.contains($0.name) }
        engine?.setFramePageScript(inFrames.isEmpty ? nil : Self.compose(parts: inFrames, base: nil))

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

    /// `callDocument` for a part: false when the document is gone.
    func callDocument(_ tab: EngineTab, frame: String, origin: String, part: String, kind: String, json: String) -> Bool {
        engine?.callDocument(tab, frame: frame, origin: origin, kind: part + "." + kind, json: json) ?? false
    }

    /// `callFrameDocument` for a part: false when the frame is gone.
    func callFrameDocument(_ tab: EngineTab, frame: String, origin: String, part: String, kind: String, json: String) -> Bool {
        engine?.callFrameDocument(tab, frame: frame, origin: origin, kind: part + "." + kind, json: json) ?? false
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

    /// One install function for every part (AircKit's PageScriptComposer).
    static func compose(parts: [(name: String, source: String)], base: String?) -> String? {
        PageScriptComposer.compose(parts: parts, base: base)
    }
}

#if canImport(AircCore)
// Chromium: the frame ID is the engine's render frame host, and the origin its committed one, so a frame that has
// gone (a cross-site navigation, the back-forward cache) or shows another origin now gets nothing.
extension ChromiumEngine {
    func callDocument(_ tab: EngineTab, frame: String, origin: String, kind: String, json: String) -> Bool {
        if tab is WebKitTab { return WebKitPageScripts.shared.callDocument(tab, origin: origin, kind: kind, json: json) }
        guard let core = core(of: tab), core.committedOrigin == origin, core.hasLiveFrame(frame) else { return false }
        core.callFrame(frame, kind: kind, json: json)
        return true
    }

    /// A frame below the top one: the engine has no committed origin per frame here, so only a frame that's still live
    /// gets it; the document's token, made by that document, decides in the page.
    func callFrameDocument(_ tab: EngineTab, frame: String, origin: String, kind: String, json: String) -> Bool {
        if tab is WebKitTab { return WebKitPageScripts.shared.callFrameDocument(tab, frame: frame, origin: origin, kind: kind, json: json) }
        guard let core = core(of: tab), !frame.isEmpty, core.hasLiveFrame(frame) else { return false }
        core.callFrame(frame, kind: kind, json: json)
        return true
    }
}
#endif
