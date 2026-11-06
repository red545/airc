// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// Which Google accounts a profile is signed in to, read from that profile's own cookies: Google's ListAccounts answer
/// (the list Chromium's GaiaCookieManagerService keeps for a profile's cookie jar), loaded in a hidden tab of that
/// profile, one profile at a time. Onboarding's accounts step asks for every profile that existed before the import
/// (a new one has no cookies yet) and again after a sign-in window closes, however it closed, so an account signed in
/// earlier, or a sign-in that ended on another Google page, still shows.
///
/// Engine-neutral (a tab and its page text), so it works the same on WebKit and Chromium. The answer stays on this Mac:
/// the caller keeps the email in the profile (`Profile.googleAccount`); it is never logged or sent to telemetry.
final class GoogleAccountProbe: NSObject, EngineWindowDelegate, EngineTabDelegate {
    /// nil: no answer (offline, timed out, not Google's list); []: nobody is signed in.
    typealias Completion = ([GoogleAccount]?) -> Void

    #if AIRC_TESTING
    /// The checks point this at a loopback mock; never a real Google account.
    static var testURL: URL?
    #endif

    /// Google's list, or the checks' mock. Automated runs never ask Google.
    static var listAccountsURL: URL? {
        #if AIRC_TESTING
        if let testURL { return testURL }
        if LaunchOptions.current.isAutomated { return nil }
        #endif
        return SignInWindowController.listAccountsURL
    }

    static let timeout: TimeInterval = 8

    private let engine: BrowserEngine
    private var window: EngineWindow?
    private var queue: [(profile: EngineProfile, done: Completion)] = []
    private var current: (tab: EngineTab, done: Completion, url: URL)?
    private var timer: Timer?
    private var reading = false

    init(engine: BrowserEngine) {
        self.engine = engine
    }

    /// Reads `profile`'s accounts. Completion on the main queue.
    func read(_ profile: EngineProfile, completion: @escaping Completion) {
        guard Self.listAccountsURL != nil else { return completion(nil) }
        queue.append((profile, completion))
        pump()
    }

    /// Stops: the pending reads answer nil, the hidden window goes.
    func cancel() {
        let pending = queue
        queue = []
        finish(nil)
        pending.forEach { $0.done(nil) }
        window?.window.orderOut(nil)
        window = nil
    }

    private func pump() {
        guard current == nil, !queue.isEmpty, let url = Self.listAccountsURL else { return }
        let next = queue.removeFirst()
        let w = window ?? {
            // Never shown: a page view nobody sees, so nothing is drawn and nothing takes focus.
            let w = engine.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300))
            w.delegate = self
            window = w
            return w
        }()
        reading = false
        let tab = w.openTab(url: url, profile: next.profile, foreground: false)
        tab.delegate = self
        current = (tab, next.done, url)
        // Loading callbacks for a tab nobody shows aren't guaranteed on every engine: look every quarter second too.
        let deadline = Date().addingTimeInterval(Self.timeout)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            if Date() > deadline { self?.finish(nil) } else { self?.check() }
        }
    }

    private func finish(_ result: [GoogleAccount]?) {
        timer?.invalidate()
        timer = nil
        guard let c = current else { return }
        current = nil
        c.tab.delegate = nil
        c.tab.close()
        c.done(result)
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }

    // MARK: Engine callbacks

    private func check() {
        guard let c = current, !reading, !c.tab.isLoading, c.tab.url?.path == c.url.path else { return }
        let t = c.tab
        reading = true
        // Google's answer is JSON shown as the page's text (a JSON viewer may add words around it; the parser finds it).
        t.evaluate("(document.querySelector('pre') || document.body || {}).innerText || ''") { [weak self] value in
            guard let self, self.current?.tab === t else { return }
            if let accounts = GoogleAccounts.accounts(fromListAccounts: value as? String ?? "") {
                self.finish(accounts)
            } else {
                self.reading = false   // not drawn yet, or not Google's list: look again until the deadline
            }
        }
    }

    func tabDidChangeLoading(_ t: EngineTab) {
        if t === current?.tab { check() }
    }

    func tabDidChangeURL(_ tab: EngineTab) {}
    func tabDidChangeTitle(_ tab: EngineTab) {}
    func tabDidChangeFavicon(_ tab: EngineTab) {}
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}

    // The list opens nothing; anything that tries is closed.
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) { tab.close() }
    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {}
    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}
}

/// A Google account's picture, fetched without cookies from Google's image host (https only) and kept in memory.
enum GoogleAccountPhoto {
    private static var cache: [String: CGImage] = [:]

    static func load(_ address: String?, completion: @escaping (CGImage?) -> Void) {
        guard let address, let url = URL(string: address), allowed(url) else { return completion(nil) }
        if let hit = cache[address] { return completion(hit) }
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            DispatchQueue.main.async {
                if let image { cache[address] = image }
                completion(image)
            }
            session.finishTasksAndInvalidate()
        }.resume()
    }

    private static func allowed(_ url: URL) -> Bool {
        #if AIRC_TESTING
        // The checks' mock serves its picture from a scratch file.
        if url.isFileURL, LaunchOptions.current.isAutomated { return true }
        #endif
        return url.scheme == "https"
    }
}
