// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

// The page script on the dev engine: a WKUserScript at document start in the page's world, top frame only, in every
// profile's user content controller, and a second one for the parts that also run in frames below it (Boosts, BST-3),
// which skips the top frame. `post` is a script message handler; `callPage` calls the
// `receive` the script returned. Unlike Chromium, the page can see the handler and `receive` (WebKit has no hidden
// main-world channel), so a page could only post as itself: the site still comes from WebKit's frame origin. And
// `callDocument` checks the document's own origin (`location`, which a page can't redefine) before it calls anything
// the page could have replaced: a document of another origin never sees the message.
// A private session's profile gets the same scripts with install's third argument `true` (as the Chromium engine
// gives a private profile's processes, airc_page_script.cc): parts that stay out of private windows know it.
extension WebKitEngine: EnginePageScripts {
    var existingPageScript: String? { nil }

    func setPageScript(_ source: String?) { WebKitPageScripts.shared.setSource(source) }

    func setFramePageScript(_ source: String?) { WebKitPageScripts.shared.setFrameSource(source) }

    func callFrameDocument(_ tab: EngineTab, frame: String, origin: String, kind: String, json: String) -> Bool {
        WebKitPageScripts.shared.callFrameDocument(tab, frame: frame, origin: origin, kind: kind, json: json)
    }

    var pageMessageHandler: ((EngineTab, EnginePageMessage) -> Void)? {
        get { WebKitPageScripts.shared.handler }
        set { WebKitPageScripts.shared.handler = newValue }
    }

    func callPage(_ tab: EngineTab, kind: String, json: String) {
        guard let web = (tab as? WebKitTab)?.webView else { return }
        let args = (try? JSONSerialization.data(withJSONObject: [kind, json])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        web.evaluateJavaScript("(function (a) { var r = window.__aircPageReceive; if (typeof r === 'function') r(a[0], a[1]); })(\(args))",
                               completionHandler: nil)
    }

    func callDocument(_ tab: EngineTab, frame: String, origin: String, kind: String, json: String) -> Bool {
        WebKitPageScripts.shared.callDocument(tab, origin: origin, kind: kind, json: json)
    }

    func executeScript(_ code: String, in tab: EngineTab, frame: String?) {
        (tab as? WebKitTab)?.webView.evaluateJavaScript(code, completionHandler: nil)
    }
}

final class WebKitPageScripts: NSObject, WKScriptMessageHandler {
    static let shared = WebKitPageScripts()
    static let messageName = "aircPage"

    var handler: ((EngineTab, EnginePageMessage) -> Void)?
    private var script: WKUserScript?
    private var frameScript: WKUserScript?
    /// The same two for private sessions.
    private var privateScript: WKUserScript?
    private var privateFrameScript: WKUserScript?
    private final class Entry {
        weak var profile: WebKitProfile?
        var installed: WKUserScript?
        var installedFrames: WKUserScript?
        init(_ p: WebKitProfile) { profile = p }
    }
    private var entries: [Entry] = []
    /// Frames below the top one that posted lately, by the ID their message carried ("frame-12"): WebKit has no frame
    /// ID of its own to call back with, only the frame's info, which `evaluateJavaScript(_:in:in:)` takes.
    private struct Posted { weak var webView: WKWebView?; var info: WKFrameInfo }
    private var frames: [String: Posted] = [:]
    private var frameOrder: [String] = []
    private var lastFrame = 0

    /// Every profile, as it's made (WebKitProfile.init).
    func attach(_ profile: WebKitProfile) {
        entries = entries.filter { $0.profile != nil }
        let e = Entry(profile)
        entries.append(e)
        profile.userContent.add(self, name: Self.messageName)
        install(e)
    }

    func setSource(_ source: String?) {
        script = source.map {
            WKUserScript(source: Self.wrap($0), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        }
        privateScript = source.map {
            WKUserScript(source: Self.wrap($0, isPrivate: true), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        }
        entries.forEach(install)
    }

    /// The parts for frames below the top one (the top frame has them in `setSource`'s script).
    func setFrameSource(_ source: String?) {
        frameScript = source.map {
            WKUserScript(source: Self.wrap($0, framesOnly: true), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        }
        privateFrameScript = source.map {
            WKUserScript(source: Self.wrap($0, framesOnly: true, isPrivate: true), injectionTime: .atDocumentStart,
                         forMainFrameOnly: false, in: .page)
        }
        entries.forEach(install)
    }

    /// WebKit can't remove one user script: the others are put back around the new ones.
    private func install(_ e: Entry) {
        guard let p = e.profile else { return }
        let top = p.privateSession ? privateScript : script, frames = p.privateSession ? privateFrameScript : frameScript
        guard e.installed !== top || e.installedFrames !== frames else { return }
        let uc = p.userContent
        let others = uc.userScripts.filter { $0 !== e.installed && $0 !== e.installedFrames }
        uc.removeAllUserScripts()
        others.forEach(uc.addUserScript)
        if let top { uc.addUserScript(top) }
        if let frames { uc.addUserScript(frames) }
        e.installed = top
        e.installedFrames = frames
    }

    /// The top-frame document only if its origin (WebKit's `location.origin`, as `securityOrigin` gave it) is still
    /// `origin`, read before anything of the page's is touched. True: sent (WebKit evaluates in the page shown now).
    func callDocument(_ tab: EngineTab, origin: String, kind: String, json: String) -> Bool {
        guard let web = (tab as? WebKitTab)?.webView, !origin.isEmpty else { return false }
        let args = (try? JSONSerialization.data(withJSONObject: [origin, kind, json])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        web.evaluateJavaScript("""
            (function (a) { if (window.top !== window || location.origin !== a[0]) return; \
            var r = window.__aircPageReceive; if (typeof r === 'function') r(a[1], a[2]); })(\(args))
            """, completionHandler: nil)
        return true
    }

    /// The frame `id` (an EnginePageMessage frame of a frame below the top one) still holding a document of `origin`,
    /// checked in the frame before anything of the page's is touched.
    func callFrameDocument(_ tab: EngineTab, frame id: String, origin: String, kind: String, json: String) -> Bool {
        guard let web = (tab as? WebKitTab)?.webView, let posted = frames[id], posted.webView === web, !origin.isEmpty else { return false }
        let args = (try? JSONSerialization.data(withJSONObject: [origin, kind, json])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        web.evaluateJavaScript("""
            (function (a) { if (window.top === window || location.origin !== a[0]) return 0; \
            var r = window.__aircPageReceive; if (typeof r === 'function') r(a[1], a[2]); return 1; })(\(args))
            """, in: posted.info, in: .page) { result in
            if case .failure = result { self.frames[id] = nil }
        }
        return true
    }

    static func wrap(_ source: String, framesOnly: Bool = false, isPrivate: Bool = false) -> String {
        """
        (function () {
          \(framesOnly ? "if (window.top === window) return;" : "")
          var install = (\(source));
          if (typeof install !== 'function') return;
          var channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
          // Taken now, before the page's scripts: a page that replaces postMessage later doesn't see what's posted.
          var send = channel && Function.prototype.call.bind(channel.postMessage), str = String;
          var post = function (kind, json) {
            try { send(channel, { kind: str(kind), json: typeof json === 'string' ? json : 'null' }); } catch (e) {}
          };
          var receive = install(post, undefined, \(isPrivate ? "true" : "false"));
          if (typeof receive === 'function') Object.defineProperty(window, '__aircPageReceive', { value: receive, configurable: true });
        })();
        """
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String, let json = body["json"] as? String, let web = message.webView,
              let tab = entries.lazy.compactMap({ $0.profile?.router.tab(for: web) }).first else { return }
        let o = message.frameInfo.securityOrigin
        let origin = o.host.isEmpty ? "" : "\(o.protocol)://\(o.host.contains(":") ? "[\(o.host)]" : o.host)" + (o.port > 0 ? ":\(o.port)" : "")
        handler?(tab, EnginePageMessage(kind: kind, json: json, frame: message.frameInfo.isMainFrame ? "main" : remember(message.frameInfo, in: web),
                                        isMainFrame: message.frameInfo.isMainFrame, origin: origin))
    }

    /// An ID for a frame below the top one that just posted; the 200 most recent are kept.
    private func remember(_ info: WKFrameInfo, in web: WKWebView) -> String {
        lastFrame += 1
        let id = "frame-\(lastFrame)"
        frames[id] = Posted(webView: web, info: info)
        frameOrder.append(id)
        if frameOrder.count > 200 { frames[frameOrder.removeFirst()] = nil }
        return id
    }
}
