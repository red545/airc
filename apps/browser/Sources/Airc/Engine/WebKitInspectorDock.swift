// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

/// Web Inspector attached to the window it inspects, as in Safari: WebKit's own attach (`_WKInspector`'s `attach`, SPI
/// behind responds(to:)) puts the Inspector's page next to the web view in the page's host and shrinks the web view; the
/// Inspector's own dock buttons (bottom, right, separate window) and its splitter work as in Safari.
/// Airc remembers whether the person last kept it in its own window, and the side (when this WebKit says it), and makes
/// it follow the tab: a hidden page's Inspector is hidden with it.
enum WebKitInspectorDock {
    static let detachedKey = "DevTools.webKitDetached"
    static let sideKey = "DevTools.webKitAttachmentSide"

    static func inspector(_ tab: WebKitTab) -> NSObject? {
        guard tab.webView.responds(to: NSSelectorFromString("_inspector")) else { return nil }
        return tab.webView.value(forKey: "_inspector") as? NSObject
    }
    static func bool(_ object: NSObject, _ key: String) -> Bool? {
        object.responds(to: NSSelectorFromString(key)) ? (object.value(forKey: key) as? Bool) : nil
    }

    /// Before a show: the side the person last used (WebKit keeps it in the page's preferences, which Airc makes anew).
    static func prepare(_ tab: WebKitTab) {
        let prefs = tab.webView.configuration.preferences
        let set = NSSelectorFromString("_setInspectorAttachmentSide:")
        if let side = UserDefaults.standard.object(forKey: sideKey) as? Int, side >= 0, prefs.responds(to: set) {
            typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(prefs.method(for: set), to: Setter.self)(prefs, set, UInt(side))
        }
    }

    /// After a show: note its view once WebKit has put it next to the web view (WebKit attaches by itself when it can).
    /// If it opened in its own window instead, attach it, unless the person last chose its own window.
    static func attach(_ tab: WebKitTab) {
        guard let inspector = inspector(tab) else { return }
        let known = Set(siblings(of: tab).map(ObjectIdentifier.init))
        var attachedOnce = false
        let generation = tab.inspectorGeneration
        func find(_ tries: Int) {
            guard tab.inspectorGeneration == generation else { return }   // closed or shown again since
            if let v = siblings(of: tab).first(where: { !known.contains(ObjectIdentifier($0)) && !$0.isHidden })
                ?? siblings(of: tab).first(where: { $0 === tab.inspectorView }) {
                tab.inspectorView = v
                return
            }
            // Visible but not here after a moment: its own window.
            if tries <= 20, !attachedOnce, bool(inspector, "isVisible") == true, !UserDefaults.standard.bool(forKey: detachedKey),
               inspector.responds(to: NSSelectorFromString("attach")) {
                attachedOnce = true
                inspector.perform(NSSelectorFromString("attach"))
            }
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { find(tries - 1) } }
        }
        find(30)
    }

    /// WebKit's Inspector page views next to the web view (its own WKWebView subclass).
    static func siblings(of tab: WebKitTab) -> [WKWebView] {
        (tab.webView.superview?.subviews ?? []).compactMap { $0 as? WKWebView }
            .filter { $0 !== tab.webView && NSStringFromClass(type(of: $0)).contains("Inspector") }
    }

    /// Before a close: remember whether it was attached, and where.
    static func remember(_ tab: WebKitTab) {
        guard let inspector = inspector(tab), bool(inspector, "isVisible") == true else { return }
        // Attached means its page is next to the web view here; otherwise it was in its own window.
        let attached = tab.inspectorView.map { $0.superview != nil && $0.superview === tab.webView.superview } ?? !siblings(of: tab).isEmpty
        UserDefaults.standard.set(!attached, forKey: detachedKey)
        let prefs = tab.webView.configuration.preferences
        let get = NSSelectorFromString("_inspectorAttachmentSide")
        if prefs.responds(to: get) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
            UserDefaults.standard.set(Int(unsafeBitCast(prefs.method(for: get), to: Getter.self)(prefs, get)), forKey: sideKey)
        }
    }

    /// The Inspector shows only while its page does (another tab, another Space, a page out of its host hides it).
    static func follow(_ tabs: [WebKitTab]) {
        for tab in tabs {
            guard let v = tab.inspectorView, v.superview != nil else { continue }
            let hidden = tab.webView.isHidden || tab.webView.superview == nil || tab.webView.superview !== v.superview
            if v.isHidden != hidden { v.isHidden = hidden }
        }
    }
}
