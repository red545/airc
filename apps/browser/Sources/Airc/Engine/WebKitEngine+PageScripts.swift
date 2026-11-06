// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

// The page script on the dev engine: a WKUserScript at document start in the page's world, top frame only (as Boosts
// need), in every profile's user content controller. `post` is a script message handler; `callPage` calls the
// `receive` the script returned. Unlike Chromium, the page can see the handler and `receive` (WebKit has no hidden
// main-world channel), so a page could only post as itself: the site still comes from WebKit's frame origin.
extension WebKitEngine: EnginePageScripts {
    var existingPageScript: String? { nil }

    func setPageScript(_ source: String?) { WebKitPageScripts.shared.setSource(source) }

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

    func executeScript(_ code: String, in tab: EngineTab, frame: String?) {
        (tab as? WebKitTab)?.webView.evaluateJavaScript(code, completionHandler: nil)
    }
}

final class WebKitPageScripts: NSObject, WKScriptMessageHandler {
    static let shared = WebKitPageScripts()
    static let messageName = "aircPage"

    var handler: ((EngineTab, EnginePageMessage) -> Void)?
    private var script: WKUserScript?
    private final class Entry { weak var profile: WebKitProfile?; var installed: WKUserScript?; init(_ p: WebKitProfile) { profile = p } }
    private var entries: [Entry] = []

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
        entries.forEach(install)
    }

    /// WebKit can't remove one user script: the others are put back around the new one.
    private func install(_ e: Entry) {
        guard let p = e.profile, e.installed !== script else { return }
        let uc = p.userContent
        let others = uc.userScripts.filter { $0 !== e.installed }
        uc.removeAllUserScripts()
        others.forEach(uc.addUserScript)
        if let script { uc.addUserScript(script) }
        e.installed = script
    }

    static func wrap(_ source: String) -> String {
        """
        (function () {
          var install = (\(source));
          if (typeof install !== 'function') return;
          var channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
          var post = function (kind, json) {
            try { channel.postMessage({ kind: String(kind), json: typeof json === 'string' ? json : 'null' }); } catch (e) {}
          };
          var receive = install(post);
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
        handler?(tab, EnginePageMessage(kind: kind, json: json, frame: message.frameInfo.isMainFrame ? "main" : "frame",
                                        isMainFrame: message.frameInfo.isMainFrame, origin: origin))
    }
}
