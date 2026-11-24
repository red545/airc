// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// "Sign in with Google" for one profile (onboarding step 3, SP-12): Google's sign-in page in a small window, in
/// that profile, so the login lands in that profile's cookies. When Google sends the user on to their account page,
/// the window reads which account is signed in (Google's own ListAccounts endpoint, as Chromium does) and closes. A
/// sign-in that ends elsewhere (a passkey offer, a security check) is still seen: onboarding reads the profile's
/// accounts again whenever this window closes (GoogleAccountProbe). `switching` opens Google's account chooser, to
/// sign in to another account.
final class SignInWindowController: NSObject, NSWindowDelegate, EngineWindowDelegate, EngineTabDelegate {
    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmyaccount.google.com%2F&hl=en")!
    static let switchURL = URL(string: "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fmyaccount.google.com%2F&hl=en")!
    static let listAccountsURL = URL(string: "https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard")!

    private let engineWindow: EngineWindow
    private let profile: EngineProfile
    private var startURL: URL
    #if AIRC_TESTING
    /// The checks' loopback sign-in page (never Google's).
    static var testStartURL: URL?
    #endif
    private var tab: EngineTab?
    private var reading = false
    private var finished = false
    /// The signed-in account (the profile's primary one), or nil if the window was closed first.
    var onFinish: ((GoogleAccount?) -> Void)?

    init(engine: BrowserEngine, profile: EngineProfile, profileName: String, switching: Bool = false) {
        self.profile = profile
        startURL = switching ? Self.switchURL : Self.signInURL
        #if AIRC_TESTING
        if let mock = Self.testStartURL { startURL = mock }
        #endif
        engineWindow = engine.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640))
        super.init()
        let w = engineWindow.window
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.title = (switching ? "Switch Google account · " : "Sign in to Google · ") + profileName
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
        let t = engineWindow.openTab(url: startURL, profile: profile, foreground: true)
        t.delegate = self
        tab = t
        w.makeKeyAndOrderFront(nil)
    }

    private func done(_ account: GoogleAccount?) {
        guard !finished else { return }
        finished = true
        onFinish?(account)
        tab?.close()
        engineWindow.window.orderOut(nil)
    }

    var window: NSWindow { engineWindow.window }
    /// The page the window shows (the checks read it).
    var page: EngineTab? { tab }

    func bringForward() { engineWindow.window.makeKeyAndOrderFront(nil) }

    /// Closes the window without an answer (the onboarding window was closed).
    func close() { done(nil) }

    func windowWillClose(_ notification: Notification) { done(nil) }

    // MARK: Engine callbacks

    func tabDidChangeURL(_ t: EngineTab) {
        if t !== tab {
            guard let url = t.url, url.scheme != "about" else { return }
            tab?.load(url)
            return t.close()
        }
        guard let url = t.url, let host = url.host?.lowercased() else { return }
        if host == "myaccount.google.com", !reading {
            reading = true
            t.load(Self.listAccountsURL)
        }
    }

    func tabDidChangeLoading(_ t: EngineTab) {
        guard reading, !t.isLoading, t.url?.path == "/ListAccounts" else { return }
        t.evaluate("(document.querySelector('pre') || document.body || {}).innerText || ''") { [weak self] value in
            self?.done(GoogleAccounts.accounts(fromListAccounts: value as? String ?? "")?.first)
        }
    }

    func tabDidChangeTitle(_ tab: EngineTab) {}
    func tabDidChangeFavicon(_ tab: EngineTab) {}
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}

    // Sign-in popups (passkeys, "use another account") stay in this window's one tab.
    // signinfix: a pop-up whose address isn't known yet (window.open() then a navigation) waits for its first address
    // instead of being closed unseen.
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        if let url = tab.url, url.scheme != "about" {
            self.tab?.load(url)
            return tab.close()
        }
        tab.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if !tab.isClosed { tab.close() } }
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {}
    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}
}

/// signinfix: Settings › Profiles' Sign In… for a profile no Space uses (no sidebar card can sign it in): Google's
/// sign-in in its own small window, in that profile, as onboarding does; the account it ends on is kept on the profile.
enum SettingsSignIn {
    /// The window now open (one at a time; a second press brings it forward).
    private(set) static var current: SignInWindowController?

    static func begin(profile: Profile, app: AppDelegate, over parent: NSWindow?) {
        if let current { return current.bringForward() }
        let pid = profile.id
        app.profiles.whenLoaded(pid, { engineProfile in
            guard current == nil else { return }
            let s = SignInWindowController(engine: app.engine, profile: engineProfile, profileName: profile.name,
                                           switching: profile.googleAccount != nil)
            current = s
            s.onFinish = { account in
                current = nil
                if let account { try? app.store.keepGoogleAccount(pid, account: account, index: 0) }
            }
            s.show(over: parent ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? s.window)
        }, failed: {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open \(profile.name) to sign in"
            alert.informativeText = "Try again in a moment. If it keeps happening, quit and reopen Airc."
            if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
        })
    }
}
