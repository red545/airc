// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// "Sign in with Google" for one profile (onboarding step 3, SP-12): Google's sign-in page in a small window, in
/// that profile, so the login lands in that profile's cookies. When Google sends the user on to their account page,
/// the window reads which account is signed in (Google's own ListAccounts endpoint, as Chromium does) and closes.
final class SignInWindowController: NSObject, NSWindowDelegate, EngineWindowDelegate, EngineTabDelegate {
    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmyaccount.google.com%2F&hl=en")!
    static let listAccountsURL = URL(string: "https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard")!

    private let engineWindow: EngineWindow
    private let profile: EngineProfile
    private var tab: EngineTab?
    private var reading = false
    private var finished = false
    /// The signed-in account's email, or nil if the window was closed first.
    var onFinish: ((String?) -> Void)?

    init(engine: BrowserEngine, profile: EngineProfile, profileName: String) {
        self.profile = profile
        engineWindow = engine.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640))
        super.init()
        let w = engineWindow.window
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.title = "Sign in to Google · \(profileName)"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: w.contentLayoutRect.size))
        content.wantsLayer = true
        let host = engineWindow.hostView
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        w.contentView = content
        engineWindow.delegate = self
        engineWindow.activeProfile = profile
    }

    func show(over parent: NSWindow) {
        let w = engineWindow.window
        let f = parent.frame
        w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
        let t = engineWindow.openTab(url: Self.signInURL, profile: profile, foreground: true)
        t.delegate = self
        tab = t
        w.makeKeyAndOrderFront(nil)
    }

    private func done(_ email: String?) {
        guard !finished else { return }
        finished = true
        onFinish?(email)
        tab?.close()
        engineWindow.window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { done(nil) }

    // MARK: Engine callbacks

    func tabDidChangeURL(_ t: EngineTab) {
        guard let url = t.url, let host = url.host?.lowercased() else { return }
        if host == "myaccount.google.com", !reading {
            reading = true
            t.load(Self.listAccountsURL)
        }
    }

    func tabDidChangeLoading(_ t: EngineTab) {
        guard reading, !t.isLoading, t.url?.path == "/ListAccounts" else { return }
        t.evaluate("document.body ? document.body.innerText : ''") { [weak self] value in
            let email = GoogleAccounts.emails(fromListAccounts: value as? String ?? "").first
            self?.done(email)
        }
    }

    func tabDidChangeTitle(_ tab: EngineTab) {}
    func tabDidChangeFavicon(_ tab: EngineTab) {}
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}

    // Sign-in popups (passkeys, "use another account") stay in this window's one tab.
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        if let url = tab.url { self.tab?.load(url) }
        tab.close()
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {}
    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}
}
