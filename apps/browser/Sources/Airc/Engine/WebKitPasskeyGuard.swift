// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

/// wkpasskeyquit: nothing a sign-in page starts by itself may get in the way of quitting, closing a tab or a window, or
/// going to another page (WebKit engine).
///
/// signinfix found that the real appleid.apple.com sign-in page, signed out, attached an empty sheet to the browser
/// window as it loaded, and that a quit was held while it was attached (15 s and more, then the check's bound; it
/// happens when Airc is not the active app, e.g. Quit from the Dock, and the sheet also stays through ⌘W and a new
/// address in that tab). It is not a passkey request: WebKit's Extensible SSO (AppSSO) hands that page's loads to macOS's "Sign In With Apple" SSO
/// extension, whose UI (AppSSOUI's SOUIAuthorizationViewController, a remote ViewBridge view) WebKit attaches as a
/// sheet. In Airc it stays an empty dark panel, and during a quit a second remote sheet hangs on it. Passkey autofill
/// is not involved: without Apple's browser passkey capability (engine/PASSKEYS.md) WebKit answers
/// `isConditionalMediationAvailable()` with false and rejects a conditional request at once, with no UI.
///
/// - **Sign In With Apple's SSO extension is ignored** (`ssoPolicy`): the page shows its own web sign-in form, which
///   works. Every other SSO extension (an employer's Okta, Microsoft or Kerberos sign-in on a managed Mac) keeps
///   WebKit's own policy.
/// - **A system sheet ends first** (`prepareForQuit`, `prepareToClose`, `cancel`): AuthenticationServices' or AppSSO's
///   remote sheet still attached to a window is ended before every quit (Airc's Quit menu item and hold ⌘Q, the quit
///   Apple Event of the Dock or a logout, and in applicationShouldTerminate for the rest), before its window closes,
///   and when its page's tab closes or Airc loads another address in it. AppKit holds a quit that arrives while Airc is
///   in the background with such a sheet before it asks the app delegate, so the sheet ends before AppKit's terminate.
///   Airc's own sheets (alerts, save panels) are never touched.
/// - **With the passkey capability** (mode "pass"), a page's passkey requests go to WebKit with an abort signal of
///   Airc's own joined to the page's, and the same moments abort them first (the page sees AbortError), so a request
///   WebKit keeps open can't hold anything either. Without it (mode "native", every build until the owner's capability
///   step) no page script is added: WebKit's own answer stands.
enum WebKitPasskeyGuard {
    /// "native": no capability (WebKit answers passkey requests itself). "pass": the capability (requests tracked).
    static let mode: String = {
        #if AIRC_TESTING
        // passkeyquit's arms, test builds only. "pass": an entitled build's tracking, in a test build. "sso": as native,
        // but Sign In With Apple's SSO extension keeps WebKit's policy, so its sheet comes and the ending path is proved.
        // "off": nothing of this file runs, as before wkpasskeyquit.
        if let m = ProcessInfo.processInfo.environment["AIRC_TEST_PASSKEY_GUARD"], ["native", "pass", "sso", "off"].contains(m) { return m }
        #endif
        return WebKitPasskeyNotice.entitled ? "pass" : "native"
    }()

    static var off: Bool { mode == "off" }

    /// The page part (mode "pass" only). Installed before signinfix's notice watcher and watchfix's agent part, so they
    /// wrap it and see the page's own options.
    static let script = """
    (function(){
      if (Object.prototype.hasOwnProperty.call(window, '__aircPasskeyCancel')) return;
      var P = window.CredentialsContainer && CredentialsContainer.prototype;
      if (!P || typeof P.get !== 'function' || typeof P.create !== 'function') return;
      var live = new Set();
      function like(f, original) {
        try { Object.defineProperty(f, 'toString', { value: function () { return Function.prototype.toString.call(original); } }); } catch (e) {}
        return f;
      }
      function reasonOf(signal) {
        return signal && signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
      }
      // To WebKit with Airc's own abort signal joined to the page's, so Airc can end it (cancel below).
      function wrap(original) {
        return like(function (options) {
          var pk = false;
          try { pk = !!(options && options.publicKey); } catch (e) {}
          if (!pk) return original.apply(this, arguments);
          var page = options.signal, ours = new AbortController();
          if (page) {
            if (page.aborted) return original.call(this, options);
            try { page.addEventListener('abort', function () { ours.abort(reasonOf(page)); }, { once: true }); } catch (e) {}
          }
          var copy = {};
          for (var k in options) copy[k] = options[k];
          copy.signal = ours.signal;
          var p = original.call(this, copy);
          live.add(ours);
          function settle() { live.delete(ours); }
          Promise.resolve(p).then(settle, settle);
          return p;
        }, original);
      }
      P.get = wrap(P.get);
      P.create = wrap(P.create);
      // Airc ends this page's requests (quit, tab or window closing), and so does leaving the page.
      function cancel() {
        var n = live.size;
        live.forEach(function (c) { try { c.abort(new DOMException('The page is closing.', 'AbortError')); } catch (e) {} });
        live.clear();
        return n;
      }
      try { Object.defineProperty(window, '__aircPasskeyCancel', { value: cancel }); } catch (e) {}
      addEventListener('pagehide', cancel);
    })();
    """

    static func install(in userContent: WKUserContentController) {
        guard mode == "pass" else { return }
        userContent.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    // MARK: Ending requests and sheets

    /// Every open WebKit page (ScriptRouter.register adds each).
    private static let tabs = NSHashTable<WebKitTab>.weakObjects()
    static func register(_ tab: WebKitTab) { tabs.add(tab) }

    /// What the last ending did, for logs and checks.
    nonisolated(unsafe) static var lastReport = ""

    /// `page` is closing or loading another address: a system sheet on the window that shows it ends now, and its
    /// passkey requests are aborted (mode "pass").
    static func cancel(_ page: WebKitTab, reason: String) {
        guard !off else { return }
        if let window = page.webView.window {
            let ended = endSystemSheets(on: window)
            if ended > 0 { lastReport = "\(reason): ended \(ended) sheet(s)" }
        }
        guard mode == "pass" else { return }
        page.webView.evaluateJavaScript("typeof window.__aircPasskeyCancel === 'function' ? window.__aircPasskeyCancel() : 0") { v, _ in
            let n = (v as? NSNumber)?.intValue ?? 0
            if n > 0 { lastReport = "\(reason): aborted \(n) passkey request(s)" }
        }
    }

    /// Before the app quits: system sheets end now (synchronously, so a quit never waits on a page), and every page's
    /// passkey requests are aborted. Returns the sheets ended.
    @discardableResult
    static func prepareForQuit() -> Int {
        guard !off else { return 0 }
        if mode == "pass" { for t in tabs.allObjects where !t.isClosed { cancel(t, reason: "quit") } }
        let ended = NSApp.windows.reduce(0) { $0 + endSystemSheets(on: $1) }
        if ended > 0 { lastReport = "quit: ended \(ended) sheet(s)" }
        #if AIRC_TESTING
        QuitDiagnostics.mark("passkey guard: ended \(ended) system sheet(s)")
        #endif
        return ended
    }

    /// Before a browser window closes: the same for its pages and its window.
    static func prepareToClose(_ window: NSWindow) {
        guard !off else { return }
        for t in tabs.allObjects where !t.isClosed && t.webView.window === window { cancel(t, reason: "window") }
        if endSystemSheets(on: window) > 0 { lastReport = "window: ended a sheet" }
    }

    /// Ends a system sheet attached to `window` (and one attached to that sheet). Returns how many.
    @discardableResult
    static func endSystemSheets(on window: NSWindow) -> Int {
        guard let sheet = window.attachedSheet, isSystemPasskeySheet(sheet) else { return 0 }
        let inner = endSystemSheets(on: sheet)
        window.endSheet(sheet)
        sheet.orderOut(nil)
        return inner + 1
    }

    static func isSystemPasskeySheet(_ sheet: NSWindow) -> Bool {
        // Never one of Airc's own (an alert, a save panel), which have their own answers.
        if sheet is NSPanel { return false }
        // AuthenticationServices' passkey UI and AppSSO's SSO UI: remote views of a system service in a plain NSWindow.
        let marks = ["AuthenticationServices", "ASCAuthorization", "ASAuthorization", "AppSSO", "SOUIAuthorization",
                     "SOAuthorization", "NSRemoteView", "ViewBridge"]
        return describe(sheet).contains { name in marks.contains { name.contains($0) } }
    }

    /// Class names of the sheet, its controller (and its framework) and its views (four levels): how a sheet is
    /// recognised, and the log.
    static func describe(_ sheet: NSWindow) -> [String] {
        var names = [NSStringFromClass(type(of: sheet))]
        if let vc = sheet.contentViewController {
            names.append(NSStringFromClass(type(of: vc)))
            if let path = Bundle(for: type(of: vc)).bundlePath.split(separator: "/").last { names.append(String(path)) }
        }
        func walk(_ v: NSView?, _ depth: Int) {
            guard let v, depth < 4 else { return }
            names.append(NSStringFromClass(type(of: v)))
            v.subviews.forEach { walk($0, depth + 1) }
        }
        walk(sheet.contentView, 0)
        return names
    }
}

// MARK: Sign In With Apple's SSO extension (Extensible SSO)

/// WebKit asks its navigation delegate before an SSO extension takes a load (WKNavigationDelegatePrivate). For
/// appleid.apple.com it names macOS's "Sign In With Apple" extension with policy Allow (buildmac, macOS 26.6).
extension WebKitPasskeyGuard {
    /// `_WKSOAuthorizationLoadPolicy`: Allow 0, Ignore 1.
    static let ssoAllow = 0, ssoIgnore = 1

    /// The loads WebKit asked about (last 20), for logs and checks.
    nonisolated(unsafe) static var ssoLoads: [String] = []

    /// macOS's own Apple Account sign-in extension. WebKit passes its display name ("Sign In With Apple"); a bundle
    /// identifier is matched too.
    static func isAppleIDExtension(_ ext: String?) -> Bool {
        guard let ext = ext?.lowercased() else { return false }
        return ext.contains("sign in with apple") || (ext.hasPrefix("com.apple.") && ext.contains("appleid"))
    }

    static func ssoPolicy(current: Int, extension ext: String?, host: String?) -> Int {
        let ignore = (mode == "native" || mode == "pass") && current == ssoAllow && isAppleIDExtension(ext)
        let answer = ignore ? ssoIgnore : current
        ssoLoads = Array((ssoLoads + ["\(host ?? "-"): extension \(ext ?? "-"), policy \(current) → \(answer)"]).suffix(20))
        return answer
    }
}

extension WebKitTab {
    @objc(_webView:decidePolicyForSOAuthorizationLoadWithCurrentPolicy:forExtension:completionHandler:)
    func aircSOAuthorizationLoad(_ webView: WKWebView, policy: Int, forExtension ext: String?,
                                 completionHandler: @escaping (Int) -> Void) {
        completionHandler(WebKitPasskeyGuard.ssoPolicy(current: policy, extension: ext, host: webView.url?.host))
    }
}

// MARK: Quitting

extension WebKitPasskeyGuard {
    /// AppKit's own quit Apple Event handler (the Dock's Quit, a logout or restart, another app's "quit"), wrapped.
    nonisolated(unsafe) private static var appKitQuit: AEEventHandlerUPP?
    nonisolated(unsafe) private static var appKitQuitRefcon: UnsafeMutableRawPointer?

    /// Wraps AppKit's quit Apple Event handler so a system sheet ends before it runs. With Airc in the background and a
    /// remote sheet attached, AppKit holds that quit before the app delegate is asked (passkeyquit QUIT=ae, sso arm:
    /// 17.7 s, the bound). AppKit's handler itself still runs, unchanged, with its own reply (a logout Airc cancels
    /// still says so). Call once AppKit has installed it (didFinishLaunching); does nothing if it can't be found.
    static func wrapQuitAppleEvent() {
        guard !off, appKitQuit == nil else { return }
        var handler: AEEventHandlerUPP?
        var refcon: UnsafeMutableRawPointer?
        let klass = AEEventClass(kCoreEventClass), quit = AEEventID(kAEQuitApplication)
        guard AEGetEventHandler(klass, quit, &handler, &refcon, false) == noErr, let handler else { return }
        appKitQuit = handler
        appKitQuitRefcon = refcon
        let wrapped: AEEventHandlerUPP = { event, reply, _ in
            MainActor.assumeIsolated { _ = WebKitPasskeyGuard.prepareForQuit() }
            guard let original = WebKitPasskeyGuard.appKitQuit else { return OSErr(errAEEventNotHandled) }
            return original(event, reply, WebKitPasskeyGuard.appKitQuitRefcon)
        }
        if AEInstallEventHandler(klass, quit, wrapped, nil, false) != noErr { appKitQuit = nil }
    }
}

extension NSApplication {
    /// Airc's Quit (the menu item, hold ⌘Q): a system sheet still attached to a window ends first, then the usual
    /// terminate. With Airc in the background and AppSSO's remote sheet attached, AppKit holds a terminate before it
    /// asks the app delegate (passkeyquit's before arm: no applicationShouldTerminate, the quit bound after 17 s), so
    /// ending the sheet in applicationShouldTerminate alone would be too late; that call stays for quits that reach it.
    @objc func aircQuit(_ sender: Any?) {
        WebKitPasskeyGuard.prepareForQuit()
        terminate(sender)
    }
}
