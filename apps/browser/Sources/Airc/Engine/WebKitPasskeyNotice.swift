// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import WebKit

/// signinfix: WebKit pages can use passkeys only when Apple grants the app its managed browser capability
/// (`com.apple.developer.web-browser.public-key-credential`, engine/PASSKEYS.md). Without it every `get` and `create`
/// fails at once with NotAllowedError and no sheet, so a site's "Sign in with a passkey" did nothing you could see.
/// In a build without the capability, a small page script tells Airc when that happens, and the window says why
/// (BlockedPopupNotice.swift shows it). Builds with the capability install nothing.
enum WebKitPasskeyNotice {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// The running app has the capability (checked once).
    static let entitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (value as? Bool) == true || (value as? NSNumber)?.boolValue == true
    }()

    static let messageName = "aircPasskeyUnavailable"
    /// Posted on the main queue with the tab (object) whose page's passkey request failed for that reason.
    static let didFail = Notification.Name("AircWebKitPasskeyUnavailable")

    /// Watches the page's own passkey requests (not conditional autofill ones, which never show anything): one that
    /// fails with NotAllowedError (or NotSupportedError) within 1.5 s, as without the capability, is reported. Every frame (a sign-in frame).
    static let script = """
    (function(){
      if (window.__aircPasskeyWatch) return;
      window.__aircPasskeyWatch = 'pending';
      function report(kind) {
        try { window.webkit.messageHandlers.\(messageName).postMessage(kind); } catch (_) {}
      }
      try {
        // The prototype's methods (WebIDL: writable, configurable), so every container of the page is covered, even
        // one made after this ran. Not gated on PublicKeyCredential: WebKit may expose it and still reject.
        const proto = window.CredentialsContainer && CredentialsContainer.prototype;
        if (!proto) { window.__aircPasskeyWatch = 'no CredentialsContainer'; return; }
        for (const name of ['get', 'create']) {
          const original = proto[name];
          if (typeof original !== 'function') continue;
          proto[name] = function(options) {
            const p = original.apply(this, arguments);
            if (options && options.publicKey && options.mediation !== 'conditional') {
              const t = Date.now();
              p.catch(function(e) {
                if (e && (e.name === 'NotAllowedError' || e.name === 'NotSupportedError') && Date.now() - t < 1500) report(name);
              });
            }
            return p;
          };
        }
        window.__aircPasskeyWatch = 'on';
      } catch (e) {
        window.__aircPasskeyWatch = 'failed: ' + e;
      }
    })();
    """

    static func install(in userContent: WKUserContentController, router: WKScriptMessageHandler) {
        guard !entitled else { return }
        userContent.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContent.add(router, name: messageName)
    }
}
