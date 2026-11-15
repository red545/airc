// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// What WebKit's own WebAuthn does inside an app like Airc's WebKit engine (a WKWebView in an app that is not
// Safari and lacks Apple's managed browser-passkey entitlement). Loopback page only, scratch data store.
// Usage: webkit-probe URL REPORT. Each request is aborted after a few seconds, so a system sheet, if WebKit shows
// one, closes by itself; nothing here presses a button.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3, let pageURL = URL(string: args[1]) else { exit(64) }

final class Probe: NSObject, WKNavigationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 760, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let web: WKWebView
    var report: [String: Any] = [:]
    let url: URL
    let reportPath: String

    init(url: URL, reportPath: String) {
        self.url = url
        self.reportPath = reportPath
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: window.contentView!.bounds, configuration: config)
        super.init()
        window.title = "Airc WebKit passkey probe"
        window.contentView!.addSubview(web)
        web.navigationDelegate = self
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.finish("probe timeout") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.run() }
    }

    @MainActor func js(_ body: String) async -> Any? {
        do { return try await web.callAsyncJavaScript(body, contentWorld: .page) } catch { return "js error: \(error)" }
    }

    @MainActor func run() async {
        report["windowKey"] = window.isKeyWindow
        report["appActive"] = NSApp.isActive
        report["page"] = await js("return {origin: location.origin, secure: isSecureContext, focused: document.hasFocus()}")
        report["availability"] = await js("""
            return {
              publicKeyCredential: typeof PublicKeyCredential,
              userVerifyingPlatformAuthenticator: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
              conditionalMediation: PublicKeyCredential.isConditionalMediationAvailable
                ? await PublicKeyCredential.isConditionalMediationAvailable() : 'missing'
            }
            """)
        // callAsyncJavaScript runs with a user gesture, like a click on the page's button.
        report["create"] = await js("""
            const signal = AbortSignal.timeout(8000);
            try {
              const c = await navigator.credentials.create({signal, publicKey: {
                challenge: crypto.getRandomValues(new Uint8Array(32)), rp: {name: 'Airc fixture'},
                user: {id: new Uint8Array([7, 8, 9]), name: 'fixture@example.com', displayName: 'Fixture'},
                pubKeyCredParams: [{type: 'public-key', alg: -7}],
                authenticatorSelection: {residentKey: 'required', userVerification: 'preferred'}}});
              return {result: 'created', type: c.type};
            } catch (e) { return {error: e.name, message: e.message}; }
            """)
        report["getModal"] = await js("""
            try {
              await navigator.credentials.get({signal: AbortSignal.timeout(6000),
                publicKey: {challenge: crypto.getRandomValues(new Uint8Array(32)), userVerification: 'preferred'}});
              return {result: 'asserted'};
            } catch (e) { return {error: e.name, message: e.message}; }
            """)
        report["getConditional"] = await js("""
            try {
              await navigator.credentials.get({mediation: 'conditional', signal: AbortSignal.timeout(3000),
                publicKey: {challenge: crypto.getRandomValues(new Uint8Array(32))}});
              return {result: 'asserted'};
            } catch (e) { return {error: e.name, message: e.message}; }
            """)
        finish(nil)
    }

    func finish(_ error: String?) {
        report["error"] = error ?? ""
        report["pid"] = getpid()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: reportPath, contents: data)
        }
        exit(error == nil ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = Probe(url: pageURL, reportPath: args[2])
DispatchQueue.main.async { probe.start() }
app.run()
